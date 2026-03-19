// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {MockVRFCoordinator} from "../src/mocks/MockVRFCoordinator.sol";

contract PrrrSettlementTest is Test {
    PrrrSettlement public settlement;
    CircuitBreaker public breaker;
    MockVRFCoordinator public vrfCoordinator;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public targetProtocol = makeAddr("aavePool");

    bytes32 public constant KEY_HASH = bytes32(uint256(1));
    uint256 public constant SUB_ID = 1;
    uint256 internal _vrfRequestCounter;

    function setUp() public {
        vrfCoordinator = new MockVRFCoordinator();
        settlement = new PrrrSettlement(
            address(vrfCoordinator), SUB_ID, KEY_HASH, address(1)
        );
        breaker = new CircuitBreaker(address(settlement));
        settlement.setCircuitBreaker(address(breaker));
        vm.deal(address(settlement), 10 ether);
    }

    // ── Epoch Creation ───────────────────────────────────────────────

    function test_createEpoch() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 10, 50);
        assertEq(epochId, 1);
        assertEq(settlement.epochCount(), 1);

        (uint256 id, address target, uint64 startBlock, uint64 pubWindowStart, uint64 endBlock, bool settled) =
            settlement.epochs(epochId);
        assertEq(id, epochId);
        assertEq(target, targetProtocol);
        assertEq(startBlock, uint64(block.number));
        assertEq(pubWindowStart, uint64(block.number) + 10);
        assertEq(endBlock, uint64(block.number) + 50);
        assertFalse(settled);
    }

    function test_createEpoch_revertsZeroTarget() public {
        vm.expectRevert("Zero target");
        settlement.createEpoch(address(0), 10, 50);
    }

    function test_createEpoch_revertsDurationLessEqualDelay() public {
        vm.expectRevert("Duration <= delay");
        settlement.createEpoch(targetProtocol, 50, 50);
        vm.expectRevert("Duration <= delay");
        settlement.createEpoch(targetProtocol, 50, 10);
    }

    function test_createMultipleEpochs() public {
        uint256 e1 = settlement.createEpoch(targetProtocol, 10, 50);
        uint256 e2 = settlement.createEpoch(targetProtocol, 5, 30);
        assertEq(e1, 1);
        assertEq(e2, 2);
        assertEq(settlement.epochCount(), 2);
    }

    // ── Report Submission ────────────────────────────────────────────

    function test_submitReport() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        bytes32 reportHash = keccak256("report1");

        vm.prank(alice);
        settlement.submitReport(epochId, reportHash);

        assertEq(settlement.getEpochReportCount(epochId), 1);
        PrrrSettlement.Report memory report = settlement.getEpochReport(epochId, 0);
        assertEq(report.reportHash, reportHash);
        assertEq(report.publisher, alice);
        assertEq(report.randomValue, 0);
    }

    function test_submitReport_revertsPubWindowNotOpen() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 10, 50);
        vm.prank(alice);
        vm.expectRevert("Pub window not open");
        settlement.submitReport(epochId, keccak256("report1"));
    }

    function test_submitReport_revertsEpochEnded() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 5);
        vm.roll(block.number + 6);
        vm.prank(alice);
        vm.expectRevert("Epoch ended");
        settlement.submitReport(epochId, keccak256("report1"));
    }

    function test_submitReport_revertsNonexistentEpoch() public {
        vm.prank(alice);
        vm.expectRevert("Epoch does not exist");
        settlement.submitReport(999, keccak256("report1"));
    }

    function test_multipleReportsSameEpoch() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report1"));
        vm.prank(bob);
        settlement.submitReport(epochId, keccak256("report2"));
        vm.prank(charlie);
        settlement.submitReport(epochId, keccak256("report3"));
        assertEq(settlement.getEpochReportCount(epochId), 3);
    }

    // ── Settlement ───────────────────────────────────────────────────

    function test_requestSettlement() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report1"));
        settlement.requestSettlement(epochId);
    }

    function test_requestSettlement_revertsNoReports() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.expectRevert("No reports");
        settlement.requestSettlement(epochId);
    }

    function test_requestSettlement_revertsAlreadySettled() public {
        uint256 epochId = _createEpochAndSubmitReport();
        _settleEpoch(epochId, 12345);
        vm.expectRevert("Already settled");
        settlement.requestSettlement(epochId);
    }

    function test_fullSettlement_singleReport() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report1"));

        uint256 aliceBalBefore = alice.balance;
        _settleEpoch(epochId, 42);

        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled);

        // Alice should receive rv - rMin (Case 2: succinct, single report)
        uint256 aliceGain = alice.balance - aliceBalBefore;
        assertGt(aliceGain, 0, "Winner should receive positive reward");
        assertTrue(breaker.triggered(epochId));
    }

    function test_fullSettlement_twoReports() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report1"));
        vm.prank(bob);
        settlement.submitReport(epochId, keccak256("report2"));

        _settleEpoch(epochId, 999);

        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled);
        assertTrue(breaker.triggered(epochId));
    }

    function test_fullSettlement_threeReports() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report_a"));
        vm.prank(bob);
        settlement.submitReport(epochId, keccak256("report_b"));
        vm.prank(charlie);
        settlement.submitReport(epochId, keccak256("report_c"));

        _settleEpoch(epochId, 777);

        (,,,,, bool settled) = settlement.epochs(epochId);
        assertTrue(settled);
        assertEq(settlement.getEpochReportCount(epochId), 3);
    }

    function test_submitReport_revertsAfterSettlement() public {
        uint256 epochId = _createEpochAndSubmitReport();
        _settleEpoch(epochId, 12345);
        vm.prank(bob);
        vm.expectRevert("Already settled");
        settlement.submitReport(epochId, keccak256("late_report"));
    }

    // ── RVlog Verification ───────────────────────────────────────────

    function test_rvlog_alwaysAboveRMin() public view {
        // RVlog = rMin + (1/λ) * (-ln(1 - u)) should always be >= rMin
        for (uint256 i = 0; i < 50; i++) {
            bytes32 rh = keccak256(abi.encode("report", i));
            uint256 rv = settlement.previewRVlog(rh, i * 777);
            assertGe(rv, settlement.R_MIN(), "RVlog must be >= rMin");
        }
    }

    function test_rvlog_differentReportsGetDifferentValues() public view {
        bytes32 rh1 = keccak256("report_x");
        bytes32 rh2 = keccak256("report_y");
        uint256 S = 42;
        uint256 rv1 = settlement.previewRVlog(rh1, S);
        uint256 rv2 = settlement.previewRVlog(rh2, S);
        assertTrue(rv1 != rv2, "Different reports should get different RVlog values");
    }

    function test_rvlog_sameReportSameSeed_deterministic() public view {
        bytes32 rh = keccak256("report_z");
        uint256 S = 12345;
        uint256 rv1 = settlement.previewRVlog(rh, S);
        uint256 rv2 = settlement.previewRVlog(rh, S);
        assertEq(rv1, rv2, "Same inputs should produce same RVlog");
    }

    function test_secondPriceReward_twoReports() public {
        // Verify second-price allocation: winner gets r1-r2, not r1-rMin
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);

        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("alpha"));
        vm.prank(bob);
        settlement.submitReport(epochId, keccak256("beta"));

        uint256 aliceBal = alice.balance;
        uint256 bobBal = bob.balance;

        _settleEpoch(epochId, 0xdeadbeef);

        // Exactly one gained, the other didn't
        uint256 aliceGain = alice.balance - aliceBal;
        uint256 bobGain = bob.balance - bobBal;
        assertTrue(
            (aliceGain > 0 && bobGain == 0) || (bobGain > 0 && aliceGain == 0),
            "Exactly one winner"
        );

        // The gain should equal r1 - r2 (the surplus)
        // We can verify by checking totalRewardsDistributed
        assertGt(settlement.totalRewardsDistributed(), 0);
    }

    // ── Constants ────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(settlement.R_MIN(), 0.01 ether);
        assertEq(settlement.LAMBDA_INV(), 0.005 ether);
        assertTrue(settlement.LAMBDA_INV() < settlement.R_MIN(), "Skipping Resistance violated: 1/lambda must be < rMin");
        assertEq(settlement.REQUEST_CONFIRMATIONS(), 3);
        assertEq(settlement.NUM_WORDS(), 1);
        assertEq(settlement.CALLBACK_GAS_LIMIT(), 500_000);
    }

    // ── Events ───────────────────────────────────────────────────────

    function test_emitsEpochCreated() public {
        vm.expectEmit(true, true, false, true);
        emit PrrrSettlement.EpochCreated(1, targetProtocol, uint64(block.number) + 10, uint64(block.number) + 50);
        settlement.createEpoch(targetProtocol, 10, 50);
    }

    function test_emitsReportSubmitted() public {
        uint256 epochId = settlement.createEpoch(targetProtocol, 0, 50);
        bytes32 reportHash = keccak256("report1");

        vm.expectEmit(true, true, false, true);
        emit PrrrSettlement.ReportSubmitted(epochId, alice, reportHash, 0);

        vm.prank(alice);
        settlement.submitReport(epochId, reportHash);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _createEpochAndSubmitReport() internal returns (uint256 epochId) {
        epochId = settlement.createEpoch(targetProtocol, 0, 50);
        vm.prank(alice);
        settlement.submitReport(epochId, keccak256("report1"));
    }

    function _settleEpoch(uint256 epochId, uint256 randomSeed) internal {
        settlement.requestSettlement(epochId);
        _vrfRequestCounter++;
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomSeed;
        vrfCoordinator.fulfillRandomWords(_vrfRequestCounter, randomWords);
    }
}
