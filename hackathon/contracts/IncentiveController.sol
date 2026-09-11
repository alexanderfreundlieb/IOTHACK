// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IIncentiveController.sol";

/**
 * @title IncentiveController
 * @notice Phase 3 (OPTIONAL): Belohnt Haushalte mit besseren Preisen,
 *         wenn ihr tatsächlicher Verbrauch der AI-Prognose entspricht.
 *
 * @dev Umgesetztes Incentive-Design: Reputationsscore über Zeit.
 *        1. `ai_forecast.py` schreibt pro Haushalt und Slot eine Prognose
 *           (submitForecast) und nach Ablauf des Slots den Ist-Wert
 *           (submitActual).
 *        2. Beim Ist-Wert vergleicht _updateScoreForSlot() beides und passt den
 *           Reputationsscore an: Abweichung unter TIGHT_BAND (10%) belohnt mit
 *           +SCORE_REWARD, Abweichung über LOOSE_BAND (25%) bestraft mit
 *           -SCORE_PENALTY, dazwischen liegt eine neutrale Zone.
 *        3. getPriceMultiplier() bildet den Score (0-1000, Start 500) linear auf
 *           einen Preisfaktor zwischen 800 und 1200 Promille ab, also ±20%.
 *
 *      Bewertet wird ausschliesslich der Verbrauch, nicht die PV-Erzeugung -
 *      Begründung siehe _updateScoreForSlot().
 *
 *      Das Python-Skript `ai_forecast.py` schreibt Prognosen in diesen Contract.
 *      Bei der Settlement-Phase liest P2PEnergyMarket den Preisfaktor aus
 *      (siehe P2PEnergyMarket.sol, Feld `incentiveController` +
 *      `setIncentiveController()`).
 *
 *      Dieser Contract implementiert IIncentiveController, damit
 *      P2PEnergyMarket ihn über das Interface ansprechen kann, ohne den
 *      vollen Code zu kennen (gleiches Muster wie IBatteryManager in Phase 2).
 */
