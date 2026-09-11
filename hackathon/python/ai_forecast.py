"""
ai_forecast.py

Phase 3 (optional): Trainiert das Prognosemodell auf der gesammelten Historie,
schreibt stündliche Verbrauchs- und Erzeugungsprognosen in den
IncentiveController und reicht die zugehörigen Ist-Werte nach, sobald ein Slot
abgelaufen ist. Daraus berechnet der Contract Reputationsscore und Preisfaktor.

Das Modell selbst liegt in forecast_model.py.

Zwei Punkte, die dieses Skript korrekt treffen muss:

  1. Die simulierte Uhr. Die Trainingsdaten tragen `sim_hour` aus der virtuellen
     Uhr des Simulators. Diese läuft 15-fach beschleunigt und startet bei jedem
     Neustart von oracle_writer.py neu. Die reale Uhrzeit ist KEIN Ersatz -
     sonst wird auf der einen Uhr trainiert und auf der anderen prognostiziert.
     forecast_model.current_sim_hour() rekonstruiert sie aus der jüngsten Zeile
     der Historie.

  2. Slot-Ausrichtung. OracleStorage.currentSlot folgt block.timestamp, nicht der
     Anzahl der updateSlot()-Aufrufe. Slots werden also übersprungen, sobald ein
     Durchlauf von oracle_writer.py länger als 60s dauert. Niemals annehmen,
     dass der nächste Slot == aktueller + 1 ist: eingereichte Slots werden
     gemerkt und erst dann abgeglichen, wenn ihre Messwerte tatsächlich
     on-chain stehen.

Voraussetzungen:
  - oracle_writer.py läuft (füllt data/history.db und OracleStorage)
  - .env mit AI_PRIVATE_KEY, ausgestattet mit Sepolia-ETH
  - diese Adresse ist via IncentiveController.authorizeAI() autorisiert
  - web3 >= 7 (v6 nutzt rawTransaction / geth_poa_middleware, funktioniert nicht)
"""

import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Set

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

import forecast_model as fm

load_dotenv()

CONFIG_PATH = Path(__file__).parent / "config.json"
ABI_DIR = Path(__file__).parent / "abi"

# Eine simulierte Stunde = 4 Slots. Das ist die von der Challenge geforderte
# Prognosegranularität (stündlich = 4-Minuten-Intervall in der Simulation).
SLOTS_PER_SIM_HOUR = 4

# So viele Slots im Voraus wird prognostiziert, damit die Transaktion gemined
# ist, bevor der prognostizierte Slot abgelaufen ist.
FORECAST_LEAD_SLOTS = 2

SLOT_SECONDS = 60

PRIVATE_KEY = os.getenv("AI_PRIVATE_KEY")
if not PRIVATE_KEY:
    # Eigene Wallet nötig: teilen sich beide Prozesse einen Key, konkurrieren
    # sie um dieselbe Nonce und Transaktionen gehen verloren.
    print("ERROR: AI_PRIVATE_KEY not set in .env")
    print("Use a wallet separate from ORACLE_PRIVATE_KEY - sharing one makes the")
    print("two processes race on nonces and transactions get dropped.")
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────
#  On-Chain-Hilfsfunktionen
# ─────────────────────────────────────────────────────────────────────

def send_tx(w3, account, fn, gas: int = 250_000) -> bool:
    """
    Simuliert den Aufruf zuerst (Dry-Run) und sendet ihn dann. True = Erfolg.

    Der Dry-Run kostet nichts und verwandelt einen stillen Gas-Verlust
    (z.B. "Not authorized AI") in einen sofort lesbaren Fehler.
    """
    try:
        fn.call({"from": account.address})
    except Exception as e:
        print(f"    would revert, not sending: {e}")
        return False

    try:
        tx = fn.build_transaction({
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address, "pending"),
            "chainId": w3.eth.chain_id,
            "gas": gas,
            "maxFeePerGas": w3.to_wei("30", "gwei"),
            "maxPriorityFeePerGas": w3.to_wei("2", "gwei"),
        })
        signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        return receipt["status"] == 1
    except Exception as e:
        print(f"    tx failed: {e}")
        return False


# ─────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────

