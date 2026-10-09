# DEPLOY — Robinhood Chain mainnet (chain ID 4663)

This repo never creates, stores or prints a private key or seed phrase. All signing goes through Foundry keystores.

## 0. Pre-flight checklist
- [ ] `forge test` passes and `cd app && pnpm build` succeeds.
- [ ] Decide the privileged addresses. Each one defaults to the deployer if unset, which is acceptable for a soft launch but not recommended:
  - `TIMELOCK_PROPOSER`: a multisig (Safe) that may *propose* Timelock operations; 48h delay.
  - `GUARDIAN`: a multisig that can pause and unpause, edit the market calendar, and manage the compliance allowlist.
  - `TREASURY`: receives protocol fees.
  - `KEEPER`: gets the soft-liquidation role. Use the `holdcredit-keeper` address.
- [ ] Optional: a private RPC such as Alchemy (`https://robinhood-mainnet.g.alchemy.com/v2/<KEY>`). The public RPC is rate-limited.

## 1. Import the keys (once, interactive — your keys never touch this repo)
```bash
cast wallet import holdcredit-deployer --interactive
```
```bash
cast wallet import holdcredit-keeper --interactive
```
Fund `holdcredit-deployer` with **0.005 ETH** on Robinhood Chain; the dry run estimated 0.0014 ETH. Fund `holdcredit-keeper` with about 0.01 ETH for gas. Check the deployer address with:
```bash
cast wallet address --account holdcredit-deployer
```

## 2. Rehearse (simulation only, no broadcast)
```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender $(cast wallet address --account holdcredit-deployer)
```
Expect `SIMULATION COMPLETE`. It writes `deployments/4663.dryrun.json` and nothing else.

## 3. Deploy + verify (the one command)
```bash
cd contracts && KEEPER=$(cast wallet address --account holdcredit-keeper) forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account holdcredit-deployer --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```
Prefix it with `GUARDIAN=0x... TIMELOCK_PROPOSER=0x... TREASURY=0x...` when using multisigs.

What it does, in one broadcast (about 70 transactions):
1. Deploys every contract and wires them together.
2. Configures 16 collateral assets (Chainlink feeds, risk tiers, Uniswap fee tiers) and the 2026–27 NYSE holidays.
3. Hands every admin role to the 48h Timelock; the deployer keeps nothing.
4. Verifies all contracts on Blockscout.
5. Writes `contracts/deployments/4663.json` **and** `app/src/config/deployments/4663.json`.

If verification hits a rate limit, re-run the same command with `--resume` in place of `--broadcast`.

## 4. Post-deploy checks
```bash
RPC=https://rpc.mainnet.chain.robinhood.com
addr() { python -c "import json,sys;print(json.load(open('contracts/deployments/4663.json'))[sys.argv[1]])" "$1"; }
cast call $(addr timelock) "getMinDelay()(uint256)" --rpc-url $RPC
cast call $(addr lenderPool) "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast wallet address --account holdcredit-deployer) --rpc-url $RPC
cast call $(addr oracleAdapter) "getPrice(address)(uint256)" 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC --rpc-url $RPC
```
Expected results: `172800`, then `false` (the deployer is no longer admin), then a non-zero NVDA price.

Then commit both `deployments/4663.json` files.

## 5. Seed liquidity
Lenders deposit USDG on the Lend page (or call `LenderPool.deposit`). Borrowing is impossible until the pool holds USDG.

## 6. Keeper (soft liquidation + auto-repay + reserve sweeps)
```bash
pnpm install && node scripts/export-abis.mjs
cd scripts && RPC_URL=https://rpc.mainnet.chain.robinhood.com DEPLOYMENT=../contracts/deployments/4663.json KEEPER_MODE=cast KEEPER_ACCOUNT=holdcredit-keeper KEEPER_PASSWORD_FILE=/secure/keeper.pass pnpm start
```
Signing goes through `cast send --account holdcredit-keeper`, and the keeper never loads a key. Run two instances in different regions. `ALERT` lines in the log mark hard-liquidatable accounts.

## 7. Frontend on Vercel
- Import the repo; set **Root Directory** to `app` and keep the framework as Next.js.
- Env vars: `NEXT_PUBLIC_CHAIN_ID=4663`, `NEXT_PUBLIC_RPC_URL=<rpc>`, `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<id>`, `NEXT_PUBLIC_PROJECT_TOKEN=` (empty), `GEOBLOCK_COUNTRIES=US,CA,GB,CH`.
- `app/src/config/deployments/4663.json` must be committed (step 4).

## 8. Later: attach the $HOLD token
See [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): `schedule` → wait 48h → `execute` `setProjectToken`.

## Ongoing ops
- Before 2028, add that year's NYSE holidays (`MarketClock.setHolidays`, GUARDIAN).
- Emergency: GUARDIAN calls `pause()` on the factory, pool or liquidators. Repayments and deposits stay open.

## Local fork rehearsal (optional)
Start a fork of mainnet:
```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --auto-impersonate --port 8746
```
Deploy to it from a fresh address funded via `anvil_setBalance` (not anvil's default accounts, which have mainnet nonces):
```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8746 --broadcast --slow --unlocked --sender <fresh-addr>
```
Then seed test balances:
```bash
bash scripts/fork-seed.sh http://127.0.0.1:8746 <your-test-addr> contracts/deployments/31337.json
```
