import { formatUnits, parseUnits } from "viem";

export const WAD = 10n ** 18n;
export const MAX_UINT = 2n ** 256n - 1n;

export function fmtUsd(wad?: bigint, digits = 2): string {
  if (wad === undefined) return "-";
  const n = Number(formatUnits(wad, 18));
  return n.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: digits });
}

export function fmtToken(raw?: bigint, decimals = 18, digits = 4): string {
  if (raw === undefined) return "-";
  const n = Number(formatUnits(raw, decimals));
  return n.toLocaleString("en-US", { maximumFractionDigits: digits });
}

export function fmtPct(wad?: bigint, digits = 2): string {
  if (wad === undefined) return "-";
  return `${(Number(formatUnits(wad, 18)) * 100).toFixed(digits)}%`;
}

export function fmtHealth(wad?: bigint): string {
  if (wad === undefined) return "-";
  if (wad > 10n ** 30n) return "Inf";
  return Number(formatUnits(wad, 18)).toFixed(3);
}

export function safeParse(value: string, decimals: number): bigint {
  try {
    if (!value || Number(value) <= 0) return 0n;
    return parseUnits(value as `${number}`, decimals);
  } catch {
    return 0n;
  }
}

export function shortAddr(a?: string): string {
  return a ? `${a.slice(0, 6)}...${a.slice(-4)}` : "";
}