def main():
    with open(CONFIG_PATH) as f:
        config = json.load(f)

    bc = config["blockchain"]
    w3 = Web3(Web3.HTTPProvider(bc["rpc_url"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    account = w3.eth.account.from_key(PRIVATE_KEY)

    with open(ABI_DIR / "IncentiveController.json") as f:
        ic_abi = json.load(f)["abi"]
    with open(ABI_DIR / "OracleStorage.json") as f:
        oracle_abi = json.load(f)["abi"]

    incentive = w3.eth.contract(
        address=Web3.to_checksum_address(bc["incentive_controller_address"]),
        abi=ic_abi)
    oracle = w3.eth.contract(
        address=Web3.to_checksum_address(bc["oracle_storage_address"]),
        abi=oracle_abi)

    print(f"AI forecaster account: {account.address}")
    balance = w3.from_wei(w3.eth.get_balance(account.address), "ether")
    print(f"Sepolia balance      : {balance} ETH")

    # Früh scheitern, statt das Problem erst an einer verbrannten TX zu merken.
    if not incentive.functions.authorizedAI(account.address).call():
        print(f"\nERROR: {account.address} is not an authorised AI.")
        print("The IncentiveController owner must call authorizeAI() for it.")
        sys.exit(1)
    if balance == 0:
        print("\nERROR: wallet has no Sepolia ETH, transactions cannot be sent.")
        sys.exit(1)

    # ── Training ─────────────────────────────────────────────────────

    households = fm.load_household_config(CONFIG_PATH)
    model = fm.train_from_db(config_path=CONFIG_PATH)
    filled, total = model.coverage()
    print(f"\nModel trained. Hour-bin coverage: {filled}/{total}")
    print(f"Production slope: {model.production_slope:.4f}\n")

    addr_of = {h_id: Web3.to_checksum_address(cfg["address"])
               for h_id, cfg in households.items()}

    # Slot -> Haushalte, deren Ist-Werte noch ausstehen
    pending: Dict[int, Set[str]] = {}
    last_forecast_slot = -SLOTS_PER_SIM_HOUR

    # ── Hauptschleife ────────────────────────────────────────────────

    while True:
        cycle_start = time.time()
        try:
            current_slot = oracle.functions.getCurrentSlot().call()

            # ---- Prognose, einmal pro simulierter Stunde ----
            if current_slot - last_forecast_slot >= SLOTS_PER_SIM_HOUR:
                target_slot = current_slot + FORECAST_LEAD_SLOTS
                sim_now = fm.current_sim_hour()
                target_hour = fm.sim_hour_after_slots(sim_now, FORECAST_LEAD_SLOTS)
                irradiance = model.estimate_irradiance(target_hour)

                print(f"\n→ Forecast for slot {target_slot} "
                      f"(sim_hour {target_hour:.2f}, est. {irradiance:.0f} W/m2)")

                submitted: Set[str] = set()
                for h_id in households:
                    cons, prod, conf = model.predict(h_id, target_hour)
                    if conf == "fallback":
                        print(f"  {h_id}: no data for this hour, skipping")
                        continue
                    print(f"  {h_id}: cons={cons:.0f}Wh prod={prod:.0f}Wh [{conf}]")
                    ok = send_tx(w3, account, incentive.functions.submitForecast(
                        addr_of[h_id], target_slot, int(cons), int(prod)))
                    if ok:
                        submitted.add(h_id)

                if submitted:
                    pending[target_slot] = submitted
                last_forecast_slot = current_slot

            # ---- Ist-Werte abgelaufener Slots nachreichen ----
            # Die Prognose muss vor dem Ist-Wert on-chain stehen, sonst bricht
            # _updateScoreForSlot() früh ab und es wird still nichts bewertet.
            for slot in sorted(pending):
                if slot >= current_slot:
                    continue  # Slot läuft noch

                still_waiting: Set[str] = set()
                for h_id in sorted(pending[slot]):
                    reading = oracle.functions.getMeterAtSlot(
                        addr_of[h_id], slot).call()
                    cons_wh, prod_wh = reading[0], reading[1]
                    if cons_wh == 0 and prod_wh == 0:
                        # Slot wurde vom Oracle-Writer übersprungen - es wurden
                        # nie Messwerte geschrieben, also gibt es nichts zu
                        # bewerten.
                        continue
                    print(f"  actual slot {slot} {h_id}: "
                          f"cons={cons_wh}Wh prod={prod_wh}Wh")
                    if not send_tx(w3, account, incentive.functions.submitActual(
                            addr_of[h_id], slot, cons_wh, prod_wh)):
                        still_waiting.add(h_id)

                if still_waiting:
                    pending[slot] = still_waiting
                else:
                    del pending[slot]

        except RuntimeError as e:
            # Wird von current_sim_hour() geworfen, wenn history.db veraltet ist
            # (= oracle_writer.py läuft nicht).
            print(f"  {e}")
        except Exception as e:
            print(f"  error: {e}")

        time.sleep(max(0, SLOT_SECONDS - (time.time() - cycle_start)))


if __name__ == "__main__":
    main()
