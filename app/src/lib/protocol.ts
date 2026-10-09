"use client";

import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { zeroAddress, type Address } from "viem";
import {
  creditAccountFactoryAbi,
  riskEngineAbi,
  lenderPoolAbi,
  marketClockAbi,
  oracleAdapterAbi,
  erc20Abi,
  autoRepayAbi,
} from "@/abi/generated";
import { assets, deployment } from "@/config/deployments";

const d = deployment as Required<typeof deployment>;
const REFRESH = { refetchInterval: 12_000 } as const;

/** The connected user's CreditAccount (zero address if none yet). */
export function useCreditAccount() {
  const { address } = useAccount();
  const q = useReadContract({
    address: d.creditAccountFactory,
    abi: creditAccountFactoryAbi,
    functionName: "accountOf",
    args: [address ?? zeroAddress],
    query: { enabled: Boolean(address && d.creditAccountFactory) },
  });
  const acct = q.data as Address | undefined;
  return { account: acct && acct !== zeroAddress ? acct : undefined, ...q };
}

export function useAccountState(account?: Address) {
  return useReadContract({
    address: d.riskEngine,
    abi: riskEngineAbi,
    functionName: "accountState",
    args: [account ?? zeroAddress],
    query: { enabled: Boolean(account), ...REFRESH },
  });
}

export function useMarketOpen() {
  return useReadContract({ address: d.marketClock, abi: marketClockAbi, functionName: "isOpen", query: REFRESH });
}

export function useClosedDrawCap() {
  return useReadContract({ address: d.riskEngine, abi: riskEngineAbi, functionName: "closedDrawCap" });
}

/** Prices + wallet/account balances for every collateral asset (failures tolerated: stale feeds). */
export function useAssetTable(account?: Address) {
  const { address } = useAccount();
  const contracts = assets.flatMap((a) => [
    { address: d.oracleAdapter, abi: oracleAdapterAbi, functionName: "getPrice", args: [a.token] } as const,
    { address: a.token, abi: erc20Abi, functionName: "balanceOf", args: [address ?? zeroAddress] } as const,
    { address: a.token, abi: erc20Abi, functionName: "balanceOf", args: [account ?? zeroAddress] } as const,
  ]);
  const q = useReadContracts({ contracts, allowFailure: true, query: REFRESH });
  const rows = assets.map((a, i) => {
    const price = q.data?.[i * 3]?.result as bigint | undefined;
    const wallet = address ? (q.data?.[i * 3 + 1]?.result as bigint | undefined) : 0n;
    const pledged = account ? (q.data?.[i * 3 + 2]?.result as bigint | undefined) : 0n;
    return { ...a, price, wallet: wallet ?? 0n, pledged: pledged ?? 0n };
  });
  return { rows, ...q };
}

export function usePreviewLimit(tokens: Address[], amounts: bigint[]) {
  return useReadContract({
    address: d.riskEngine,
    abi: riskEngineAbi,
    functionName: "previewLimit",
    args: [tokens, amounts],
    query: { enabled: tokens.length > 0 },
  });
}

export function useStable(owner?: Address, spender?: Address) {
  return useReadContracts({
    contracts: [
      { address: d.stable, abi: erc20Abi, functionName: "balanceOf", args: [owner ?? zeroAddress] },
      { address: d.stable, abi: erc20Abi, functionName: "allowance", args: [owner ?? zeroAddress, spender ?? zeroAddress] },
    ],
    query: { enabled: Boolean(owner), ...REFRESH },
  });
}

export function usePoolStats() {
  const { address } = useAccount();
  return useReadContracts({
    contracts: [
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "totalAssets" },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "totalDebt" },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "utilization" },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "borrowRatePerYear", args: [0] },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "borrowRatePerYear", args: [1] },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "supplyRatePerYear" },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "availableLiquidityPreview" },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "balanceOf", args: [address ?? zeroAddress] },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "maxWithdraw", args: [address ?? zeroAddress] },
      { address: d.lenderPool, abi: lenderPoolAbi, functionName: "totalBadDebt" },
    ],
    query: REFRESH,
  });
}

export function useAutoRepayPlan(account?: Address) {
  return useReadContracts({
    contracts: [
      { address: d.autoRepay, abi: autoRepayAbi, functionName: "plans", args: [account ?? zeroAddress] },
      { address: d.autoRepay, abi: autoRepayAbi, functionName: "nextExecution", args: [account ?? zeroAddress] },
    ],
    query: { enabled: Boolean(account), ...REFRESH },
  });
}

export { d as addresses };
