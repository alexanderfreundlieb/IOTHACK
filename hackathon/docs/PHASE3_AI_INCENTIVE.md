# Phase 3 – AI Prediction & Incentive-Modell

KI-gestützte Last- und PV-Prognose je simulierter Stunde, gekoppelt an ein
on-chain abgebildetes Preis-Incentive: Wer sich an die Prognose hält, kauft
Energie günstiger.

Beteiligte Dateien: [`python/forecast_model.py`](../python/forecast_model.py),
[`python/ai_forecast.py`](../python/ai_forecast.py),
[`contracts/IncentiveController.sol`](../contracts/IncentiveController.sol),
[`contracts/IncentiveController.t.sol`](../contracts/IncentiveController.t.sol).

## Prognosemodell

### Modellwahl und Begründung

Gewählt wurde ein **Bin-Mittelwert-Modell für den Verbrauch plus eine lineare
Regression durch den Ursprung für die PV-Erzeugung** – bewusst kein LSTM,
XGBoost oder Prophet.

Der Grund liegt in der Struktur der Daten: Der Verbrauch ist im Simulator eine
Treppenfunktion der simulierten Tageszeit (Morgenspitze 07–09, Mittag 12–14,
Abendspitze 18–22, Nachtabsenkung 23–06), überlagert von unabhängigem
Rauschen `uniform(0.85, 1.15)`. Für eine solche Funktion ist der Mittelwert je
Stunden-Bin der optimale Schätzer – ein grösseres Modell könnte darüber hinaus
nichts lernen und würde bei der vorhandenen Datenmenge nur overfitten. Die
PV-Erzeugung ist exakt linear in der Einstrahlung und geht durch den Ursprung
(kein Licht, keine Erzeugung), braucht also eine Steigung und keinen
Achsenabschnitt.

Nebeneffekt: Das Modell kommt ohne numpy und scikit-learn aus, läuft in
Sekunden und ist vollständig nachvollziehbar.

### Merkmale und Trainingsdaten

| Merkmal | Herkunft |
|---------|----------|
| Simulierte Tageszeit (`sim_hour`, 24 Bins) | Historie `meter_history` |
| Wochentag (`sim_dayofweek`) | Historie, als Kalendermerkmal verfügbar |
| Solarstrahlung | Historie `weather_history`, per Zeitstempel gejoint |
| Historischer Verbrauch | aus Phase 1 und 2 gesammelt |
| Historische PV-Erzeugung | aus Phase 1 und 2, mit Wetter korreliert |

Trainingsdatensatz ist `data/history.db`, die `data_simulator.py` nebenbei
mitschreibt.

Drei Details, die über die Qualität entscheiden:

- **Normierung.** Die Verbrauchswerte werden auf die Grundlast des Haushalts
  normiert. Dadurch trainieren alle Haushalte gemeinsam eine Tagesform, statt
  vier dünn besetzte Kurven zu schätzen. Bei der Vorhersage wird wieder mit der
  Grundlast hochskaliert.
- **Sessions.** Die simulierte Uhr springt bei jedem Neustart von
  `oracle_writer.py` zurück. `load_history()` erkennt Lücken über 300 Sekunden
  und gruppiert die Zeilen in Sessions.
- **Leere Bins.** Für unbeobachtete Stunden wird der nächste belegte Nachbar auf
  der zyklischen Stundenachse genutzt (maximal 3 Bins weit), nicht der globale
  Mittelwert: Das Lastprofil hat breite Plateaus, ein leeres Bin liegt also
  meist mitten in einem davon. Jede Schätzung wird mit ihrer Herkunft
  gekennzeichnet (`ok`, `sparse`, `interpolated`, `fallback`).

### Validierung

`python forecast_model.py` gibt einen Validierungsreport aus. Kreuzvalidiert
wird nach dem **Leave-one-session-out-Prinzip**: Jede Session ist einmal
Testmenge. Ein zufälliger Split wäre hier wertlos – aufeinanderfolgende Slots
im selben Bin sind nahezu identisch, ein solcher Split leckt und meldet eine
fiktiv gute Bewertung.

Berichtet werden MAE und MAPE für Verbrauch (gegen eine Baseline aus dem
Haushaltsmittelwert) und für die Erzeugung, letztere zweimal: mit gemessenem
Wetter und mit aus der Stunde geschätztem Wetter – nur der zweite Wert
entspricht dem Live-Pfad. Untergrenze für den Verbrauch sind rund 8 % MAPE,
das ist das eingebaute Rauschen des Simulators. Ein besserer Wert wäre ein
Hinweis auf ein Leck im Split, kein besseres Modell.

## Incentive-Design

### Mechanismus

Gewählt wurde ein **Reputationssystem**: Die Prognosetreue wird über Zeit
akkumuliert und bestimmt den Einkaufspreis.

1. `ai_forecast.py` schreibt einmal je simulierter Stunde (alle 4 Slots) eine
   Prognose in den Contract (`submitForecast`), zwei Slots im Voraus, damit die
   Transaktion vor dem prognostizierten Slot gemined ist.
2. Nach Ablauf des Slots liest das Skript den tatsächlichen Messwert aus dem
   Oracle und reicht ihn nach (`submitActual`).
3. `_updateScoreForSlot()` berechnet die Abweichung in Promille und passt den
   Reputationsscore an.
