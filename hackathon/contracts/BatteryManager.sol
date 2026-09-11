// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracleStorage.sol";
import "./interfaces/IBatteryManager.sol";

/**
 * @title BatteryManager
 * @notice Phase 2: Lade-/Entladestrategie für Haushaltsbatterien.
 *
 *      Idee: Der Contract liest Wetterprognose und aktuellen SoC,
 *            entscheidet pro Slot, ob die Batterie geladen, entladen
 *            oder leer/voll bleibt, und protokolliert die Entscheidung.
 *
 *      Wichtig: Die simulierte SoC-Kurve im OracleStorage läuft unabhängig
 *      von diesen Entscheidungen weiter (sie folgt im Simulator nur
 *      production/consumption) - dieser Contract kann sie NICHT zurückschreiben.
 *      Wirksam wird eure Entscheidung stattdessen dadurch, dass
 *      P2PEnergyMarket.settleSlot() optional decideAction() aufruft und die
 *      gehandelte Energiemenge entsprechend anpasst (siehe P2PEnergyMarket.sol,
 *      Feld `batteryManager` + `setBatteryManager()`).
 *
 *      Dieser Contract implementiert IBatteryManager, damit P2PEnergyMarket
 *      ihn über das Interface ansprechen kann, ohne den vollen Code zu kennen.
 *
 *      ---- Optimierungsstrategie (Phase 2) ----------------------------
 *      Priorisierung: PV-Eigenverbrauch > Batterie laden > Netz einspeisen.
 *        1. Eigenverbrauch ist implizit: gerechnet wird mit dem NETTO
 *           (production - consumption), PV deckt also zuerst den Eigenbedarf.
 *        2. Überschuss (netto > 0) -> CHARGE, begrenzt durch maxRateWh und den
 *           Kopfraum bis MAX_SOC. Erst was nicht in die Batterie passt, bleibt
 *           im Netto und wird von settleSlot() am Markt verkauft.
 *        3. Defizit (netto < 0)    -> DISCHARGE, begrenzt durch maxRateWh und
 *           die nutzbare Energie oberhalb des wetterabhängigen SoC-Bodens.
 *        4. Wetter-Adaption: der SoC-Boden (_reserveSoc) steigt bei starker
 *           Bewölkung und sinkt bei hoher Strahlung - bei wenig erwarteter PV
 *           bleibt also mehr Puffer in der Batterie, bei viel erwarteter PV
 *           darf sie tiefer entladen werden, weil sie sich bald wieder füllt.
 *
 *      Visualisierung "Ladestand-Verlauf über Zeit": dafür braucht es hier
 *      keinen zusätzlichen Storage - OracleStorage emittiert pro Slot bereits
 *      `BatteryUpdated(household, slot, soc)`. Zusammen mit den
 *      `DecisionMade`-Events unten ergibt das die vollständige Kurve
 *      inklusive Begründung pro Slot.
 */
