# Slither report

Command (from `contracts/`):

```bash
slither . --filter-paths "lib/|test/|script/"
```

**Result: 0 High, 0 Medium.** What remains is Low/Informational only:
- `calls-loop`: loops are bounded at 15 assets;
- `timestamp`: time-based logic is intentional;
- `missing-zero-check` on admin setters;
- unindexed event addresses.

## Fixed in code

| Finding | Fix |
|---|---|
| `uninitialized-local` (7) | Locals are now initialised explicitly. |
| `unused-return` on `dex.swapExactIn` and router calls | The reported amount is now checked. The account, SoftLiquidator and DexAdapter all require `received >= max(minOut, reported)`. |
| `unused-return` on `pool.repay` in HardLiquidator | The actual repaid amount is used, and any unused USDG is refunded to the liquidator. |
| `unused-return` on Chainlink `latestRoundData` | Added an `answeredInRound >= roundId` check. |
| Stack-too-deep refactors | DexAdapter routing moved into `_route`, and liquidation sizing into `_size` / `_plan` / `_choose`. |

## Suppressed false positives (each has an inline justification)

| Detector | Where | Why it is not an issue |
|---|---|---|
| `weak-prng`, `divide-before-multiply`, `incorrect-equality`, `timestamp` | `MarketClock` calendar functions | `%` and integer division here are date arithmetic (days from civil date, weekday, DST), not randomness or precision loss. |
| `reentrancy-balance` | `CreditAccount.swap`, `DexAdapter.swapExactIn`, `SoftLiquidator._sell` | The balance read before the call is intentional: output is measured as a balance delta. Every function is `nonReentrant`, the router is the canonical Uniswap SwapRouter02, and the limit or health is re-checked afterwards. |
| `reentrancy-balance` | `SoftLiquidator.softLiquidate` | `healthBefore` is a deliberate pre-trade snapshot used to prove improvement; every callee is protocol-owned and non-reentrant. |
| `reentrancy-no-eth` | `CreditAccount.swap` (`_untrackIfEmpty` after the swap) | Untracking depends on the post-swap balance. The function is `nonReentrant`, the adapter is governance-set, and the limit is re-checked last. |
| `arbitrary-send-erc20` | `AutoRepay.execute` | `from` is the account owner, who opted into `pullFromOwner` and approved AutoRepay. The amount is capped by the plan and by the debt, and the funds can only repay that owner's own debt. |
| `incorrect-equality` | `== 0` / `== debt` guards in the pool, liquidators, account, fees and hooks | Exact comparisons of integer bookkeeping values; nothing depends on an attacker-manipulable balance being exactly equal. |
| `unused-return` | `OracleAdapter` (`startedAt`, sequencer feed) | Fields are unused on purpose, per Chainlink's documented semantics. |
| `divide-before-multiply` | `ProjectTokenHooks.notifyReward` | The rate is WAD-scaled, so truncation is under 1 wei per second of reward. |

## Windows note
Slither maps source lines from byte offsets. Non-ASCII characters and CRLF line endings shift those lines, so suppressions land on the wrong statement. Sources are therefore ASCII-only, and `.gitattributes` forces LF.
