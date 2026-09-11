# Phase 2 – Batterie- und Wetterdaten-Integration

Dynamische Lade-/Entladesteuerung auf Basis von Echtzeitdaten, on-chain
entschieden und direkt in der Abrechnung wirksam.

Beteiligte Dateien: [`contracts/BatteryManager.sol`](../contracts/BatteryManager.sol),
[`contracts/OracleStorage.sol`](../contracts/OracleStorage.sol),
[`contracts/BatteryManager.t.sol`](../contracts/BatteryManager.t.sol),
[`python/battery_optimizer.py`](../python/battery_optimizer.py).

## Neue Eingabedaten

| Datum | Quelle | Feld |
|-------|--------|------|
| Ladestand (SoC) | `updateBattery()` | `socPercent` (0–100) |
| Kapazität | `updateBattery()` | `capacityWh` |
| Max. Lade-/Entladerate je Slot | `updateBattery()` | `maxRateWh` |
| Solarstrahlung | `updateWeather()` | `irradianceWm2` |
| Temperatur | `updateWeather()` | `temperatureC` (×10, z.B. 235 = 23.5 °C) |
| Bewölkungsgrad | `updateWeather()` | `cloudCover` (0–100 %) |

Wetterdaten gelten für alle Haushalte gemeinsam, daher genügt ein Datensatz je
Slot. In Simulationszeit werden sie stündlich aktualisiert, also alle vier
Slots beziehungsweise vier realen Minuten.

## Optimierungsstrategie

Die geforderte Priorisierung lautet **PV-Eigenverbrauch > Batterie laden >
Netz einspeisen**. Umgesetzt ist sie in vier Schritten in
`BatteryManager._evaluate()`:

1. **Eigenverbrauch zuerst – implizit.** Gerechnet wird mit dem Netto
   (`production - consumption`). Die PV deckt damit definitionsgemäss zuerst
   den eigenen Bedarf; nur was übrig bleibt, steht überhaupt zur Disposition.
2. **Überschuss (Netto > 0) → `CHARGE`.** Die Lademenge ist doppelt begrenzt:
   durch `maxRateWh` und durch den Kopfraum bis `MAX_SOC`.

   ```
   headroomWh = capacityWh * (MAX_SOC - socPercent) / 100
   chargeWh   = min(netto, maxRateWh, headroomWh)
   ```

   Erst was nicht in die Batterie passt, bleibt im Netto und wird von
   `settleSlot()` am Markt verkauft – Laden hat also Vorrang vor Einspeisen.
3. **Defizit (Netto < 0) → `DISCHARGE`.** Das Defizit wird zuerst aus der
   Batterie gedeckt, statt teuer am Markt zuzukaufen. Nutzbar ist nur die
   Energie oberhalb des wetterabhängigen SoC-Bodens:

   ```
   usableWh    = capacityWh * (socPercent - reserveSoc) / 100
   dischargeWh = min(|netto|, maxRateWh, usableWh)
   ```

4. **Wetter-Adaption des SoC-Bodens.** `_reserveSoc()` verschiebt die
   Entladegrenze nach der erwarteten PV-Ausbeute: viel erwartete Sonne erlaubt
   tieferes Entladen, weil sich die Batterie bald wieder füllt; bei starker
   Bewölkung bleibt mehr Puffer liegen.

| Wetterlage | Bedingung | Reserve-SoC |
|------------|-----------|-------------|
| Bewölkt | `cloudCover >= 80 %` | 40 % |
| Sonnig | `irradianceWm2 >= 400 W/m²` | 10 % |
| Normal / noch kein Wetterwert | sonst | 20 % |

Weitere Parameter: `MAX_SOC = 95 %` – schont die Zellen und lässt Kopfraum für
Erzeugungsspitzen.

### Entscheidungstabelle

| Situation | Aktion | Begründungstext im Event |
|-----------|--------|--------------------------|
| Keine Batterie (`capacityWh == 0`) | `IDLE` | `no battery capacity` |
| Überschuss, SoC ≥ `MAX_SOC` | `IDLE` | `battery full - surplus to market` |
| Überschuss, Kopfraum vorhanden | `CHARGE` | `store PV surplus` |
| Defizit, SoC ≤ Reserve | `IDLE` | `soc at weather reserve - buy from market` |
| Defizit, Reserve überschritten | `DISCHARGE` | `battery covers deficit` |
| Erzeugung = Verbrauch | `IDLE` | `production matches consumption` |