contract BatteryManager is IBatteryManager {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    IOracleStorage public immutable oracle;
    address public owner;

    /// @notice Letzte protokollierte Entscheidung pro Haushalt
    struct Decision {
        Action action;
        uint256 amountWh;
        uint256 slot;
        uint256 timestamp;
    }

    mapping(address => Decision) public lastDecision;
    mapping(address => bool) public isManaged;
    address[] public managedHouseholds;

    /// @notice Kumulierte Lade-/Entlademengen pro Haushalt in Wh.
    /// @dev Deckt das Demo-Deliverable "Nachweis von Lade-/Entladezyklen" ab:
    ///      beide Zähler wachsen nur, wenn decideAction() wirklich gehandelt hat.
    mapping(address => uint256) public totalChargedWh;
    mapping(address => uint256) public totalDischargedWh;

    // ─────────────────────────────────────────────────────────────
    //  Strategie-Parameter
    // ─────────────────────────────────────────────────────────────

    /// @notice Obergrenze fürs Laden - schont die Zellen und lässt Puffer für Peaks.
    uint256 public constant MAX_SOC = 95;

    /// @notice SoC-Boden bei normalem Wetter.
    uint256 public constant RESERVE_SOC_BASE = 20;
    /// @notice SoC-Boden bei starker Bewölkung (wenig PV erwartet -> mehr Puffer halten).
    uint256 public constant RESERVE_SOC_CLOUDY = 40;
    /// @notice SoC-Boden bei hoher Strahlung (viel PV erwartet -> tiefer entladen erlaubt).
    uint256 public constant RESERVE_SOC_SUNNY = 10;

    /// @notice Ab dieser Bewölkung (%) gilt das Wetter als schlecht.
    uint256 public constant CLOUDY_THRESHOLD = 80;
    /// @notice Ab dieser Strahlung (W/m²) gilt das Wetter als gut.
    uint256 public constant SUNNY_THRESHOLD_WM2 = 400;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event HouseholdManaged(address indexed household);
    event DecisionMade(
        address indexed household,
        Action action,
        uint256 amountWh,
        uint256 slot,
        string reason
    );

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address _oracle) {
        oracle = IOracleStorage(_oracle);
        owner = msg.sender;
    }

    /// @notice Stellt einen Haushalt unter Batterie-Verwaltung.
    /// @dev Nur verwaltete Haushalte akzeptiert decideAction(); reine
    ///      Konsumenten ohne Batterie liefern dort IDLE statt zu reverten.
    function addHousehold(address household) external {
        require(msg.sender == owner, "Only owner");
        require(!isManaged[household], "Already managed");
        require(oracle.isHouseholdRegistered(household), "Not in oracle");
        isManaged[household] = true;
        managedHouseholds.push(household);
        emit HouseholdManaged(household);
    }

    // ─────────────────────────────────────────────────────────────
    //  Optimierungs-Logik
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Trifft eine Lade-/Entladeentscheidung für einen Haushalt,
     *         protokolliert sie im Storage und emittiert `DecisionMade`.
     * @dev Aufrufer ist im Normalfall P2PEnergyMarket.settleSlot() - live in
     *      derselben Transaktion, damit Entscheidung und Meter-Daten zum
     *      gleichen Slot gehören. Der Rückgabewert wird dort auf das
     *      gehandelte Netto angerechnet.
     * @return action   IDLE / CHARGE / DISCHARGE
     * @return amountWh Energiemenge in Wh, um die das Netto korrigiert wird
     */
    function decideAction(address household) external returns (Action, uint256) {
        require(isManaged[household], "Not managed");

        uint256 slot = oracle.getCurrentSlot();
        Decision memory prev = lastDecision[household];

        // Idempotenz pro Slot: settleSlot() UND battery_optimizer.py können
        // decideAction() im selben Slot aufrufen. Der zweite Aufruf liefert die
        // bereits getroffene Entscheidung zurück, statt die Zähler doppelt
        // hochzuzählen oder ein zweites Event zu emittieren. `timestamp != 0`
        // unterscheidet "noch nie entschieden" von einer Entscheidung in Slot 0.
        if (prev.timestamp != 0 && prev.slot == slot) {
            return (prev.action, prev.amountWh);
        }

        (Action action, uint256 amountWh, string memory reason) = _evaluate(household);

        lastDecision[household] = Decision({
            action: action,
            amountWh: amountWh,
            slot: slot,
            timestamp: block.timestamp
        });

        if (action == Action.CHARGE) {
            totalChargedWh[household] += amountWh;
        } else if (action == Action.DISCHARGE) {
            totalDischargedWh[household] += amountWh;
        }

        emit DecisionMade(household, action, amountWh, slot, reason);
        return (action, amountWh);
    }

    /**
     * @notice Gleiche Strategie wie decideAction(), aber als `view` - ohne
     *         Transaktion und ohne State-Änderung.
     * @dev Für battery_optimizer.py bzw. das CLI-Dashboard: die Entscheidung
     *      kann gratis gelesen und angezeigt werden, bevor settleSlot() sie
     *      fixiert. Beide Einstiegspunkte teilen sich _evaluate(), damit
     *      Anzeige und Abrechnung garantiert dieselbe Logik verwenden.
     */
    function previewAction(address household)
        external
        view
        returns (Action action, uint256 amountWh, string memory reason)
    {
        return _evaluate(household);
    }

    /**
     * @dev Kern der Strategie: liest die Oracle-Daten und leitet daraus die
     *      Entscheidung ab. Bewusst `view`, damit decideAction() (schreibend)
     *      und previewAction() (lesend) dieselbe Funktion nutzen können.
     */
    function _evaluate(address household)
        internal
        view
        returns (Action, uint256, string memory)
    {
        IOracleStorage.MeterReading memory mr = oracle.getLatestMeterReading(household);
        IOracleStorage.BatteryState memory bs = oracle.getLatestBatteryState(household);

        // Reine Konsumenten (config: battery_capacity_kwh = 0) und Haushalte,
        // für die der Oracle noch keinen Batterie-Wert geschrieben hat, dürfen
        // nicht reverten - sonst blockiert settleSlot() den Slot für alle.
        // Zugleich schützt das die Division durch capacityWh weiter unten.
        if (bs.capacityWh == 0) {
            return (Action.IDLE, 0, "no battery capacity");
        }

        // Schritt 1+2 der Strategie: netto = PV nach Eigenverbrauch.
        int256 netWh = int256(mr.productionWh) - int256(mr.consumptionWh);

        if (netWh > 0) {
            // Überschuss -> Laden hat Vorrang vor dem Verkauf am Markt.
            if (bs.socPercent >= MAX_SOC) {
                return (Action.IDLE, 0, "battery full - surplus to market");
            }
            // Kopfraum bis MAX_SOC in Wh (socPercent ist 0-100, daher /100).
            uint256 headroomWh = (bs.capacityWh * (MAX_SOC - bs.socPercent)) / 100;
            uint256 chargeWh = _min(_min(uint256(netWh), bs.maxRateWh), headroomWh);
            if (chargeWh == 0) {
                return (Action.IDLE, 0, "charge limit reached");
            }
            return (Action.CHARGE, chargeWh, "store PV surplus");
        }

        if (netWh < 0) {
            // Defizit -> zuerst aus der Batterie decken, statt am Markt zuzukaufen.
            // Das Wetter wird erst hier gelesen: nur der Entlade-Boden hängt
            // davon ab, und settleSlot() ruft das pro Haushalt auf (Gas sparen).
            uint256 reserveSoc = _reserveSoc(oracle.getLatestWeather());
            if (bs.socPercent <= reserveSoc) {
                return (Action.IDLE, 0, "soc at weather reserve - buy from market");
            }
            // Nutzbar ist nur die Energie OBERHALB des Wetter-Puffers.
            uint256 usableWh = (bs.capacityWh * (bs.socPercent - reserveSoc)) / 100;
            uint256 dischargeWh = _min(_min(uint256(-netWh), bs.maxRateWh), usableWh);
            if (dischargeWh == 0) {
                return (Action.IDLE, 0, "discharge limit reached");
            }
            return (Action.DISCHARGE, dischargeWh, "battery covers deficit");
        }

        return (Action.IDLE, 0, "production matches consumption");
    }

    /**
     * @dev Wetter-adaptiver SoC-Boden (Schritt 4 der Strategie).
     *      Viel erwartete PV -> tieferes Entladen erlaubt, die Batterie füllt
     *      sich bald wieder. Wenig erwartete PV -> mehr Reserve halten.
     *      Fehlt der Wetter-Wert noch (alle Felder 0), greift automatisch der
     *      konservative Basiswert - dafür braucht es keinen Sonderfall.
     */
    function _reserveSoc(IOracleStorage.WeatherData memory wd)
        internal
        pure
        returns (uint256)
    {
        if (wd.cloudCover >= CLOUDY_THRESHOLD) return RESERVE_SOC_CLOUDY;
        if (wd.irradianceWm2 >= SUNNY_THRESHOLD_WM2) return RESERVE_SOC_SUNNY;
        return RESERVE_SOC_BASE;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Letzte protokollierte Entscheidung inklusive Slot und Zeitstempel.
    function getLastDecision(address household) external view returns (Decision memory) {
        return lastDecision[household];
    }

    /// @notice Alle Haushalte, deren Batterie dieser Contract steuert.
    function getManagedHouseholds() external view returns (address[] memory) {
        return managedHouseholds;
    }

    /// @notice Batterie-Status eines Haushalts, wie ihn die Strategie gerade sieht.
    /// @dev Ein Call fürs Dashboard statt mehrerer einzelner Oracle-Reads:
    ///      socPercent/capacityWh kommen unverändert aus dem Oracle, `reserveSoc`
    ///      ist der daraus abgeleitete Entlade-Boden dieses Slots, die beiden
    ///      Zähler zeigen die kumulierten Zyklen.
    function getBatteryStatus(address household)
        external
        view
        returns (
            uint256 socPercent,
            uint256 capacityWh,
            uint256 reserveSoc,
            uint256 chargedWh,
            uint256 dischargedWh
        )
    {
        IOracleStorage.BatteryState memory bs = oracle.getLatestBatteryState(household);
        return (
            bs.socPercent,
            bs.capacityWh,
            _reserveSoc(oracle.getLatestWeather()),
            totalChargedWh[household],
            totalDischargedWh[household]
        );
    }
}
