"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import type { Address } from "viem";
import { creditAccountAbi, lenderPoolAbi, erc20Abi } from "@/abi/generated";
import { addresses, useAccountState, useAssetTable, useClosedDrawCap, useStable } from "@/lib/protocol";
import { fmtHealth, fmtToken, fmtUsd, MAX_UINT, safeParse, WAD } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";
import { HealthBar } from "./HealthBar";
import { STABLE_DECIMALS, STABLE_SYMBOL } from "@/config/deployments";

type State = {
  collateralValue: bigint;
  adjustedValue: bigint;
  limitOpen: bigint;
  limit: bigint;
  softThreshold: bigint;
  hardThreshold: bigint;
  debtValue: bigint;
  debt: bigint;
  softHealth: bigint;
  hardHealth: bigint;
  marketOpen: boolean;
};

export function AccountPanel({ account }: { account: Address }) {
  const { address } = useAccount();
  const st = useAccountState(account).data as State | undefined;
  const cap = useClosedDrawCap().data as bigint | undefined;
  const stable = useStable(address, addresses.lenderPool);
  const acctStable = useStable(account, addresses.lenderPool);
  const { rows } = useAssetTable(account);
  const [draw, setDraw] = useState("");
  const [repay, setRepay] = useState("");
  const [wAsset, setWAsset] = useState("");
  const [wAmt, setWAmt] = useState("");
  const tx = useTxRunner();

  const walletUsdg = (stable.data?.[0]?.result as bigint | undefined) ?? 0n;
  const accountUsdg = (acctStable.data?.[0]?.result as bigint | undefined) ?? 0n;
  const headroomUsd = st && st.limit > st.debtValue ? st.limit - st.debtValue : 0n;
  const available = (headroomUsd * 10n ** BigInt(STABLE_DECIMALS)) / WAD;
  const drawAmt = safeParse(draw, STABLE_DECIMALS);
  const repayAmt = safeParse(repay, STABLE_DECIMALS);

  const doDraw = () =>
    tx.run([{ label: "Draw", args: { address: account, abi: creditAccountAbi, functionName: "draw", args: [drawAmt, address!] } }] as never);

  const doRepay = (max: boolean) => {
    const amount = max ? MAX_UINT : repayAmt;
    const approveAmt = max ? ((st?.debt ?? 0n) * 1001n) / 1000n + 1n : repayAmt;
    return tx.run([
      { label: "Approve USDG", args: { address: addresses.stable, abi: erc20Abi, functionName: "approve", args: [addresses.lenderPool, approveAmt] } },
      { label: "Repay", args: { address: addresses.lenderPool, abi: lenderPoolAbi, functionName: "repay", args: [account, amount] } },
    ] as never);
  };

  const repayFromAccount = () =>
    tx.run([{ label: "Repay from account balance", args: { address: account, abi: creditAccountAbi, functionName: "repayFromBalance", args: [accountUsdg] } }] as never);

  const withdrawRow = rows.find((r) => r.symbol === wAsset);
  const doWithdraw = () =>
    withdrawRow &&
    tx.run([
      {
        label: `Withdraw ${withdrawRow.symbol}`,
        args: { address: account, abi: creditAccountAbi, functionName: "withdraw", args: [withdrawRow.token, safeParse(wAmt, 18), address!] },
      },
    ] as never);

  return (
    <div className="card">
      <h2>
        Your credit line{" "}
        {st && <span className={`pill ${st.marketOpen ? "open" : "closed"}`}>{st.marketOpen ? "Market open" : "Market closed"}</span>}
      </h2>
      <div className="stats">
        <div className="stat">
          <div className="k">Collateral</div>
          <div className="v">{fmtUsd(st?.collateralValue)}</div>
        </div>
        <div className="stat">
          <div className="k">Limit now</div>
          <div className="v">{fmtUsd(st?.limit)}</div>
        </div>
        <div className="stat">
          <div className="k">Debt</div>
          <div className="v">{fmtUsd(st?.debtValue)}</div>
        </div>
        <div className="stat">
          <div className="k">Available</div>
          <div className="v big">{fmtUsd(headroomUsd)}</div>
        </div>
        <div className="stat">
          <div className="k">Soft health</div>
          <div className="v">{fmtHealth(st?.softHealth)}</div>
        </div>
      </div>
      {st && <HealthBar debt={st.debtValue} limit={st.limit} soft={st.softThreshold} hard={st.hardThreshold} />}

      <label htmlFor="draw">Draw {STABLE_SYMBOL}</label>
      <div className="row">
        <input id="draw" inputMode="decimal" placeholder="0.00" value={draw} onChange={(e) => setDraw(e.target.value)} />
        <button disabled={drawAmt === 0n || drawAmt > available || tx.busy} onClick={doDraw}>
          Draw
        </button>
      </div>
      <p className="muted" style={{ fontSize: 13 }}>
        Up to {fmtToken(available, STABLE_DECIMALS, 2)} {STABLE_SYMBOL}
        {st && !st.marketOpen && cap !== undefined && ` (closed-market cap ${fmtToken(cap, STABLE_DECIMALS, 0)} per day)`}
      </p>

      <label htmlFor="repay">Repay {STABLE_SYMBOL} (wallet: {fmtToken(walletUsdg, STABLE_DECIMALS, 2)})</label>
      <div className="row">
        <input id="repay" inputMode="decimal" placeholder="0.00" value={repay} onChange={(e) => setRepay(e.target.value)} />
        <button disabled={repayAmt === 0n || repayAmt > walletUsdg || tx.busy} onClick={() => doRepay(false)}>
          Repay
        </button>
        <button className="secondary" disabled={!st || st.debt === 0n || walletUsdg < st.debt || tx.busy} onClick={() => doRepay(true)}>
          Repay all
        </button>
      </div>
      {accountUsdg > 0n && (
        <p className="muted">
          {fmtToken(accountUsdg, STABLE_DECIMALS, 2)} {STABLE_SYMBOL} has arrived in your credit account.{" "}
          <button className="link-btn" disabled={tx.busy} onClick={repayFromAccount}>
            Use it to repay
          </button>
        </p>
      )}

      <label htmlFor="wasset">Withdraw collateral</label>
      <div className="row">
        <select id="wasset" value={wAsset} onChange={(e) => setWAsset(e.target.value)}>
          <option value="">Select stock</option>
          {rows
            .filter((r) => r.pledged > 0n)
            .map((r) => (
              <option key={r.symbol} value={r.symbol}>
                {r.symbol} ({fmtToken(r.pledged)})
              </option>
            ))}
        </select>
        <input inputMode="decimal" placeholder="0" value={wAmt} onChange={(e) => setWAmt(e.target.value)} aria-label="Withdraw amount" />
        <button className="secondary" disabled={!withdrawRow || safeParse(wAmt, 18) === 0n || tx.busy} onClick={doWithdraw}>
          Withdraw
        </button>
      </div>
      <p className="status">{tx.status}</p>
    </div>
  );
}
