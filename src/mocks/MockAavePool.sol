// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockAavePool — Simulates Aave V3 pool for testing
/// @dev Returns a configurable asset price and tracks pause state
contract MockAavePool {
    mapping(address => uint256) public assetPrices;
    mapping(address => bool) public paused;

    event AssetPriceSet(address indexed asset, uint256 price);
    event PoolPaused(address indexed asset);

    function setAssetPrice(address _asset, uint256 _price) external {
        assetPrices[_asset] = _price;
        emit AssetPriceSet(_asset, _price);
    }

    function getAssetPrice(address _asset) external view returns (uint256) {
        return assetPrices[_asset];
    }

    function pausePool(address _asset) external {
        paused[_asset] = true;
        emit PoolPaused(_asset);
    }
}
