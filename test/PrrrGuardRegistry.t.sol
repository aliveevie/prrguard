// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrrrGuardRegistry} from "../src/PrrrGuardRegistry.sol";

contract PrrrGuardRegistryTest is Test {
    PrrrGuardRegistry public registry;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        registry = new PrrrGuardRegistry();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_register() public {
        vm.prank(alice);
        registry.register{value: 0.01 ether}();

        (address addr, uint256 stake,, , bool active) = registry.watchers(alice);
        assertEq(addr, alice);
        assertEq(stake, 0.01 ether);
        assertTrue(active);
        assertEq(registry.watcherCount(), 1);
    }

    function test_register_revertsInsufficientStake() public {
        vm.prank(alice);
        vm.expectRevert("Insufficient stake");
        registry.register{value: 0.005 ether}();
    }

    function test_register_revertsAlreadyRegistered() public {
        vm.startPrank(alice);
        registry.register{value: 0.01 ether}();

        vm.expectRevert("Already registered");
        registry.register{value: 0.01 ether}();
        vm.stopPrank();
    }

    function test_deregister() public {
        vm.startPrank(alice);
        registry.register{value: 0.05 ether}();

        uint256 balBefore = alice.balance;
        registry.deregister();
        uint256 balAfter = alice.balance;

        assertEq(balAfter - balBefore, 0.05 ether);
        (, uint256 stake,,, bool active) = registry.watchers(alice);
        assertEq(stake, 0);
        assertFalse(active);
        assertEq(registry.watcherCount(), 0);
        vm.stopPrank();
    }

    function test_deregister_revertsNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert("Not registered");
        registry.deregister();
    }

    function test_registerMultiple() public {
        vm.prank(alice);
        registry.register{value: 0.01 ether}();

        vm.prank(bob);
        registry.register{value: 0.02 ether}();

        assertEq(registry.watcherCount(), 2);
    }

    function test_emitsWatcherRegistered() public {
        vm.expectEmit(true, false, false, true);
        emit PrrrGuardRegistry.WatcherRegistered(alice, 0.01 ether);

        vm.prank(alice);
        registry.register{value: 0.01 ether}();
    }

    function test_emitsWatcherDeregistered() public {
        vm.prank(alice);
        registry.register{value: 0.01 ether}();

        vm.expectEmit(true, false, false, true);
        emit PrrrGuardRegistry.WatcherDeregistered(alice, 0.01 ether);

        vm.prank(alice);
        registry.deregister();
    }
}
