import { defineChain } from "viem";

/** Robinhood Chain mainnet. Source: https://docs.robinhood.com/chain/connecting */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

/** Local anvil fork of Robinhood Chain mainnet (pnpm fork:anvil). */
export const forkChain = defineChain({
  id: 31337,
  name: "Local fork (4663)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export const targetChainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? "4663");
export const targetChain = targetChainId === 31337 ? forkChain : robinhoodChain;
export const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || targetChain.rpcUrls.default.http[0];
