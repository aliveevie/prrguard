// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPrrrSettlement {
    function createEpoch(address targetProtocol, uint64 pubWindowDelay, uint64 epochDuration) external returns (uint256);
    function submitReport(uint256 epochId, bytes32 reportHash) external;
    function requestSettlement(uint256 epochId) external;
}