contract IncentiveController is IIncentiveController {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    address public owner;
    mapping(address => bool) public authorizedAI;

    /// @notice Prognose pro Haushalt und Slot
    struct Forecast {
        uint256 expectedConsumptionWh;
        uint256 expectedProductionWh;
        uint256 slot;
        uint256 timestamp;
    }

    /// @notice Tatsächlicher Wert (nach dem Slot eingetragen)
    struct Actual {
        uint256 actualConsumptionWh;
        uint256 actualProductionWh;
        uint256 slot;
    }

    mapping(address => mapping(uint256 => Forecast)) public forecasts;
    mapping(address => mapping(uint256 => Actual)) public actuals;

    /// @notice Reputationsscore pro Haushalt (0-1000, Start: 500)
    mapping(address => uint256) public reputationScore;

    /// @notice Haushalt hat einen Score erhalten.
    /// @dev Notwendig, weil score==0 ein gültiger (schlechtester) Score ist.
    ///      Ohne dieses Flag würde "0" gleichzeitig "neu" bedeuten und ein
    ///      maximal schlecht bewerteter Haushalt bekäme beim nächsten
    ///      submitForecast() den Startwert 500 zurück - eine Gratis-Amnestie.
    mapping(address => bool) public initialized;

    /// @notice Slot wurde für diesen Haushalt bereits bewertet.
    /// @dev Macht die Bewertung idempotent: ein wiederholtes submitActual()
    ///      (z.B. Retry nach einem Timeout, obwohl die TX doch durchging)
    ///      darf den Score nicht ein zweites Mal verändern.
    mapping(address => mapping(uint256 => bool)) public scored;

    /// @notice Basispreis-Multiplikator in Promille (1000 = 100%, also normaler Preis)
    uint256 public constant BASE_MULTIPLIER = 1000;

    /// @notice Maximaler Rabatt: 200 Promille = 20%
    uint256 public constant MAX_DISCOUNT = 200;

    /// @notice Maximaler Aufschlag: 200 Promille = 20%
    uint256 public constant MAX_PENALTY = 200;

    /// @notice Score-Grenzen und Startwert
    uint256 public constant MAX_SCORE = 1000;
    uint256 public constant INITIAL_SCORE = 500;

    /// @notice Abweichung (Promille), bis zu der belohnt wird: 100 = 10%.
    /// @dev Kalibriert auf das Rauschen der Simulation. Der Verbrauch wird mit
    ///      uniform(0.85, 1.15) multipliziert, was rund 8% mittlere Abweichung
    ///      erzeugt - selbst eine perfekte Prognose kann nicht darunter kommen.
    ///      Ein Band von 10% ist damit knapp über dem Rauschboden: erreichbar
    ///      mit guter Prognose, aber nicht geschenkt.
    uint256 public constant TIGHT_BAND = 100;

    /// @notice Abweichung (Promille), ab der bestraft wird: 250 = 25%.
    uint256 public constant LOOSE_BAND = 250;

    /// @notice Score-Änderung pro bewertetem Slot.
    /// @dev Bewusst asymmetrisch (Strafe doppelt so hoch wie Belohnung): mit
    ///      einer brauchbaren Prognose liegen die meisten Slots im Belohnungs-
    ///      band, und ein symmetrisches Update würde alle Haushalte binnen
    ///      weniger Stunden auf MAX_SCORE festnageln - der Unterschied zwischen
    ///      den Haushalten, den das Incentive sichtbar machen soll, verschwände.
    uint256 public constant SCORE_REWARD = 30;
    uint256 public constant SCORE_PENALTY = 60;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event ForecastSubmitted(address indexed household, uint256 slot, uint256 expectedConsumption);
    event ActualSubmitted(address indexed household, uint256 slot, uint256 actualConsumption);
    event ScoreUpdated(address indexed household, uint256 newScore, uint256 deviation);
    event AIAuthorized(address indexed ai);

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAI() {
        require(authorizedAI[msg.sender], "Not authorized AI");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        authorizedAI[msg.sender] = true;
    }

    /// @notice Autorisiert eine Adresse, Prognosen und Ist-Werte einzureichen.
    /// @dev Gegenstück zu OracleStorage.authorizeOracle(): nur die AI-Wallet
    ///      von `ai_forecast.py` darf schreiben, sonst könnte jeder sich
    ///      selbst einen guten Score verschaffen.
    function authorizeAI(address ai) external onlyOwner {
        authorizedAI[ai] = true;
        emit AIAuthorized(ai);
    }

    // ─────────────────────────────────────────────────────────────
    //  Prognose & Ist-Wert eintragen
    // ─────────────────────────────────────────────────────────────

    /// @notice Trägt die Prognose für einen künftigen Slot ein.
    /// @dev Muss VOR submitActual() für denselben Slot erfolgen, sonst gibt es
    ///      nichts zu bewerten und _updateScoreForSlot() bricht ab.
    /// @param slot Slot-Nummer aus OracleStorage.getCurrentSlot(), auf die sich
    ///        die Prognose bezieht (ai_forecast.py prognostiziert im Voraus).
    function submitForecast(
        address household,
        uint256 slot,
        uint256 expectedConsumptionWh,
        uint256 expectedProductionWh
    ) external onlyAI {
        forecasts[household][slot] = Forecast({
            expectedConsumptionWh: expectedConsumptionWh,
            expectedProductionWh: expectedProductionWh,
            slot: slot,
            timestamp: block.timestamp
        });

        // Startwert nur einmal setzen - siehe `initialized`.
        if (!initialized[household]) {
            initialized[household] = true;
            reputationScore[household] = INITIAL_SCORE;
        }

        emit ForecastSubmitted(household, slot, expectedConsumptionWh);
    }

    /// @notice Trägt den gemessenen Ist-Wert eines abgelaufenen Slots ein und
    ///         löst damit automatisch die Score-Bewertung aus.
    /// @dev Idempotent: ein wiederholter Aufruf für denselben Slot verändert den
    ///      Score nicht erneut (siehe `scored`).
    function submitActual(
        address household,
        uint256 slot,
        uint256 actualConsumptionWh,
        uint256 actualProductionWh
    ) external onlyAI {
        actuals[household][slot] = Actual({
            actualConsumptionWh: actualConsumptionWh,
            actualProductionWh: actualProductionWh,
            slot: slot
        });
        emit ActualSubmitted(household, slot, actualConsumptionWh);

        // Automatisch Score aktualisieren wenn beide Werte vorhanden
        _updateScoreForSlot(household, slot);
    }

    // ─────────────────────────────────────────────────────────────
    //  Score-Update  (HIER IMPLEMENTIEREN TEAMS)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Aktualisiert den Reputationsscore basierend auf der Abweichung
     *         zwischen Prognose und tatsächlichem Verbrauch.
     *
     * @dev Bewertet wird ausschliesslich der VERBRAUCH, nicht die PV-Erzeugung.
     *      Begründung: das Incentive soll Verhalten belohnen, das der Haushalt
     *      steuern kann. Die Erzeugung hängt an der Einstrahlung und damit am
     *      Wetter - ein Haushalt für Wolken zu bestrafen wäre ökonomisch
     *      sinnlos und würde PV-Besitzer systematisch benachteiligen, weil die
     *      Wetterprognose deutlich ungenauer ist als die Lastprognose.
     *      Die Erzeugungsprognose wird weiterhin on-chain festgehalten (für
     *      Nachvollziehbarkeit), fliesst aber nicht in den Score ein.
     *
     *      Der Nenner (erwarteter Verbrauch) wird nie klein: das niedrigste
     *      Lastprofil der Simulation liegt bei rund 40 Wh pro Slot. Eine
     *      Normierung auf eine künstliche Referenz ist deshalb nicht nötig.
     */
    function _updateScoreForSlot(address household, uint256 slot) internal {
        Forecast memory f = forecasts[household][slot];
        Actual memory a = actuals[household][slot];

        // Ohne Prognose gibt es nichts zu bewerten. Wichtig für die Reihenfolge:
        // submitForecast() muss vor submitActual() für denselben Slot kommen.
        if (f.timestamp == 0 || f.expectedConsumptionWh == 0) return;

        // Slot wurde vom Oracle übersprungen - es existieren keine Messwerte.
        if (a.actualConsumptionWh == 0 && a.actualProductionWh == 0) return;

        // Jeden Slot nur einmal bewerten.
        if (scored[household][slot]) return;
        scored[household][slot] = true;

        uint256 deviation = _calculateDeviation(
            f.expectedConsumptionWh,
            a.actualConsumptionWh
        );

        uint256 score = reputationScore[household];
        if (deviation < TIGHT_BAND) {
            score = _min(score + SCORE_REWARD, MAX_SCORE);
        } else if (deviation > LOOSE_BAND) {
            score = score > SCORE_PENALTY ? score - SCORE_PENALTY : 0;
        }
        // Dazwischen: neutrale Zone, Score bleibt unverändert.

        reputationScore[household] = score;
        emit ScoreUpdated(household, score, deviation);
    }

    // ─────────────────────────────────────────────────────────────
    //  Preisfaktor (wird vom P2PEnergyMarket gelesen)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Gibt den Preismultiplikator für einen Haushalt zurück.
     * @return multiplier in Promille (1000 = neutral, <1000 = Rabatt für Käufer)
     *
     * @dev Lineare Interpolation zwischen 800 und 1200:
     *        score 1000 -> 800  (20% Rabatt)
     *        score  500 -> 1000 (neutral)
     *        score    0 -> 1200 (20% Aufschlag)
     *
     *      Ein Haushalt ohne jede Prognose bleibt bewusst neutral statt bestraft
     *      zu werden - fehlende Daten sind kein Fehlverhalten.
     */
    function getPriceMultiplier(address household) external view returns (uint256 multiplier) {
        if (!initialized[household]) return BASE_MULTIPLIER;

        uint256 score = reputationScore[household];
        if (score >= INITIAL_SCORE) {
            uint256 discount = ((score - INITIAL_SCORE) * MAX_DISCOUNT) / INITIAL_SCORE;
            return BASE_MULTIPLIER - discount;
        }
        uint256 penalty = ((INITIAL_SCORE - score) * MAX_PENALTY) / INITIAL_SCORE;
        return BASE_MULTIPLIER + penalty;
    }

    // ─────────────────────────────────────────────────────────────
    //  Hilfsfunktionen (vorgegeben)
    // ─────────────────────────────────────────────────────────────

    /// @notice Berechnet die Abweichung in Promille (Fixedpoint-Arithmetik)
    function _calculateDeviation(uint256 expected, uint256 actual) internal pure returns (uint256) {
        if (expected == 0) return 0;
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        return (diff * 1000) / expected;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    function getReputationScore(address household) external view returns (uint256) {
        return reputationScore[household];
    }

    function getForecast(address household, uint256 slot) external view returns (Forecast memory) {
        return forecasts[household][slot];
    }

    function getActual(address household, uint256 slot) external view returns (Actual memory) {
        return actuals[household][slot];
    }
}
