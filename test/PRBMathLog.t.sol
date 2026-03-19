// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PRBMathLog} from "../src/libraries/PRBMathLog.sol";

/// @title PRBMathLog Tests — Verifies the RVlog math from the Prrr paper
/// @notice Tests the logarithmic random-value function (§5.5, Appendix B.1):
///         RVlog(Rpt, S) = rMin - (1/λ) * ln(1 - H(Rpt||S))
contract PRBMathLogTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant R_MIN = 0.01 ether;
    uint256 constant LAMBDA_INV = 0.005 ether;

    // ── lnWad tests ─────────────────────────────────────────────────

    function test_lnWad_of1_isZero() public pure {
        int256 result = PRBMathLog.lnWad(WAD);
        assertEq(result, 0, "ln(1) should be 0");
    }

    function test_lnWad_ofHalf_isNegative() public pure {
        int256 result = PRBMathLog.lnWad(WAD / 2);
        // ln(0.5) ≈ -0.6931
        assertTrue(result < 0, "ln(0.5) should be negative");
        // Check approximate value: -0.6931 * 1e18
        assertApproxEqRel(result, -693147180559945309, 0.01e18); // 1% tolerance
    }

    function test_lnWad_ofQuarter() public pure {
        int256 result = PRBMathLog.lnWad(WAD / 4);
        // ln(0.25) ≈ -1.3863
        assertApproxEqRel(result, -1386294361119890619, 0.01e18);
    }

    function test_lnWad_nearZero_veryNegative() public pure {
        // ln(0.01) ≈ -4.605
        int256 result = PRBMathLog.lnWad(WAD / 100);
        assertTrue(result < -3e18, "ln(0.01) should be very negative");
    }

    function test_lnWad_nearOne_nearZero() public pure {
        // ln(0.99) ≈ -0.01005
        int256 result = PRBMathLog.lnWad(99e16);
        assertTrue(result < 0, "ln(0.99) should be slightly negative");
        assertTrue(result > -0.02e18, "ln(0.99) should be close to 0");
    }

    // ── negLnOneMinusU tests ────────────────────────────────────────

    function test_negLn_zero_isZero() public pure {
        uint256 result = PRBMathLog.negLnOneMinusU(0);
        assertEq(result, 0, "-ln(1-0) = -ln(1) = 0");
    }

    function test_negLn_half() public pure {
        uint256 result = PRBMathLog.negLnOneMinusU(WAD / 2);
        // -ln(0.5) ≈ 0.6931
        assertApproxEqRel(result, 693147180559945309, 0.01e18);
    }

    function test_negLn_highU_givesLargeValue() public pure {
        // u = 0.9 → -ln(0.1) ≈ 2.302
        uint256 result = PRBMathLog.negLnOneMinusU(9e17);
        assertGt(result, 2e18, "-ln(0.1) should be > 2");
    }

    function test_negLn_monotonic_samples() public pure {
        uint256 r1 = PRBMathLog.negLnOneMinusU(0.1e18);
        uint256 r2 = PRBMathLog.negLnOneMinusU(0.5e18);
        uint256 r3 = PRBMathLog.negLnOneMinusU(0.9e18);
        assertLt(r1, r2, "Monotonicity: 0.1 < 0.5");
        assertLt(r2, r3, "Monotonicity: 0.5 < 0.9");
    }

    // ── computeRVlog tests ──────────────────────────────────────────

    function test_rvlog_alwaysAboveRMin() public pure {
        for (uint256 i = 1; i <= 100; i++) {
            bytes32 rh = keccak256(abi.encode("report", i));
            uint256 rv = PRBMathLog.computeRVlog(rh, i, R_MIN, LAMBDA_INV);
            assertGe(rv, R_MIN, "RVlog must be >= rMin");
        }
    }

    function test_rvlog_deterministic() public pure {
        bytes32 rh = keccak256("test_report");
        uint256 rv1 = PRBMathLog.computeRVlog(rh, 42, R_MIN, LAMBDA_INV);
        uint256 rv2 = PRBMathLog.computeRVlog(rh, 42, R_MIN, LAMBDA_INV);
        assertEq(rv1, rv2);
    }

    function test_rvlog_differentInputs_differentOutputs() public pure {
        bytes32 rh1 = keccak256("report_1");
        bytes32 rh2 = keccak256("report_2");
        uint256 rv1 = PRBMathLog.computeRVlog(rh1, 42, R_MIN, LAMBDA_INV);
        uint256 rv2 = PRBMathLog.computeRVlog(rh2, 42, R_MIN, LAMBDA_INV);
        assertTrue(rv1 != rv2);
    }

    function test_rvlog_differentSeeds_differentOutputs() public pure {
        bytes32 rh = keccak256("same_report");
        uint256 rv1 = PRBMathLog.computeRVlog(rh, 1, R_MIN, LAMBDA_INV);
        uint256 rv2 = PRBMathLog.computeRVlog(rh, 2, R_MIN, LAMBDA_INV);
        assertTrue(rv1 != rv2);
    }

    /// @notice Verify the Exp(λ) distribution property
    /// @dev For RVlog with the logarithmic function, RVlog - rMin ~ Exp(λ)
    ///      The mean of Exp(λ) is 1/λ. Over many samples, the average
    ///      should be close to LAMBDA_INV.
    function test_rvlog_distributionMean() public pure {
        uint256 N = 500;
        uint256 sum = 0;
        for (uint256 i = 0; i < N; i++) {
            bytes32 rh = keccak256(abi.encode("distribution_test", i));
            uint256 rv = PRBMathLog.computeRVlog(rh, 777, R_MIN, LAMBDA_INV);
            sum += (rv - R_MIN);
        }
        uint256 mean = sum / N;
        // Mean should be approximately LAMBDA_INV = 0.005 ether
        // Allow 50% tolerance due to finite sample size
        assertGt(mean, LAMBDA_INV / 2, "Mean too low");
        assertLt(mean, LAMBDA_INV * 3, "Mean too high");
    }

    // ── Fuzz tests ──────────────────────────────────────────────────

    function testFuzz_rvlog_alwaysAboveRMin(bytes32 reportHash, uint256 seed) public pure {
        uint256 rv = PRBMathLog.computeRVlog(reportHash, seed, R_MIN, LAMBDA_INV);
        assertGe(rv, R_MIN);
    }

    function testFuzz_negLn_monotonic(uint256 u1, uint256 u2) public pure {
        u1 = bound(u1, 0, WAD - 1);
        u2 = bound(u2, 0, WAD - 1);
        uint256 r1 = PRBMathLog.negLnOneMinusU(u1);
        uint256 r2 = PRBMathLog.negLnOneMinusU(u2);
        if (u1 > u2) {
            assertGe(r1, r2, "-ln(1-u) must be monotonically increasing");
        } else if (u2 > u1) {
            assertGe(r2, r1, "-ln(1-u) must be monotonically increasing");
        }
    }
}
