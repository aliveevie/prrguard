"use client";

import { useState, useEffect } from "react";
import { ethers } from "ethers";

const SETTLEMENT_ADDRESS = "0x9cdDb161697784F96B23391B608baf220e164996";
const CIRCUIT_BREAKER_ADDRESS = "0x72E6aCBd6C8426BF8743037FB72D9d2210cc2088";
const REGISTRY_ADDRESS = "0x5F4b69915D8c3860d4cdcAa78fc9Dd118c0aCb99";
const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";

const SETTLEMENT_ABI = [
  "function epochCount() view returns (uint256)",
  "function epochs(uint256) view returns (uint256 id, address targetProtocol, uint64 startBlock, uint64 pubWindowStart, uint64 endBlock, bool settled)",
  "function getEpochReportCount(uint256) view returns (uint256)",
  "function getEpochReport(uint256, uint256) view returns (tuple(bytes32 reportHash, address publisher, uint256 randomValue, uint64 submittedBlock))",
  "function R_MIN() view returns (uint256)",
  "function LAMBDA_INV() view returns (uint256)",
  "function totalRewardsDistributed() view returns (uint256)",
  "event EpochCreated(uint256 indexed epochId, address indexed targetProtocol, uint64 pubWindowStart, uint64 endBlock)",
  "event ReportSubmitted(uint256 indexed epochId, address indexed publisher, bytes32 reportHash, uint256 reportIndex)",
  "event EpochSettled(uint256 indexed epochId, address indexed winner, uint256 winnerReward, uint256 validatorReward, uint256 winnerRV, uint256 secondRV)",
  "event CircuitBreakerTriggered(uint256 indexed epochId, address indexed targetProtocol)",
];

interface EpochData {
  id: number;
  targetProtocol: string;
  startBlock: number;
  pubWindowStart: number;
  endBlock: number;
  settled: boolean;
  reportCount: number;
}

interface ReportData {
  reportHash: string;
  publisher: string;
  randomValue: string;
  submittedBlock: number;
}

