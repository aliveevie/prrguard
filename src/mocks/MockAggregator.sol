// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockAggregator — Simulates a Chainlink price feed for testing oracle attacks
/// @dev Used in demo to simulate a 10%+ oracle deviation that triggers watchers
contract MockAggregator {
    int256 public price;
    uint8 public immutable decimals_;
    string public description;
    uint80 private _roundId;
    uint256 private _updatedAt;

    event PriceUpdated(int256 oldPrice, int256 newPrice, uint80 roundId);
    event OracleAttackSimulated(int256 originalPrice, int256 attackPrice, uint256 deviationBps);

    constructor(int256 _initialPrice, uint8 _decimals, string memory _description) {
        price = _initialPrice;
        decimals_ = _decimals;
        description = _description;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, price, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, price, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice Update the price (admin function for testing)
    function updatePrice(int256 _newPrice) external {
        int256 oldPrice = price;
        price = _newPrice;
        _roundId++;
        _updatedAt = block.timestamp;
        emit PriceUpdated(oldPrice, _newPrice, _roundId);
    }

    /// @notice Simulate an oracle attack by dropping price by a percentage
    /// @param _deviationBps Deviation in basis points (e.g., 1000 = 10%)
    function simulateAttack(uint256 _deviationBps) external {
        int256 originalPrice = price;
        int256 drop = (originalPrice * int256(_deviationBps)) / 10000;
        int256 attackPrice = originalPrice - drop;

        price = attackPrice;
        _roundId++;
        _updatedAt = block.timestamp;

        emit OracleAttackSimulated(originalPrice, attackPrice, _deviationBps);
        emit PriceUpdated(originalPrice, attackPrice, _roundId);
    }
}
