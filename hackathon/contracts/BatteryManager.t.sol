// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {OracleStorage} from "./OracleStorage.sol";
import {BatteryManager} from "./BatteryManager.sol";
import {IBatteryManager} from "./interfaces/IBatteryManager.sol";

/**
 * @title BatteryManagerTest
 * @notice Phase 2: prüft die Lade-/Entladestrategie inkl. Wetter-Adaption.
 * @dev Der Test-Contract deployt OracleStorage selbst und ist damit
 *      automatisch dessen owner + authorizedOracle - er kann also Meter-,
 *      Batterie- und Wetterdaten wie das Python-Oracle schreiben.
 */
contract BatteryManagerTest is Test {
    OracleStorage oracle;
    BatteryManager bm;

    address constant HOUSE_A = address(0xA1);   // PV + Batterie 10 kWh
    address constant HOUSE_B = address(0xB2);   // PV + Batterie 7.5 kWh
    address constant HOUSE_C = address(0xC3);   // reiner Konsument, keine Batterie

    uint256 constant CAP_A = 10_000;            // Wh
    uint256 constant RATE_A = 3_000;            // Wh pro Slot

    function setUp() public {
        oracle = new OracleStorage();
        bm = new BatteryManager(address(oracle));

        oracle.registerHousehold(HOUSE_A);
        oracle.registerHousehold(HOUSE_B);
        oracle.registerHousehold(HOUSE_C);

        bm.addHousehold(HOUSE_A);
        bm.addHousehold(HOUSE_B);
        bm.addHousehold(HOUSE_C);
    }

    // ── Helpers ──────────────────────────────────────────────────

    /// @dev Schreibt einen kompletten Slot wie oracle_writer.py: Wetter + Meter + Batterie.
    function _feed(
        address household,
        uint256 productionWh,
        uint256 consumptionWh,
        uint256 socPercent,
        uint256 capacityWh,
        uint256 irradianceWm2,
        uint256 cloudCover
    ) internal {
        oracle.updateWeather(irradianceWm2, 200, cloudCover);
        oracle.updateMeter(household, consumptionWh, productionWh);
        oracle.updateBattery(household, socPercent, capacityWh, RATE_A);
    }

    /// @dev Rückt einen Slot vor - decideAction() entscheidet nur einmal pro Slot.
    function _nextSlot() internal {
        vm.warp(block.timestamp + oracle.SLOT_DURATION());
        oracle.updateSlot();
    }

    // ── Laden ────────────────────────────────────────────────────

    function test_ChargeOnSurplus() public {
        // Überschuss 2000 Wh, SoC 50% -> alles passt in die Batterie
        _feed(HOUSE_A, 3_000, 1_000, 50, CAP_A, 300, 40);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);

        assertEq(uint8(action), uint8(IBatteryManager.Action.CHARGE));
        assertEq(amount, 2_000);
    }

    function test_ChargeCappedByMaxRate() public {
        // Überschuss 5000 Wh > maxRate 3000 Wh -> Rest geht an den Markt
        _feed(HOUSE_A, 6_000, 1_000, 50, CAP_A, 700, 10);

        (, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(amount, RATE_A);
    }

    function test_ChargeCappedByHeadroom() public {
        // SoC 93% -> Kopfraum bis MAX_SOC(95) = 10000 * 2 / 100 = 200 Wh
        _feed(HOUSE_A, 4_000, 1_000, 93, CAP_A, 700, 10);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.CHARGE));
        assertEq(amount, 200);
    }

    function test_IdleWhenBatteryFull() public {
        // SoC == MAX_SOC -> Überschuss bleibt im Netto und wird verkauft
        _feed(HOUSE_A, 4_000, 1_000, bm.MAX_SOC(), CAP_A, 700, 10);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.IDLE));
        assertEq(amount, 0);
    }

    // ── Entladen ─────────────────────────────────────────────────

    function test_DischargeOnDeficit() public {
        // Defizit 2000 Wh, SoC 50%, normales Wetter -> Reserve 20%
        // nutzbar = 10000 * (50-20) / 100 = 3000 Wh -> Defizit voll gedeckt
        _feed(HOUSE_A, 0, 2_000, 50, CAP_A, 100, 40);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.DISCHARGE));
        assertEq(amount, 2_000);
    }

    function test_CloudyWeatherRaisesReserveAndLimitsDischarge() public {
        // Bewölkung 85% -> Reserve 40% statt 20%
        // nutzbar = 10000 * (50-40) / 100 = 1000 Wh, obwohl 2000 Wh fehlen
        _feed(HOUSE_A, 0, 2_000, 50, CAP_A, 50, 85);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.DISCHARGE));
        assertEq(amount, 1_000);
    }

    function test_SunnyWeatherAllowsDeeperDischarge() public {
        // SoC 15%: bei Basis-Reserve (20%) wäre das IDLE.
        // Hohe Strahlung -> Reserve 10% -> nutzbar = 10000 * 5 / 100 = 500 Wh
        _feed(HOUSE_A, 0, 2_000, 15, CAP_A, 700, 10);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.DISCHARGE));
        assertEq(amount, 500);
    }

    function test_IdleWhenSocAtReserve() public {
        // SoC 20% == Basis-Reserve -> nicht entladen, Defizit wird zugekauft
        _feed(HOUSE_A, 0, 2_000, 20, CAP_A, 100, 40);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.IDLE));
        assertEq(amount, 0);
    }

    // ── Randfälle ───────────────────────────────────────────────

    function test_IdleForHouseholdWithoutBattery() public {
        // Reiner Konsument (capacityWh = 0) darf NICHT reverten,
        // sonst blockiert settleSlot() den Slot für alle.
        _feed(HOUSE_C, 0, 2_000, 0, 0, 100, 40);

        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_C);
        assertEq(uint8(action), uint8(IBatteryManager.Action.IDLE));
        assertEq(amount, 0);
    }

    function test_IdleWhenProductionMatchesConsumption() public {
        _feed(HOUSE_A, 1_500, 1_500, 50, CAP_A, 300, 40);

        (IBatteryManager.Action action,) = bm.decideAction(HOUSE_A);
        assertEq(uint8(action), uint8(IBatteryManager.Action.IDLE));
    }

    function test_RevertsForUnmanagedHousehold() public {
        vm.expectRevert("Not managed");
        bm.decideAction(address(0xDEAD));
    }

    function test_PreviewMatchesDecision() public {
        _feed(HOUSE_A, 3_000, 1_000, 50, CAP_A, 300, 40);

        (IBatteryManager.Action pAction, uint256 pAmount,) = bm.previewAction(HOUSE_A);
        (IBatteryManager.Action dAction, uint256 dAmount) = bm.decideAction(HOUSE_A);

        assertEq(uint8(pAction), uint8(dAction));
        assertEq(pAmount, dAmount);
    }

    // ── Slot-Idempotenz und Zyklen ───────────────────────────────

    function test_SecondCallInSameSlotDoesNotDoubleCount() public {
        _feed(HOUSE_A, 3_000, 1_000, 50, CAP_A, 300, 40);

        bm.decideAction(HOUSE_A);
        // Zweiter Aufruf im gleichen Slot (z.B. settleSlot() nach dem
        // battery_optimizer.py) liefert die gecachte Entscheidung.
        (IBatteryManager.Action action, uint256 amount) = bm.decideAction(HOUSE_A);

        assertEq(uint8(action), uint8(IBatteryManager.Action.CHARGE));
        assertEq(amount, 2_000);
        assertEq(bm.totalChargedWh(HOUSE_A), 2_000);   // NICHT 4000
    }

    function test_ChargeDischargeCycleAcrossSlots() public {
        // Slot 1: Sonne, Überschuss -> laden
        _nextSlot();
        _feed(HOUSE_A, 3_000, 1_000, 50, CAP_A, 700, 10);
        (IBatteryManager.Action a1,) = bm.decideAction(HOUSE_A);
        assertEq(uint8(a1), uint8(IBatteryManager.Action.CHARGE));

        // Slot 2: Abend, Defizit -> entladen
        _nextSlot();
        _feed(HOUSE_A, 0, 2_500, 70, CAP_A, 0, 40);
        (IBatteryManager.Action a2,) = bm.decideAction(HOUSE_A);
        assertEq(uint8(a2), uint8(IBatteryManager.Action.DISCHARGE));

        // Beide Zähler sind gewachsen -> Lade-/Entladezyklus nachgewiesen
        assertEq(bm.totalChargedWh(HOUSE_A), 2_000);
        assertEq(bm.totalDischargedWh(HOUSE_A), 2_500);

        // lastDecision hält den Slot der letzten Entscheidung fest
        BatteryManager.Decision memory d = bm.getLastDecision(HOUSE_A);
        assertEq(d.slot, oracle.getCurrentSlot());
        assertEq(d.amountWh, 2_500);
    }

    function test_TwoHouseholdsWithBatteryAreIndependent() public {
        // Demo-Anforderung: mindestens 2 Haushalte mit Batterie
        oracle.updateWeather(300, 200, 40);

        oracle.updateMeter(HOUSE_A, 1_000, 3_000);          // Überschuss
        oracle.updateBattery(HOUSE_A, 50, CAP_A, RATE_A);

        oracle.updateMeter(HOUSE_B, 2_000, 0);              // Defizit
        oracle.updateBattery(HOUSE_B, 60, 7_500, 2_500);

        (IBatteryManager.Action aA, uint256 amtA) = bm.decideAction(HOUSE_A);
        (IBatteryManager.Action aB, uint256 amtB) = bm.decideAction(HOUSE_B);

        assertEq(uint8(aA), uint8(IBatteryManager.Action.CHARGE));
        assertEq(amtA, 2_000);

        assertEq(uint8(aB), uint8(IBatteryManager.Action.DISCHARGE));
        assertEq(amtB, 2_000);   // nutzbar = 7500 * (60-20)/100 = 3000 -> Defizit deckt

        assertEq(bm.getManagedHouseholds().length, 3);
    }

    function test_BatteryStatusExposesWeatherReserve() public {
        _feed(HOUSE_A, 0, 2_000, 50, CAP_A, 50, 85);   // bewölkt
        bm.decideAction(HOUSE_A);

        (
            uint256 soc,
            uint256 capacity,
            uint256 reserveSoc,
            uint256 charged,
            uint256 discharged
        ) = bm.getBatteryStatus(HOUSE_A);

        assertEq(soc, 50);
        assertEq(capacity, CAP_A);
        assertEq(reserveSoc, bm.RESERVE_SOC_CLOUDY());
        assertEq(charged, 0);
        assertEq(discharged, 1_000);
    }
}
