import { config as dotenvConfig } from "dotenv";
dotenvConfig({ path: "../.env" });

export const config = {
  RPC_URL: process.env.RPC_URL || process.env.SEPOLIA_RPC_URL!,
  PRIVATE_KEY: process.env.PRIVATE_KEY!,
  SETTLEMENT_ADDRESS: process.env.SETTLEMENT_ADDRESS!,
  CHAINLINK_FEED: process.env.CHAINLINK_FEED!,
  AAVE_ORACLE: process.env.AAVE_ORACLE!,
  MONITORED_ASSET: process.env.MONITORED_ASSET!,
  ACTIVE_EPOCH_ID: Number(process.env.ACTIVE_EPOCH_ID ?? "1"),
  POLL_INTERVAL_MS: Number(process.env.POLL_INTERVAL_MS ?? "3000"),
};
