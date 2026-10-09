"use client";

import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { zeroAddress, type Address } from "viem";
import { erc20Abi, projectTokenHooksAbi } from "@/abi/generated";
import { addresses } from "@/lib/protocol";
import { fmtToken, safeParse } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";
import { projectToken, STABLE_DECIMALS, STABLE_SYMBOL, tokenFeaturesEnabled } from "@/config/deployments";

export default function StakePage() {
  const { address } = useAccount();
  const token = (projectToken || zeroAddress) as Address;
  const hooks = addresses.projectTokenHooks as Address;
  const q = useReadContracts({
    contracts: [
      { address: hooks, abi: projectTokenHooksAbi, functionName: "projectToken" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "stakedOf", args: [address ?? zeroAddress] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "earned", args: [address ?? zeroAddress] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "isDiscounted", args: [address ?? zeroAddress] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "minStakeForDiscount" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "cooling", args: [address ?? zeroAddress] },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [address ?? zeroAddress] },
    ],
    query: { enabled: tokenFeaturesEnabled, refetchInterval: 12_000 },
  });
  const r = (i: number) => q.data?.[i]?.result;
  const onchainToken = r(0) as Address | undefined;
  const staked = r(1) as bigint | undefined;
  const earned = r(2) as bigint | undefined;
  const discounted = r(3) as boolean | undefined;
  const minStake = r(4) as bigint | undefined;
  const cooling = r(5) as readonly [bigint, bigint] | undefined;
  const wallet = (r(6) as bigint | undefined) ?? 0n;
  const [amt, setAmt] = useState("");
  const tx = useTxRunner();
  const a = safeParse(amt, 18);

  if (!tokenFeaturesEnabled) {
    return <p className="banner">Token features are not enabled in this deployment.</p>;
  }
  const live = onchainToken && onchainToken !== zeroAddress && onchainToken.toLowerCase() === token.toLowerCase();

  return (
    <>
      <h1>Stake $HOLD</h1>
      <p className="sub">
        Stakers get a lower borrow-rate tier and a share of the protocol interest spread (paid in {STABLE_SYMBOL}, streamed
        over 7 days). Unstaking has a 7-day cooldown.
      </p>
      {!live && <p className="banner warn">The project token has not been activated on-chain yet (governance Timelock pending).</p>}
      <div className="card">
        <div className="stats">
          <div className="stat"><div className="k">Staked</div><div className="v">{fmtToken(staked)}</div></div>
          <div className="stat"><div className="k">Rewards</div><div className="v">{fmtToken(earned, STABLE_DECIMALS, 2)} {STABLE_SYMBOL}</div></div>
          <div className="stat"><div className="k">Rate tier</div><div className="v">{discounted ? "Staker" : "Standard"}</div></div>
          <div className="stat"><div className="k">Tier threshold</div><div className="v">{fmtToken(minStake, 18, 0)}</div></div>
        </div>
        <label htmlFor="amt">Amount (wallet: {fmtToken(wallet)})</label>
        <div className="row">
          <input id="amt" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="0" />
          <button
            disabled={!live || a === 0n || a > wallet || tx.busy}
            onClick={() =>
              tx.run([
                { label: "Approve", args: { address: token, abi: erc20Abi, functionName: "approve", args: [hooks, a] } },
                { label: "Stake", args: { address: hooks, abi: projectTokenHooksAbi, functionName: "stake", args: [a] } },
              ] as never)
            }
          >
            Stake
          </button>
          <button
            className="secondary"
            disabled={!live || a === 0n || a > (staked ?? 0n) || tx.busy}
            onClick={() => tx.run([{ label: "Request unstake", args: { address: hooks, abi: projectTokenHooksAbi, functionName: "requestUnstake", args: [a] } }] as never)}
          >
            Unstake
          </button>
        </div>
        <div className="row" style={{ marginTop: 12 }}>
          <button className="secondary" disabled={!earned || tx.busy} onClick={() => tx.run([{ label: "Claim", args: { address: hooks, abi: projectTokenHooksAbi, functionName: "claimRewards" } }] as never)}>
            Claim rewards
          </button>
          <button
            className="secondary"
            disabled={!cooling || cooling[0] === 0n || BigInt(Math.floor(Date.now() / 1000)) < cooling[1] || tx.busy}
            onClick={() => tx.run([{ label: "Withdraw", args: { address: hooks, abi: projectTokenHooksAbi, functionName: "withdrawUnstaked" } }] as never)}
          >
            Withdraw unstaked{cooling && cooling[0] > 0n ? ` (${fmtToken(cooling[0])}, ${new Date(Number(cooling[1]) * 1000).toLocaleDateString()})` : ""}
          </button>
        </div>
        <p className="status">{tx.status}</p>
      </div>
    </>
  );
}