4. `getPriceMultiplier()` bildet den Score auf einen Preisfaktor ab, den
   `P2PEnergyMarket` bei jedem Trade auf den Basispreis anwendet.

### Parameter

| Parameter | Wert | Bedeutung |
|-----------|------|-----------|
| `INITIAL_SCORE` | 500 | Startwert, entspricht neutralem Preis |
| `MAX_SCORE` | 1000 | Obergrenze |
| `TIGHT_BAND` | 100 ‰ (10 %) | Darunter wird belohnt |
| `LOOSE_BAND` | 250 ‰ (25 %) | Darüber wird bestraft |
| `SCORE_REWARD` | +30 | Score-Gewinn je treffendem Slot |
| `SCORE_PENALTY` | −60 | Score-Verlust je stark abweichendem Slot |
| `MAX_DISCOUNT` / `MAX_PENALTY` | 200 ‰ | Preisspanne ±20 % |

Preisabbildung, linear interpoliert:

```
Score 1000 -> Multiplikator  800  (20 % Rabatt)
Score  500 -> Multiplikator 1000  (neutral)
Score    0 -> Multiplikator 1200  (20 % Aufschlag)
```

### Begründung der Kalibrierung

- **Toleranzband 10 %.** Der Simulator multipliziert den Verbrauch mit
  `uniform(0.85, 1.15)`, was rund 8 % mittlere Abweichung erzeugt – selbst eine
  perfekte Prognose kommt nicht darunter. 10 % liegt knapp über diesem
  Rauschboden: erreichbar mit guter Prognose, aber nicht geschenkt.
- **Asymmetrie (Strafe doppelt so hoch wie Belohnung).** Mit brauchbarer
  Prognose liegen die meisten Slots im Belohnungsband. Ein symmetrisches Update
  würde alle Haushalte binnen weniger Stunden auf `MAX_SCORE` festnageln und
  genau den Unterschied einebnen, den das Incentive sichtbar machen soll.
- **Nur der Verbrauch wird bewertet.** Die PV-Erzeugung hängt an der
  Einstrahlung und damit am Wetter. Einen Haushalt für Wolken zu bestrafen wäre
  ökonomisch sinnlos und würde PV-Besitzer systematisch benachteiligen, weil die
  Wetterprognose deutlich ungenauer ist als die Lastprognose. Die
  Erzeugungsprognose wird trotzdem on-chain festgehalten – für die
  Nachvollziehbarkeit, aber ohne Einfluss auf den Score.
- **Der Multiplikator gilt für den Käufer.** Belohnt wird, wer seinen eigenen
  Bezug vorhersehbar hält; der Produzent erhält unverändert genau das, was die
  Konsumenten bezahlen, ohne zusätzliche Marge oder Abzug.

### Robustheit

| Fall | Verhalten |
|------|-----------|
| Haushalt ohne jede Prognose | Bleibt neutral (Multiplikator 1000). Fehlende Daten sind kein Fehlverhalten. |
| Score auf 0 gefallen | `initialized`-Flag verhindert, dass der nächste `submitForecast()` den Startwert 500 zurückgibt – keine Gratis-Amnestie. |
| `submitActual()` doppelt gesendet | `scored[household][slot]` macht die Bewertung idempotent, ein Retry verändert den Score nicht erneut. |
| Ist-Wert ohne Prognose | Wird nicht bewertet; die Reihenfolge Prognose vor Ist-Wert ist Voraussetzung. |
| Vom Oracle übersprungener Slot | Messwert ist 0/0 und wird übersprungen, statt als perfekte Abweichung gewertet zu werden. |
| Unbefugte Schreibversuche | `onlyAI`, gesetzt über `authorizeAI()`. |

## Demo-Nachweis

Gefordert ist mindestens ein Haushalt mit Incentive-Belohnung gegenüber einem
ohne. Belegt wird das doppelt:

- `IncentiveController.t.sol::test_RewardedVsUnrewarded_PriceGap` – ein Haushalt
  mit 2 % Abweichung gegen einen mit 60 % Abweichung, mit messbar
  unterschiedlichem Preisfaktor.
- `P2PEnergyMarket.t.sol::test_IncentiveController_ChangesPriceByReputation` –
  derselbe Unterschied in der echten Abrechnung: Der genaue Haushalt zahlt
  weniger als den Basispreis, der abweichende mehr.
- Live: `ScoreUpdated`-Events auf Sepolia sowie die Ansicht „Prognose gegen
  Ist-Verbrauch“ im Dashboard.

## Lieferobjekte

| Anforderung | Stand |
|-------------|-------|
| AI-Modell (Code + Erläuterung der Wahl) | `forecast_model.py`, Abschnitt „Modellwahl und Begründung“ |
| Prognosegranularität stündlich (4 Slots) | `SLOTS_PER_SIM_HOUR = 4` in `ai_forecast.py` |
| Erweiterter Smart Contract mit Incentive-Mechanismus | `IncentiveController.sol`, eingebunden in `settleSlot()` |
| On-Chain Incentive-Logik und Preisvergabe | `_updateScoreForSlot()`, `getPriceMultiplier()` |
| Visualisierung Prognose vs. Ist + Preisvergleich | `p2p-energy-dashboard.html`, Validierungsreport von `forecast_model.py` |
| Nachweis belohnter vs. nicht belohnter Haushalt | siehe Demo-Nachweis |
| Dokumentation des Incentive-Designs | dieses Dokument |
