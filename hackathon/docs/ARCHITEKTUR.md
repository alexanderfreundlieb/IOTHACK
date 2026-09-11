# Architektur

Systemüberblick über alle drei Phasen: welche Komponente welche Aufgabe hat,
wie die Daten fliessen und welche Annahmen dabei gelten.

## Komponenten

| Komponente | Ort | Aufgabe |
|------------|-----|---------|
| `data_simulator.py` | off-chain | Erzeugt Verbrauch, PV-Erzeugung, Batterie-SoC und Wetter; schreibt alles zusätzlich nach `data/history.db` |
| `oracle_writer.py` | off-chain | Sendet die Simulationsdaten je Slot an `OracleStorage` |
| `OracleStorage.sol` | on-chain | Einzige Datenquelle der Contracts: Meter-, Batterie- und Wetterdaten plus Slot-Zähler |
| `P2PEnergyMarket.sol` | on-chain | Rechnet je Slot ab: Matching und Stablecoin-Transfers |
| `BatteryManager.sol` | on-chain | Entscheidet je Slot über Laden, Entladen oder Nichtstun |
| `IncentiveController.sol` | on-chain | Führt Prognose, Ist-Wert, Reputationsscore und Preisfaktor |
| `settlement_trigger.py` | off-chain | Löst `settleSlot()` einmal pro Slot aus |
| `forecast_model.py` / `ai_forecast.py` | off-chain | Trainiert das Prognosemodell und schreibt Prognosen sowie Ist-Werte on-chain |
| `p2p-energy-dashboard.html` | Browser | Visualisiert Handel, SoC-Verlauf und Prognosegüte aus den Events |

## Datenfluss je Slot

```
 data_simulator.py ──► oracle_writer.py ──► OracleStorage
        │                                        │
        │ (SQLite)                               │ Meter / Batterie / Wetter
        ▼                                        ▼
   data/history.db                       BatteryManager.decideAction()
        │                                        │  Action + Menge
        │ Training                               ▼
        ▼                          settlement_trigger.py ──► P2PEnergyMarket.settleSlot()
  forecast_model.py                                              │
        │                                                        │ Preisfaktor
        ▼                                                        ▼
   ai_forecast.py ──► IncentiveController ─────────────────────► Stablecoin-Transfer
                        (Prognose / Ist / Score)                (Konsument -> Produzent)
```

Alle Contracts lesen ausschliesslich aus `OracleStorage`. Damit gibt es genau
eine Wahrheit je Slot, und Abrechnung, Batterieentscheidung und Bewertung
beziehen sich garantiert auf dieselben Messwerte.

## Abhängigkeiten zwischen den Contracts

Die Kopplung ist bewusst einseitig und läuft nur über Interfaces:

```
P2PEnergyMarket ──IOracleStorage──────────► OracleStorage
                ──IBatteryManager─────────► BatteryManager ──IOracleStorage──► OracleStorage
                ──IIncentiveController────► IncentiveController
                ──IEnergyStablecoin───────► Stablecoin (extern)
```

`BatteryManager` und `IncentiveController` kennen den Markt nicht. Beide sind
optional: Solange `setBatteryManager()` bzw. `setIncentiveController()` nicht
aufgerufen wurden, stehen die Felder auf `address(0)` und `settleSlot()`
verhält sich exakt wie in Phase 1 – ein stiller, aber bewusster Fallback, der
das Deployment in der vorgegebenen Reihenfolge erst möglich macht.

## Zeitmodell

Ein Slot ist eine reale Minute und entspricht 15 Minuten Simulationszeit.

| Grösse | Wert |
|--------|------|
| `OracleStorage.SLOT_DURATION` | 60 Sekunden |
| `SIM_MINUTES_PER_SLOT` (Python) | 15 |
| Prognoseintervall | 4 Slots = 1 simulierte Stunde |
| Ein simulierter Tag | 96 Slots = 96 reale Minuten |

Zwei Eigenheiten, die jede Logik im System berücksichtigen muss:

