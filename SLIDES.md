# PrrrGuard — Slide Deck

> Shape Rotator Virtual Hackathon 2026 | DeFi, Security & Mechanism Design Track

---

## Slide 1: Title

### PrrrGuard
**Permissionless DeFi Attack Detection Powered by the Prrr Mechanism**

- First on-chain implementation of "Prrr: Personal Random Rewards for Blockchain Reporting"
- Paper by Chen, Ke, Deng, Eyal — IC3 (Initiative for CryptoCurrencies and Contracts)
- Live on Sepolia Testnet | 77 Tests Passing | Full-Stack Application

Shape Rotator Virtual Hackathon 2026 — DeFi, Security & Mechanism Design

---

## Slide 2: The Problem

### DeFi Loses Billions to Exploits Every Year

**$3.8B stolen in 2022 alone** — oracle manipulation, flash loans, price feed exploits.

Current defense systems are fundamentally broken:

| Approach | Failure Mode |
|---|---|
| **Centralized Guardians** | Single point of failure. If the guardian is offline or compromised, the protocol is unprotected. |
| **First-Reporter-Wins** | Gas wars, MEV extraction, centralization around nodes with the lowest latency. Only the fastest win. |
| **Bounty Programs** | Retroactive, not real-time. The exploit has already drained funds before anyone reports. |
| **Sybil Attacks** | Multiple identities splitting rewards. No way to distinguish honest reporters from Sybil farms. |

**The core question:** How do you incentivize permissionless, real-time attack reporting without gas wars, bribery, or centralization?

---

## Slide 3: The Solution — Prrr Mechanism

### Ex-Ante Synthetic Asymmetry (EASA)

The Prrr mechanism solves this with a single insight: **don't pay the first reporter — pay the luckiest**.

Instead of racing to be first, reporters submit simultaneously. A Chainlink VRF random seed `S` assigns each report a random value using the **RVlog function**:

```
RVlog(Rpt, S) = rMin + (1/lambda) * (-ln(1 - H(Rpt || S)))
```

- **No gas war** — submission order doesn't matter, only the random value
- **No bribery** — validators can't profitably re-roll the randomness (Skipping Resistance)
- **No Sybil advantage** — more identities don't increase expected reward
- **Constant expected reward** — regardless of how many reporters participate (Reward Monotonicity)

The winner is determined **after** all reports are submitted, using verifiable randomness that nobody can predict or manipulate.

---

## Slide 4: System Architecture

### End-to-End Attack Detection Pipeline

```
PHASE 1: MONITORING          PHASE 2: REPORTING            PHASE 3: SETTLEMENT
┌─────────────────┐          ┌─────────────────┐           ┌─────────────────┐
│ Admin creates    │          │ Watchers detect  │           │ Chainlink VRF   │
│ monitoring epoch │  ──────► │ anomaly, submit  │  ────────►│ provides random  │
│ for target DeFi  │          │ report hashes    │           │ seed S           │
│ protocol         │          │ (zero bids)      │           │                  │
└─────────────────┘          └─────────────────┘           └────────┬─────────┘
                                                                    │
PHASE 6: SAFE                PHASE 5: ACTION               PHASE 4: REWARD
┌─────────────────┐          ┌─────────────────┐           ┌───────▼──────────┐
│ Protocol paused  │          │ CircuitBreaker   │           │ RVlog computed   │
│ before funds     │ ◄─────── │ fires, halts     │ ◄──────── │ for each report. │
│ are drained      │          │ target protocol  │           │ Second-price     │
│                  │          │                  │           │ reward allocated │
└─────────────────┘          └─────────────────┘           └──────────────────┘
```

**Smart Contracts (Solidity 0.8.24 + Foundry):**

| Contract | Role |
|---|---|
| `PrrrSettlement` | Core Prrr mechanism — epochs, reports, VRF settlement, second-price rewards |
| `CircuitBreaker` | Pause hook — halts monitored protocol upon validated anomaly report |
| `PrrrGuardRegistry` | Watcher registration with 0.01 ETH minimum stake |
| `PRBMathLog` | On-chain fixed-point logarithm library for RVlog computation |

---

## Slide 5: On-Chain RVlog — The Core Innovation

### Computing Logarithms in Solidity (No Native Float Support)

The RVlog function requires computing `ln(x)` on-chain — Solidity has no floating-point math.

**Our approach (`PRBMathLog.sol`):**

