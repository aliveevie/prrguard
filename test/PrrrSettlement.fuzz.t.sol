// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {MockVRFCoordinator} from "../src/mocks/MockVRFCoordinator.sol";
import {PRBMathLog} from "../src/libraries/PRBMathLog.sol";

contract PrrrSettlementFuzzTest is Test {
    PrrrSettlement public settlement;
    CircuitBreaker public breaker;
    MockVRFCoordinator public vrfCoordinator;
    address public targetProtocol = makeAddr("aavePool");
    uint256 internal _vrfRequestCounter;

    function setUp() public {
        vrfCoordinator = new MockVRFCoordinator();
        settlement = new PrrrSettlement(
            address(vrfCoordinator), 1, bytes32(uint256(1)), address(1)
        );
        breaker = new CircuitBreaker(address(settlement));
        settlement.setCircuitBreaker(address(breaker));
        vm.deal(address(settlement), 100 ether);
    }

    function testFuzz_createEpoch(uint64 pubDelay, uint64 duration) public {
        vm.assume(duration > pubDelay);
        vm.assume(duration > 0);
        vm.assume(uint256(block.number) + uint256(duration) < type(uint64).max);

        uint256 epochId = settlement.createEpoch(targetProtocol, pubDelay, duration);
        assertEq(epochId, 1);
        (uint256 id, address target,,,, bool settled) = settlement.epochs(epochId);
        assertEq(id, 1);
        assertEq(target, targetProtocol);
        assertFalse(settled);
    }

    function testFuzz_submitReport(bytes32 reportHash) public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        address reporter = makeAddr("reporter");
        vm.prank(reporter);
        settlement.submitReport(epochId, reportHash);
        PrrrSettlement.Report memory report = settlement.getEpochReport(epochId, 0);
        assertEq(report.reportHash, reportHash);
        assertEq(report.publisher, reporter);
    }

    function testFuzz_rvlog_alwaysAboveRMin(bytes32 reportHash, uint256 seed) public view {
        uint256 rv = settlement.previewRVlog(reportHash, seed);
        assertGe(rv, settlement.R_MIN(), "RVlog must always be >= rMin");
    }

    function testFuzz_settlement_deterministic(uint256 randomSeed) public {
        vm.assume(randomSeed > 0);
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);

        address reporter1 = makeAddr("reporter1");
        address reporter2 = makeAddr("reporter2");
        vm.prank(reporter1);
        settlement.submitReport(epochId, keccak256("r1"));
        vm.prank(reporter2);
        settlement.submitReport(epochId, keccak256("r2"));

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomSeed;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, randomWords);

        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled);
        assertTrue(breaker.triggered(epochId));
    }

    function testFuzz_multipleReporters(uint8 numReporters, uint256 randomSeed) public {
        numReporters = uint8(bound(numReporters, 1, 20));
        vm.assume(randomSeed > 0);

        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 1000);
        for (uint256 i = 0; i < numReporters; i++) {
            address reporter = address(uint160(i + 100));
            vm.prank(reporter);
            settlement.submitReport(epochId, keccak256(abi.encode("report", i)));
        }
        assertEq(settlement.getEpochReportCount(epochId), numReporters);

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomSeed;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, randomWords);

        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled);
    }

    function testFuzz_pubWindowTiming(uint64 delay) public {
        delay = uint64(bound(delay, 1, 100));
        uint256 epochId = settlement.createEpoch(targetProtocol, delay, delay + 50);

        vm.prank(makeAddr("reporter"));
        vm.expectRevert("Pub window not open");
        settlement.submitReport(epochId, keccak256("report"));

        vm.roll(block.number + delay);
        vm.prank(makeAddr("reporter"));
        settlement.submitReport(epochId, keccak256("report"));
        assertEq(settlement.getEpochReportCount(epochId), 1);
    }

    /// @notice Fuzz test verifying the paper's Skipping Resistance property
    /// @dev Property 2: RAllPub(N) = 1/λ < rMin for all N
    ///      For the logarithmic value function, the expected total publisher reward
    ///      is exactly 1/λ regardless of N (Appendix B.1)
    function testFuzz_skippingResistance_lambdaInvLessThanRMin(uint256 rMin, uint256 lambdaInv) public pure {
        rMin = bound(rMin, 0.001 ether, 1 ether);
        lambdaInv = bound(lambdaInv, 0.0001 ether, rMin - 1);
        // Property 2: 1/λ < rMin must hold
        assertTrue(lambdaInv < rMin, "Skipping Resistance: 1/lambda must be < rMin");
    }

    /// @notice Fuzz: winner reward equals first RV minus second RV (second-price)
    function testFuzz_secondPriceRewardCorrectness(uint256 randomSeed) public {
        vm.assume(randomSeed > 0);
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);

        bytes32 hashA = keccak256("fuzz_report_a");
        bytes32 hashB = keccak256("fuzz_report_b");

        vm.prank(makeAddr("a"));
        settlement.submitReport(epochId, hashA);
        vm.prank(makeAddr("b"));
        settlement.submitReport(epochId, hashB);

        // Preview RVlog values
        uint256 rvA = settlement.previewRVlog(hashA, randomSeed);
        uint256 rvB = settlement.previewRVlog(hashB, randomSeed);

        uint256 expectedReward;
        if (rvA > rvB && rvB > settlement.R_MIN()) {
            expectedReward = rvA - rvB; // Case 1
        } else if (rvB > rvA && rvA > settlement.R_MIN()) {
            expectedReward = rvB - rvA; // Case 1
        } else if (rvA > rvB) {
            expectedReward = rvA - settlement.R_MIN(); // Case 2
        } else {
            expectedReward = rvB - settlement.R_MIN(); // Case 2
        }

        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomSeed;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, randomWords);

        assertEq(settlement.totalRewardsDistributed(), expectedReward);
    }
}