1. **Slots können springen.** `currentSlot = (block.timestamp - startTimestamp) / SLOT_DURATION`.
   Der Oracle-Writer sendet bis zu acht sequenzielle Transaktionen je Slot; bei
   ~12s Blockzeit überschreitet ein Durchlauf schon mal 60s. Nie annehmen, dass
   der nächste Slot `aktueller + 1` ist.
2. **Die simulierte Uhr ist flüchtig.** Sie lebt im Prozessspeicher von
   `oracle_writer.py` und springt bei jedem Neustart auf 06:00 zurück, ebenso
   der Batterie-SoC auf 50%. `forecast_model.current_sim_hour()` rekonstruiert
   sie deshalb aus der jüngsten Zeile der Historie statt aus der realen Uhrzeit,
   und `load_history()` gruppiert die Historie in Sessions.

## Sicherheitsmodell

| Rolle | Rechte | Gesetzt durch |
|-------|--------|---------------|
| Owner | Haushalte registrieren, Preis setzen, Integrationen verknüpfen, Oracles und AI autorisieren | Deployer |
| Autorisiertes Oracle | Messwerte in `OracleStorage` schreiben | `authorizeOracle()` |
| Autorisierte AI | Prognosen und Ist-Werte schreiben | `authorizeAI()` |
| Beliebig | `settleSlot()` auslösen, alle Daten lesen | – |

`settleSlot()` ist absichtlich permissionless: die Funktion verarbeitet nur
Daten, die autorisierte Oracles bereits on-chain geschrieben haben, und
`lastSettledSlot` lässt jeden Slot höchstens einmal abrechnen. Ein fremder
Aufruf kann also nichts erzeugen, was nicht ohnehin passieren würde.

Weitere bewusste Entscheidungen:

- **Checks-Effects-Interactions:** `lastSettledSlot` wird vor der
  Transfer-Schleife gesetzt. Ein bösartiger Token-Callback kann `settleSlot()`
  damit nicht erneut für denselben Slot betreten.
- **Fehlerisolation:** Jeder einzelne Trade und jeder Batterie-Call läuft in
  `try/catch`. Ein Konsument ohne ausreichendes `approve()` bringt nur seinen
  eigenen Trade zu Fall, nicht den Slot für alle.
- **Keine Reverts durch Randfälle:** Reine Konsumenten ohne Batterie liefern
  `IDLE` statt zu reverten; `isManaged()` wird vor `decideAction()` geprüft.

## Events

Vollständige Nachvollziehbarkeit der Abrechnung – auch die Grundlage des
Dashboards:

| Event | Contract | Bedeutung |
|-------|----------|-----------|
| `MeterUpdated` | OracleStorage | Neue Verbrauchs-/Erzeugungsdaten je Haushalt und Slot |
| `BatteryUpdated` | OracleStorage | Neuer Ladestand – ergibt den SoC-Verlauf über die Zeit |
| `WeatherUpdated` | OracleStorage | Neue Strahlungs- und Temperaturwerte |
| `EnergyTraded` | P2PEnergyMarket | Ein Match: Produzent, Konsument, Energiemenge, Betrag, Slot |
| `SlotSettled` | P2PEnergyMarket | Slot abgeschlossen, mit gehandelter Gesamtenergie und Gesamtbetrag |
| `DecisionMade` | BatteryManager | Lade-/Entladeentscheidung inklusive Begründungstext |
| `ForecastSubmitted` / `ActualSubmitted` | IncentiveController | Prognose bzw. Ist-Wert eines Slots |
| `ScoreUpdated` | IncentiveController | Neuer Reputationsscore und gemessene Abweichung |

## Tests

`contracts/*.t.sol` (Solidity-Unit-Tests, Ausführung mit `npx hardhat test solidity`):

- `BatteryManager.t.sol` – Laden, Entladen, Wetter-Adaption, Randfälle,
  Slot-Idempotenz und der Nachweis vollständiger Lade-/Entladezyklen.
- `IncentiveController.t.sol` – Score-Auf- und -Abbau, Sättigung, neutrale Zone,
  Retry-Sicherheit und der Preisvergleich belohnter gegen abweichender Haushalt.
- `P2PEnergyMarket.t.sol` – Abrechnung mit und ohne Incentive-Controller,
  inklusive Nachweis, dass der Multiplikator nur den Käufer betrifft.