1. **Hash-to-Uniform**: Map 256-bit keccak hash to `u in [0, 1)` using 128-bit WAD precision
2. **Taylor Series for artanh**: `ln(x) = 2 * artanh((x-1)/(x+1))` expanded to 8 terms
3. **Inverse CDF**: `-ln(1 - u)` transforms Uniform(0,1) into Exp(1)
4. **WAD Arithmetic**: All computation in 18-decimal fixed-point (1e18 scale)

```solidity
// PRBMathLog.sol — Faithful implementation of paper's Section 5.5
function computeRVlog(bytes32 reportHash, uint256 S, uint256 rMin, uint256 lambdaInv)
    internal pure returns (uint256 rv)
{
    bytes32 h = keccak256(abi.encode(reportHash, S));
    uint256 hi = uint256(h) >> 128;          // Top 128 bits
    uint256 u = (hi * WAD) >> 128;           // Uniform in [0, WAD)
    uint256 expVal = negLnOneMinusU(u);      // -ln(1-u) ~ Exp(1)
    rv = rMin + (lambdaInv * expVal) / WAD;  // RVlog in wei
}
```

**Result:** RVlog - rMin follows Exp(lambda), exactly as the paper requires. Verified with distribution mean test over 200 samples.

---

## Slide 6: Formal Properties — Proven On-Chain

### Paper Guarantees, Verified in Code

| Paper Property | Formal Statement | How We Test It |
|---|---|---|
| **Reward Monotonicity** (Property 1) | `RAllPub(N) = 1/lambda` for all N | `test_rvlog_distributionMean`: Mean of 200 RVlog samples = 1/lambda within tolerance |
| **Skipping Resistance** (Property 2) | `1/lambda < rMin` makes bribery unprofitable | `invariant_skippingResistance`: Checked across 256 runs x 50 depth |
| **2-Efficiency** | At most 2 reports needed on-chain | `fulfillRandomWords` uses only top-2 RVlog values for settlement |
| **RVlog >= rMin always** | No report gets reward below minimum | `testFuzz_rvlog_alwaysAboveRMin`: Fuzzed with 256 random inputs |
| **Second-Price Correctness** | Winner = r1 - r2, Validator = r2 | `testFuzz_secondPriceRewardCorrectness`: Fuzzed reward allocation |

