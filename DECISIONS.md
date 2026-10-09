# DECISIONS

One line of reasoning per decision. Newest decisions at the bottom of each section.

## Chain, assets, external dependencies

- **Chain:** Robinhood Chain mainnet, chain ID 4663, ETH gas, Blockscout verification. Taken from docs.robinhood.com/chain and checked with `cast chain-id`.
- **Borrow/lend asset: USDG (6 decimals).** It is the stablecoin listed on the official Token Contracts page, and the deepest stock-token pools pair against it.
- **Stock-token addresses come from the official asset registry API** (`api.robinhood.com/rhj/assets`, the source behind the docs' token table), joined on ticker with Chainlink's feed list and verified on-chain (`symbol()`, `decimals()`, `uiMultiplier()`).
- **Launch collateral: 16 tokens** that have both a Chainlink feed and at least ~$100k of USDG depth in a Uniswap v3 pool (measured on-chain on 2026-10-08). The other 16 feed-backed tokens are too illiquid for safe liquidation.
- **Oracle: Chainlink proxies (8 decimals, 24h heartbeat, 0.5% deviation, 24/5 hours).** These are the official price source in the Robinhood Chain docs. The feed price already includes the ERC-8056 multiplier, so the protocol never applies it again.
- **Staleness: 25h while the market is open, 4 days while closed.** That is heartbeat plus a 1h buffer when open, and a window that covers weekends plus a holiday when closed.
- **The USDG/USD feed values debt.** If USDG depegs upward, debt value rises and the protocol becomes stricter. That is safer than assuming $1.
- **The corporate-action pause flag is honoured.** Stock tokens expose `oraclePaused()`, and the adapter refuses prices while it is set.
- **Sequencer uptime feed:** none is published for Robinhood Chain yet. The adapter supports one (`address(0)` disables it) and governance can enable it later. Documented as a gap.
- **Secondary feed / deviation check:** supported per asset, but off by default. Chainlink's "secondary" proxy reads the same aggregator, so pairing them would add gas without adding independence.
- **DEX: Uniswap v3 SwapRouter02**, the official deployment on Robinhood Chain. Routes are token↔USDG (one hop) or token→USDG→token (two hops), and fee tiers are set per token by governance. Callers cannot choose pools, which blocks "route through my own pool" abuse.
- **No on-chain US market calendar exists, so Holdcredit ships its own MarketClock.**
  - US DST rules are computed on-chain.
  - Holidays and early closes are preloaded for 2026–27 and maintained by a calendar-ops role. That role can only close the market or return it to auto; forcing it open needs the Timelock.
- **"Open" means the regular session (09:30–16:00 ET), not the 24/5 token trading window.** Price discovery and DEX depth are best then; extended hours count as closed, which is conservative. Governance can widen the session.

## Risk model

- **Single credit limit:** Σ(value × LTV), with three weights per asset: LTV < soft < hard. One number drives draws, a second soft liquidation, and a third hard liquidation.
- **Diversification ("concentration penalty"):** the part of any position above 40% of the portfolio loses 50% of its credit weight. It is continuous and monotone, so adding collateral never lowers a limit (fuzz-tested). Applying it only to the excess avoids cliff effects.
- **Four risk tiers:**
  - ETF 70/77/83;
  - megacap 60/68/75;
  - volatile 50/58/66;
  - high-volatility 35/43/50.
  The soft/hard spacing guarantees that selling a slice always improves soft health (proof sketch in THREAT_MODEL).
- **Market closed: the limit shrinks to 80% and draws are capped at 500 USDG per account per New York day.** This allows small weekend liquidity while capping gap exposure.
- **Withdrawing collateral while indebted** needs an open market, an unpaused protocol and a post-trade limit check. With no debt, withdrawals are allowed at any time, so users can always exit.
- **Swaps:**
  - only while the market is open;
  - executed price at most 3% worse than oracle value;
  - post-swap debt must be ≤ the limit;
  - the account trusts the balance it actually received, never less than the adapter reports.
- **Collateral list is capped at 15 assets per account** (spec), which bounds every loop. Only the owner can deposit or track assets, so nobody can grief an account by filling its list.
- **Debt checks are authoritative after execution:** `draw` re-checks the limit after borrowing because scaled-debt rounding can add one or two wei. The invariant suite found this.

## Liquidations

- **Soft liquidation is gated to keepers (KEEPER_ROLE) by default.** It is a gentle protocol action, and gating reduces MEV games; governance can make it permissionless.
- **Soft liquidation picks the most overweight asset, else the one with the highest value × liquidity score, on-chain.** The keeper chooses nothing, so it cannot steer the sale.
- **Soft slice:** the size needed to reach soft health 1.05, capped at 10% of the portfolio, with a 5-minute cooldown, minOut = oracle − 1.5%, and a 0.5% keeper fee. The call reverts unless soft health strictly improves.
- **Hard liquidation is permissionless at any hour.**
  - 8% bonus, 10% of which goes to the FeeCollector;
  - 50% close factor;
  - 100% if hard health is below 0.95 or the debt is at most 100 USDG.
  This is industry standard and keeps the protocol solvent even when keepers are offline.
- **Bad debt is written off when collateral is below $1.** Reserves cover it first, then lenders share the rest, and it is tracked as `totalBadDebt`.

## Pool and rates

- **ERC-4626 with a 6-decimal virtual offset**, which makes first-depositor inflation attacks uneconomic (tested).
- **Kinked rate:** 3% base, +9% up to 85% utilization, +80% above it (the slope2 jump). The model is immutable and swapped via the Timelock.
- **Staker tier:** a second borrow index at a 20% rate discount. Accounts move between indexes via `syncTier`, which runs automatically on stake and unstake. Two indexes keep accrual O(1).
- **Reserve factor of 15%.** Reserves are the protocol's "interest spread" and flow to the FeeCollector.
- **Repayments are never pausable,** and neither are collateral deposits. Pausing them could only increase risk.

## Token ($HOLD)

- **No ERC-20 is written or deployed.** `ProjectTokenHooks.setProjectToken(address)` is callable once by the admin (the Timelock), and every token feature is inert until then.
- **Staking:**
  - A 7-day unstake cooldown; cooling tokens earn nothing and give no discount.
  - The discount tier needs 1,000 tokens (scaled to the token's decimals) and is adjustable through the Timelock.
  - Rewards stream over 7 days (Synthetix-style) to neutralise just-in-time staking.
- **Interest-spread sharing:** FeeCollector sends 50% of collected reserves to stakers once the token is live and staked, otherwise 100% to the treasury.

## Governance & ops

- **TimelockController with a 48h minimum delay that it administers itself.** Executors are open, so anyone can execute a matured operation.
- **The guardian can pause and unpause instantly but cannot change parameters.** Instant unpause avoids a 48h outage after a false alarm.
- **The deployer holds no role after `Deploy.s.sol`.** Every admin role moves to the Timelock in the same broadcast, and a test asserts this.
- **Every signing key lives in a Foundry keystore** (`holdcredit-deployer`, `holdcredit-keeper`). The keeper signs through `cast send --account` and never loads a key itself.
- **The compliance registry is deployed but disabled.** The factory always consults it, and its action flags are pre-set, so enabling it is one Timelock call.
- **The frontend geoblock is driven by an env var.** The example lists US, CA, GB and CH because the issuer restricts stock tokens there.

## Tooling

- **Solidity 0.8.28, `evm_version = cancun`** (supported by Arbitrum Orbit), optimizer at 200 runs, no via-IR, which keeps coverage instrumentation accurate.
- **Slither: zero High or Medium findings.** True positives were fixed in code; false positives have per-line suppressions with a written justification (docs/SLITHER.md).
- **Sources are ASCII-only with LF line endings** (`.gitattributes`). Non-ASCII characters and CRLF shift Slither's source-line mapping on Windows.
- **Fork tests run the real `Deploy` script** against Robinhood Chain mainnet state, so the production wiring is what gets exercised.
- **Frontend: Next.js 15 App Router, wagmi 2, viem 2, RainbowKit 2,** with no CSS framework to keep the dependency surface small.
- **A "fork dev wallet" (wagmi mock connector) exists only for chain 31337** with `--auto-impersonate`, so the UI can be driven on a fork without any private key.
