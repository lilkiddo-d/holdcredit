"use client";

import { useEffect, useMemo, useState } from "react";
import { usePublicClient } from "wagmi";
import { encodePacked, formatUnits, type Address } from "viem";
import { creditAccountAbi } from "@/abi/generated";
import { addresses, useAccountState, useAssetTable, useCreditAccount, useMarketOpen, usePreviewLimit, useStable } from "@/lib/protocol";
import { fmtToken, fmtUsd, safeParse } from "@/lib/format";
import { useTxRunner } from "@/lib/tx";
import { DeployBanner, MarketBanner } from "@/components/Banners";
import { assets, STABLE_DECIMALS, STABLE_SYMBOL } from "@/config/deployments";

const quoterAbi = [
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [{ name: "path", type: "bytes" }, { name: "amountIn", type: "uint256" }],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96AfterList", type: "uint160[]" },
      { name: "initializedTicksCrossedList", type: "uint32[]" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

const STABLE = "USDG";

export default function TradePage() {
  const { account } = useCreditAccount();
  const open = useMarketOpen().data as boolean | undefined;
  const { rows } = useAssetTable(account);
  const acctStable = (useStable(account, addresses.lenderPool).data?.[0]?.result as bigint | undefined) ?? 0n;
  const st = useAccountState(account).data as { limit: bigint; debtValue: bigint; debt: bigint } | undefined;
  const client = usePublicClient();
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [amount, setAmount] = useState("");
  const [slippage, setSlippage] = useState("1");
  const [quote, setQuote] = useState<bigint | undefined>();
  const [quoteErr, setQuoteErr] = useState("");
  const tx = useTxRunner();

  const meta = (sym: string) =>
    sym === STABLE
      ? { token: addresses.stable as Address, decimals: STABLE_DECIMALS, fee: 0, balance: acctStable }
      : (() => {
          const r = rows.find((x) => x.symbol === sym);
          return r ? { token: r.token, decimals: 18, fee: r.fee, balance: r.pledged } : undefined;
        })();
  const fromM = meta(from);
  const toM = meta(to);
  const amountIn = safeParse(amount, fromM?.decimals ?? 18);

  // Live Uniswap quote along the exact route the DexAdapter will use (token <-> USDG hub).
  useEffect(() => {
    setQuote(undefined);
    setQuoteErr("");
    if (!client || !fromM || !toM || amountIn === 0n || from === to) return;
    const path =
      from === STABLE
        ? encodePacked(["address", "uint24", "address"], [fromM.token, toM.fee, toM.token])
        : to === STABLE
          ? encodePacked(["address", "uint24", "address"], [fromM.token, fromM.fee, toM.token])
          : encodePacked(
              ["address", "uint24", "address", "uint24", "address"],
              [fromM.token, fromM.fee, addresses.stable as Address, toM.fee, toM.token],
            );
    let cancelled = false;
    client
      .simulateContract({ address: addresses.quoterV2 as Address, abi: quoterAbi, functionName: "quoteExactInput", args: [path, amountIn] })
      .then((r) => !cancelled && setQuote(r.result[0]))
      .catch(() => !cancelled && setQuoteErr("No quote (insufficient pool liquidity?)"));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, from, to, amountIn]);

  const slipBps = BigInt(Math.round(Math.min(Math.max(Number(slippage) || 0, 0), 3) * 100));
  const minOut = quote ? (quote * (10_000n - slipBps)) / 10_000n : 0n;

  // Projected limit after the swap (pledged holdings with the trade applied).
  const projected = useMemo(() => {
    const t: Address[] = [];
    const a: bigint[] = [];
    rows.forEach((r) => {
      let amt = r.pledged;
      if (r.symbol === from) amt -= amountIn > amt ? amt : amountIn;
      if (r.symbol === to && quote) amt += quote;
      if (amt > 0n) {
        t.push(r.token);
        a.push(amt);
      }
    });
    return { t, a };
  }, [rows, from, to, amountIn, quote]);
  const proj = usePreviewLimit(projected.t, projected.a).data as readonly [bigint, bigint, bigint] | undefined;
  const breaches = st && st.debt > 0n && proj ? st.debtValue > proj[1] : false;

  const doSwap = () =>
    account &&
    fromM &&
    toM &&
    tx.run([
      {
        label: `Swap ${from} -> ${to}`,
        args: {
          address: account,
          abi: creditAccountAbi,
          functionName: "swap",
          args: [fromM.token, toM.token, amountIn, minOut, BigInt(Math.floor(Date.now() / 1000) + 600)],
        },
      },
    ] as never);

  const symbols = [...assets.map((a) => a.symbol), STABLE];
  return (
    <>
      <h1>Trade inside your credit account</h1>
      <p className="sub">
        Rebalance pledged stocks without withdrawing: swaps route through governance-selected Uniswap v3 pools and must
        leave your debt within the post-trade credit limit.
      </p>
      <DeployBanner />
      <MarketBanner open={open} />
      {!account ? (
        <p className="banner">Open a credit account on the Borrow page first.</p>
      ) : (
        <div className="grid">
          <div className="col-7 card">
            <div className="row">
              <div>
                <label htmlFor="from">From</label>
                <select id="from" value={from} onChange={(e) => setFrom(e.target.value)}>
                  <option value="">Select</option>
                  {symbols.map((s) => (
                    <option key={s}>{s}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="to">To</label>
                <select id="to" value={to} onChange={(e) => setTo(e.target.value)}>
                  <option value="">Select</option>
                  {symbols.filter((s) => s !== from).map((s) => (
                    <option key={s}>{s}</option>
                  ))}
                </select>
              </div>
            </div>
            <label htmlFor="amt">
              Amount {fromM && <>(in account: {fmtToken(fromM.balance, fromM.decimals)})</>}
              {fromM && fromM.balance > 0n && (
                <button className="link-btn" onClick={() => setAmount(formatUnits(fromM.balance, fromM.decimals))}>
                  max
                </button>
              )}
            </label>
            <input id="amt" inputMode="decimal" placeholder="0" value={amount} onChange={(e) => setAmount(e.target.value)} />
            <label htmlFor="slip">Max slippage % (protocol hard cap vs oracle: 3%)</label>
            <input id="slip" inputMode="decimal" value={slippage} onChange={(e) => setSlippage(e.target.value)} />
            <div className="stats" style={{ marginTop: 14 }}>
              <div className="stat">
                <div className="k">Quote</div>
                <div className="v">{quote !== undefined && toM ? `${fmtToken(quote, toM.decimals)} ${to}` : quoteErr || "-"}</div>
              </div>
              <div className="stat">
                <div className="k">Min received</div>
                <div className="v">{minOut && toM ? fmtToken(minOut, toM.decimals) : "-"}</div>
              </div>
              <div className="stat">
                <div className="k">Limit after</div>
                <div className="v" style={{ color: breaches ? "var(--bad)" : undefined }}>{proj ? fmtUsd(proj[1]) : "-"}</div>
              </div>
            </div>
            {breaches && <p className="banner bad">This trade would put your debt above the new credit limit and will revert.</p>}
            <div className="row" style={{ marginTop: 14 }}>
              <button disabled={!open || !quote || amountIn === 0n || (fromM && amountIn > fromM.balance) || breaches || tx.busy} onClick={doSwap}>
                Swap in account
              </button>
            </div>
            <p className="status">{tx.status}</p>
          </div>
          <div className="col-5 card">
            <h2>Current position</h2>
            <p>Debt: {fmtUsd(st?.debtValue)}</p>
            <p>Limit now: {fmtUsd(st?.limit)}</p>
            <p>
              Idle {STABLE_SYMBOL} in account: {fmtToken(acctStable, STABLE_DECIMALS, 2)}
            </p>
            <p className="muted" style={{ fontSize: 13 }}>
              Swaps are only allowed while the US market is open, must execute within 3% of oracle value, and are
              checked against your credit limit after execution. Swapping into an ETF or diversifying usually raises
              your limit; concentrating lowers it.
            </p>
          </div>
        </div>
      )}
    </>
  );
}