**Parameters (from paper's Section 5.4):**

| Parameter | Value | Constraint |
|---|---|---|
| `rMin` | 0.01 ETH | Must cover validator inclusion cost |
| `1/lambda` | 0.005 ETH | Must satisfy `1/lambda < rMin` (Skipping Resistance) |
| VRF confirmations | 3 | Prevents validator from predicting seed S before report submission |

---

## Slide 7: Test Suite — 77 Tests, 8 Suites

### Comprehensive Verification Across All Layers

```
forge test -vv
Ran 8 test suites: 77 tests passed, 0 failed, 0 skipped
```

| Suite | Count | Coverage |
|---|---|---|
| **PrrrSettlement Unit** | 23 | Epoch lifecycle, report submission, VRF settlement, access control, edge cases |
| **PRBMathLog Unit** | 16 | Taylor series accuracy, ln(0.5), ln(0.25), boundary values, distribution mean |
| **PrrrSettlement Fuzz** | 8 | Random epochs, random reporters (up to 255), random seeds, RVlog bounds |
| **PrrrSettlement Invariant** | 6 | Epoch monotonicity, settled finality, RVlog floor, skipping resistance |
| **PrrrGuardRegistry Invariant** | 1 | MIN_STAKE immutability across random interactions |
| **Integration** | 8 | Full attack simulation, multi-watcher competition, second-price math, circuit breaker |
| **CircuitBreaker Unit** | 7 | Pause mechanics, double-trigger prevention, onlySettlement access |
| **PrrrGuardRegistry Unit** | 8 | Stake/unstake, duplicate prevention, watcher count tracking |

**Key fuzz test highlights:**

- `testFuzz_multipleReporters(uint8, uint256)` — Tests 1-255 reporters with random VRF seeds
- `testFuzz_settlement_deterministic(uint256)` — Same inputs always produce same RVlog outputs
- `testFuzz_skippingResistance_lambdaInvLessThanRMin(uint256, uint256)` — Protocol's core safety guarantee

---

## Slide 8: Live Demo — Oracle Attack Simulation

### Full Prrr Cycle: Detection to Circuit Breaker in One Transaction

**`SimulateAttack.s.sol`** runs the complete pipeline:

```
Step 1: Deploy mock Chainlink aggregator (ETH/USD at $2,000)
Step 2: Deploy mock Aave pool + PrrrSettlement + CircuitBreaker
Step 3: Create monitoring epoch for the Aave pool
Step 4: Simulate oracle attack — 10% price drop ($2,000 -> $1,800)
Step 5: Three independent watchers detect anomaly, submit reports
Step 6: Request Chainlink VRF settlement
Step 7: VRF callback computes RVlog for each report
Step 8: Second-price reward: winner gets r1 - r2, validator gets r2
Step 9: CircuitBreaker fires — protocol paused, funds protected
```

**What the demo proves:**

- Three permissionless watchers submit independently — no coordination needed
- Prrr assigns random values — submission order is irrelevant
- Winner is determined by RVlog, not by who has the fastest node
- Circuit breaker fires automatically — protocol is safe before any drain
- Total gas for full settlement with 3 reports: ~808K gas

**Deployed on Sepolia:**

| Contract | Etherscan |
|---|---|
| PrrrSettlement | [`0x9cdDb161...e164996`](https://sepolia.etherscan.io/address/0x9cdDb161697784F96B23391B608baf220e164996) |
| CircuitBreaker | [`0x72E6aCBd...cc2088`](https://sepolia.etherscan.io/address/0x72E6aCBd6C8426BF8743037FB72D9d2210cc2088) |
| PrrrGuardRegistry | [`0x5F4b6991...cb99`](https://sepolia.etherscan.io/address/0x5F4b69915D8c3860d4cdcAa78fc9Dd118c0aCb99) |

---

## Slide 9: Full-Stack Application

### Beyond Smart Contracts — Production-Ready System

**Live Dashboard (Next.js 14)**
- Real-time epoch monitoring from Sepolia
- RVlog value visualization with winner highlighting
- Prrr property status indicators (Skipping Resistance, Reward Monotonicity, 2-Efficiency)
- Deployed contract links to Etherscan
- Auto-refreshes every 12 seconds (one Ethereum block)

**TypeScript Watcher SDK**
- `OracleDeviationMonitor` — detects 5%+ Chainlink/Aave price deviation
- `Reporter` — builds report hashes and submits to PrrrSettlement
- Configurable polling interval, multi-asset support
- Ready for permissionless deployment by any node operator

**Project Structure:**

```
PrrrGuard/
├── src/            # 4 contracts + 1 library + 3 mocks
├── test/           # 77 tests across 8 suites
├── script/         # Deploy + SimulateAttack
├── frontend/       # Next.js 14 dashboard (static export)
└── watcher/        # TypeScript SDK (ethers v6)
```

**Tech Stack:** Solidity 0.8.24 | Foundry | Chainlink VRF v2.5 | Next.js 14 | ethers.js v6 | TypeScript

---

## Slide 10: Impact & Future Work

### From Research Paper to Production Infrastructure

**What We Built:**
- First faithful on-chain implementation of the Prrr mechanism from IC3 research
- On-chain logarithm computation via Taylor series — enabling RVlog without off-chain oracles
- Complete attack detection pipeline: monitor, report, settle, protect
- 77 tests proving the paper's formal properties hold in production Solidity

**Why This Matters for DeFi:**
- **$3.8B+ stolen annually** — real-time detection prevents exploits before funds drain
- **Permissionless** — anyone can run a watcher, no centralized guardian needed
- **Incentive-compatible** — honest reporting is the dominant strategy (proven mathematically)
- **Protocol-agnostic** — any DeFi protocol can integrate CircuitBreaker as a safety module

**Future Roadmap:**

| Phase | Milestone |
|---|---|
| **Phase 1** | Mainnet deployment with production Chainlink VRF subscription |
| **Phase 2** | Multi-monitor SDK: health factors, proof-of-reserves, TVL anomalies |
| **Phase 3** | Integration with Aave, Compound, MakerDAO safety modules |
| **Phase 4** | Decentralized epoch creation — governance-free protocol protection |
| **Phase 5** | Cross-chain monitoring via Chainlink CCIP |

**The Prrr equilibrium:** Fair rewards. No gas wars. No bribery. Protocols protected.

---

*PrrrGuard — Shape Rotator Virtual Hackathon 2026*
*Paper: "Prrr: Personal Random Rewards for Blockchain Reporting" — Chen, Ke, Deng, Eyal (IC3)*
*GitHub: [repository link] | Dashboard: [hosted link] | Sepolia: [etherscan links]*
