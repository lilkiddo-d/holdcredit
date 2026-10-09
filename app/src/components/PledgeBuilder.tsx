"use client";

import { useMemo, useState } from "react";
import { formatUnits, type Address } from "viem";
import { erc20Abi, creditAccountAbi } from "@/abi/generated";
import { useAssetTable, usePreviewLimit } from "@/lib/protocol";
import { fmtToken, fmtUsd, safeParse, WAD } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";

/** Build-your-pledge: pick stock tokens from the wallet and watch the credit limit update live. */
export function PledgeBuilder({ account, marketOpen }: { account?: Address; marketOpen?: boolean }) {
  const { rows } = useAssetTable(account);
  const [adds, setAdds] = useState<Record<string, string>>({});
  const { run, status, busy } = useTxRunner();

  const parsed = rows.map((r) => safeParse(adds[r.symbol] ?? "", 18));
  const tokens = rows.map((r) => r.token);
  const current = rows.map((r) => r.pledged);
  const proposed = rows.map((r, i) => r.pledged + parsed[i]);
  const held = (arr: bigint[]) => {
    const idx = arr.map((v, i) => (v > 0n ? i : -1)).filter((i) => i >= 0);
    return { t: idx.map((i) => tokens[i]), a: idx.map((i) => arr[i]) };
  };
  const cur = held(current);
  const nxt = held(proposed);
  const curQ = usePreviewLimit(cur.t, cur.a);
  const nxtQ = usePreviewLimit(nxt.t, nxt.a);
  const [curValue, curLimitOpen] = (curQ.data as readonly [bigint, bigint, bigint] | undefined) ?? [0n, 0n, 0n];
  const [nxtValue, nxtLimitOpen, nxtLimitNow] = (nxtQ.data as readonly [bigint, bigint, bigint] | undefined) ?? [0n, 0n, 0n];

  const topWeight = useMemo(() => {
    let best = { sym: "", w: 0 };
    rows.forEach((r, i) => {
      if (!r.price || nxtValue === 0n) return;
      const v = (proposed[i] * r.price) / WAD;
      const w = Number((v * 10_000n) / nxtValue) / 100;
      if (w > best.w) best = { sym: r.symbol, w };
    });
    return best;
  }, [rows, proposed, nxtValue]);

  const anyAdd = parsed.some((p) => p > 0n);
  const overWallet = rows.some((r, i) => parsed[i] > r.wallet);

  async function pledge() {
    if (!account) return;
    const steps = rows.flatMap((r, i) =>
      parsed[i] > 0n
        ? [
            { label: `Approve ${r.symbol}`, args: { address: r.token, abi: erc20Abi, functionName: "approve", args: [account, parsed[i]] } },
            { label: `Pledge ${r.symbol}`, args: { address: account, abi: creditAccountAbi, functionName: "deposit", args: [r.token, parsed[i]] } },
          ]
        : [],
    );
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    if (await run(steps as any)) setAdds({});
  }

  return (
    <div className="card">
      <h2>Build your pledge</h2>
      <p className="muted" style={{ marginTop: -6 }}>
        Credit limit = sum of value x haircut. Any single stock above 40% of the portfolio gets an extra haircut on the
        excess, so diversified pledges get higher limits.
      </p>
      <div className="stats" style={{ margin: "12px 0" }}>
        <div className="stat">
          <div className="k">Portfolio value</div>
          <div className="v">{fmtUsd(nxtValue)}</div>
        </div>
        <div className="stat">
          <div className="k">Credit limit</div>
          <div className="v big">{fmtUsd(nxtLimitOpen)}</div>
        </div>
        <div className="stat">
          <div className="k">Change</div>
          <div className="v">{nxtLimitOpen >= curLimitOpen ? "+" : ""}{fmtUsd(nxtLimitOpen - curLimitOpen)}</div>
        </div>
        <div className="stat">
          <div className="k">Largest weight</div>
          <div className="v" style={{ color: topWeight.w > 40 ? "var(--warn)" : undefined }}>
            {topWeight.sym ? `${topWeight.sym} ${topWeight.w.toFixed(1)}%` : "-"}
          </div>
        </div>
      </div>
      {!marketOpen && nxtLimitOpen > 0n && (
        <p className="banner warn">US market closed: the usable limit is shrunk to {fmtUsd(nxtLimitNow)} until the open.</p>
      )}
      {curValue > 0n && <p className="muted">Currently pledged: {fmtUsd(curValue)}</p>}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Stock</th>
              <th className="num">Price</th>
              <th className="num">Haircut</th>
              <th className="num">Wallet</th>
              <th className="num">Pledged</th>
              <th className="num">Add</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.symbol}>
                <td>
                  <strong>{r.symbol}</strong>
                </td>
                <td className="num">{r.price ? fmtUsd(r.price) : <span className="muted">stale</span>}</td>
                <td className="num">{(100 - r.ltvBps / 100).toFixed(0)}%</td>
                <td className="num">
                  {fmtToken(r.wallet)}
                  {r.wallet > 0n && (
                    <button className="link-btn" onClick={() => setAdds({ ...adds, [r.symbol]: formatUnits(r.wallet, 18) })}>
                      max
                    </button>
                  )}
                </td>
                <td className="num">{fmtToken(r.pledged)}</td>
                <td className="num">
                  <input
                    className="small"
                    inputMode="decimal"
                    placeholder="0"
                    aria-label={`Add ${r.symbol}`}
                    value={adds[r.symbol] ?? ""}
                    onChange={(e) => setAdds({ ...adds, [r.symbol]: e.target.value })}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="row" style={{ marginTop: 14 }}>
        <button disabled={!account || !anyAdd || overWallet || busy} onClick={pledge}>
          {account ? "Pledge to my credit account" : "Open a credit account first"}
        </button>
      </div>
      {overWallet && <p className="status">Amount exceeds wallet balance.</p>}
      <p className="status">{status}</p>
    </div>
  );
}
