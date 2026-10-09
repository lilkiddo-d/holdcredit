import type { Address } from "viem";
import mainnet from "./deployments/4663.json";
import fork from "./deployments/31337.json";
import { targetChainId } from "./chains";

/** Written by contracts/script/Deploy.s.sol on broadcast. */
export interface Deployment {
  chainId: number;
  stable: Address;
  quoterV2: Address;
  timelock: Address;
  marketClock: Address;
  oracleAdapter: Address;
  lenderPool: Address;
  riskEngine: Address;
  creditAccountFactory: Address;
  dexAdapter: Address;
  feeCollector: Address;
  softLiquidator: Address;
  hardLiquidator: Address;
  autoRepay: Address;
  projectTokenHooks: Address;
  complianceRegistry: Address;
  assetsRaw: string;
}

export interface CollateralAsset {
  symbol: string;
  token: Address;
  feed: Address;
  fee: number;
  ltvBps: number;
  softBps: number;
  hardBps: number;
}

const all: Record<number, Partial<Deployment>> = {
  4663: mainnet as unknown as Partial<Deployment>,
  31337: fork as unknown as Partial<Deployment>,
};

export const deployment = all[targetChainId] as Partial<Deployment>;
export const isDeployed = Boolean(deployment?.creditAccountFactory);

export const assets: CollateralAsset[] = (() => {
  try {
    return deployment?.assetsRaw ? (JSON.parse(deployment.assetsRaw) as CollateralAsset[]) : [];
  } catch {
    return [];
  }
})();

export const assetBySymbol = (s: string) => assets.find((a) => a.symbol === s);
export const assetByAddress = (a?: string) => assets.find((x) => x.token.toLowerCase() === a?.toLowerCase());

/** Project token ($HOLD). Empty env = every token feature is hidden. */
export const projectToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "") as Address | "";
export const tokenFeaturesEnabled = /^0x[0-9a-fA-F]{40}$/.test(projectToken);

export const STABLE_DECIMALS = 6;
export const STABLE_SYMBOL = "USDG";
