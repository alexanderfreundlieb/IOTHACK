# Energy Trading Challenge – P2P Energiehandel auf Sepolia

Dezentrales Peer-to-Peer-Energiehandelssystem: Haushalte mit Photovoltaik verkaufen
ihren Überschussstrom direkt an andere Haushalte – ohne Intermediär, automatisiert
über Smart Contracts auf dem Sepolia-Testnet, bezahlt in einem ERC-20-Stablecoin.

Alle drei Phasen der Challenge sind umgesetzt:

| Phase | Inhalt | Status | Umsetzung |
|-------|--------|--------|-----------|
| 1 (Pflicht) | P2P-Abrechnung aus Smart-Meter- und PV-Daten | ✅ | `P2PEnergyMarket.sol`, `OracleStorage.sol` |
| 2 (Pflicht) | Batteriesteuerung + Wetterdaten | ✅ | `BatteryManager.sol` |
| 3 (Bonus) | KI-Prognose + Incentive-Modell | ✅ | `IncentiveController.sol`, `forecast_model.py` |

## Contract-Adressen (Sepolia, Chain-ID 11155111)

| Contract | Adresse | Etherscan |
|----------|---------|-----------|
| OracleStorage | `0xD67f5d8CF4338FeFB65A43B581880CA65A6eC3eB` | [ansehen](https://sepolia.etherscan.io/address/0xD67f5d8CF4338FeFB65A43B581880CA65A6eC3eB) |
| P2PEnergyMarket | `0xbA9807E2A47566Eaa863A3f3EffAaAC3DFc54404` | [ansehen](https://sepolia.etherscan.io/address/0xbA9807E2A47566Eaa863A3f3EffAaAC3DFc54404) |
| BatteryManager | `0xad8bfCa01391F8E45b15d74874abf9420b581da8` | [ansehen](https://sepolia.etherscan.io/address/0xad8bfCa01391F8E45b15d74874abf9420b581da8) |
| IncentiveController | `0x205D53728DF46bf3b5e64ADCfb4e55032BAd1547` | [ansehen](https://sepolia.etherscan.io/address/0x205D53728DF46bf3b5e64ADCfb4e55032BAd1547) |
| Stablecoin (bereitgestellt, 6 Decimals) | `0x4BaBBaE33998fEd65Ada53bc41CeAa3Cde7F7B46` | [ansehen](https://sepolia.etherscan.io/address/0x4BaBBaE33998fEd65Ada53bc41CeAa3Cde7F7B46) |

Massgeblich sind immer die Werte in [python/config.json](python/config.json) unter `blockchain`.

## Dokumentation

| Dokument | Inhalt |
|----------|--------|
| [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md) | Systemüberblick, Datenfluss, Zeitmodell, Sicherheitsmodell |
| [docs/PHASE1_P2P_ABRECHNUNG.md](docs/PHASE1_P2P_ABRECHNUNG.md) | Abrechnungslogik, Matching, Preisbildung, Events |
| [docs/PHASE2_BATTERIE_WETTER.md](docs/PHASE2_BATTERIE_WETTER.md) | Optimierungsstrategie für Batterie und Wetter |
| [docs/PHASE3_AI_INCENTIVE.md](docs/PHASE3_AI_INCENTIVE.md) | Prognosemodell, Modellwahl, Incentive-Design |

## Projektstruktur

```
contracts/
  interfaces/
    IEnergyStablecoin.sol      Interface des bereitgestellten ERC-20-Tokens
    IOracleStorage.sol         Lesezugriff auf Mess-, Batterie- und Wetterdaten
    IBatteryManager.sol        Schnittstelle Phase 2 -> P2PEnergyMarket
    IIncentiveController.sol   Schnittstelle Phase 3 -> P2PEnergyMarket
  OracleStorage.sol            On-Chain-Speicher aller Oracle-Daten (vorgegeben)
  P2PEnergyMarket.sol          Abrechnung und Matching (Phase 1, Kern des Systems)
  BatteryManager.sol           Lade-/Entladestrategie (Phase 2)
  IncentiveController.sol      Reputationsscore und Preisfaktor (Phase 3)
  *.t.sol                      Solidity-Unit-Tests (forge-std)

python/
  data_simulator.py            Simuliert Verbrauch, PV, Batterie, Wetter (vorgegeben)
  oracle_writer.py             Schreibt die Simulationsdaten on-chain (vorgegeben)
  settlement_trigger.py        Ruft settleSlot() einmal pro Slot auf
  battery_optimizer.py         CLI-Sicht auf Batterie und Wetter (Lesepfad)
  forecast_model.py            Prognosemodell inkl. Kreuzvalidierung (Phase 3)
  ai_forecast.py               Schreibt Prognosen und Ist-Werte on-chain (Phase 3)
  deploy_helper.py             Deployment-Hilfsskript (vorgegeben)
  config.json                  Haushalte, Adressen, RPC-Endpunkt
  abi/                         Kompilierte ABIs für die Python-Skripte

p2p-energy-dashboard.html      Dashboard: Handel, SoC-Verlauf, Prognose vs. Ist
data/history.db                SQLite-Historie, Trainingsdatensatz für Phase 3
```

## Setup

### 1. Smart Contracts kompilieren

Voraussetzung: Node.js 22.13+.

```bash
npm install
npx hardhat compile
npx hardhat test solidity      # Unit-Tests Phase 2 und 3
```

Die ABIs unter `python/abi/` müssen zu den deployten Contracts passen. Nach einer
Contract-Änderung die Artefakte aus `artifacts/contracts/<Name>.sol/<Name>.json`
dorthin kopieren.

### 2. Python-Umgebung

```bash
cd python
python -m venv venv
venv\Scripts\activate          # Windows
# source venv/bin/activate     # Linux/macOS
pip install -r requirements.txt
```

`web3 >= 7.0` ist zwingend – ältere Versionen kennen `ExtraDataToPOAMiddleware` nicht.

### 3. `.env` anlegen

`python/.env` mit vier Schlüsseln, jeweils eine Sepolia-Wallet mit Test-ETH:

```
DEPLOYER_PRIVATE_KEY=   # deployt die Contracts, ist Owner
ORACLE_PRIVATE_KEY=     # schreibt Messwerte (muss autorisiertes Oracle sein)
TRIGGER_PRIVATE_KEY=    # ruft settleSlot() auf
AI_PRIVATE_KEY=         # schreibt Prognosen (muss autorisierte AI sein)
```

Oracle und AI brauchen eigene Wallets: teilen sich zwei Prozesse einen Key,
konkurrieren sie um dieselbe Nonce und Transaktionen gehen verloren.

### 4. Deployment (nur bei Neuaufsetzen nötig)

Reihenfolge ist verbindlich, jede Adresse danach in `config.json` eintragen:

```bash
python deploy_helper.py OracleStorage
python deploy_helper.py P2PEnergyMarket <stablecoin_addr> <oracle_addr>
python deploy_helper.py BatteryManager <oracle_addr>
python deploy_helper.py IncentiveController
```

Anschliessend einmalig verknüpfen und freischalten – ohne diese Schritte
verhält sich `settleSlot()` still wie in Phase 1:

```
p2pMarket.setBatteryManager(<battery_manager_addr>)
p2pMarket.setIncentiveController(<incentive_controller_addr>)
oracleStorage.authorizeOracle(<oracle_wallet>)
incentiveController.authorizeAI(<ai_wallet>)
```

Je Haushalt: `oracleStorage.registerHousehold()` (macht `oracle_writer.py`
automatisch), danach `p2pMarket.registerHousehold()`. Jeder Konsument muss
zusätzlich `stablecoin.approve(<p2p_market_addr>, 2**256-1)` aufrufen, sonst
schlägt sein Kauf fehl.

## Demo starten

Vier Terminals, jeweils aus `python/`:

```bash
python oracle_writer.py        # Terminal 1: Messdaten on-chain, 1 Slot/Minute
python settlement_trigger.py   # Terminal 2: ruft settleSlot() pro Slot auf
python battery_optimizer.py    # Terminal 3: CLI-Sicht auf SoC und Wetter
python ai_forecast.py          # Terminal 4: Prognose + Ist-Werte (Phase 3)
```

`ai_forecast.py` braucht eine gefüllte `data/history.db`; `oracle_writer.py`
sollte also einige Minuten Vorlauf haben.

Visualisierung: `p2p-energy-dashboard.html` im Browser öffnen (liest die Events
direkt von Sepolia – Handel je Slot, SoC-Verlauf, Prognose gegen Ist-Verbrauch).

## Konfigurierte Haushalte

| ID | Typ | PV | Batterie | Grundlast |
|----|-----|----|----------|-----------|
| house_01 | Produzent + Konsument | 8.0 kWp | 10.0 kWh / 3.0 kW | 0.4 kWh/h |
| house_02 | Produzent + Konsument | 5.0 kWp | 7.5 kWh / 2.5 kW | 0.6 kWh/h |
| house_03 | reiner Konsument | – | – | 0.8 kWh/h |
| house_04 | reiner Konsument | – | – | 0.9 kWh/h |

Damit sind die Demo-Anforderungen abgedeckt: mindestens 3 Haushalte (Phase 1)
und mindestens 2 Haushalte mit Batterie (Phase 2).

## Zeitbeschleunigung

| Real | Simulation |
|------|------------|
| 1 Minute (1 Slot) | 15 Minuten Abrechnungsslot |
| 4 Minuten (4 Slots) | 1 Stunde Prognoseintervall |
| 96 Minuten | 1 simulierter Tag |

`OracleStorage.currentSlot` wird aus `block.timestamp` abgeleitet, nicht aus der
Anzahl der `updateSlot()`-Aufrufe. Dauert ein Oracle-Durchlauf länger als 60s,
springt der Zähler – die Logik darf sich nicht auf lückenlose Slots verlassen.

## Hinweise

- **Decimals:** Der Stablecoin nutzt 6 Decimals, 1 Token = 1'000'000 Units.
  Basispreis `energyPricePerKwh = 100_000` = 0.10 Token pro kWh.
- **Neustart:** Simulierte Tageszeit und Batterie-SoC leben nur im
  Prozessspeicher von `oracle_writer.py`. Ein Neustart setzt beides zurück
  (Sim-Zeit auf 06:00, SoC auf 50%) – erwartetes Verhalten, kein Fehler.
- **Gas:** `settleSlot()` iteriert über alle Haushalte und ruft je Haushalt
  externe Contracts auf. Das Gas-Limit in `settlement_trigger.py` (1'500'000)
  muss mit der Anzahl Haushalte mitwachsen.
