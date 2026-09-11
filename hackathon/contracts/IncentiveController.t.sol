// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IncentiveController} from "./IncentiveController.sol";

/**
 * @title IncentiveControllerTest
 * @notice Phase 3: prüft Score-Update und Preis-Multiplikator.
 * @dev Der Test-Contract deployt den Controller selbst und ist damit owner
 *      und autorisierte AI - er kann Prognosen und Ist-Werte schreiben.
 */
contract IncentiveControllerTest is Test {
    IncentiveController ic;

    address constant GOOD = address(0xA1);   // hält sich an die Prognose
    address constant BAD  = address(0xB2);   // weicht stark ab
    address constant NONE = address(0xC3);   // nie prognostiziert

    function setUp() public {
        ic = new IncentiveController();
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// @dev Ein kompletter Slot: Prognose rein, Ist-Wert rein, Score fällt an.
    function _slot(
        address household,
        uint256 slot,
        uint256 expectedCons,
        uint256 actualCons
    ) internal {
        ic.submitForecast(household, slot, expectedCons, 0);
        ic.submitActual(household, slot, actualCons, 0);
    }

    // ── Startzustand ─────────────────────────────────────────────────

    function test_UnknownHousehold_IsNeutral() public view {
        assertEq(ic.getPriceMultiplier(NONE), 1000, "unbekannt muss neutral sein");
        assertEq(ic.getReputationScore(NONE), 0);
    }

    function test_FirstForecast_SetsInitialScore() public {
        ic.submitForecast(GOOD, 1, 1000, 0);
        assertEq(ic.getReputationScore(GOOD), 500, "Startwert 500");
        assertEq(ic.getPriceMultiplier(GOOD), 1000, "Startwert = neutraler Preis");
    }

    // ── Belohnung ────────────────────────────────────────────────────

    function test_AccurateForecast_RaisesScoreAndCutsPrice() public {
        // 5% Abweichung -> innerhalb TIGHT_BAND (100 Promille)
        _slot(GOOD, 1, 1000, 1050);
        assertEq(ic.getReputationScore(GOOD), 530, "500 + SCORE_REWARD");
        assertLt(ic.getPriceMultiplier(GOOD), 1000, "guter Score = Rabatt");
    }

    function test_Score_SaturatesAtMax() public {
        for (uint256 s = 1; s <= 30; s++) {
            _slot(GOOD, s, 1000, 1000);
        }
        assertEq(ic.getReputationScore(GOOD), 1000, "Deckel bei MAX_SCORE");
        assertEq(ic.getPriceMultiplier(GOOD), 800, "max Score = 20% Rabatt");
    }

    // ── Bestrafung ───────────────────────────────────────────────────

    function test_BadForecast_LowersScoreAndRaisesPrice() public {
        // 50% Abweichung -> über LOOSE_BAND (250 Promille)
        _slot(BAD, 1, 1000, 1500);
        assertEq(ic.getReputationScore(BAD), 440, "500 - SCORE_PENALTY");
        assertGt(ic.getPriceMultiplier(BAD), 1000, "schlechter Score = Aufschlag");
    }

    function test_Score_FloorsAtZero() public {
        for (uint256 s = 1; s <= 20; s++) {
            _slot(BAD, s, 1000, 3000);
        }
        assertEq(ic.getReputationScore(BAD), 0, "kein Underflow unter 0");
        assertEq(ic.getPriceMultiplier(BAD), 1200, "min Score = 20% Aufschlag");
    }

    // ── Neutrale Zone ────────────────────────────────────────────────

    function test_MiddleDeviation_LeavesScoreUnchanged() public {
        // 15% Abweichung: über TIGHT_BAND, unter LOOSE_BAND
        _slot(GOOD, 1, 1000, 1150);
        assertEq(ic.getReputationScore(GOOD), 500, "neutrale Zone");
    }

    // ── Regressionen: die beiden Fallen im Starter-Code ──────────────

    /// @dev score==0 darf NICHT als "neuer Haushalt" gelesen werden, sonst
    ///      bekommt der schlechteste Haushalt beim nächsten Forecast 500
    ///      geschenkt.
    function test_ZeroScore_IsNotResetByNextForecast() public {
        for (uint256 s = 1; s <= 20; s++) {
            _slot(BAD, s, 1000, 3000);
        }
        assertEq(ic.getReputationScore(BAD), 0);

        ic.submitForecast(BAD, 99, 1000, 0);
        assertEq(ic.getReputationScore(BAD), 0, "keine Gratis-Amnestie");
        assertEq(ic.getPriceMultiplier(BAD), 1200, "Aufschlag bleibt");
    }

    /// @dev Ein wiederholtes submitActual() für denselben Slot darf den Score
    ///      nicht erneut verändern (Retry-Sicherheit).
    function test_RepeatedActual_ScoresOnlyOnce() public {
        ic.submitForecast(GOOD, 1, 1000, 0);
        ic.submitActual(GOOD, 1, 1000, 0);
        assertEq(ic.getReputationScore(GOOD), 530);

        ic.submitActual(GOOD, 1, 1000, 0);
        ic.submitActual(GOOD, 1, 1000, 0);
        assertEq(ic.getReputationScore(GOOD), 530, "Slot nur einmal bewertet");
    }

    // ── Reihenfolge / fehlende Daten ─────────────────────────────────

    /// @dev Ohne vorherige Prognose gibt es nichts zu bewerten.
    function test_ActualWithoutForecast_DoesNothing() public {
        ic.submitActual(GOOD, 1, 1000, 0);
        assertEq(ic.getReputationScore(GOOD), 0, "kein Score ohne Prognose");
        assertEq(ic.getPriceMultiplier(GOOD), 1000);
    }

    /// @dev Übersprungener Slot: Oracle hat nie Messwerte geschrieben.
    function test_ZeroActual_DoesNotScore() public {
        ic.submitForecast(GOOD, 1, 1000, 0);
        ic.submitActual(GOOD, 1, 0, 0);
        assertEq(ic.getReputationScore(GOOD), 500, "unveraendert");
    }

    // ── Zugriffsschutz ───────────────────────────────────────────────

    function test_OnlyAuthorizedAI_CanSubmit() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("Not authorized AI");
        ic.submitForecast(GOOD, 1, 1000, 0);
    }

    // ── Das Demo-Ergebnis ────────────────────────────────────────────

    /// @dev Der Nachweis, den Phase 3 verlangt: ein belohnter Haushalt gegen
    ///      einen nicht belohnten, mit messbar unterschiedlichem Preis.
    function test_RewardedVsUnrewarded_PriceGap() public {
        for (uint256 s = 1; s <= 10; s++) {
            _slot(GOOD, s, 1000, 1020);   // 2% Abweichung
            _slot(BAD, s, 1000, 1600);    // 60% Abweichung
        }

        uint256 goodPrice = ic.getPriceMultiplier(GOOD);
        uint256 badPrice = ic.getPriceMultiplier(BAD);

        assertLt(goodPrice, 1000, "genauer Haushalt zahlt weniger");
        assertGt(badPrice, 1000, "abweichender Haushalt zahlt mehr");
        assertGt(badPrice - goodPrice, 100, "Unterschied muss sichtbar sein");
    }
}
