// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IOracleStorage.sol";

/**
 * @title OracleStorage
 * @notice Zentraler On-Chain Speicher für alle Mess- und Wetterdaten.
 * @dev VOLLSTÄNDIG VORGEGEBEN - Teams modifizieren diesen Contract NICHT.
 *
 *      Schreibzugriff: Nur autorisierte Oracle-Adressen (gesetzt vom Owner).
 *      Lesezugriff: Öffentlich.
 *
 *      Das Python-Skript `oracle_writer.py` schreibt jeden Slot neue Werte.
 *      Andere Contracts (P2PEnergyMarket, BatteryManager, etc.) lesen via Interface.
 */
contract OracleStorage is IOracleStorage {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    address public owner;
    mapping(address => bool) public authorizedOracles;
    mapping(address => bool) public registeredHouseholds;

    // Aktuellster Wert pro Haushalt (für einfachen Zugriff)
    mapping(address => MeterReading) private latestMeter;
    mapping(address => BatteryState) private latestBattery;
    WeatherData private latestWeather;

    // Historie pro Haushalt und Slot (optional, für AI-Phase 3)
    mapping(address => mapping(uint256 => MeterReading)) public meterHistory;

    // Slot-Counter: 1 Slot = 1 reale Minute = 15 Simulationsminuten
    // (konsistent mit config.json und data_simulator.py)
    uint256 public currentSlot;
    uint256 public immutable startTimestamp;
    uint256 public constant SLOT_DURATION = 60; // 60 Sekunden

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event HouseholdRegistered(address indexed household);
    event OracleAuthorized(address indexed oracle);
    event OracleRevoked(address indexed oracle);
    event MeterUpdated(address indexed household, uint256 slot, uint256 consumption, uint256 production);
    event BatteryUpdated(address indexed household, uint256 slot, uint256 soc);
    event WeatherUpdated(uint256 slot, uint256 irradiance, int256 temperature);

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyOracle() {
        require(authorizedOracles[msg.sender], "Not authorized oracle");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        authorizedOracles[msg.sender] = true; // Deployer ist initial Oracle
        startTimestamp = block.timestamp;
        emit OracleAuthorized(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────

    /// @notice Erlaubt einer Adresse das Schreiben von Messwerten.
    /// @dev Erfüllt die Challenge-Anforderung "nur autorisierte Oracle-Adressen
    ///      dürfen Daten einspeisen".
    function authorizeOracle(address oracle) external onlyOwner {
        authorizedOracles[oracle] = true;
        emit OracleAuthorized(oracle);
    }

    /// @notice Entzieht einer Adresse das Schreibrecht wieder.
    function revokeOracle(address oracle) external onlyOwner {
        authorizedOracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    /// @notice Meldet einen Haushalt an; erst danach nimmt der Oracle Messwerte
    ///         für ihn entgegen.
    /// @dev Wird von `oracle_writer.py` beim Start für jeden Haushalt aus
    ///      config.json aufgerufen. P2PEnergyMarket.registerHousehold() prüft
    ///      gegen diese Liste.
    function registerHousehold(address household) external onlyOracle {
        registeredHouseholds[household] = true;
        emit HouseholdRegistered(household);
    }

    // ─────────────────────────────────────────────────────────────
    //  Schreibfunktionen (nur Oracle)
    // ─────────────────────────────────────────────────────────────

    /// @notice Setzt den Slot-Zähler auf den aus der Blockzeit abgeleiteten Wert.
    /// @dev `currentSlot` folgt block.timestamp, NICHT der Anzahl der Aufrufe.
    ///      Dauert ein Oracle-Durchlauf länger als SLOT_DURATION, springt der
    ///      Zähler - Aufrufer dürfen sich nicht auf lückenlose Slots verlassen.
    function updateSlot() external onlyOracle {
        currentSlot = (block.timestamp - startTimestamp) / SLOT_DURATION;
    }

    /// @notice Schreibt Smart-Meter- und PV-Daten eines Haushalts für den
    ///         aktuellen Slot (Phase 1).
    /// @dev Schreibt sowohl den Letztwert als auch die Historie unter
    ///      `meterHistory[household][currentSlot]` (Basis für Phase 3).
    function updateMeter(
        address household,
        uint256 consumptionWh,
        uint256 productionWh
    ) external onlyOracle {
        require(registeredHouseholds[household], "Not registered");
        MeterReading memory r = MeterReading({
            consumptionWh: consumptionWh,
            productionWh: productionWh,
            timestamp: block.timestamp
        });
        latestMeter[household] = r;
        meterHistory[household][currentSlot] = r;
        emit MeterUpdated(household, currentSlot, consumptionWh, productionWh);
    }

    /// @notice Schreibt den Batteriezustand eines Haushalts (Phase 2).
    /// @param socPercent Ladestand in Prozent (0-100), wird validiert.
    /// @dev Emittiert `BatteryUpdated` - zusammen mit den DecisionMade-Events des
    ///      BatteryManagers ergibt das den Ladestand-Verlauf über die Zeit.
    function updateBattery(
        address household,
        uint256 socPercent,
        uint256 capacityWh,
        uint256 maxRateWh
    ) external onlyOracle {
        require(registeredHouseholds[household], "Not registered");
        require(socPercent <= 100, "Invalid SoC");
        latestBattery[household] = BatteryState({
            socPercent: socPercent,
            capacityWh: capacityWh,
            maxRateWh: maxRateWh,
            timestamp: block.timestamp
        });
        emit BatteryUpdated(household, currentSlot, socPercent);
    }

    /// @notice Schreibt die gemeinsamen Wetterdaten des aktuellen Slots (Phase 2).
    /// @dev Wetter gilt für alle Haushalte gemeinsam, daher nur ein Datensatz.
    ///      In der Simulation stündlich aktualisiert (= 4-Minuten-Intervall).
    function updateWeather(
        uint256 irradianceWm2,
        int256 temperatureC,
        uint256 cloudCover
    ) external onlyOracle {
        require(cloudCover <= 100, "Invalid cloud cover");
        latestWeather = WeatherData({
            irradianceWm2: irradianceWm2,
            temperatureC: temperatureC,
            cloudCover: cloudCover,
            timestamp: block.timestamp
        });
        emit WeatherUpdated(currentSlot, irradianceWm2, temperatureC);
    }

    // ─────────────────────────────────────────────────────────────
    //  Getter
    // ─────────────────────────────────────────────────────────────

    function getLatestMeterReading(address household) external view returns (MeterReading memory) {
        return latestMeter[household];
    }

    function getLatestBatteryState(address household) external view returns (BatteryState memory) {
        return latestBattery[household];
    }

    function getLatestWeather() external view returns (WeatherData memory) {
        return latestWeather;
    }

    function getCurrentSlot() external view returns (uint256) {
        return currentSlot;
    }

    function isHouseholdRegistered(address household) external view returns (bool) {
        return registeredHouseholds[household];
    }

    /// @notice Historischer Messwert eines Haushalts zu einem bestimmten Slot.
    /// @dev Wird von `ai_forecast.py` genutzt, um den Ist-Wert eines abgelaufenen
    ///      Slots nachzureichen. Ein Ergebnis mit lauter Nullen bedeutet, dass
    ///      der Slot übersprungen wurde.
    function getMeterAtSlot(address household, uint256 slot) external view returns (MeterReading memory) {
        return meterHistory[household][slot];
    }
}
