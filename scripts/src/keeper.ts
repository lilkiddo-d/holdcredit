/**
 * Holdcredit keeper: soft liquidations + monthly auto-repay (+ optional reserve collection).
 *
 * Signing: this process never sees a private key.
 *   KEEPER_MODE=cast      -> transactions are signed by `cast send --account holdcredit-keeper` (Foundry keystore).
 *                            Put the keystore password in a file readable only by the keeper user and point
 *                            KEEPER_PASSWORD_FILE at it (or omit it and type the password at each prompt).
 *   KEEPER_MODE=unlocked  -> local anvil fork started with --auto-impersonate; KEEPER_ADDRESS is impersonated.
 *
 * Env: RPC_URL, DEPLOYMENT (path to contracts/deployments/<chainId>.json), KEEPER_MODE, KEEPER_ACCOUNT,
 *      KEEPER_PASSWORD_FILE, KEEPER_ADDRESS, INTERVAL_MS (60000), COLLECT_RESERVES (true|false), --once
 */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import {
  autoRepayAbi,
  creditAccountFactoryAbi,
  feeCollectorAbi,
  lenderPoolAbi,
  marketClockAbi,
  riskEngineAbi,
  softLiquidatorAbi,
} from "./abi.js";

const WAD = 10n ** 18n;
const env = (k: string, d?: string) => process.env[k] ?? d;
const once = process.argv.includes("--once");

const rpcUrl = env("RPC_URL", "http://127.0.0.1:8545")!;
const deploymentPath = resolve(env("DEPLOYMENT", "../contracts/deployments/31337.json")!);
const dep = JSON.parse(readFileSync(deploymentPath, "utf8")) as Record<string, string>;
const mode = env("KEEPER_MODE", "cast") as "cast" | "unlocked";
const keeperAccount = env("KEEPER_ACCOUNT", "holdcredit-keeper")!;
const passwordFile = env("KEEPER_PASSWORD_FILE");
const intervalMs = Number(env("INTERVAL_MS", "60000"));
const collectReserves = env("COLLECT_RESERVES", "true") === "true";

const client = createPublicClient({ transport: http(rpcUrl) });

function log(...a: unknown[]) {
  console.log(new Date().toISOString(), ...a);
}

function castArgs(): string[] {
  const a = ["--rpc-url", rpcUrl, "--account", keeperAccount];
  if (passwordFile) a.push("--password-file", passwordFile);
  return a;
}

function resolveKeeperAddress(): Address {
  if (mode === "unlocked") {
    const a = env("KEEPER_ADDRESS");
    if (!a) throw new Error("KEEPER_ADDRESS is required in unlocked mode");
    return a as Address;
  }
  const args = ["wallet", "address", "--account", keeperAccount];
  if (passwordFile) args.push("--password-file", passwordFile);
  return execFileSync("cast", args, { encoding: "utf8" }).trim() as Address;
}

const keeper = resolveKeeperAddress();
const wallet = mode === "unlocked" ? createWalletClient({ account: keeper, transport: http(rpcUrl) }) : undefined;

/** Simulate first (no gas burned on reverts), then send via the configured signer. */
async function send(to: Address, abi: Abi, functionName: string, args: readonly unknown[], label: string) {
  try {
    await client.simulateContract({ address: to, abi, functionName, args, account: keeper } as never);
  } catch (e) {
    log(`skip ${label}: simulation reverted (${(e as Error).message.split("\n")[0]})`);
    return false;
  }
  const data = encodeFunctionData({ abi, functionName, args } as never) as Hex;
  if (mode === "unlocked") {
    const hash = await wallet!.sendTransaction({ to, data, chain: null });
    const r = await client.waitForTransactionReceipt({ hash });
    log(`${label}: ${r.status} ${hash}`);
    return r.status === "success";
  }
  const out = execFileSync("cast", ["send", to, data, ...castArgs(), "--json"], { encoding: "utf8" });
  const r = JSON.parse(out) as { status: string; transactionHash: string };
  log(`${label}: ${r.status} ${r.transactionHash}`);
  return r.status === "0x1" || r.status === "1";
}

async function allAccounts(): Promise<Address[]> {
  const n = (await client.readContract({
    address: dep.creditAccountFactory as Address,
    abi: creditAccountFactoryAbi,
    functionName: "accountsLength",
  })) as bigint;
  const out: Address[] = [];
  for (let off = 0n; off < n; off += 200n) {
    const page = (await client.readContract({
      address: dep.creditAccountFactory as Address,
      abi: creditAccountFactoryAbi,
      functionName: "getAccounts",
      args: [off, 200n],
    })) as Address[];
    out.push(...page);
  }
  return out;
}

type State = { softHealth: bigint; hardHealth: bigint; debt: bigint; marketOpen: boolean };

async function cycle(n: number) {
  const accounts = await allAccounts();
  const open = (await client.readContract({ address: dep.marketClock as Address, abi: marketClockAbi, functionName: "isOpen" })) as boolean;
  const states = await client.multicall({
    contracts: accounts.map((a) => ({ address: dep.riskEngine as Address, abi: riskEngineAbi, functionName: "accountState", args: [a] }) as const),
    allowFailure: true,
  });
  const due = await client.multicall({
    contracts: accounts.map((a) => ({ address: dep.autoRepay as Address, abi: autoRepayAbi, functionName: "isDue", args: [a] }) as const),
    allowFailure: true,
  });
  let soft = 0, hard = 0, repaid = 0;
  for (let i = 0; i < accounts.length; i++) {
    const acct = accounts[i];
    const s = states[i];
    if (s.status === "success") {
      const st = s.result as unknown as State;
      if (st.hardHealth < WAD) {
        hard++;
        log(`ALERT ${acct} hard-liquidatable (hardHealth ${Number(st.hardHealth) / 1e18}) - open to any liquidator`);
      }
      if (open && st.softHealth < WAD) {
        const ok = await send(
          dep.softLiquidator as Address,
          softLiquidatorAbi as Abi,
          "softLiquidate",
          [acct, BigInt(Math.floor(Date.now() / 1000) + 300)],
          `softLiquidate ${acct}`,
        );
        if (ok) soft++;
      }
    } else {
      log(`warn ${acct}: accountState reverted (stale oracle?)`);
    }
    if (due[i].status === "success" && due[i].result === true) {
      const ok = await send(dep.autoRepay as Address, autoRepayAbi as Abi, "execute", [acct], `autoRepay ${acct}`);
      if (ok) repaid++;
    }
  }
  if (collectReserves && n % 60 === 0) {
    await send(dep.lenderPool as Address, lenderPoolAbi as Abi, "collectReserves", [], "collectReserves");
    await send(dep.feeCollector as Address, feeCollectorAbi as Abi, "distribute", [], "distribute");
  }
  log(`cycle ${n}: ${accounts.length} accounts, market ${open ? "open" : "closed"}, soft=${soft}, autoRepay=${repaid}, hardAlerts=${hard}`);
}

async function main() {
  log(`keeper ${keeper} mode=${mode} rpc=${rpcUrl} deployment=${deploymentPath}`);
  for (let n = 0; ; n++) {
    try {
      await cycle(n);
    } catch (e) {
      log("cycle error:", (e as Error).message);
    }
    if (once) break;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

main();
