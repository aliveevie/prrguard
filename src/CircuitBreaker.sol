// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICircuitBreaker} from "./interfaces/ICircuitBreaker.sol";

contract CircuitBreaker is ICircuitBreaker {
    address public immutable settlement;
    mapping(uint256 => bool) public triggered;

    event Paused(address indexed protocol, uint256 epochId, bytes32 reportHash);

    modifier onlySettlement() {
        require(msg.sender == settlement, "Not settlement contract");
        _;
    }

    constructor(address _settlement) {
        require(_settlement != address(0), "Zero address");
        settlement = _settlement;
    }

    function pause(
        address _protocol,
        uint256 _epochId,
        bytes32 _reportHash
    ) external onlySettlement {
        require(!triggered[_epochId], "Already triggered");
        triggered[_epochId] = true;
        emit Paused(_protocol, _epochId, _reportHash);
    }
}
