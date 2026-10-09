"use client";

import { useState } from "react";
import type { Address } from "viem";
import { autoRepayAbi, erc20Abi } from "@/abi/generated";
import { addresses, useAutoRepayPlan } from "@/lib/protocol";
import { fmtToken, safeParse } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";
import { STABLE_DECIMALS, STABLE_SYMBOL } from "@/config/deployments";

export function AutoRepayCard({ account }: { account: Address }) {
  const q = useAutoRepayPlan(account);
  const plan = q.data?.[0]?.result as readonly [bigint, bigint, boolean, boolean] | undefined;
  const next = q.data?.[1]?.result as bigint | undefined;
  const [amount, setAmount] = useState("");
  const [fromWallet, setFromWallet] = useState(false);
  const tx = useTxRunner();
  const amt = safeParse(amount, STABLE_DECIMALS);

  const save = () => {
    const steps: unknown[] = [];
    if (fromWallet) {
      steps.push({
        label: "Approve AutoRepay (12 months)",
        args: { address: addresses.stable, abi: erc20Abi, functionName: "approve", args: [addresses.autoRepay, amt * 12n] },
      });
    }
    steps.push({ label: "Save plan", args: { address: addresses.autoRepay, abi: autoRepayAbi, functionName: "setPlan", args: [account, amt, fromWallet] } });
    return tx.run(steps as never);
  };
  const cancel = () =>
    tx.run([{ label: "Cancel plan", args: { address: addresses.autoRepay, abi: autoRepayAbi, functionName: "cancelPlan", args: [account] } }] as never);

  const active = plan?.[3];
  return (
    <div className="card">
      <h2>Auto-repay</h2>
      <p className="muted" style={{ marginTop: -6 }}>
        Once a month, keepers repay from {STABLE_SYMBOL} that arrives in your credit account (send salary or dividends to it),
        and optionally top up from your wallet.
      </p>
      {active ? (
        <p>
          Active: <strong>{fmtToken(plan![0], STABLE_DECIMALS, 2)} {STABLE_SYMBOL}</strong> / month
          {plan![2] ? " (wallet top-up on)" : ""}. Next run:{" "}
          {next && next > 0n ? new Date(Number(next) * 1000).toLocaleDateString() : "next keeper cycle"}.{" "}
          <button className="link-btn" onClick={cancel} disabled={tx.busy}>
            Cancel
          </button>
        </p>
      ) : (
        <p className="muted">No plan set.</p>
      )}
      <label htmlFor="ar">Monthly amount ({STABLE_SYMBOL})</label>
      <div className="row">
        <input id="ar" inputMode="decimal" placeholder="500" value={amount} onChange={(e) => setAmount(e.target.value)} />
        <button disabled={amt === 0n || tx.busy} onClick={save}>
          {active ? "Update plan" : "Start plan"}
        </button>
      </div>
      <label style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <input type="checkbox" style={{ width: "auto" }} checked={fromWallet} onChange={(e) => setFromWallet(e.target.checked)} />
        Also pull from my wallet if the account balance is short
      </label>
      <p className="status">{tx.status}</p>
    </div>
  );
}
