// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {OracleStorage} from "./OracleStorage.sol";
import {P2PEnergyMarket} from "./P2PEnergyMarket.sol";
import {IncentiveController} from "./IncentiveController.sol";
import {IEnergyStablecoin} from "./interfaces/IEnergyStablecoin.sol";

/// @dev Minimaler ERC-20-Mock, genau genug fuer IEnergyStablecoin.
contract MockStablecoin is IEnergyStablecoin {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function faucet() external {
        balanceOf[msg.sender] += 1_000_000;
    }
}

/**
 * @title P2PEnergyMarketTest
 * @notice Phase 3: prueft, dass settleSlot() den Incentive-Preismultiplikator
 *         tatsaechlich auf den Konsumenten anwendet.
 * @dev Deployt OracleStorage, IncentiveController und P2PEnergyMarket selbst
 *      und ist damit owner + authorizedOracle + authorizedAI zugleich.
 */
contract P2PEnergyMarketTest is Test {
    OracleStorage oracle;
    IncentiveController incentive;
    P2PEnergyMarket market;
    MockStablecoin token;

    address constant PRODUCER = address(0xA1);
    address constant GOOD_CONSUMER = address(0xB2);   // wird belohnt
    address constant BAD_CONSUMER = address(0xC3);    // wird bestraft

    uint256 constant PRICE_PER_KWH = 100_000; // wie im Contract-Default

    function setUp() public {
        oracle = new OracleStorage();
        token = new MockStablecoin();
        market = new P2PEnergyMarket(address(token), address(oracle));
        incentive = new IncentiveController();

        oracle.registerHousehold(PRODUCER);
        oracle.registerHousehold(GOOD_CONSUMER);
        oracle.registerHousehold(BAD_CONSUMER);

        market.registerHousehold(PRODUCER);
        market.registerHousehold(GOOD_CONSUMER);
        market.registerHousehold(BAD_CONSUMER);

        token.mint(GOOD_CONSUMER, 1_000_000_000);
        token.mint(BAD_CONSUMER, 1_000_000_000);
        vm.prank(GOOD_CONSUMER);
        token.approve(address(market), type(uint256).max);
        vm.prank(BAD_CONSUMER);
        token.approve(address(market), type(uint256).max);
    }

    /// @dev Baut fuer GOOD_CONSUMER einen hohen und fuer BAD_CONSUMER einen
    ///      niedrigen Reputationsscore auf, bevor gehandelt wird.
    function _buildDivergentScores() internal {
        for (uint256 s = 1; s <= 10; s++) {
            incentive.submitForecast(GOOD_CONSUMER, s, 1000, 0);
            incentive.submitActual(GOOD_CONSUMER, s, 1020, 0);  // 2% Abweichung

            incentive.submitForecast(BAD_CONSUMER, s, 1000, 0);
            incentive.submitActual(BAD_CONSUMER, s, 1600, 0);   // 60% Abweichung
        }
    }

    function _settleOneSlot(uint256 producerNetWh, uint256 goodDeficitWh, uint256 badDeficitWh) internal {
        oracle.updateMeter(PRODUCER, 0, producerNetWh);
        oracle.updateMeter(GOOD_CONSUMER, goodDeficitWh, 0);
        oracle.updateMeter(BAD_CONSUMER, badDeficitWh, 0);

        vm.warp(block.timestamp + 61);
        oracle.updateSlot();
        market.settleSlot();
    }

    // ── Ohne IncentiveController: unveraenderter Basispreis ────────────

    function test_WithoutIncentiveController_UsesBasePrice() public {
        _settleOneSlot(2000, 1000, 1000);

        // Jeder Konsument bekommt 1000 Wh, beide zum Basispreis.
        uint256 expected = market.calculateCost(1000);
        assertEq(1_000_000_000 - token.balanceOf(GOOD_CONSUMER), expected);
        assertEq(1_000_000_000 - token.balanceOf(BAD_CONSUMER), expected);
    }

    // ── Mit IncentiveController: Preis folgt dem Score ──────────────────

    function test_IncentiveController_ChangesPriceByReputation() public {
        market.setIncentiveController(address(incentive));
        _buildDivergentScores();

        uint256 goodMultiplier = incentive.getPriceMultiplier(GOOD_CONSUMER);
        uint256 badMultiplier = incentive.getPriceMultiplier(BAD_CONSUMER);
        assertLt(goodMultiplier, 1000, "guter Score -> Rabatt");
        assertGt(badMultiplier, 1000, "schlechter Score -> Aufschlag");

        _settleOneSlot(2000, 1000, 1000);

        uint256 goodPaid = 1_000_000_000 - token.balanceOf(GOOD_CONSUMER);
        uint256 badPaid = 1_000_000_000 - token.balanceOf(BAD_CONSUMER);
        uint256 basePaid = market.calculateCost(1000);

        assertLt(goodPaid, basePaid, "guter Haushalt zahlt weniger als Basispreis");
        assertGt(badPaid, basePaid, "schlechter Haushalt zahlt mehr als Basispreis");
        assertLt(goodPaid, badPaid, "guter Haushalt zahlt weniger als schlechter");

        // Exakte Rechnung fuer GOOD_CONSUMER nachvollziehen.
        uint256 expectedGood = (1000 * PRICE_PER_KWH * goodMultiplier) / 1000 / 1000;
        assertEq(goodPaid, expectedGood);
    }

    function test_IncentiveController_ProducerSideUnaffected() public {
        market.setIncentiveController(address(incentive));
        _buildDivergentScores();
        _settleOneSlot(2000, 1000, 1000);

        // Der Multiplikator wirkt nur auf den Kaeufer - der Produzent bekommt
        // in Summe trotzdem genau das, was beide Konsumenten bezahlt haben
        // (keine zusaetzliche Marge/Abzug beim Produzenten selbst).
        uint256 goodPaid = 1_000_000_000 - token.balanceOf(GOOD_CONSUMER);
        uint256 badPaid = 1_000_000_000 - token.balanceOf(BAD_CONSUMER);
        assertEq(token.balanceOf(PRODUCER), goodPaid + badPaid);
    }
}
