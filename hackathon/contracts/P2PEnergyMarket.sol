// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IEnergyStablecoin.sol";
import "./interfaces/IOracleStorage.sol";
import "./interfaces/IBatteryManager.sol";
import "./interfaces/IIncentiveController.sol";

/**
 * @title P2PEnergyMarket
 * @notice Phase 1: Direkter Peer-to-Peer-Energiehandel zwischen Haushalten,
 *         abgerechnet in einem ERC-20-Stablecoin - ohne Intermediär.
 *
 * @dev Zentraler Contract des Systems. Ablauf je Abrechnungsslot (settleSlot()):
 *        1. Slot-Nummer aus dem OracleStorage lesen, Doppelabrechnung ausschliessen
 *        2. Pro Haushalt Netto = Erzeugung - Verbrauch aus den Meter-Daten bilden
 *        3. [Phase 2, optional] Batterie-Entscheidung auf das Netto anrechnen
 *        4. Haushalte in Produzenten (Netto > 0) und Konsumenten (Netto < 0) teilen
 *        5. Proportionales Matching: jeder Produzent liefert anteilig an jeden Konsumenten
 *        6. Pro Match Stablecoin vom Konsumenten an den Produzenten transferieren
 *           ([Phase 3, optional] Preis skaliert mit dem Reputationsscore des Käufers)
 *
 *      Wichtig: Konsumenten müssen vorab approve() auf dem Stablecoin aufrufen,
 *               damit der Contract Tokens in ihrem Namen transferieren kann.
 *
 *      Sicherheitsmodell: Die Datenhoheit liegt beim OracleStorage - nur dort
 *      autorisierte Oracle-Adressen können Messwerte einspeisen. Registrierung
 *      und Preis sind owner-geschützt; settleSlot() selbst ist bewusst
 *      permissionless, da es nur bereits on-chain stehende Daten verarbeitet
 *      und jeden Slot höchstens einmal abrechnet.
 *
 *      Transparenz: Jeder Handel erzeugt ein `EnergyTraded`-Event, jeder Slot
 *      zusätzlich ein `SlotSettled`-Event.
 */
