// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/// @notice Minimal mock VRF Coordinator for testing PrrrSettlement
contract MockVRFCoordinator {
    uint256 private _nextRequestId;
    mapping(uint256 => address) private _consumers;

    event RandomWordsRequested(uint256 requestId);

    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata
    ) external returns (uint256 requestId) {
        requestId = ++_nextRequestId;
        _consumers[requestId] = msg.sender;
        emit RandomWordsRequested(requestId);
    }

    /// @notice Simulate VRF callback with controlled randomness
    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) external {
        address consumer = _consumers[_requestId];
        require(consumer != address(0), "Invalid request");

        // Call rawFulfillRandomWords on the consumer
        (bool success, bytes memory reason) = consumer.call(
            abi.encodeWithSignature(
                "rawFulfillRandomWords(uint256,uint256[])",
                _requestId,
                _randomWords
            )
        );
        require(success, string(reason));
    }

    // Stub functions required by the interface
    function createSubscription() external pure returns (uint256) { return 1; }
    function addConsumer(uint256, address) external {}
}
