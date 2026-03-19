// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {ICircuitBreaker} from "./interfaces/ICircuitBreaker.sol";
import {PRBMathLog} from "./libraries/PRBMathLog.sol";

/// @title PrrrSettlement — Core Prrr mechanism (IC3 paper implementation)
/// @notice Implements the Personal Random Rewards for Reporting protocol
/// @dev Faithfully implements §5.2 of the paper:
///      - Publication Phase (§5.2.2): Publishers submit report hashes, zero bids
///      - Inclusion Phase (§5.2.3): VRF provides random string S
///      - Processing Phase (§5.2.4): Second-price-style reward allocation
///
///      Random Value Function: RVlog(Rpt, S) = rMin + (1/λ) * (-ln(1 - H(Rpt||S)))
///      This ensures RVlog - rMin ~ Exp(λ), giving us:
///        - Reward Monotonicity (Property 1): RAllPub(N) = 1/λ for all N
///        - Skipping Resistance (Property 2): 1/λ < rMin ⟹ no profitable bribery
///
///      Settlement follows Algorithm 3 from the paper:
///        Case 1: Two reports, r1 >= r2 > rMin → validator gets r2, winner gets r1-r2
///        Case 2: One report → validator gets rMin, winner gets r1-rMin
///        Case 3+: Deviation cases → winner gets r1-rMin, validator gets 0
contract PrrrSettlement is VRFConsumerBaseV2Plus {
    using PRBMathLog for bytes32;

    // ── Prrr parameters (§5.4, §5.5) ────────────────────────────────
    // λ must satisfy λ > 1/rMin (Skipping Resistance, Property 2)
    // We set rMin = 0.01 ETH and 1/λ = 0.005 ETH → λ = 200
    // This ensures 1/λ = 0.005 < 0.01 = rMin ✓
    uint256 public constant R_MIN = 0.01 ether;
    uint256 public constant LAMBDA_INV = 0.005 ether; // 1/λ in wei

    // ── Epoch state ──────────────────────────────────────────────────
    struct Epoch {
        uint256 id;
        address targetProtocol;
        uint64  startBlock;        // Report generation window opens
        uint64  pubWindowStart;    // TPub: publication window opens (§5.2.1)
        uint64  endBlock;          // Epoch ends
        bool    settled;
    }

    struct Report {
        bytes32 reportHash;        // keccak256(epochId, anomalyType, evidence, nonce)
        address publisher;
        uint256 randomValue;       // RVlog value, filled after VRF callback
        uint64  submittedBlock;
    }

    mapping(uint256 => Epoch)     public epochs;
    mapping(uint256 => Report[])  internal _epochReports;
    mapping(uint256 => uint256)   public vrfRequestToEpoch;

    ICircuitBreaker public circuitBreaker;
    uint256 public epochCount;
    uint256 public totalRewardsDistributed;

    // ── Chainlink VRF config ────────────────────────────────────────
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint16  public constant REQUEST_CONFIRMATIONS = 3; // §5.2.3: prevents validator prediction
    uint32  public constant NUM_WORDS = 1;
    uint32  public constant CALLBACK_GAS_LIMIT = 500_000;

    // ── Events ──────────────────────────────────────────────────────
    event EpochCreated(uint256 indexed epochId, address indexed targetProtocol, uint64 pubWindowStart, uint64 endBlock);
    event ReportSubmitted(uint256 indexed epochId, address indexed publisher, bytes32 reportHash, uint256 reportIndex);
    event VRFRequested(uint256 indexed epochId, uint256 requestId);
    event RandomValuesAssigned(uint256 indexed epochId, uint256 reportCount, uint256 vrfSeed);
    event EpochSettled(
        uint256 indexed epochId,
        address indexed winner,
        uint256 winnerReward,
        uint256 validatorReward,
        uint256 winnerRV,
        uint256 secondRV
    );
    event CircuitBreakerTriggered(uint256 indexed epochId, address indexed targetProtocol);

    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _circuitBreaker
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
    }

    // ── Admin ───────────────────────────────────────────────────────

    function setCircuitBreaker(address _circuitBreaker) external onlyOwner {
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
    }

    // ── Epoch lifecycle (§5.2.1) ─────────────────────────────────────

    /// @notice Create a new monitoring epoch for a target protocol
    /// @param _targetProtocol Address of the DeFi protocol being monitored
    /// @param _pubWindowDelay Blocks between epoch start and publication window (TPub)
    /// @param _epochDuration Total epoch duration in blocks
    function createEpoch(
        address _targetProtocol,
        uint64  _pubWindowDelay,
        uint64  _epochDuration
    ) external returns (uint256 epochId) {
        require(_targetProtocol != address(0), "Zero target");
        require(_epochDuration > _pubWindowDelay, "Duration <= delay");

        epochId = ++epochCount;
        uint64 currentBlock = uint64(block.number);
        epochs[epochId] = Epoch({
            id: epochId,
            targetProtocol: _targetProtocol,
            startBlock: currentBlock,
            pubWindowStart: currentBlock + _pubWindowDelay,
            endBlock: currentBlock + _epochDuration,
            settled: false
        });
        emit EpochCreated(epochId, _targetProtocol, currentBlock + _pubWindowDelay, currentBlock + _epochDuration);
    }

    // ── Report submission — Publication phase (§5.2.2, Algorithm 1) ──

    /// @notice Submit a report hash. Zero bids enforced — no bribes accepted.
    /// @dev Per Algorithm 1: publishers submit (Rpt, 0) with bribe function = 0
    ///      reportHash = keccak256(abi.encode(epochId, anomalyType, evidenceABI, nonce))
    function submitReport(uint256 _epochId, bytes32 _reportHash) external {
        Epoch storage e = epochs[_epochId];
        require(e.id != 0, "Epoch does not exist");
        require(block.number >= e.pubWindowStart, "Pub window not open");
        require(block.number <= e.endBlock, "Epoch ended");
        require(!e.settled, "Already settled");

        uint256 reportIndex = _epochReports[_epochId].length;
        _epochReports[_epochId].push(Report({
            reportHash: _reportHash,
            publisher: msg.sender,
            randomValue: 0,
            submittedBlock: uint64(block.number)
        }));
        emit ReportSubmitted(_epochId, msg.sender, _reportHash, reportIndex);
    }

    // ── Inclusion phase: request VRF (§5.2.3) ────────────────────────

    /// @notice Request Chainlink VRF randomness to settle an epoch
    /// @dev Anyone can call this once reports exist. The VRF random string S
    ///      is generated privately by the VRF oracle (§5.2.3) — publishers
    ///      cannot know S when publishing, preventing strategic withholding.
    function requestSettlement(uint256 _epochId) external {
        Epoch storage e = epochs[_epochId];
        require(e.id != 0, "Epoch does not exist");
        require(!e.settled, "Already settled");
        require(_epochReports[_epochId].length > 0, "No reports");

        uint256 reqId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
        vrfRequestToEpoch[reqId] = _epochId;
        emit VRFRequested(_epochId, reqId);
    }

    // ── VRF callback → Processing phase (§5.2.4, Algorithm 3) ───────

    /// @notice Called by Chainlink VRF with the random string S
    /// @dev Implements Algorithm 3 from the paper:
    ///      1. Compute RVlog for each report using the random string S
    ///      2. Find top-2 reports by random value
    ///      3. Allocate rewards using second-price-style rule:
    ///         - Case 1 (standard): 2 reports, r1 >= r2 > rMin
    ///           → validator gets r2, winner gets r1 - r2
    ///         - Case 2 (succinct): 1 report or r2 == rMin
    ///           → validator gets rMin, winner gets r1 - rMin
    ///      4. Trigger circuit breaker
    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        uint256 epochId = vrfRequestToEpoch[_requestId];
        Epoch storage e = epochs[epochId];
        require(!e.settled, "Already settled");

        uint256 S = _randomWords[0]; // Random string Sₖ from VRF

        Report[] storage reports = _epochReports[epochId];
        uint256 n = reports.length;

        // Step 1: Assign RVlog(Rpt, S) to each report (§5.5)
        // RVlog(Rpt, S) = rMin + (1/λ) * (-ln(1 - H(Rpt||S)/2^256))
        for (uint256 i = 0; i < n; i++) {
            reports[i].randomValue = PRBMathLog.computeRVlog(
                reports[i].reportHash,
                S,
                R_MIN,
                LAMBDA_INV
            );
        }

        emit RandomValuesAssigned(epochId, n, S);

        // Step 2: Find top-2 reports by RVlog value (Algorithm 2 SORT)
        uint256 first = 0;
        uint256 second = 0;
        uint256 firstIdx = type(uint256).max;
        uint256 secondIdx = type(uint256).max;

        for (uint256 i = 0; i < n; i++) {
            uint256 rv = reports[i].randomValue;
            if (rv > first) {
                second = first;
                secondIdx = firstIdx;
                first = rv;
                firstIdx = i;
            } else if (rv > second) {
                second = rv;
                secondIdx = i;
            }
        }

        // Step 3: Second-price reward allocation (Algorithm 3)
        address winner = reports[firstIdx].publisher;
        uint256 winnerReward;
        uint256 validatorReward;

        if (secondIdx != type(uint256).max && second > R_MIN) {
            // Case 1 (Standard): Two reports, r1 >= r2 > rMin
            // Winner gets surplus: r1 - r2
            // Validator gets: r2
            winnerReward = first - second;
            validatorReward = second;
        } else {
            // Case 2 (Succinct): Single report or second value == rMin
            // Winner gets: r1 - rMin
            // Validator gets: rMin
            winnerReward = first - R_MIN;
            validatorReward = R_MIN;
        }

        e.settled = true;
        totalRewardsDistributed += winnerReward;

        // Pay winner
        if (winnerReward > 0 && address(this).balance >= winnerReward) {
            (bool success,) = payable(winner).call{value: winnerReward}("");
            require(success, "Transfer failed");
        }

        emit EpochSettled(epochId, winner, winnerReward, validatorReward, first, second);

        // Step 4: Trigger circuit breaker — pause the monitored protocol
        circuitBreaker.pause(e.targetProtocol, epochId, reports[firstIdx].reportHash);
        emit CircuitBreakerTriggered(epochId, e.targetProtocol);
    }

    // ── View helpers ────────────────────────────────────────────────

    function getEpochReportCount(uint256 _epochId) external view returns (uint256) {
        return _epochReports[_epochId].length;
    }

    function getEpochReport(uint256 _epochId, uint256 _index) external view returns (Report memory) {
        return _epochReports[_epochId][_index];
    }

    /// @notice Preview what RVlog value a report would get with a given random string
    /// @dev Useful for off-chain simulation and testing
    function previewRVlog(bytes32 _reportHash, uint256 _S) external pure returns (uint256) {
        return PRBMathLog.computeRVlog(_reportHash, _S, R_MIN, LAMBDA_INV);
    }

    receive() external payable {}
}
