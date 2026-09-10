"""
ai_forecast.py

Phase 3 (optional): trains a forecast model on the collected history and writes
hourly consumption/production predictions into the IncentiveController contract,
then submits the matching actuals once each slot has elapsed.

The model itself lives in forecast_model.py.

Two things this has to get right, both of which are easy to get wrong:

  1. The simulated clock. Training rows carry `sim_hour` from the simulator's
     virtual clock, which runs 15x real time and resets on every oracle_writer
     restart. Wall-clock time is NOT a substitute - using it trains on one clock
     and predicts on another. forecast_model.current_sim_hour() reconstructs it
     from the newest history row.

  2. Slot alignment. OracleStorage.currentSlot follows block.timestamp, not the
     number of updateSlot() calls, so slots skip whenever an oracle_writer pass
     overruns 60s. Never assume next == current + 1; track submitted slots and
     reconcile them when their meter data actually shows up.

Prerequisites:
  - oracle_writer.py running (fills data/history.db and OracleStorage)
  - .env with AI_PRIVATE_KEY, funded with Sepolia ETH
  - that address authorised via IncentiveController.authorizeAI()
  - web3 >= 7  (v6 uses rawTransaction / geth_poa_middleware and will not work)
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

# One simulated hour = 4 slots, which is the granularity the challenge asks for.
SLOTS_PER_SIM_HOUR = 4

# Submit a forecast this many slots ahead, so the transaction is mined before
# the slot it predicts has elapsed.
FORECAST_LEAD_SLOTS = 2

SLOT_SECONDS = 60

PRIVATE_KEY = os.getenv("AI_PRIVATE_KEY")
if not PRIVATE_KEY:
    print("ERROR: AI_PRIVATE_KEY not set in .env")
    print("Use a wallet separate from ORACLE_PRIVATE_KEY - sharing one makes the")
    print("two processes race on nonces and transactions get dropped.")
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────
#  On-chain helpers
# ─────────────────────────────────────────────────────────────────────

def send_tx(w3, account, fn, gas: int = 250_000) -> bool:
    """
    Dry-runs a call, then sends it. Returns True on success.

    The dry run costs nothing and turns a silent gas burn (e.g. "Not authorized
    AI") into an immediate, readable error.
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

    # Fail fast rather than discovering this via a burned transaction.
    if not incentive.functions.authorizedAI(account.address).call():
        print(f"\nERROR: {account.address} is not an authorised AI.")
        print("The IncentiveController owner must call authorizeAI() for it.")
        sys.exit(1)
    if balance == 0:
        print("\nERROR: wallet has no Sepolia ETH, transactions cannot be sent.")
        sys.exit(1)

    # ── train ────────────────────────────────────────────────────────

    households = fm.load_household_config(CONFIG_PATH)
    model = fm.train_from_db(config_path=CONFIG_PATH)
    filled, total = model.coverage()
    print(f"\nModel trained. Hour-bin coverage: {filled}/{total}")
    print(f"Production slope: {model.production_slope:.4f}\n")

    addr_of = {h_id: Web3.to_checksum_address(cfg["address"])
               for h_id, cfg in households.items()}

    # slot -> households whose actuals are still outstanding
    pending: Dict[int, Set[str]] = {}
    last_forecast_slot = -SLOTS_PER_SIM_HOUR

    # ── loop ─────────────────────────────────────────────────────────

    while True:
        cycle_start = time.time()
        try:
            current_slot = oracle.functions.getCurrentSlot().call()

            # ---- forecast, once per simulated hour ----
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

            # ---- reconcile actuals for elapsed slots ----
            # A forecast must exist before its actual, otherwise
            # _updateScoreForSlot() returns early and scoring silently no-ops.
            for slot in sorted(pending):
                if slot >= current_slot:
                    continue  # not finished yet

                still_waiting: Set[str] = set()
                for h_id in sorted(pending[slot]):
                    reading = oracle.functions.getMeterAtSlot(
                        addr_of[h_id], slot).call()
                    cons_wh, prod_wh = reading[0], reading[1]
                    if cons_wh == 0 and prod_wh == 0:
                        # Slot was skipped by the oracle writer - no data was
                        # ever written for it, so there is nothing to settle.
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
            # Raised by current_sim_hour() when history.db has gone stale.
            print(f"  {e}")
        except Exception as e:
            print(f"  error: {e}")

        time.sleep(max(0, SLOT_SECONDS - (time.time() - cycle_start)))


if __name__ == "__main__":
    main()
