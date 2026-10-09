# THREAT MODEL

Scope: `contracts/src/**`, the keeper (`scripts/`), and the frontend (`app/`). Holdcredit has not had a third-party audit. This document lists the assets at risk, who might attack them, how, and what mitigates each attack. It also lists residual risks that remain. Section 1 covers the top three risks named in the spec.

## Assets at risk
- Lender USDG held in `LenderPool`.
- Borrower collateral (stock tokens) held in each `CreditAccount`.
- Protocol reserves and fees (`LenderPool.reserves`, `FeeCollector`).
- Staker rewards (`ProjectTokenHooks`, once the token is set).

## Actors
| Actor | Trust | Powers |
|---|---|---|
| Timelock (48h) | Trusted, delayed | All parameters, module swaps, `setProjectToken`, oracle feeds |
| Guardian multisig | Semi-trusted | Pause/unpause; calendar ops (holidays, force-close); compliance allowlist |
| Keeper (`KEEPER_ROLE`) | Semi-trusted | Trigger soft liquidations. It cannot choose the asset, size, venue or price. |
| Hard liquidators | Untrusted | Repay the debt of accounts below the hard threshold for discounted collateral |
| Borrowers / lenders | Untrusted | Their own accounts and positions |
| Oracle (Chainlink) | External trust | Prices |
| Uniswap v3 pools | Untrusted liquidity | Execution venue |
| Stock-token issuer | External trust | Token contract upgrades, transfer restrictions, `oraclePaused` |

---

## 1. Top risks (from the spec)

### 1.1 Correlated crashes
**Threat:** every stock in a portfolio falls together, as in a broad sell-off or a market-wide gap at the open. Diversification gives no protection, and liquidations all fire at once against thin DEX liquidity.

**Mitigations**
- **Conservative per-asset haircuts by volatility tier.** ETFs 70% LTV down to high-volatility names at 35%. The hard thresholds sit 13–17 points above LTV, so a portfolio drawn to its limit survives roughly a 15–20% uniform drop before hard liquidation.
- **Two-stage deleveraging.** Soft liquidation trims positions early, in small slices while liquidity is good, which stops liquidations from piling up all at the end.
- **Closed-market shrink and draw caps.** Outside regular hours the limit is 80%, and new borrowing is capped at 500 USDG per day per account. That bounds new exposure across weekend and overnight gaps, which is when correlated gaps happen.
- **Hard liquidation keeps running at any hour and needs no DEX.** Liquidators repay USDG and take stock at an oracle-priced discount, so the protocol does not depend on pool depth during a crash.
- **Losses are covered in order: reserves first, then lenders pro rata.** Bad debt is tracked (`totalBadDebt`), and the invariant `totalAssets >= deposits - withdrawals - realisedBadDebt` is fuzzed.
- **Lender liquidity backstop.** The rate model jumps to +80% APR above 85% utilisation, which pulls repayments in when liquidity is tight.

**Residual risk:** a gap larger than (hard − LTV) on the whole portfolio creates bad debt. The parameters are deliberately conservative but are not a guarantee. Monitor `totalBadDebt` and per-asset exposure.

### 1.2 In-account swap abuse
**Threats**
- Swapping collateral into worthless or illiquid assets to extract value.
- Routing through an attacker-owned pool at a manipulated price, which pays the attacker and leaves the account under-collateralised.
- Swapping into an asset whose oracle lags.
- Reentrancy during the swap.

**Mitigations**
- **Allow-listed assets only.** `tokenOut` must be enabled and not frozen collateral, or USDG.
- **Callers cannot pick routes.** The `DexAdapter` routes only through governance-configured Uniswap v3 fee tiers against the USDG hub.
- **Oracle-bounded execution.** The output's oracle value must be at least 97% (default) of the input's oracle value. A manipulated pool can extract at most 3% per swap, and only from the user's own equity.
- **Limit check after execution.** If there is any debt, the swap reverts unless debt ≤ limit afterwards (property-fuzzed and invariant-tested: "no swap leaves an account above its limit").
- **The account measures real balance deltas** and requires the received amount to be at least both `minAmountOut` and what the adapter reports.
- **Market-open only.** That is when oracles update most often and DEX depth is highest.
- **Reentrancy guards.** `nonReentrant` on the account, the adapter and the pool. Approvals are reset to zero after every swap.

**Residual risk:** a user can still lose up to `maxSwapLossBps` of their own equity to MEV on each swap. That is their own value, not lenders'.

### 1.3 Soft-liquidation sandwiching
**Threat:** an attacker front-runs a soft liquidation by pushing the stock/USDG pool price down. The protocol's sale then fills at the bad price and the attacker back-runs for profit, extracting value from the borrower.

