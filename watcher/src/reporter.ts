import { ethers } from "ethers";

const PrrrSettlementABI = [
  "function submitReport(uint256 epochId, bytes32 reportHash) external",
  "function requestSettlement(uint256 epochId) external",
  "function getEpochReportCount(uint256 epochId) external view returns (uint256)",
  "event ReportSubmitted(uint256 indexed epochId, address indexed publisher, bytes32 reportHash)",
];

export class Reporter {
  private settlement: ethers.Contract;

  constructor(
    private signer: ethers.Wallet,
    private settlementAddress: string
  ) {
    this.settlement = new ethers.Contract(
      settlementAddress,
      PrrrSettlementABI,
      signer
    );
  }

  buildReportHash(
    epochId: bigint,
    anomalyType: string,
    evidenceABI: string,
    nonce: number
  ): string {
    return ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "string", "bytes", "uint256"],
        [epochId, anomalyType, evidenceABI, nonce]
      )
    );
  }

  async submitReport(epochId: bigint, reportHash: string): Promise<string> {
    const tx = await this.settlement.submitReport(epochId, reportHash, {
      value: 0n,
      gasLimit: 200_000n,
    });
    const receipt = await tx.wait();
    console.log(`[Reporter] Report submitted. tx: ${receipt.hash}`);
    return receipt.hash;
  }

  async requestSettlement(epochId: bigint): Promise<string> {
    const tx = await this.settlement.requestSettlement(epochId, {
      gasLimit: 300_000n,
    });
    const receipt = await tx.wait();
    console.log(`[Reporter] Settlement requested. tx: ${receipt.hash}`);
    return receipt.hash;
  }
}
