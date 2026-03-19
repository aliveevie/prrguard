import { ethers } from "ethers";
import { OracleDeviationMonitor } from "./monitors/OracleDeviationMonitor";
import { Reporter } from "./reporter";
import { config } from "./config";

async function main() {
  const provider = new ethers.JsonRpcProvider(config.RPC_URL);
  const signer = new ethers.Wallet(config.PRIVATE_KEY, provider);

  const chainlinkFeed = new ethers.Contract(
    config.CHAINLINK_FEED,
    [
      "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
    ],
    provider
  );
  const aaveOracle = new ethers.Contract(
    config.AAVE_ORACLE,
    ["function getAssetPrice(address) view returns (uint256)"],
    provider
  );

  const monitor = new OracleDeviationMonitor(
    provider,
    chainlinkFeed,
    aaveOracle,
    config.MONITORED_ASSET
  );
  const reporter = new Reporter(signer, config.SETTLEMENT_ADDRESS);

  console.log(
    "[PrrrGuard] Watcher started. Monitoring:",
    config.MONITORED_ASSET
  );

  let nonce = Date.now();

  while (true) {
    try {
      const report = await monitor.check();

      if (report) {
        console.log(
          `[PrrrGuard] Anomaly detected! deviation: ${report.deviationBps}bps`
        );

        const reportHash = reporter.buildReportHash(
          BigInt(config.ACTIVE_EPOCH_ID),
          report.anomalyType,
          report.evidenceABI,
          nonce++
        );

        await reporter.submitReport(
          BigInt(config.ACTIVE_EPOCH_ID),
          reportHash
        );
      }
    } catch (err) {
      console.error("[PrrrGuard] Error:", err);
    }

    await sleep(config.POLL_INTERVAL_MS);
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch(console.error);
