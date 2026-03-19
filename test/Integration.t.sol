// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {PrrrGuardRegistry} from "../src/PrrrGuardRegistry.sol";
import {MockVRFCoordinator} from "../src/mocks/MockVRFCoordinator.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

/// @title Integration Test — Full Prrr attack simulation
/// @notice Tests the complete cycle: oracle attack → watcher detection → report → VRF → settlement → circuit breaker
contract IntegrationTest is Test {
    PrrrSettlement public settlement;
    CircuitBreaker public breaker;
    PrrrGuardRegistry public registry;
    MockVRFCoordinator public vrfCoordinator;
    MockAggregator public chainlinkFeed;
    MockAavePool public aavePool;

    address public admin = makeAddr("admin");
    address public watcherA = makeAddr("watcherA");
    address public watcherB = makeAddr("watcherB");
    address public watcherC = makeAddr("watcherC");

    uint256 internal _vrfRequestCounter;

    function setUp() public {
        vm.startPrank(admin);

        vrfCoordinator = new MockVRFCoordinator();
        settlement = new PrrrSettlement(
            address(vrfCoordinator), 1, bytes32(uint256(1)), address(1)
        );
        breaker = new CircuitBreaker(address(settlement));
        settlement.setCircuitBreaker(address(breaker));
        registry = new PrrrGuardRegistry();

        // Deploy mock price infrastructure
        chainlinkFeed = new MockAggregator(2000_00000000, 8, "ETH/USD");
        aavePool = new MockAavePool();
        aavePool.setAssetPrice(address(0xdead), 2000_00000000);

        vm.stopPrank();

        vm.deal(address(settlement), 10 ether);
        vm.deal(watcherA, 1 ether);
        vm.deal(watcherB, 1 ether);
        vm.deal(watcherC, 1 ether);
    }

    /// @notice Full Prrr cycle with oracle attack simulation
    function test_fullPrrrCycle() public {
        // Step 1: Admin creates epoch
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 10, 50);
        assertEq(epochId, 1);

        // Step 2: Watchers register
        vm.prank(watcherA);
        registry.register{value: 0.01 ether}();
        vm.prank(watcherB);
        registry.register{value: 0.01 ether}();
        vm.prank(watcherC);
        registry.register{value: 0.01 ether}();
        assertEq(registry.watcherCount(), 3);

        // Step 3: Oracle attack — price drops 10%
        vm.prank(admin);
        chainlinkFeed.simulateAttack(1000);
        (, int256 attackPrice,,,) = chainlinkFeed.latestRoundData();
        assertEq(attackPrice, 1800_00000000); // $1800

        // Step 4: Advance to pub window
        vm.roll(block.number + 10);

        // Step 5: Three watchers detect deviation and submit reports
        bytes32 reportA = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "evidence_a", uint256(1)));
        bytes32 reportB = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "evidence_b", uint256(2)));
        bytes32 reportC = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "evidence_c", uint256(3)));

        vm.prank(watcherA);
        settlement.submitReport(epochId, reportA);
        vm.prank(watcherB);
        settlement.submitReport(epochId, reportB);
        vm.prank(watcherC);
        settlement.submitReport(epochId, reportC);
        assertEq(settlement.getEpochReportCount(epochId), 3);

        // Step 6: Request settlement + VRF
        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0xdeadbeefcafe;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, randomWords);

        // Step 7: Verify
        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled, "Epoch should be settled");
        assertTrue(breaker.triggered(epochId), "Circuit breaker should fire");

        // Verify RVlog values were assigned
        for (uint256 i = 0; i < 3; i++) {
            PrrrSettlement.Report memory r = settlement.getEpochReport(epochId, i);
            assertGe(r.randomValue, settlement.R_MIN(), "RVlog >= rMin");
        }

        // Winner received reward
        assertGt(settlement.totalRewardsDistributed(), 0, "Reward distributed");
    }

    /// @notice Test pub window enforcement
    function test_pubWindowEnforcement() public {
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 10, 50);

        vm.prank(watcherA);
        vm.expectRevert("Pub window not open");
        settlement.submitReport(epochId, keccak256("early_report"));

        vm.roll(block.number + 10);
        vm.prank(watcherA);
        settlement.submitReport(epochId, keccak256("on_time_report"));

        vm.roll(block.number + 50);
        vm.prank(watcherB);
        vm.expectRevert("Epoch ended");
        settlement.submitReport(epochId, keccak256("late_report"));
    }

    /// @notice Test VRF determines winner via RVlog second-price
    function test_vrfDeterminesWinner() public {
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 0, 50);

        vm.prank(watcherA);
        settlement.submitReport(epochId, keccak256("report_a"));
        vm.prank(watcherB);
        settlement.submitReport(epochId, keccak256("report_b"));

        uint256 balA_before = watcherA.balance;
        uint256 balB_before = watcherB.balance;

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory rw = new uint256[](1);
        rw[0] = 42;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw);

        uint256 rewardA = watcherA.balance - balA_before;
        uint256 rewardB = watcherB.balance - balB_before;
        assertTrue(
            (rewardA > 0 && rewardB == 0) || (rewardB > 0 && rewardA == 0),
            "Exactly one watcher should receive the reward"
        );
    }

    /// @notice Circuit breaker idempotent
    function test_circuitBreakerIdempotent() public {
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 0, 50);
        vm.prank(watcherA);
        settlement.submitReport(epochId, keccak256("report1"));

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory rw = new uint256[](1);
        rw[0] = 999;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw);

        assertTrue(breaker.triggered(epochId));

        vm.prank(address(settlement));
        vm.expectRevert("Already triggered");
        breaker.pause(address(aavePool), epochId, keccak256("report1"));
    }

    /// @notice Concurrent epochs
    function test_concurrentEpochs() public {
        vm.startPrank(admin);
        uint256 epoch1 = settlement.createEpoch(address(aavePool), 0, 100);
        uint256 epoch2 = settlement.createEpoch(address(aavePool), 0, 100);
        vm.stopPrank();

        vm.prank(watcherA);
        settlement.submitReport(epoch1, keccak256("e1_report"));
        vm.prank(watcherB);
        settlement.submitReport(epoch2, keccak256("e2_report"));

        // Settle epoch 1
        settlement.requestSettlement(epoch1);
        _vrfRequestCounter++;
        uint256[] memory rw1 = new uint256[](1);
        rw1[0] = 111;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw1);

        (,,,,, bool settled1) = settlement.epochs(epoch1);
        (,,,,, bool settled2) = settlement.epochs(epoch2);
        assertTrue(settled1);
        assertFalse(settled2);

        // Settle epoch 2
        settlement.requestSettlement(epoch2);
        _vrfRequestCounter++;
        uint256[] memory rw2 = new uint256[](1);
        rw2[0] = 222;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw2);

        (,,,,, settled2) = settlement.epochs(epoch2);
        assertTrue(settled2);
    }

    /// @notice Full watcher lifecycle
    function test_watcherFullLifecycle() public {
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 0, 50);

        vm.prank(watcherA);
        registry.register{value: 0.05 ether}();

        vm.prank(watcherA);
        settlement.submitReport(epochId, keccak256("watcherA_report"));

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory rw = new uint256[](1);
        rw[0] = 555;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw);

        uint256 balBefore = watcherA.balance;
        vm.prank(watcherA);
        registry.deregister();
        assertEq(watcherA.balance - balBefore, 0.05 ether);
    }

    /// @notice Oracle attack simulation with MockAggregator
    function test_oracleAttackSimulation() public {
        // Verify initial price
        (, int256 price1,,,) = chainlinkFeed.latestRoundData();
        assertEq(price1, 2000_00000000);

        // Simulate 15% attack
        vm.prank(admin);
        chainlinkFeed.simulateAttack(1500);

        (, int256 price2,,,) = chainlinkFeed.latestRoundData();
        assertEq(price2, 1700_00000000); // 2000 - 15% = 1700

        // Aave still reports old price
        uint256 aavePrice = aavePool.getAssetPrice(address(0xdead));
        assertEq(aavePrice, 2000_00000000);

        // Deviation: |2000 - 1700| / 2000 = 15% > 5% threshold
        uint256 diff = aavePrice > uint256(price2)
            ? aavePrice - uint256(price2)
            : uint256(price2) - aavePrice;
        uint256 deviationBps = (diff * 10000) / aavePrice;
        assertEq(deviationBps, 1500); // 15%
        assertTrue(deviationBps > 500, "Should trigger 5% threshold");
    }

    /// @notice Test that RVlog second-price rewards are correct
    function test_secondPriceRewardMath() public {
        vm.prank(admin);
        uint256 epochId = settlement.createEpoch(address(aavePool), 0, 50);

        bytes32 hashA = keccak256("math_report_a");
        bytes32 hashB = keccak256("math_report_b");

        vm.prank(watcherA);
        settlement.submitReport(epochId, hashA);
        vm.prank(watcherB);
        settlement.submitReport(epochId, hashB);

        uint256 seed = 0xbeef;
        uint256 rvA = settlement.previewRVlog(hashA, seed);
        uint256 rvB = settlement.previewRVlog(hashB, seed);

        // Both should be >= rMin (Paper §5.5)
        assertGe(rvA, settlement.R_MIN());
        assertGe(rvB, settlement.R_MIN());

        // The expected winner reward is |rvA - rvB| if both > rMin (Case 1)
        // or max(rvA,rvB) - rMin if one equals rMin (Case 2)
        uint256 expectedReward;
        uint256 higher = rvA > rvB ? rvA : rvB;
        uint256 lower = rvA > rvB ? rvB : rvA;
        if (lower > settlement.R_MIN()) {
            expectedReward = higher - lower; // Case 1
        } else {
            expectedReward = higher - settlement.R_MIN(); // Case 2
        }

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory rw = new uint256[](1);
        rw[0] = seed;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, rw);

        assertEq(settlement.totalRewardsDistributed(), expectedReward, "Second-price reward incorrect");
    }
}
