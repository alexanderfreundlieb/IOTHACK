# Phase 1 – Peer-to-Peer Energy Payment

Automatisierte Abrechnung der Energieflüsse zwischen Haushalten über Smart
Contracts auf Sepolia, bezahlt in einem ERC-20-Stablecoin.

Beteiligte Dateien: [`contracts/P2PEnergyMarket.sol`](../contracts/P2PEnergyMarket.sol),
[`contracts/OracleStorage.sol`](../contracts/OracleStorage.sol),
[`python/oracle_writer.py`](../python/oracle_writer.py),
[`python/settlement_trigger.py`](../python/settlement_trigger.py).

## Oracle-Anbindung

Blockchains haben keinen Zugriff auf externe Daten, deshalb der Umweg über ein
Oracle:

1. `data_simulator.py` erzeugt je Slot Verbrauch und PV-Erzeugung pro Haushalt.
2. `oracle_writer.py` schreibt sie mit der autorisierten Oracle-Wallet on-chain:
   `updateSlot()`, `updateWeather()` und je Haushalt `updateMeter()` sowie
   – sofern eine Batterie vorhanden ist – `updateBattery()`.
3. `OracleStorage` speichert Letztwert und Historie (`meterHistory[haushalt][slot]`)
   und emittiert je Schreibvorgang ein Event.
4. `P2PEnergyMarket` liest die Werte über `IOracleStorage` und rechnet ab.

Schreibzugriff hat ausschliesslich, wer in `authorizedOracles` steht; das
erfüllt die Anforderung „nur autorisierte Oracle-Adressen dürfen Daten
einspeisen“. Lesen darf jeder.

## Ablauf von `settleSlot()`

Ausgelöst von `settlement_trigger.py` einmal pro Slot:

1. **Slot prüfen.** `currentSlot` aus dem Oracle lesen und gegen
   `lastSettledSlot` prüfen – jeder Slot wird höchstens einmal abgerechnet.
2. **Netto je Haushalt.** `netto = productionWh - consumptionWh` aus dem
   jüngsten Messwert. Der Eigenverbrauch ist damit implizit bereits abgezogen.
3. **Batterie einrechnen** (Phase 2, nur wenn `batteryManager` gesetzt ist):
   `CHARGE` verringert das handelbare Netto, `DISCHARGE` erhöht es. Details in
   [PHASE2_BATTERIE_WETTER.md](PHASE2_BATTERIE_WETTER.md).
4. **Klassifizieren.** Netto > 0 ergibt einen Produzenten mit Überschuss,
   Netto < 0 einen Konsumenten mit Defizit.
5. **Matching.** Proportionale Verteilung: jeder Produzent liefert an jeden
   Konsumenten anteilig zu dessen Defizit.

   ```
   flow(i -> j) = surplus_i * deficit_j / totalDeficit
   ```

   Eine ausgeglichene Energiebilanz wird bewusst nicht verlangt – Energie kann
   ungenutzt bleiben, deshalb ist die entsprechende Bilanzprüfung im Code
   auskommentiert und nicht aktiv.
6. **Preis und Transfer** je Match in `_executeTrade()`:

   ```
   amountPaid = flowWh * pricePerKwh / 1000        // Wh -> kWh
   stablecoin.transferFrom(konsument, produzent, amountPaid)
   ```

   Der Konsument muss vorher `approve()` auf dem Stablecoin aufgerufen haben.
7. **Events.** `EnergyTraded` je Match, `SlotSettled` am Slot-Ende.

## Preisbildung

| Grösse | Wert |
|--------|------|
| `energyPricePerKwh` | 100'000 Token-Units pro kWh = 0.10 Token/kWh |
| Stablecoin-Decimals | 6 (1 Token = 1'000'000 Units) |
| Änderbar über | `setEnergyPrice()`, nur Owner, emittiert `PriceUpdated` |

In Phase 3 wird dieser Basispreis pro Trade mit dem Multiplikator des
Konsumenten skaliert. `calculateCost()` bleibt als Vorschau-Helfer für den
unveränderten Basispreis bestehen und wird von der Abrechnung nicht benutzt.

## Robustheit

| Risiko | Massnahme |
|--------|-----------|
| Doppelabrechnung eines Slots | `require(currentSlot > lastSettledSlot)` |
| Reentrancy über den Token | `lastSettledSlot` wird vor der Transfer-Schleife gesetzt |
| Konsument ohne `approve()` | Einzelner Trade in `try/catch`, der Slot läuft weiter |
| „Stack too deep“ | Preisberechnung und Transfer sind in `_executeTrade()` ausgelagert; der Aufruf ist über `require(msg.sender == address(this))` abgesichert |
| Batterie-Call revertet | `isManaged()`-Prüfung plus `try/catch` |

## Demo-Nachweis

- **Haushalte:** vier konfiguriert (`house_01` bis `house_04`), zwei davon mit
  PV und Batterie, zwei reine Konsumenten – mehr als die geforderten drei.
- **Abrechnungszyklen:** `settlement_trigger.py` rechnet einen Slot pro Minute
  ab; fünf Zyklen entsprechen fünf Minuten Laufzeit.
- **Belege:** `SlotSettled`- und `EnergyTraded`-Events des P2PEnergyMarket auf
  Sepolia Etherscan, zusätzlich live im Dashboard `p2p-energy-dashboard.html`.

## Lieferobjekte

| Anforderung | Stand |
|-------------|-------|
| Solidity Smart Contract (P2P + Oracle) auf Sepolia | `P2PEnergyMarket.sol`, `OracleStorage.sol`, Adressen im [README](../README.md) |
| Verifizierung auf Sepolia Etherscan | über die Adresslinks im README prüfbar |
| ERC-20-Stablecoin-Integration | `IEnergyStablecoin`, `transferFrom()` je Match |
| Automatische Abrechnung | `settleSlot()`, getriggert je Slot |
| Event-Logs für alle Transaktionen | `EnergyTraded`, `SlotSettled`, `PriceUpdated`, `HouseholdRegistered` |
| Nur autorisierte Oracles dürfen schreiben | `onlyOracle` in `OracleStorage` |
| Python-Oracle-Skript mit Dokumentation | `oracle_writer.py`, `data_simulator.py` |
| README mit Setup und Contract-Adressen | [../README.md](../README.md) |
