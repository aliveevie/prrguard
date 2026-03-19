// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {MockVRFCoordinator} from "../src/mocks/MockVRFCoordinator.sol";

/// @title SimulateAttack — Full Prrr cycle demo script
/// @notice Deploys all contracts, simulates oracle attack, and runs settlement
contract SimulateAttack is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== PrrrGuard Attack Simulation ===");
        console.log("Deployer:", deployer);

        // 1. Deploy mock infrastructure
        MockVRFCoordinator vrfCoord = new MockVRFCoordinator();
        console.log("MockVRFCoordinator:", address(vrfCoord));

        MockAggregator chainlinkFeed = new MockAggregator(
            2000_00000000, // $2000 with 8 decimals
            8,
            "ETH / USD"
        );
        console.log("MockAggregator (ETH/USD):", address(chainlinkFeed));

        MockAavePool aavePool = new MockAavePool();
        aavePool.setAssetPrice(address(0xdead), 2000_00000000); // Same price initially
        console.log("MockAavePool:", address(aavePool));

        // 2. Deploy PrrrSettlement + CircuitBreaker
        PrrrSettlement settlement = new PrrrSettlement(
            address(vrfCoord),
            1,
            bytes32(uint256(1)),
            address(1)
        );
        CircuitBreaker breaker = new CircuitBreaker(address(settlement));
        settlement.setCircuitBreaker(address(breaker));
        console.log("PrrrSettlement:", address(settlement));
        console.log("CircuitBreaker:", address(breaker));

        // Fund settlement for rewards
        (bool funded,) = address(settlement).call{value: 0.05 ether}("");
        require(funded, "Funding failed");
        console.log("Settlement funded with 0.05 ETH");

        // 3. Create monitoring epoch (pubWindowDelay=0, duration=100)
        uint256 epochId = settlement.createEpoch(address(aavePool), 0, 100);
        console.log("");
        console.log("=== Epoch Created ===");
        console.log("Epoch ID:", epochId);

        // 4. Simulate oracle attack: drop price by 10%
        console.log("");
        console.log("=== Simulating Oracle Attack ===");
        chainlinkFeed.simulateAttack(1000); // 10% drop
        (, int256 attackPrice,,,) = chainlinkFeed.latestRoundData();
        console.log("Original price: $2000");
        console.log("Attack price: $", uint256(attackPrice) / 1e8);
        console.log("Deviation: 10%");

        // 5. Three watchers submit reports
        console.log("");
        console.log("=== Watchers Submitting Reports ===");

        bytes32 reportA = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "watcher_a", uint256(1)));
        bytes32 reportB = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "watcher_b", uint256(2)));
        bytes32 reportC = keccak256(abi.encode(epochId, "ORACLE_DEVIATION", "watcher_c", uint256(3)));

        settlement.submitReport(epochId, reportA);
        console.log("Watcher A submitted report");

        settlement.submitReport(epochId, reportB);
        console.log("Watcher B submitted report");

        settlement.submitReport(epochId, reportC);
        console.log("Watcher C submitted report");

        console.log("Total reports:", settlement.getEpochReportCount(epochId));

        // 6. Preview RVlog values
        console.log("");
        console.log("=== Previewing RVlog Values ===");
        uint256 demoSeed = 0xdeadbeefcafe;
        console.log("RVlog(A):", settlement.previewRVlog(reportA, demoSeed));
        console.log("RVlog(B):", settlement.previewRVlog(reportB, demoSeed));
        console.log("RVlog(C):", settlement.previewRVlog(reportC, demoSeed));

        // 7. Request settlement and fulfill VRF
        console.log("");
        console.log("=== Settlement ===");
        settlement.requestSettlement(epochId);
        console.log("VRF requested");

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = demoSeed;
        vrfCoord.fulfillRandomWords(1, randomWords);
        console.log("VRF fulfilled, epoch settled!");

        // 8. Verify results
        (,,,,, bool settled) = settlement.epochs(epochId);
        console.log("");
        console.log("=== Results ===");
        console.log("Epoch settled:", settled);
        console.log("Circuit breaker triggered:", breaker.triggered(epochId));
        console.log("Total rewards distributed:", settlement.totalRewardsDistributed());
        console.log("");
        console.log("Protocol paused. Funds protected.");
        console.log("=== Prrr Equilibrium Achieved ===");

        vm.stopBroadcast();
    }
}