export default function Dashboard() {
  const [epochs, setEpochs] = useState<EpochData[]>([]);
  const [selectedEpoch, setSelectedEpoch] = useState<number | null>(null);
  const [reports, setReports] = useState<ReportData[]>([]);
  const [totalRewards, setTotalRewards] = useState("0");
  const [rMin, setRMin] = useState("0");
  const [lambdaInv, setLambdaInv] = useState("0");
  const [currentBlock, setCurrentBlock] = useState(0);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadData();
    const interval = setInterval(loadData, 12000);
    return () => clearInterval(interval);
  }, []);

  async function loadData() {
    try {
      const provider = new ethers.JsonRpcProvider(RPC_URL);
      const settlement = new ethers.Contract(
        SETTLEMENT_ADDRESS,
        SETTLEMENT_ABI,
        provider
      );

      const [epochCount, rMinVal, lambdaInvVal, totalRew, block] =
        await Promise.all([
          settlement.epochCount(),
          settlement.R_MIN(),
          settlement.LAMBDA_INV(),
          settlement.totalRewardsDistributed(),
          provider.getBlockNumber(),
        ]);

      setRMin(ethers.formatEther(rMinVal));
      setLambdaInv(ethers.formatEther(lambdaInvVal));
      setTotalRewards(ethers.formatEther(totalRew));
      setCurrentBlock(block);

      const epochData: EpochData[] = [];
      for (let i = 1; i <= Number(epochCount); i++) {
        const [epoch, reportCount] = await Promise.all([
          settlement.epochs(i),
          settlement.getEpochReportCount(i),
        ]);
        epochData.push({
          id: Number(epoch.id),
          targetProtocol: epoch.targetProtocol,
          startBlock: Number(epoch.startBlock),
          pubWindowStart: Number(epoch.pubWindowStart),
          endBlock: Number(epoch.endBlock),
          settled: epoch.settled,
          reportCount: Number(reportCount),
        });
      }
      setEpochs(epochData);
      setLoading(false);
    } catch (err) {
      console.error("Error loading data:", err);
      setLoading(false);
    }
  }

  async function loadReports(epochId: number) {
    setSelectedEpoch(epochId);
    try {
      const provider = new ethers.JsonRpcProvider(RPC_URL);
      const settlement = new ethers.Contract(
        SETTLEMENT_ADDRESS,
        SETTLEMENT_ABI,
        provider
      );
      const count = await settlement.getEpochReportCount(epochId);
      const reportData: ReportData[] = [];
      for (let i = 0; i < Number(count); i++) {
        const r = await settlement.getEpochReport(epochId, i);
        reportData.push({
          reportHash: r.reportHash,
          publisher: r.publisher,
          randomValue: r.randomValue.toString(),
          submittedBlock: Number(r.submittedBlock),
        });
      }
      setReports(reportData);
    } catch (err) {
      console.error("Error loading reports:", err);
    }
  }

  const statusBadge = (settled: boolean) => (
    <span
      style={{
        padding: "2px 8px",
        borderRadius: "4px",
        fontSize: "12px",
        fontWeight: "bold",
        background: settled ? "#1a472a" : "#3d2e00",
        color: settled ? "#4ade80" : "#fbbf24",
        border: `1px solid ${settled ? "#166534" : "#854d0e"}`,
      }}
    >
      {settled ? "SETTLED" : "ACTIVE"}
    </span>
  );

  return (
    <div style={{ maxWidth: 1200, margin: "0 auto", padding: "20px" }}>
      {/* Header */}
      <div
        style={{
          textAlign: "center",
          marginBottom: 40,
          paddingTop: 20,
        }}
      >
        <h1
          style={{
            fontSize: 42,
            margin: 0,
            background: "linear-gradient(135deg, #60a5fa, #a78bfa, #f472b6)",
            WebkitBackgroundClip: "text",
            WebkitTextFillColor: "transparent",
            fontWeight: 800,
          }}
        >
          PrrrGuard
        </h1>
        <p style={{ color: "#9ca3af", fontSize: 16, marginTop: 8 }}>
          Permissionless DeFi Attack Detection — Prrr Mechanism
        </p>
        <p style={{ color: "#6b7280", fontSize: 12, marginTop: 4, fontStyle: "italic" }}>
          IC3 Paper: &quot;Personal Random Rewards for Blockchain Reporting&quot; — Chen, Ke, Deng, Eyal
        </p>
        <p style={{ color: "#6b7280", fontSize: 13 }}>
          Sepolia Testnet | Block #{currentBlock}
        </p>
      </div>

      {/* Stats */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(4, 1fr)",
          gap: 16,
          marginBottom: 32,
        }}
      >
        {[
          { label: "Epochs", value: epochs.length.toString() },
          { label: "Total Rewards", value: `${totalRewards} ETH` },
          {
            label: "r_min (Min Reward)",
            value: `${rMin} ETH`,
          },
          {
            label: "1/\u03BB (Lambda Inv)",
            value: `${lambdaInv} ETH`,
          },
        ].map((stat, i) => (
          <div
            key={i}
            style={{
              background: "#111118",
              border: "1px solid #1e1e2e",
              borderRadius: 8,
              padding: 16,
              textAlign: "center",
            }}
          >
            <div style={{ fontSize: 12, color: "#9ca3af", marginBottom: 4 }}>
              {stat.label}
            </div>
            <div style={{ fontSize: 20, fontWeight: 700, color: "#e0e0e0" }}>
              {stat.value}
            </div>
          </div>
        ))}
      </div>

      {/* Prrr Properties */}
      <div
        style={{
          background: "#0d1117",
          border: "1px solid #1a472a",
          borderRadius: 8,
          padding: 16,
          marginBottom: 32,
          display: "flex",
          gap: 32,
          justifyContent: "center",
        }}
      >
        <div>
          <span style={{ color: "#4ade80", fontWeight: 600 }}>
            Skipping Resistance (Property 2)
          </span>
          <span style={{ color: "#6b7280" }}>
            {" "}
            1/\u03BB = {lambdaInv} {"<"} {rMin} = r_min{" "}
          </span>
          <span style={{ color: "#4ade80" }}>&#10003;</span>
        </div>
        <div>
          <span style={{ color: "#60a5fa", fontWeight: 600 }}>
            Reward Monotonicity (Property 1)
          </span>
          <span style={{ color: "#6b7280" }}>
            {" "}
            RAllPub(N) = 1/\u03BB for all N{" "}
          </span>
          <span style={{ color: "#60a5fa" }}>&#10003;</span>
        </div>
        <div>
          <span style={{ color: "#a78bfa", fontWeight: 600 }}>
            2-Efficiency
          </span>
          <span style={{ color: "#6b7280" }}> At most 2 reports on-chain </span>
          <span style={{ color: "#a78bfa" }}>&#10003;</span>
        </div>
      </div>

      {/* Contracts */}
      <div
        style={{
          background: "#111118",
          border: "1px solid #1e1e2e",
          borderRadius: 8,
          padding: 16,
          marginBottom: 32,
        }}
      >
        <h3 style={{ margin: "0 0 12px", color: "#9ca3af", fontSize: 14 }}>
          Deployed Contracts
        </h3>
        {[
          { name: "PrrrSettlement", addr: SETTLEMENT_ADDRESS },
          { name: "CircuitBreaker", addr: CIRCUIT_BREAKER_ADDRESS },
          { name: "PrrrGuardRegistry", addr: REGISTRY_ADDRESS },
        ].map((c) => (
          <div
            key={c.name}
            style={{
              display: "flex",
              justifyContent: "space-between",
              padding: "6px 0",
              borderBottom: "1px solid #1e1e2e",
            }}
          >
            <span style={{ color: "#9ca3af" }}>{c.name}</span>
            <a
              href={`https://sepolia.etherscan.io/address/${c.addr}`}
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "#60a5fa", textDecoration: "none", fontSize: 13 }}
            >
              {c.addr}
            </a>
          </div>
        ))}
      </div>

      {/* Epochs */}
      <h2
        style={{
          fontSize: 20,
          marginBottom: 16,
          color: "#e0e0e0",
          borderBottom: "1px solid #1e1e2e",
          paddingBottom: 8,
        }}
      >
        Monitoring Epochs
      </h2>

      {loading ? (
        <p style={{ color: "#6b7280", textAlign: "center" }}>
          Loading on-chain data...
        </p>
      ) : epochs.length === 0 ? (
        <p style={{ color: "#6b7280", textAlign: "center" }}>
          No epochs created yet. Deploy and create an epoch to get started.
        </p>
      ) : (
        <div style={{ display: "grid", gap: 12 }}>
          {epochs.map((epoch) => (
            <div
              key={epoch.id}
              onClick={() => loadReports(epoch.id)}
              style={{
                background:
                  selectedEpoch === epoch.id ? "#1a1a2e" : "#111118",
                border: `1px solid ${
                  selectedEpoch === epoch.id ? "#3b82f6" : "#1e1e2e"
                }`,
                borderRadius: 8,
                padding: 16,
                cursor: "pointer",
                transition: "border-color 0.2s",
              }}
            >
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "center",
                }}
              >
                <div>
                  <span
                    style={{
                      fontSize: 16,
                      fontWeight: 600,
                      color: "#e0e0e0",
                    }}
                  >
                    Epoch #{epoch.id}
                  </span>
                  <span style={{ marginLeft: 12 }}>
                    {statusBadge(epoch.settled)}
                  </span>
                </div>
                <span style={{ color: "#6b7280", fontSize: 13 }}>
                  {epoch.reportCount} reports
                </span>
              </div>
              <div
                style={{
                  marginTop: 8,
                  fontSize: 13,
                  color: "#6b7280",
                  display: "flex",
                  gap: 24,
                }}
              >
                <span>
                  Target: {epoch.targetProtocol.slice(0, 10)}...
                  {epoch.targetProtocol.slice(-8)}
                </span>
                <span>
                  Blocks: {epoch.startBlock} → {epoch.endBlock}
                </span>
                <span>Pub Window: block {epoch.pubWindowStart}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Reports */}
      {selectedEpoch && reports.length > 0 && (
        <div style={{ marginTop: 24 }}>
          <h3 style={{ color: "#e0e0e0", fontSize: 16 }}>
            Reports for Epoch #{selectedEpoch}
          </h3>
          <div
            style={{
              overflowX: "auto",
              background: "#111118",
              borderRadius: 8,
              border: "1px solid #1e1e2e",
            }}
          >
            <table
              style={{
                width: "100%",
                borderCollapse: "collapse",
                fontSize: 13,
              }}
            >
              <thead>
                <tr style={{ borderBottom: "1px solid #1e1e2e" }}>
                  <th
                    style={{
                      padding: 12,
                      textAlign: "left",
                      color: "#9ca3af",
                    }}
                  >
                    #
                  </th>
                  <th
                    style={{
                      padding: 12,
                      textAlign: "left",
                      color: "#9ca3af",
                    }}
                  >
                    Publisher
                  </th>
                  <th
                    style={{
                      padding: 12,
                      textAlign: "left",
                      color: "#9ca3af",
                    }}
                  >
                    Report Hash
                  </th>
                  <th
                    style={{
                      padding: 12,
                      textAlign: "left",
                      color: "#9ca3af",
                    }}
                  >
                    RVlog Value
                  </th>
                  <th
                    style={{
                      padding: 12,
                      textAlign: "left",
                      color: "#9ca3af",
                    }}
                  >
                    Block
                  </th>
                </tr>
              </thead>
              <tbody>
                {reports
                  .sort(
                    (a, b) =>
                      Number(BigInt(b.randomValue) - BigInt(a.randomValue))
                  )
                  .map((r, i) => (
                    <tr
                      key={i}
                      style={{
                        borderBottom: "1px solid #1e1e2e",
                        background: i === 0 ? "#1a2e1a" : "transparent",
                      }}
                    >
                      <td style={{ padding: 12 }}>
                        {i === 0 ? (
                          <span style={{ color: "#fbbf24" }}>
                            &#9733; Winner
                          </span>
                        ) : (
                          i + 1
                        )}
                      </td>
                      <td style={{ padding: 12, color: "#60a5fa" }}>
                        {r.publisher.slice(0, 8)}...{r.publisher.slice(-6)}
                      </td>
                      <td style={{ padding: 12, fontFamily: "monospace" }}>
                        {r.reportHash.slice(0, 14)}...
                      </td>
                      <td style={{ padding: 12, fontFamily: "monospace" }}>
                        {r.randomValue === "0"
                          ? "Pending..."
                          : ethers.formatEther(r.randomValue) + " ETH"}
                      </td>
                      <td style={{ padding: 12 }}>{r.submittedBlock}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Footer */}
      <div
        style={{
          textAlign: "center",
          marginTop: 48,
          padding: "24px 0",
          borderTop: "1px solid #1e1e2e",
          color: "#4b5563",
          fontSize: 13,
        }}
      >
        <p>
          Built for Shape Rotator Hackathon 2026 — DeFi, Security & Mechanism
          Design
        </p>
        <p>
          Paper: "Prrr: Personal Random Rewards for Blockchain Reporting" —
          Chen, Ke, Deng, Eyal (IC3)
        </p>
      </div>
    </div>
  );
}
