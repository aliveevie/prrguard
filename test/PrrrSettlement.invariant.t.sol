// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrrrSettlement} from "../src/PrrrSettlement.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {PrrrGuardRegistry} from "../src/PrrrGuardRegistry.sol";
import {MockVRFCoordinator} from "../src/mocks/MockVRFCoordinator.sol";

/// @notice Handler that defines allowed actions for invariant testing
contract SettlementHandler is Test {
    PrrrSettlement public settlement;
    MockVRFCoordinator public vrfCoordinator;
    address public targetProtocol;

    uint256 public epochsCreated;
    uint256 public reportsSubmitted;
    uint256 public settlementsCompleted;
    uint256 public vrfRequestCounter;

    constructor(PrrrSettlement _settlement, MockVRFCoordinator _vrfCoordinator, address _target) {
        settlement = _settlement;
        vrfCoordinator = _vrfCoordinator;
        targetProtocol = _target;
    }

    function createEpoch(uint64 delay, uint64 duration) external {
        delay = uint64(bound(delay, 0, 10));
        duration = uint64(bound(duration, delay + 1, delay + 100));
        settlement.createEpoch(targetProtocol, delay, duration);
        epochsCreated++;
    }

    function submitReport(uint256 epochSeed, bytes32 reportHash) external {
        if (epochsCreated == 0) return;
        uint256 epochId = (epochSeed % epochsCreated) + 1;
        (uint256 id,,, uint64 pubWindowStart, uint64 endBlock, bool settled) = settlement.epochs(epochId);
        if (id == 0 || settled || block.number < pubWindowStart || block.number > endBlock) return;
        settlement.submitReport(epochId, reportHash);
        reportsSubmitted++;
    }

    function settleEpoch(uint256 epochSeed, uint256 randomSeed) external {
        if (epochsCreated == 0) return;
        uint256 epochId = (epochSeed % epochsCreated) + 1;
        (uint256 id,,,, , bool settled) = settlement.epochs(epochId);
        if (id == 0 || settled) return;
        if (settlement.getEpochReportCount(epochId) == 0) return;

        try settlement.requestSettlement(epochId) {
            vrfRequestCounter++;
            uint256[] memory randomWords = new uint256[](1);
            randomWords[0] = randomSeed == 0 ? 1 : randomSeed;
            try vrfCoordinator.fulfillRandomWords(vrfRequestCounter, randomWords) {
                settlementsCompleted++;
            } catch {}
        } catch {}
    }

    function advanceBlock(uint256 blocks) external {
        blocks = bound(blocks, 1, 10);
        vm.roll(block.number + blocks);
    }
}

contract PrrrSettlementInvariantTest is Test {
    PrrrSettlement public settlement;
    CircuitBreaker public breaker;
    MockVRFCoordinator public vrfCoordinator;
    SettlementHandler public handler;
    address public targetProtocol = makeAddr("aavePool");

    function setUp() public {
        vrfCoordinator = new MockVRFCoordinator();
        settlement = new PrrrSettlement(
            address(vrfCoordinator), 1, bytes32(uint256(1)), address(1)
        );
        breaker = new CircuitBreaker(address(settlement));
        settlement.setCircuitBreaker(address(breaker));
        vm.deal(address(settlement), 100 ether);
        handler = new SettlementHandler(settlement, vrfCoordinator, targetProtocol);
        targetContract(address(handler));
    }

    /// @notice Epoch count always matches created count
    function invariant_epochCountMatchesCreated() public view {
        assertEq(settlement.epochCount(), handler.epochsCreated());
    }

    /// @notice Skipping Resistance (Property 2): 1/λ < rMin
    function invariant_skippingResistance() public view {
        assertTrue(settlement.LAMBDA_INV() < settlement.R_MIN());
    }

    /// @notice Settled epochs always have circuit breaker triggered
    function invariant_settledEpochsHaveBreakerTriggered() public view {
        for (uint256 i = 1; i <= settlement.epochCount(); i++) {
            (,,,,, bool settled) = settlement.epochs(i);
            if (settled) {
                assertTrue(breaker.triggered(i));
            }
        }
    }

    /// @notice Epoch IDs are sequential starting from 1
    function invariant_sequentialEpochIds() public view {
        for (uint256 i = 1; i <= settlement.epochCount(); i++) {
            (uint256 id,,,,,) = settlement.epochs(i);
            assertEq(id, i);
        }
    }

    /// @notice Unsettled epochs must NOT have circuit breaker triggered
    function invariant_unsettledEpochsNotTriggered() public view {
        for (uint256 i = 1; i <= settlement.epochCount(); i++) {
            (,,,,, bool settled) = settlement.epochs(i);
            if (!settled) {
                assertFalse(breaker.triggered(i));
            }
        }
    }

    /// @notice RVlog values for settled reports are always >= rMin
    function invariant_rvlogAboveRMin() public view {
        for (uint256 i = 1; i <= settlement.epochCount(); i++) {
            (,,,,, bool settled) = settlement.epochs(i);
            if (settled) {
                uint256 count = settlement.getEpochReportCount(i);
                for (uint256 j = 0; j < count; j++) {
                    PrrrSettlement.Report memory r = settlement.getEpochReport(i, j);
                    assertGe(r.randomValue, settlement.R_MIN(), "RVlog must be >= rMin");
                }
            }
        }
    }
}

contract PrrrGuardRegistryInvariantTest is Test {
    PrrrGuardRegistry public registry;

    function setUp() public {
        registry = new PrrrGuardRegistry();
        targetContract(address(registry));
    }

    function invariant_minStakeConstant() public view {
        assertEq(registry.MIN_STAKE(), 0.01 ether);
    }
}
