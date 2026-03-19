// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";

contract CircuitBreakerTest is Test {
    CircuitBreaker public breaker;
    address public settlement = makeAddr("settlement");
    address public protocol = makeAddr("aavePool");

    function setUp() public {
        breaker = new CircuitBreaker(settlement);
    }

    function test_constructor() public view {
        assertEq(breaker.settlement(), settlement);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert("Zero address");
        new CircuitBreaker(address(0));
    }

    function test_pause() public {
        bytes32 reportHash = keccak256("report1");

        vm.prank(settlement);
        breaker.pause(protocol, 1, reportHash);

        assertTrue(breaker.triggered(1));
    }

    function test_pause_emitsEvent() public {
        bytes32 reportHash = keccak256("report1");

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.Paused(protocol, 1, reportHash);

        vm.prank(settlement);
        breaker.pause(protocol, 1, reportHash);
    }

    function test_pause_revertsNotSettlement() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Not settlement contract");
        breaker.pause(protocol, 1, keccak256("report1"));
    }

    function test_pause_revertsAlreadyTriggered() public {
        bytes32 reportHash = keccak256("report1");

        vm.startPrank(settlement);
        breaker.pause(protocol, 1, reportHash);

        vm.expectRevert("Already triggered");
        breaker.pause(protocol, 1, reportHash);
        vm.stopPrank();
    }

    function test_multiplePauses_differentEpochs() public {
        vm.startPrank(settlement);
        breaker.pause(protocol, 1, keccak256("r1"));
        breaker.pause(protocol, 2, keccak256("r2"));
        breaker.pause(protocol, 3, keccak256("r3"));
        vm.stopPrank();

        assertTrue(breaker.triggered(1));
        assertTrue(breaker.triggered(2));
        assertTrue(breaker.triggered(3));
        assertFalse(breaker.triggered(4));
    }
}