## Wirkung in der Abrechnung

Der Simulator schreibt seine eigene SoC-Kurve fort; der Contract kann sie nicht
zurückschreiben. Wirksam wird die Entscheidung stattdessen über die
Abrechnung: `P2PEnergyMarket.settleSlot()` ruft `decideAction()` je Haushalt
auf und korrigiert das handelbare Netto.

| Aktion | Effekt auf das Netto | Bedeutung |
|--------|----------------------|-----------|
| `CHARGE` | `netto -= amountWh` | Energie bleibt im Haushalt und wird nicht verkauft |
| `DISCHARGE` | `netto += amountWh` | Batterie liefert zusätzlich und senkt den Zukauf |
| `IDLE` | unverändert | Reiner Marktfall wie in Phase 1 |

Zwei Designentscheidungen dahinter:

- **Live im selben Slot.** `decideAction()` wird innerhalb derselben
  Transaktion aufgerufen, nicht vorab separat. Nur so gehört die Entscheidung
  garantiert zu den Messwerten, mit denen gerade abgerechnet wird.
- **Idempotenz je Slot.** Ein zweiter Aufruf im selben Slot – etwa aus
  `battery_optimizer.py` – liefert die bereits getroffene Entscheidung zurück,
  statt Zähler doppelt hochzuzählen oder ein zweites Event zu erzeugen.

`previewAction()` liefert dieselbe Entscheidung als `view`, also ohne
Transaktion und Gaskosten. Anzeige und Abrechnung teilen sich dafür `_evaluate()`
und können deshalb nicht auseinanderlaufen.

## Visualisierung

`BatteryUpdated(household, slot, soc)` aus dem OracleStorage ergibt zusammen mit
`DecisionMade(household, action, amountWh, slot, reason)` den vollständigen
Ladestand-Verlauf über die Zeit inklusive Begründung je Slot. Ein zusätzlicher
Storage im Contract ist dafür nicht nötig.

- Dashboard: `p2p-energy-dashboard.html` zeichnet die SoC-Kurve aus diesen Events.
- CLI: `battery_optimizer.py` gibt je Slot SoC, Wetter und Entscheidung aus.
  Das Skript ist ein reiner Lesepfad – die produktive Strategie läuft on-chain.
- Ein Aufruf für das Dashboard: `getBatteryStatus()` liefert SoC, Kapazität,
  aktuellen Reserve-Boden sowie die kumulierten Lade- und Entlademengen.

## Demo-Nachweis

- **Zwei Haushalte mit Batterie:** `house_01` (10 kWh / 3 kW) und `house_02`
  (7.5 kWh / 2.5 kW).
- **Lade-/Entladezyklen:** `totalChargedWh` und `totalDischargedWh` wachsen nur,
  wenn tatsächlich gehandelt wurde, und belegen damit vollständige Zyklen.
- **Tests:** `BatteryManager.t.sol` deckt Laden, Ratenbegrenzung,
  Kopfraumbegrenzung, Entladen, beide Wetter-Adaptionen, Randfälle ohne
  Batterie, Slot-Idempotenz sowie einen vollständigen Lade-/Entladezyklus über
  zwei Slots ab.

## Lieferobjekte

| Anforderung | Stand |
|-------------|-------|
| Erweiterte Smart Contracts (Batterie-Logik + Oracle) | `BatteryManager.sol`, `OracleStorage.updateBattery/updateWeather` |
| Erweitertes Python-Skript mit Batterie- und Wetter-Feed | `oracle_writer.py` schreibt beides je Slot |
| Batterie-Management-Logik | `_evaluate()`, vier Strategieschritte oben |
| Priorisierung Eigenverbrauch > Laden > Einspeisen | Schritte 1–2 der Strategie |
| Batterie-Status in der Abrechnung | `settleSlot()` rechnet `decideAction()` ein |
| Visualisierung Ladestand-Verlauf | Dashboard und CLI, siehe oben |
| Demo: 2 Haushalte mit Batterie, Lade-/Entladezyklen | siehe Demo-Nachweis |
| Dokumentation der Optimierungsstrategie | dieses Dokument |