**Mitigations**
- **The contract chooses asset, size and venue, not the keeper.** It picks the most overweight asset (else highest value × liquidity score) and sizes the slice on-chain.
- **Minimum output is computed on-chain from the oracle.** The default is oracle − 1.5%, so a sandwich can extract at most 1.5% of the slice. Pushing a $1M+ pool past that bound costs more than it yields for 10% slices.
- **Small slices.** Each slice is at most 10% of the portfolio, and the same account has a 5-minute cooldown, so repeated sandwiching gets expensive.
- **Keeper-only by default, open market only.** Keepers can submit through private or FCFS ordering; Robinhood Chain's sequencer orders transactions first-come, first-served rather than by fee.
- **The transaction reverts unless soft health strictly improves.** Fuzzed property: with the asset weights we use, a slice sold within the slippage bound always improves health in the soft zone. Proof sketch: selling value V with soft weight s ≤ 0.77, total haircut f ≤ 2%, and soft health h ≥ min(soft/hard) ≥ 0.86 improves health iff s/(1−f) < h, and 0.786 < 0.86.

**Residual risk:** at most 1.5% of slice value per soft step can leak to MEV. A keeper gets a 0.5% fee per slice and could spam calls, but the cooldown and the improve-or-revert rule make spam useless.

---

## 2. Other threats

| # | Threat | Mitigation | Residual |
|---|---|---|---|
| 2.1 | Stale or manipulated oracle | Staleness by market state (25h open / 4d closed), positive-answer and `answeredInRound` checks, optional secondary-feed deviation check, optional sequencer feed, stock-token `oraclePaused()` honoured. The oracle is swappable via the Timelock. | Chainlink trust; no sequencer feed published yet |
| 2.2 | First-depositor ERC-4626 inflation | 6-decimal virtual share offset (tested with a 10k donation) | None material |
| 2.3 | Reentrancy (cross-contract) | `nonReentrant` on every state-changing entry point; checks-effects-interactions; post-execution limit checks | Read-only reentrancy through trusted tokens only |
| 2.4 | Rounding drift in debt | Debt rounds up for the protocol; `draw` re-checks the limit after borrowing (found by the invariant suite); invariant: Σ scaled debt == tier totals | Wei-level dust |
| 2.5 | Unbounded loops / DoS | ≤15 assets per account; paginated `getAccounts`; only the owner can track assets | None |
| 2.6 | Admin key compromise | Every admin power sits behind the 48h Timelock; the deployer renounces all roles; the guardian can only pause; force-opening the market needs the Timelock | Timelock proposer must be a multisig in production |
| 2.7 | Guardian abuse | The guardian can pause new draws, swaps and lending, but **not** repayments or deposits; it cannot move funds | Liveness only |
| 2.8 | Keeper compromise | Keepers can only trigger checked actions; the contract chooses every parameter; auto-repay only moves owner-authorised funds into the owner's own debt | Spam (bounded by cooldown) |
| 2.9 | Flash-stake for the rate discount or rewards | 7-day unstake cooldown; the tier drops as soon as an unstake is requested; rewards stream over 7 days | None material |
| 2.10 | Stock-token issuer actions (pause, upgrade, blacklist an account) | `oraclePaused` honoured; governance can freeze or disable assets; seize and withdraw use SafeERC20 | Issuer can freeze a specific account's collateral |
| 2.11 | Corporate actions (splits, dividends) | The oracle price already includes the ERC-8056 multiplier; the protocol never applies it twice | Short oracle pause windows |
| 2.12 | USDG depeg | Debt valued through the USDG/USD feed; an upward depeg makes the protocol stricter | A downward depeg favours borrowers until governance acts |
| 2.13 | MarketClock errors (holiday not set) | Holidays preloaded for 2026–27; calendar ops can force-close; forcing open needs the Timelock; DST computed on-chain | Ops must load future years |
| 2.14 | Compliance gating locking users in | The registry never gates repay, deposit or liquidation | — |
| 2.15 | Frontend compromise | Static app with no keys; every transaction is shown in the user's wallet; deployment addresses come from the broadcast artefact | Supply-chain risk in npm deps |

## 3. Invariants (enforced by tests)
1. No successful `draw`, `swap`, or indebted `withdraw` leaves `debtValue > limit`. Covered by the fuzz test and the invariant suite (`invariant_drawSwapWithdrawNeverBreachLimit`).
2. Soft liquidation strictly improves soft health. In the soft zone it always succeeds (fuzz `testFuzz_softLiquidation_improvesHealth`, invariant).
3. `pool.totalAssets() >= totalDeposited - totalWithdrawn - totalBadDebt` (`invariant_lenderAssetsCoverDepositsMinusBadDebt`).
4. Σ `scaledDebt[account]` == `totalScaled[0] + totalScaled[1]`.
5. Each account holds ≤ 15 assets.
6. Credit limit is monotone non-decreasing in collateral (`testFuzz_limitMonotoneInCollateral`).

## 4. Operational checklist
- Use a multisig for `TIMELOCK_PROPOSER` and `GUARDIAN` (both default to the deployer if unset).
- Run at least two keepers in different regions, plus an alert on `hardHealth < 1` (the keeper logs ALERT lines).
- Before each new year, schedule MarketClock holidays and early closes.
- Watch `totalBadDebt`, utilisation and per-asset concentration across all accounts.
- Get an external audit before meaningful TVL.
