// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICircuitBreaker {
    function pause(address protocol, uint256 epochId, bytes32 reportHash) external;
    function triggered(uint256 epochId) external view returns (bool);
}
