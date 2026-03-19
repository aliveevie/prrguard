import { ethers } from "ethers";

const DEVIATION_THRESHOLD = 0.05; // 5% deviation triggers alert

interface OracleReport {
  anomalyType: "ORACLE_DEVIATION";
  asset: string;
  onChainPrice: bigint;
  referencePrice: bigint;
  deviationBps: number;
  blockNumber: number;
  evidenceABI: string;
}

export class OracleDeviationMonitor {
  constructor(
    private provider: ethers.JsonRpcProvider,
    private chainlinkFeed: ethers.Contract,
    private aaveOracle: ethers.Contract,
    private asset: string
  ) {}

  async check(): Promise<OracleReport | null> {
    const roundData = await this.chainlinkFeed.latestRoundData();
    const chainlinkPrice: bigint = roundData[1];

    const aavePrice: bigint = await this.aaveOracle.getAssetPrice(this.asset);

    const diff =
      chainlinkPrice > aavePrice
        ? chainlinkPrice - aavePrice
        : aavePrice - chainlinkPrice;

    const deviationBps = Number((diff * 10000n) / chainlinkPrice);

    if (deviationBps > DEVIATION_THRESHOLD * 10000) {
      const block = await this.provider.getBlockNumber();
      return {
        anomalyType: "ORACLE_DEVIATION",
        asset: this.asset,
        onChainPrice: aavePrice,
        referencePrice: chainlinkPrice,
        deviationBps,
        blockNumber: block,
        evidenceABI: ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "uint256", "uint256"],
          [this.asset, aavePrice, chainlinkPrice, block]
        ),
      };
    }
    return null;
  }
}
