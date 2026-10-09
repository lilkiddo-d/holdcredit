"use client";

import { fmtUsd } from "@/lib/format";

/**
 * Position of current debt on a scale from 0 to the hard-liquidation threshold.
 * Marks: credit limit (draws stop), soft threshold (keepers trim), hard threshold (full liquidation).
 */
export function HealthBar({
  debt,
  limit,
  soft,
  hard,
}: {
  debt: bigint;
  limit: bigint;
  soft: bigint;
  hard: bigint;
}) {
  if (hard === 0n) return <p className="muted">Pledge collateral to see your health bar.</p>;
  const scale = (hard * 110n) / 100n;
  const pct = (v: bigint) => Math.min(100, Number((v * 10_000n) / scale) / 100);
  const state = debt > hard ? "Hard liquidation" : debt > soft ? "Soft liquidation zone" : debt > limit ? "Above limit" : "Healthy";
  return (
    <div>
      <div className="hb" role="img" aria-label={`Debt ${fmtUsd(debt)}; status ${state}`}>
        <div className="mark" style={{ left: `${pct(limit)}%` }}>
          <span>Limit {fmtUsd(limit, 0)}</span>
        </div>
        <div className="mark" style={{ left: `${pct(soft)}%` }}>
          <span style={{ top: 44 }}>Soft {fmtUsd(soft, 0)}</span>
        </div>
        <div className="mark" style={{ left: `${pct(hard)}%` }}>
          <span>Hard {fmtUsd(hard, 0)}</span>
        </div>
        <div className="dot" style={{ left: `${pct(debt)}%` }}>
          <span>Debt {fmtUsd(debt, 0)}</span>
        </div>
      </div>
      <p className="muted" style={{ marginTop: 34 }}>
        Status: <strong>{state}</strong>
      </p>
    </div>
  );
}
