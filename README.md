# Holdcredit

Portfolio-margin credit lines on Robinhood Chain. Users pledge a whole portfolio of tokenized stocks to a personal **CreditAccount** and draw a revolving **USDG** credit line against it, without selling. Lenders supply USDG to an ERC-4626 **LenderPool** and earn the borrow interest.

## How it works
- **Credit limit:** sum of oracle value × per-asset LTV. The part of any position above 40% of the portfolio loses 50% of its weight, so diversified pledges get higher limits.
- **Draw and repay** at any time. Interest accrues every second on a kinked, utilization-based curve.
- **Soft liquidation:** when debt crosses the soft threshold, keepers sell small slices of the most overweight (else most liquid) stock to repay debt. A slice is at most 10% of the portfolio and fills at most 1.5% below oracle. Health must strictly improve or the transaction reverts.
- **Hard liquidation:** permissionless, below a lower threshold. Liquidators get an 8% bonus; residual debt is covered by reserves first, then lenders.
- **Market closed** (MarketClock, US regular session with DST and holidays computed on-chain): limits shrink to 80%, draws are capped at 500 USDG per day, and swaps, indebted withdrawals and soft liquidations pause. Repayments and deposits always work.
- **In-account trading:** swap stock A for stock B through governance-chosen Uniswap v3 pools. Execution must be within 3% of oracle value, and the post-trade limit is re-checked.
- **Auto-repay:** a monthly plan, funded by USDG that arrives in the account and optionally the owner's wallet, executed by keepers.
- **Governance:** every admin role sits behind a 48h Timelock; a guardian can pause. An optional ComplianceRegistry allowlist is off by default.
- **$HOLD:** this repo deploys **no token**. See [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

## Repo layout
| Path | Contents |
|---|---|
| `contracts/` | Foundry project (Solidity 0.8.28, OpenZeppelin 5.7). `src/`, `test/` (unit, fuzz, invariant, fork), `script/Deploy.s.sol`, `config/deploy.4663.json` |
| `app/` | Next.js 15 + wagmi/viem + RainbowKit frontend |
| `scripts/` | Keeper (soft liquidation + auto-repay), ABI export, fork seeding |
| `config/chains.ts` | Every external address, with source links |
| `docs/` | Slither report |

## Contracts
`CreditAccountFactory`, `CreditAccount` (EIP-1167 clone), `RiskEngine`, `LenderPool` (ERC-4626), `InterestRateModel`, `SoftLiquidator`, `HardLiquidator`, `AutoRepay`, `DexAdapter` (Uniswap v3), `MarketClock`, `OracleAdapter` (Chainlink, swappable), `FeeCollector`, `ProjectTokenHooks`, `ComplianceRegistry`, `HoldcreditTimelock`.

## Quick start
```bash
pnpm install
cd contracts && forge build && forge test                  # unit + fuzz + invariant + fork tests
SKIP_FORK=true forge test                                    # offline
FOUNDRY_INVARIANT_RUNS=16 forge coverage --no-match-path "test/fork/*" --report summary
cd .. && node scripts/export-abis.mjs                        # refresh frontend/keeper ABIs
pnpm app:build
```

## Status
- 115 unit/fuzz/invariant tests and 6 Robinhood Chain mainnet fork tests pass. Core contracts have 98.5–100% line coverage.
- Slither reports 0 High and 0 Medium findings ([docs/SLITHER.md](docs/SLITHER.md)).
- The full deploy succeeded on a local mainnet fork, and the mainnet dry run (no broadcast) simulated cleanly.
- **Not audited.** Get an external audit before meaningful TVL.

## Docs
[DEPLOY.md](DEPLOY.md) · [DECISIONS.md](DECISIONS.md) · [THREAT_MODEL.md](THREAT_MODEL.md) · [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md)

Holdcredit is independent and not affiliated with any stock-token issuer, exchange or broker.
