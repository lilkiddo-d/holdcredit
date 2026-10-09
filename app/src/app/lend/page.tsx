"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { erc20Abi, lenderPoolAbi } from "@/abi/generated";
import { addresses, usePoolStats, useStable } from "@/lib/protocol";
import { fmtPct, fmtToken, safeParse } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";
import { DeployBanner } from "@/components/Banners";
import { STABLE_DECIMALS, STABLE_SYMBOL, tokenFeaturesEnabled } from "@/config/deployments";

export default function LendPage() {
  const { address } = useAccount();
  const q = usePoolStats();
  const v = (i: number) => q.data?.[i]?.result as bigint | undefined;
  const [totalAssets, totalDebt, util, rateStd, rateStaker, supplyRate, liquidity, shares, maxWithdraw, badDebt] = [
    v(0), v(1), v(2), v(3), v(4), v(5), v(6), v(7), v(8), v(9),
  ];
  const wallet = (useStable(address, addresses.lenderPool).data?.[0]?.result as bigint | undefined) ?? 0n;
  const [dep, setDep] = useState("");
  const [wd, setWd] = useState("");
  const tx = useTxRunner();
  const depAmt = safeParse(dep, STABLE_DECIMALS);
  const wdAmt = safeParse(wd, STABLE_DECIMALS);

  const deposit = () =>
    tx.run([
      { label: "Approve USDG", args: { address: addresses.stable, abi: erc20Abi, functionName: "approve", args: [addresses.lenderPool, depAmt] } },
      { label: "Deposit", args: { address: addresses.lenderPool, abi: lenderPoolAbi, functionName: "deposit", args: [depAmt, address!] } },
    ] as never);
  const withdraw = () =>
    tx.run([{ label: "Withdraw", args: { address: addresses.lenderPool, abi: lenderPoolAbi, functionName: "withdraw", args: [wdAmt, address!, address!] } }] as never);

  return (
    <>
      <h1>Lend {STABLE_SYMBOL}</h1>
      <p className="sub">
        Supply {STABLE_SYMBOL} to the ERC-4626 lender pool (hcUSDG shares). Borrowers pay a utilization-based rate;
        lenders receive the interest minus the protocol reserve factor.
      </p>
      <DeployBanner />
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="stats">
          <div className="stat"><div className="k">Pool size</div><div className="v">{fmtToken(totalAssets, STABLE_DECIMALS, 0)}</div></div>
          <div className="stat"><div className="k">Borrowed</div><div className="v">{fmtToken(totalDebt, STABLE_DECIMALS, 0)}</div></div>
          <div className="stat"><div className="k">Utilization</div><div className="v">{fmtPct(util)}</div></div>
          <div className="stat"><div className="k">Supply APR</div><div className="v big">{fmtPct(supplyRate)}</div></div>
          <div className="stat"><div className="k">Borrow APR</div><div className="v">{fmtPct(rateStd)}</div></div>
          {tokenFeaturesEnabled && (
            <div className="stat"><div className="k">Staker borrow APR</div><div className="v">{fmtPct(rateStaker)}</div></div>
          )}
          <div className="stat"><div className="k">Withdrawable liquidity</div><div className="v">{fmtToken(liquidity, STABLE_DECIMALS, 0)}</div></div>
          <div className="stat"><div className="k">Realised bad debt</div><div className="v">{fmtToken(badDebt, STABLE_DECIMALS, 2)}</div></div>
        </div>
      </div>
      <div className="grid">
        <div className="col-6 card">
          <h2>Deposit</h2>
          <label htmlFor="dep">Amount (wallet: {fmtToken(wallet, STABLE_DECIMALS, 2)} {STABLE_SYMBOL})</label>
          <div className="row">
            <input id="dep" inputMode="decimal" placeholder="0.00" value={dep} onChange={(e) => setDep(e.target.value)} />
            <button disabled={!address || depAmt === 0n || depAmt > wallet || tx.busy} onClick={deposit}>Deposit</button>
          </div>
        </div>
        <div className="col-6 card">
          <h2>Withdraw</h2>
          <label htmlFor="wd">Amount (max now: {fmtToken(maxWithdraw, STABLE_DECIMALS, 2)} {STABLE_SYMBOL}; shares: {fmtToken(shares, 12, 2)})</label>
          <div className="row">
            <input id="wd" inputMode="decimal" placeholder="0.00" value={wd} onChange={(e) => setWd(e.target.value)} />
            <button className="secondary" disabled={!address || wdAmt === 0n || wdAmt > (maxWithdraw ?? 0n) || tx.busy} onClick={withdraw}>Withdraw</button>
          </div>
          <p className="muted" style={{ fontSize: 13 }}>Withdrawals are limited by idle liquidity; high utilization pushes rates up to attract repayments.</p>
        </div>
      </div>
      <p className="status">{tx.status}</p>
      <div className="card muted" style={{ marginTop: 16, fontSize: 14 }}>
        Lender risk: if collateral cannot be liquidated fast enough (e.g. a correlated crash or a market gap), the shortfall
        is covered first by protocol reserves and then shared by all lenders pro rata. See <a href="/risk">Risks</a>.
      </div>
    </>
  );
}
