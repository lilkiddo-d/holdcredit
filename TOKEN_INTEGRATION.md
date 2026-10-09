# TOKEN_INTEGRATION ($HOLD)

**Holdcredit does not create, write or deploy any ERC-20.** The project token ($HOLD) launches separately on a launchpad. Contracts only *accept* its address later, through governance. Until then every token feature is inert and the protocol works fully without it. The only ERC-20 in this repo is `MockERC20`, under `contracts/test/mocks`, and it is used only by tests.

## Where the token plugs in

| Contract | What changes once the token is set |
|---|---|
| `ProjectTokenHooks` | `setProjectToken(address)` — **one-shot, `DEFAULT_ADMIN_ROLE` (= the 48h Timelock)**. It rejects the zero address, the stablecoin and non-contracts, and reverts with `TokenAlreadySet` on any second call. It also sets the discount threshold to 1,000 tokens, scaled to the token's `decimals()`. |
| `ProjectTokenHooks` (staking) | `stake`, `requestUnstake` (7-day cooldown), `withdrawUnstaked`, `claimRewards`. All of them revert `TokenNotSet` before activation. |
| `LenderPool` | Accounts whose owner has staked at least `minStakeForDiscount` borrow on the **staker tier**, a separate borrow index whose rate is `stakerDiscountBps` (default 20%) lower. The tier re-syncs automatically on stake and unstake. While the token is unset, `isActive() == false` and everyone stays on the standard tier. |
| `FeeCollector` | `distribute()` streams `stakerShareBps` (default 50%) of the protocol's interest spread to stakers, in USDG, over 7 days. With no token or no stakers, 100% goes to the treasury. |
| Frontend | `NEXT_PUBLIC_PROJECT_TOKEN` empty → the Stake page and the staker APR are hidden. Set → they appear; the page also checks on-chain that the hooks contract holds the same token. |

Everything else (credit lines, lending, liquidations, auto-repay) ignores the token entirely.

## Activating the token later (exact commands)

Prerequisites: the token address `HOLD`, and a proposer key for the Timelock (`TIMELOCK_PROPOSER`, which defaults to `holdcredit-deployer`).

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
addr() { python -c "import json,sys;print(json.load(open('contracts/deployments/4663.json'))[sys.argv[1]])" "$1"; }
export TIMELOCK=$(addr timelock)
export HOOKS=$(addr projectTokenHooks)
export HOLD=0xYourLaunchedTokenAddress
export DATA=$(cast calldata "setProjectToken(address)" $HOLD)
export SALT=$(cast keccak "setProjectToken-v1")

# 1) schedule (starts the 48h delay)
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT 172800 \
  --rpc-url $RPC --account holdcredit-deployer

# 2) after 48 hours, anyone can execute
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT \
  --rpc-url $RPC --account holdcredit-deployer

# 3) verify
cast call $HOOKS "projectToken()(address)" --rpc-url $RPC
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=$HOLD` in Vercel and redeploy the app.

## Optional follow-ups (each one is also a Timelock operation)
- `ProjectTokenHooks.setDiscountThreshold(uint256)`: change the minimum stake for the discount tier.
- `LenderPool.setStakerDiscount(uint16)`: rate discount for the staker tier, max 50%.
- `FeeCollector.setStakerShare(uint16)`: share of the spread paid to stakers.
- `ProjectTokenHooks.setRewardsDuration(uint256)`: reward streaming window, 1–90 days.

## Design notes
- **JIT protection.** Rewards stream over 7 days, and stake that is cooling down neither earns nor qualifies for the discount. Flash-staking right before `distribute()` therefore captures almost nothing.
- **Fee-on-transfer safe.** Staking credits the balance delta that actually arrived (tested).
- **No mint, burn or transfer hooks.** Holdcredit never needs mint rights or any special token behaviour; any standard ERC-20 works.
