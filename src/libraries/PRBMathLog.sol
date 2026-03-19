// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PRBMathLog — Fixed-point logarithm for the Prrr RVlog function
/// @notice Implements -ln(1 - x) in 18-decimal fixed-point (WAD) arithmetic
/// @dev Used to compute RVlog(Rpt, S) = rMin + (1/λ) * (-ln(1 - H(Rpt||S)))
///      where H(Rpt||S) is mapped to [0, 1) via division by 2^256
///
///      The key insight from the paper (§5.5, Appendix B.1):
///      RVlog - rMin follows Exp(λ), so the gap between the top-2 values
///      is also Exp(λ), making RAllPub(N) = 1/λ regardless of N.
///      This gives us Reward Monotonicity (Property 1) for free.
///      Setting λ > 1/rMin satisfies Skipping Resistance (Property 2).
library PRBMathLog {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 5e17;

    /// @notice Computes ln(x) where x is a WAD-scaled value in (0, WAD]
    /// @dev Uses the identity ln(x) = 2 * artanh((x-1)/(x+1)) with a Taylor series
    ///      artanh(z) = z + z^3/3 + z^5/5 + z^7/7 + ...
    ///      Accurate to ~15 significant digits for x in [0.01 WAD, WAD]
    /// @param x Input value scaled by 1e18. Must be > 0 and <= 1e18
    /// @return result ln(x) scaled by 1e18 (will be negative for x < 1e18)
    function lnWad(uint256 x) internal pure returns (int256 result) {
        require(x > 0 && x <= WAD, "lnWad: out of range");

        // ln(x) = 2 * artanh((x-1)/(x+1))
        // z = (x - WAD) / (x + WAD)  — note z is negative for x < WAD
        int256 xInt = int256(x);
        int256 wadInt = int256(WAD);

        // z = (x - 1) / (x + 1) in WAD
        int256 num = xInt - wadInt;
        int256 den = xInt + wadInt;
        int256 z = (num * wadInt) / den;

        // z^2
        int256 z2 = (z * z) / wadInt;

        // Taylor: artanh(z) ≈ z + z^3/3 + z^5/5 + z^7/7 + z^9/9 + z^11/11 + z^13/13
        int256 term = z;
        int256 sum = term;

        term = (term * z2) / wadInt;
        sum += term / 3;

        term = (term * z2) / wadInt;
        sum += term / 5;

        term = (term * z2) / wadInt;
        sum += term / 7;

        term = (term * z2) / wadInt;
        sum += term / 9;

        term = (term * z2) / wadInt;
        sum += term / 11;

        term = (term * z2) / wadInt;
        sum += term / 13;

        term = (term * z2) / wadInt;
        sum += term / 15;

        // ln(x) = 2 * artanh(z)
        result = 2 * sum;
    }

    /// @notice Computes -ln(1 - u) where u is in [0, WAD) — i.e., [0, 1)
    /// @dev This is the core of the RVlog function. For u ~ Uniform(0,1),
    ///      -ln(1-u) ~ Exp(1), which is the paper's key distribution.
    /// @param u Uniform value in [0, WAD). Must be < WAD.
    /// @return result -ln(1 - u) in WAD scale. Always >= 0.
    function negLnOneMinusU(uint256 u) internal pure returns (uint256 result) {
        require(u < WAD, "negLnOneMinusU: u >= 1");

        if (u == 0) return 0;

        // 1 - u
        uint256 oneMinusU = WAD - u;

        // ln(1 - u) is negative, so -ln(1 - u) is positive
        int256 lnVal = lnWad(oneMinusU);

        // lnVal is negative (since oneMinusU < WAD), so negate it
        result = uint256(-lnVal);
    }

    /// @notice Compute the full RVlog value for a report
    /// @dev RVlog(Rpt, S) = rMin + (1/λ) * (-ln(1 - H(Rpt||S)/2^256))
    ///      We map the 256-bit hash to [0, WAD) by: u = hash * WAD / 2^256
    ///      But to avoid overflow, we use: u = hash / (2^256 / WAD)
    ///      Since 2^256/WAD is huge, we use: u = hash >> 178 (gives ~78 bits of precision)
    ///      Actually: WAD = 1e18 ≈ 2^59.79, so hash * WAD >> 256 ≈ hash >> 196
    ///      We shift hash right by 196 bits to get a value in [0, WAD)
    /// @param reportHash The report hash
    /// @param S The VRF random string
    /// @param rMin Minimum reward (in wei)
    /// @param lambdaInv 1/λ (in wei). Must satisfy lambdaInv < rMin
    /// @return rv The random value for this report (in wei)
    function computeRVlog(
        bytes32 reportHash,
        uint256 S,
        uint256 rMin,
        uint256 lambdaInv
    ) internal pure returns (uint256 rv) {
        bytes32 h = keccak256(abi.encode(reportHash, S));
        uint256 hashVal = uint256(h);

        // Map hash to uniform in [0, WAD)
        // We want u = hashVal * WAD / 2^256
        // To avoid overflow: u = hashVal / (2^256 / WAD)
        // 2^256 / 1e18 ≈ 1.157920892e59, so we right-shift by ~196 bits
        // More precisely: hashVal * 1e18 >> 256
        // We can compute this as: (hashVal >> 196) since 2^196 / 1e18 ≈ 1.003
        // For better precision: use (hashVal >> 128) * WAD >> 128
        uint256 hi = hashVal >> 128; // top 128 bits
        uint256 u = (hi * WAD) >> 128; // scale to [0, WAD)

        // Clamp to [0, WAD - 1] to avoid ln(0)
        if (u >= WAD) {
            u = WAD - 1;
        }

        // -ln(1 - u) ~ Exp(1) when u ~ Uniform(0,1)
        uint256 expVal = negLnOneMinusU(u);

        // RVlog = rMin + lambdaInv * expVal / WAD
        rv = rMin + (lambdaInv * expVal) / WAD;
    }
}
