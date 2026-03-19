// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {PrrrGuardRegistry} from "../src/PrrrGuardRegistry.sol";

contract Deploy is Script {
    // Sepolia VRF Coordinator v2.5
    address constant VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    // Sepolia VRF key hash
    bytes32 constant KEY_HASH = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 vrfSubId = vm.envUint("VRF_SUBSCRIPTION_ID");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PrrrSettlement with placeholder circuit breaker
        PrrrSettlement settlement = new PrrrSettlement(
            VRF_COORDINATOR,
            vrfSubId,
            KEY_HASH,
            address(1) // placeholder, will be updated
        );
        console.log("PrrrSettlement deployed at:", address(settlement));

        // 2. Deploy CircuitBreaker pointing to settlement
        CircuitBreaker breaker = new CircuitBreaker(address(settlement));
        console.log("CircuitBreaker deployed at:", address(breaker));

        // 3. Update settlement with actual circuit breaker
        settlement.setCircuitBreaker(address(breaker));
        console.log("CircuitBreaker set on PrrrSettlement");

        // 4. Deploy PrrrGuardRegistry
        PrrrGuardRegistry registry = new PrrrGuardRegistry();
        console.log("PrrrGuardRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}
