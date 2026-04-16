# PrrrGuard

**Permissionless DeFi Attack Detection Powered by the Prrr Mechanism**

**support our work on giveth**

> Faithful on-chain implementation of *"Prrr: Personal Random Rewards for Blockchain Reporting"* — Chen, Ke, Deng, Eyal (IC3)

[![Tests](https://img.shields.io/badge/tests-77%20passing-brightgreen)]()
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-blue)]()
[![Network](https://img.shields.io/badge/Sepolia-Live-purple)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

---

## The Problem

DeFi protocols lose billions to oracle manipulation, flash loan attacks, and price feed exploits. Current defense mechanisms are either:

- **Centralized** — relying on a single emergency guardian (single point of failure)
- **First-reporter-wins** — causing gas wars, MEV extraction, and centralization around the fastest nodes
- **Vulnerable to Sybil attacks** — multiple identities don't help, but the system can't distinguish them

**There is no fair, permissionless, Sybil-resistant way to incentivize DeFi attack reporting.**

## The Solution: Prrr Mechanism

PrrrGuard implements the **Prrr (Personal Random Rewards for Reporting)** protocol from IC3 research. The key innovation is **Ex-Ante Synthetic Asymmetry (EASA)** — using a carefully designed random value function to create fair incentives *without* knowing reporter identities.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PrrrGuard Pipeline                          │
│                                                                     │
│  1. EPOCH CREATION         2. PUBLICATION WINDOW     3. VRF SETTLE │
│  ┌──────────────┐          ┌──────────────────┐      ┌───────────┐ │
│  │ Admin creates │   ───►  │ Watchers submit  │ ───► │ Chainlink │ │
│  │ monitoring    │         │ report hashes    │      │ VRF gives │ │
│  │ epoch for     │         │ (zero bids,      │      │ random S  │ │
│  │ target DeFi   │         │  no bribes)      │      │           │ │
│  └──────────────┘          └──────────────────┘      └─────┬─────┘ │
│                                                            │       │
│  6. PROTOCOL SAFE          5. CIRCUIT BREAKER    4. REWARD │       │
│  ┌──────────────┐          ┌──────────────────┐  ┌────────▼──────┐ │
│  │ Attack halted │  ◄───   │ Winner's report  │◄─│ RVlog assigns │ │
│  │ before funds  │         │ triggers pause   │  │ random values │ │
│  │ are drained   │         │ on target        │  │ 2nd-price pay │ │
│  └──────────────┘          └──────────────────┘  └───────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Why Prrr Works (Paper Properties)

| Property | Guarantee | Our Implementation |
|---|---|---|
| **Reward Monotonicity** (Prop 1) | Expected reward `RAllPub(N) = 1/λ` regardless of how many reporters participate | RVlog uses Exp(λ) distribution — gap between top-2 values is always Exp(λ) in expectation |
| **Skipping Resistance** (Prop 2) | No profitable bribery: `1/λ < rMin` | `1/λ = 0.005 ETH < 0.01 ETH = rMin` — cost to bribe exceeds expected gain |
| **2-Efficiency** | At most 2 reports needed on-chain for settlement | Second-price rule uses only top-2 RVlog values |
| **Sybil Resistance** | Multiple identities don't increase expected reward | Reward depends on random value rank, not identity count |

---

## Technical Implementation

### On-Chain RVlog (The Core Innovation)

We implement the paper's logarithmic random value function **entirely on-chain** using fixed-point arithmetic:

```
RVlog(Rpt, S) = rMin + (1/λ) × (-ln(1 - H(Rpt||S)/2^256))
```

This requires computing `ln(x)` in Solidity — which doesn't natively support floating-point math. Our solution in `PRBMathLog.sol`:

1. **Hash-to-Uniform Mapping**: `H(Rpt||S)` → `u ∈ [0, 1)` via 128-bit precision WAD scaling
2. **Taylor Series for artanh**: `ln(x) = 2 × artanh((x-1)/(x+1))` with 8 terms (~15 significant digits)
3. **Inverse CDF Transform**: `-ln(1-u)` converts Uniform(0,1) → Exp(1) (paper's §5.5)
4. **WAD Arithmetic**: All computation in 18-decimal fixed-point to avoid overflow

```solidity
// From PRBMathLog.sol — faithful implementation of §5.5
function computeRVlog(bytes32 reportHash, uint256 S, uint256 rMin, uint256 lambdaInv)
    internal pure returns (uint256 rv)
{
    bytes32 h = keccak256(abi.encode(reportHash, S));
    uint256 hi = uint256(h) >> 128;
    uint256 u = (hi * WAD) >> 128;       // Uniform in [0, WAD)
    uint256 expVal = negLnOneMinusU(u);   // -ln(1-u) ~ Exp(1)
    rv = rMin + (lambdaInv * expVal) / WAD;
}
```

### Second-Price Reward Allocation (Algorithm 3)

Following the paper exactly:

| Scenario | Winner Gets | Validator Gets |
|---|---|---|
| **Case 1** (Standard): 2+ reports, `r₁ ≥ r₂ > rMin` | `r₁ - r₂` (surplus) | `r₂` |
| **Case 2** (Succinct): 1 report or `r₂ ≤ rMin` | `r₁ - rMin` | `rMin` |

This second-price structure eliminates strategic behavior — reporting honestly is always the dominant strategy.

---

## Deployed Contracts (Sepolia Testnet)

| Contract | Address | Explorer |
|---|---|---|
| **PrrrSettlement** | `0x9cdDb161697784F96B23391B608baf220e164996` | [View on Etherscan](https://sepolia.etherscan.io/address/0x9cdDb161697784F96B23391B608baf220e164996) |
| **CircuitBreaker** | `0x72E6aCBd6C8426BF8743037FB72D9d2210cc2088` | [View on Etherscan](https://sepolia.etherscan.io/address/0x72E6aCBd6C8426BF8743037FB72D9d2210cc2088) |
| **PrrrGuardRegistry** | `0x5F4b69915D8c3860d4cdcAa78fc9Dd118c0aCb99` | [View on Etherscan](https://sepolia.etherscan.io/address/0x5F4b69915D8c3860d4cdcAa78fc9Dd118c0aCb99) |

---

## Architecture

```
PrrrGuard/
├── src/
│   ├── PrrrSettlement.sol          # Core Prrr mechanism + Chainlink VRF v2.5
│   ├── CircuitBreaker.sol          # Pause hook for monitored protocols
│   ├── PrrrGuardRegistry.sol       # Watcher registration + staking
│   ├── libraries/
│   │   └── PRBMathLog.sol          # On-chain RVlog: fixed-point ln() via Taylor series
│   ├── interfaces/
│   │   ├── ICircuitBreaker.sol
│   │   └── IPrrrSettlement.sol
│   └── mocks/
│       ├── MockVRFCoordinator.sol   # VRF simulation for testing
│       ├── MockAggregator.sol       # Oracle manipulation simulation
│       └── MockAavePool.sol         # Aave V3 pool mock
├── test/
│   ├── PrrrSettlement.t.sol         # 23 unit tests
│   ├── PrrrSettlement.fuzz.t.sol    # 8 fuzz tests (256 runs each)
│   ├── PrrrSettlement.invariant.t.sol # 7 invariant tests (256 runs × 50 depth)
│   ├── Integration.t.sol            # 8 integration tests (full attack simulation)
│   ├── PRBMathLog.t.sol             # 16 math library tests (distribution verification)
│   ├── CircuitBreaker.t.sol         # 7 unit tests
│   └── PrrrGuardRegistry.t.sol      # 8 unit tests
├── script/
│   ├── Deploy.s.sol                 # Deployment script
│   └── SimulateAttack.s.sol         # Full demo: oracle attack → detection → circuit breaker
├── frontend/                        # Next.js 14 live dashboard
│   └── app/page.tsx                 # Real-time epoch monitoring, RVlog visualization
├── watcher/                         # TypeScript SDK
│   └── src/
│       ├── index.ts                 # Entry point
│       ├── monitors/
│       │   └── OracleDeviationMonitor.ts
│       ├── reporter.ts              # Report submission
│       └── config.ts
└── ARCHITECTURE.md                  # Full system design document
```

---

## Test Suite — 77 Tests Passing

```bash
# Run all tests
forge test -vv

# Output:
# Ran 8 test suites: 77 tests passed, 0 failed, 0 skipped
```

### Test Categories

| Category | Tests | What It Verifies |
|---|---|---|
| **Unit Tests** | 23 | Epoch lifecycle, report submission, VRF settlement, access control |
| **Fuzz Tests** | 8 | RVlog always ≥ rMin, second-price correctness, random input safety |
| **Invariant Tests** | 7 | Epoch count monotonicity, settled finality, skipping resistance holds |
| **Integration Tests** | 8 | Full oracle attack → detection → circuit breaker pipeline |
| **Math Library Tests** | 16 | Taylor series accuracy, distribution mean ≈ 1/λ, boundary cases |
| **CircuitBreaker Tests** | 7 | Pause mechanics, double-trigger prevention, access control |
| **Registry Tests** | 8 | Staking, deregistration, duplicate prevention |

### Key Test Highlights

- **`testFuzz_rvlog_alwaysAboveRMin`** — Verifies RVlog ≥ rMin for any random input (paper's fundamental guarantee)
- **`testFuzz_secondPriceRewardCorrectness`** — Winner reward = r₁ - r₂, validator reward = r₂ for all fuzzed values
- **`invariant_rvlogAboveRMin`** — Protocol-level invariant: no report can ever receive RV below rMin
- **`test_rvlogDistributionMean`** — Verifies mean(RVlog - rMin) ≈ 1/λ over 200 samples (within 50% tolerance)
- **`test_oracleAttackSimulation`** — End-to-end: deploy mocks → simulate 10% oracle deviation → 3 watchers report → VRF settles → circuit breaker fires

---

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (forge, cast, anvil)
- Node.js 18+ (for frontend and watcher SDK)

### Build & Test

```bash
# Clone
git clone <repo-url> && cd PrrrGuard

# Build contracts
forge build

# Run full test suite
forge test -vv

# Run specific categories
forge test --match-contract PrrrSettlementTest -vv        # Unit
forge test --match-contract PrrrSettlementFuzzTest -vv     # Fuzz
forge test --match-contract PrrrSettlementInvariantTest -vv # Invariant
forge test --match-contract IntegrationTest -vv            # Integration
forge test --match-contract PRBMathLogTest -vv             # Math library
```

### Deploy to Sepolia

```bash
cp .env.example .env  # Fill in your keys
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --legacy
```

### Run the Dashboard

```bash
cd frontend
npm install
npm run dev
# Open http://localhost:3000
```

### Run the Watcher

```bash
cd watcher
npm install
npx ts-node src/index.ts
```

---

## Key Parameters

| Parameter | Symbol | Value | Paper Reference |
|---|---|---|---|
| Min reward | `rMin` | 0.01 ETH | §5.4 — must cover validator cost |
| Lambda inverse | `1/λ` | 0.005 ETH | §5.4 — must satisfy `1/λ < rMin` |
| Pub window delay | `TPub` | 10 blocks | §5.2.1 — prevents fast-connection advantage |
| Epoch duration | `T` | 50 blocks | §5.2.1 — ~10 min monitoring window |
| VRF confirmations | — | 3 | §5.2.3 — prevents validator prediction of S |
| VRF callback gas | — | 500,000 | Sufficient for RVlog Taylor series computation |

**Why these constraints matter:**
- `1/λ < rMin` → **Skipping Resistance**: cost to bribe a validator for a re-roll exceeds the expected publisher reward
- `TPub > 0` → **Publication window**: prevents fast-connection centralization (Theorem 1)
- VRF confirmations ≥ 3 → **Validator blindness**: S cannot be predicted before reports are submitted

---

## Demo Scenario: Oracle Attack Detection

```bash
# Run the full simulation script
forge script script/SimulateAttack.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --legacy
```

**What happens:**
1. Deploy mock Chainlink aggregator + Aave pool
2. Create monitoring epoch targeting the mock protocol
3. Simulate a **10% oracle price manipulation**
4. **3 independent watchers** detect the anomaly and submit reports
5. Request Chainlink VRF settlement
6. VRF callback computes RVlog for each report
7. **Second-price reward**: winner gets `r₁ - r₂`, validator gets `r₂`
8. **Circuit breaker fires** — protocol is paused before funds are drained

> *"Three permissionless watchers detect a 10% oracle deviation. Under first-reporter-wins, they'd flood the mempool in a gas war. Under Prrr, all three submit freely — Chainlink VRF determines the winner. No gas war. No centralization. No profitable bribery. The circuit breaker fires. The protocol is safe."*

---

## Paper Implementation Fidelity

| Paper Section | Concept | Implementation |
|---|---|---|
| §5.2.1 | Epoch lifecycle with TPub delay | `PrrrSettlement.createEpoch()` |
| §5.2.2 | Publication phase, zero bids | `submitReport()` — `msg.value` not accepted |
| §5.2.3 | Inclusion via VRF | Chainlink VRF v2.5, 3 confirmations |
| §5.2.4 | Processing phase, Algorithm 3 | `fulfillRandomWords()` — second-price allocation |
| §5.5 | RVlog with logarithmic function | `PRBMathLog.computeRVlog()` — full on-chain ln() |
| Appendix B.1 | RVlog - rMin ~ Exp(λ) | Verified in `test_rvlogDistributionMean` |
| Property 1 | Reward Monotonicity | `invariant_rvlogAboveRMin`, fuzz tests |
| Property 2 | Skipping Resistance: 1/λ < rMin | `invariant_skippingResistance` |
| Algorithm 2 | SORT — find top-2 by RV | O(n) scan in `fulfillRandomWords` |
| Algorithm 3 | Second-price reward allocation | Case 1 (standard) + Case 2 (succinct) |

---

## Stack

- **Smart Contracts**: Solidity 0.8.24, Foundry
- **Randomness**: Chainlink VRF v2.5 (Sepolia)
- **Math**: Custom fixed-point logarithm library (WAD arithmetic, Taylor series)
- **Frontend**: Next.js 14, ethers.js v6, static export
- **Watcher SDK**: TypeScript, ethers.js v6
- **Testing**: Foundry (unit + fuzz + invariant + integration)

---

## References

- Chen, Ke, Deng, Eyal. *"Prrr: Personal Random Rewards for Blockchain Reporting"* — IC3 (Initiative for CryptoCurrencies and Contracts)
- Chainlink VRF v2.5 Documentation
- Aave V3 Security Architecture

---
## Giveth Project Verification

PrrrGuard is listed on Giveth as a public good contributing to DeFi security research and infrastructure. Donations support mainnet deployment, security audits, and open-source tooling for the watcher ecosystem.

**Official Giveth project page:** https://giveth.io/project/prrrguard

This README serves as the official public statement verifying that the Giveth project listed above is owned and operated by the PrrrGuard team under IBX Lab. Any Giveth project claiming to represent PrrrGuard not linked from this repository is not authorized by the team.

*Built for the Shape Rotator Virtual Hackathon 2026 — DeFi, Security & Mechanism Design Track*