contract P2PEnergyMarket {

    // ─────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────

    IEnergyStablecoin public immutable stablecoin;
    IOracleStorage public immutable oracle;

    address public owner;
    address[] public households;
    mapping(address => bool) public isRegistered;

    /// @notice Energiepreis in Token-Einheiten pro kWh (6 Decimals).
    /// @dev Beispiel: 100_000 = 0.10 Token / kWh
    uint256 public energyPricePerKwh = 100_000;

    /// @notice Letzter abgerechneter Slot, um Doppelabrechnung zu verhindern
    uint256 public lastSettledSlot;

    /// @notice Optionale Phase-2-Integration: BatteryManager-Contract.
    /// @dev Default = address(0) -> keine Batterie-Logik aktiv, settleSlot()
    ///      verhält sich dann wie in Phase 1 (reiner Meter-Nettowert wird
    ///      gehandelt). Setzen via setBatteryManager() NACH dem Deployment
    ///      (Reihenfolge laut README bleibt: OracleStorage -> P2PEnergyMarket
    ///      -> BatteryManager, danach hier eintragen - deshalb Setter statt
    ///      Constructor-Arg, sonst würde die Deploy-Reihenfolge kollidieren).
    IBatteryManager public batteryManager;

    /// @notice Optionale Phase-3-Integration: IncentiveController-Contract.
    /// @dev Default = address(0) -> kein Preis-Incentive aktiv, settleSlot()
    ///      nutzt dann den unveränderten energyPricePerKwh (wie in Phase 1/2).
    ///      Setzen via setIncentiveController() NACH dem Deployment (Reihenfolge
    ///      laut README: ... -> IncentiveController, danach hier eintragen).
    IIncentiveController public incentiveController;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event HouseholdRegistered(address indexed household);
    event EnergyTraded(
        address indexed producer,
        address indexed consumer,
        uint256 energyWh,
        uint256 amountPaid,
        uint256 slot
    );
    event SlotSettled(uint256 indexed slot, uint256 totalEnergyTraded, uint256 totalPaid);
    event PriceUpdated(uint256 newPricePerKwh);
    event BatteryManagerUpdated(address indexed batteryManager);
    event IncentiveControllerUpdated(address indexed incentiveController);

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /**
     * @param _stablecoin Adresse des bereitgestellten ERC-20 Stablecoins
     * @param _oracle Adresse des OracleStorage Contracts
     */
    constructor(address _stablecoin, address _oracle) {
        stablecoin = IEnergyStablecoin(_stablecoin);
        oracle = IOracleStorage(_oracle);
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────
    //  Registrierung
    // ─────────────────────────────────────────────────────────────

    /// @notice Registriert einen Haushalt für den Marktplatz
    function registerHousehold(address household) external onlyOwner {
        require(!isRegistered[household], "Already registered");
        require(oracle.isHouseholdRegistered(household), "Not in oracle");
        households.push(household);
        isRegistered[household] = true;
        emit HouseholdRegistered(household);
    }

    function setEnergyPrice(uint256 newPricePerKwh) external onlyOwner {
        energyPricePerKwh = newPricePerKwh;
        emit PriceUpdated(newPricePerKwh);
    }

    /// @notice Verknüpft optional den BatteryManager-Contract (Phase 2).
    /// @dev address(0) = deaktiviert (Standard) -> settleSlot() verhält sich
    ///      wie in Phase 1. Erst NACH dem Deployment von BatteryManager aufrufen.
    function setBatteryManager(address _batteryManager) external onlyOwner {
        batteryManager = IBatteryManager(_batteryManager);
        emit BatteryManagerUpdated(_batteryManager);
    }

    /// @notice Verknüpft optional den IncentiveController-Contract (Phase 3).
    /// @dev address(0) = deaktiviert (Standard) -> settleSlot() nutzt den
    ///      unveränderten energyPricePerKwh. Erst NACH dem Deployment von
    ///      IncentiveController aufrufen.
    function setIncentiveController(address _incentiveController) external onlyOwner {
        incentiveController = IIncentiveController(_incentiveController);
        emit IncentiveControllerUpdated(_incentiveController);
    }

    // ─────────────────────────────────────────────────────────────
    //  Settlement-Logik  (HIER IMPLEMENTIEREN TEAMS)
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Rechnet den aktuellen Slot ab: matched Produzenten mit
     *         Konsumenten und transferiert den Stablecoin entsprechend.
     *
     * @dev Wird von `settlement_trigger.py` einmal pro Slot (= 1 reale Minute)
     *      aufgerufen. Bewusst ohne Zugriffsschutz: der Contract rechnet
     *      ausschliesslich mit Daten, die autorisierte Oracles zuvor in den
     *      OracleStorage geschrieben haben, und `lastSettledSlot` verhindert
     *      eine zweite Abrechnung desselben Slots.
     *
     *      Matching-Regel (proportionale Verteilung):
     *          flow(i -> j) = surplus_i * deficit_j / totalDeficit
     *      Jeder Produzent i liefert damit an jeden Konsumenten j anteilig zu
     *      dessen Defizit. Eine ausgeglichene Energiebilanz wird NICHT verlangt:
     *      Energie kann ungenutzt bleiben, deshalb ist die Bilanzprüfung
     *      auskommentiert.
     *
     *      Phase 2 (aktiv, sobald setBatteryManager() gesetzt ist):
     *      decideAction() wird live in derselben Transaktion aufgerufen, damit
     *      Entscheidung und Meter-Daten garantiert zum selben Slot gehören.
     *      CHARGE verringert das handelbare Netto (Energie bleibt im Haushalt),
     *      DISCHARGE erhöht es. isManaged() wird vorher geprüft, weil
     *      decideAction() für nicht verwaltete Haushalte revertet und sonst den
     *      Slot für alle blockieren würde.
     *
     *      Phase 3 (aktiv, sobald setIncentiveController() gesetzt ist):
     *      der Preis wird pro Trade in _executeTrade() mit dem Multiplikator des
     *      KONSUMENTEN skaliert (guter Prognose-Score = günstigerer Einkauf).
     *
     *      Reentrancy: `lastSettledSlot` wird VOR der Transfer-Schleife gesetzt
     *      (Checks-Effects-Interactions), damit ein bösartiger Token-Callback
     *      settleSlot() nicht erneut für denselben Slot betreten kann.
     *
     *      Robustheit: jeder einzelne Trade läuft in try/catch. Ein fehlendes
     *      oder zu niedriges approve() eines Konsumenten lässt damit nur diesen
     *      einen Trade ausfallen, nicht den gesamten Slot.
     *
     *      Emittiert `EnergyTraded` pro Match und `SlotSettled` am Slot-Ende.
     */
    function settleSlot() external {

        // get current slot state
        uint256 currentSlot = oracle.getCurrentSlot();

        require(currentSlot > lastSettledSlot, "Current slot is already settled");
        
        // iterating through all households
        int256[] memory netProduction = new int256[](households.length);

        for (uint256 i = 0; i < households.length; i++) {
            address household = households[i];

            IOracleStorage.MeterReading memory lastReading = oracle.getLatestMeterReading(household);

            netProduction[i] = int256 (lastReading.productionWh) - int256 (lastReading.consumptionWh);

            // Phase 2: Batterie-Entscheidung VOR der Klassifizierung einrechnen,
            // damit Handel und Batterie-Strategie konsistent sind.
            // isManaged() zuerst prüfen: decideAction() revertet für nicht
            // verwaltete Haushalte und würde sonst den Slot für alle blockieren.
            if (address(batteryManager) != address(0)
                && batteryManager.isManaged(household)) {
                try batteryManager.decideAction(household)
                    returns (IBatteryManager.Action action, uint256 amountWh) {
                    if (action == IBatteryManager.Action.CHARGE) {
                        netProduction[i] -= int256(amountWh);   // Energie bleibt im Haushalt
                    } else if (action == IBatteryManager.Action.DISCHARGE) {
                        netProduction[i] += int256(amountWh);   // Batterie liefert zusätzlich
                    }
                } catch {
                    // Batterie-Call fehlgeschlagen -> ignorieren, der Handel
                    // läuft mit dem ursprünglichen Netto weiter.
                }
            }
        }

        // 3. Matche Produzenten mit Konsumenten (proportional)
        uint256 totalSurplus = 0;
        uint256 totalDeficit = 0;

        /**
        uint256[] memory producers = new uint256[](households.length);
        uint256[] memory consumers = new uint256[](households.length);
        
        for (uint256 i = 0; i < netProduction.length; i++) {
            if (netProduction[i] > 0) {
                totalSurplus += netProduction[i];
                producers[] += netProduction[i];

            } else if (netProduction[i] < 0) {
                totalDeficit += netProduction[i];
                consumers[] += netProduction[i];

            }     

        } */
        
        uint256[] memory producerIdx = new uint256[](households.length);
        uint256[] memory producerAmt = new uint256[](households.length);
        uint256 producerCount = 0;

        uint256[] memory consumerIdx = new uint256[](households.length);
        uint256[] memory consumerAmt = new uint256[](households.length);
        uint256 consumerCount = 0;

        for (uint256 i = 0; i < netProduction.length; i++) {
            if (netProduction[i] > 0) {
                producerIdx[producerCount] = i;               // <-- remembers WHICH household
                producerAmt[producerCount] = uint256(netProduction[i]);
                producerCount++;
                totalSurplus += uint256(netProduction[i]);
            } else if (netProduction[i] < 0) {
                consumerIdx[consumerCount] = i;                // <-- remembers WHICH household
                consumerAmt[consumerCount] = uint256(-netProduction[i]);
                consumerCount++;
                totalDeficit += uint256(-netProduction[i]);
            }
        }

        // removed for now since energy balance may not always zero out, since energy can also just be lost/not used."
        // require(totalSurplus == totalDeficit, "Energy produced and consumed does not zero out");
        totalSurplus;   // nur für die (auskommentierte) Bilanzprüfung oben
                        // Ende Klassifizierungs-Block: netProduction/totalSurplus sind ab hier weg

        // flow(i → j) = surplus_i × (deficit_j / total_deficit)
        // producer i and consumer j

        uint256 totalEnergyTraded = 0;
        uint256 totalAmountPaid = 0;

        // 7. Setze lastSettledSlot auf currentSlot --> before settle loop to avoid re-entrancy attacks
        lastSettledSlot = currentSlot;
        
        // each flow is computed and acted on immediately
        for (uint256 i = 0; i < producerCount; i++) {
            for (uint256 j = 0; j < consumerCount; j++) {
                uint256 flowWh = (producerAmt[i] * consumerAmt[j]) / totalDeficit;
                
                if (flowWh == 0) continue;

                // Steps 4-6 stecken in _executeTrade(): ausgelagert, weil die
                // lokalen Variablen (producer, consumer, amountPaid) sonst
                // zusammen mit den Matching-Arrays "Stack too deep" auslösen.
                // try/catch (nur für external calls möglich, daher this.):
                // ein einzelner fehlschlagender Trade (z.B. fehlendes/zu
                // niedriges approve() eines Konsumenten) soll nicht den
                // gesamten Slot für alle Haushalte blockieren.
                try this._executeTrade(
                    households[producerIdx[i]],
                    households[consumerIdx[j]],
                    flowWh
                ) returns (uint256 amountPaid) {
                    totalEnergyTraded += flowWh;
                    totalAmountPaid += amountPaid;
                } catch {
                    // dieser Trade fehlgeschlagen -> überspringen, Rest des
                    // Slots wird trotzdem abgerechnet
                }

            }
        }    

        // Step 8
        emit SlotSettled(lastSettledSlot, totalEnergyTraded, totalAmountPaid);
    }

    /// @dev Führt einen einzelnen Match aus: Preis berechnen, Token
    ///      transferieren, Event emittieren. Rückgabe = bezahlter Betrag.
    function _executeTrade(
        address producer,
        address consumer,
        uint256 flowWh
    ) external returns (uint256) {
        require(msg.sender == address(this), "internal only");

        // Step 4: energyWh * pricePerKwh / 1000  (Wh -> kWh conversion).
        // Phase 3: der Incentive-Multiplikator gilt für den KONSUMENTEN
        // (Käufer), nicht den Produzenten - siehe IncentiveController.
        // getPriceMultiplier() ist `view`, daher kein try/catch nötig wie bei
        // batteryManager.decideAction() oben.
        uint256 pricePerKwh = energyPricePerKwh;
        if (address(incentiveController) != address(0)) {
            uint256 multiplier = incentiveController.getPriceMultiplier(consumer);
            pricePerKwh = (energyPricePerKwh * multiplier) / 1000;
        }
        uint256 amountPaid = (flowWh * pricePerKwh) / 1000;

        // Step 5: Konsument muss vorher approve() aufgerufen haben.
        stablecoin.transferFrom(consumer, producer, amountPaid);

        // Step 6: lastSettledSlot ist der gerade abgerechnete Slot (oben gesetzt).
        emit EnergyTraded(producer, consumer, flowWh, amountPaid, lastSettledSlot);

        return amountPaid;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions (Hilfsfunktionen)
    // ─────────────────────────────────────────────────────────────

    function getHouseholdCount() external view returns (uint256) {
        return households.length;
    }

    function getAllHouseholds() external view returns (address[] memory) {
        return households;
    }

    /// @notice Helper: Berechnet den Token-Betrag zum Basispreis (ohne Incentive).
    /// @dev _executeTrade() ruft dies NICHT auf, sondern rechnet mit dem
    ///      konsumentenspezifischen Preis - diese Funktion bleibt als
    ///      Vorschau-/UI-Helfer für den unveränderten Basispreis stehen.
    function calculateCost(uint256 energyWh) public view returns (uint256) {
        // Wh -> kWh -> Token (mit Decimals)
        return (energyWh * energyPricePerKwh) / 1000;
    }
}
