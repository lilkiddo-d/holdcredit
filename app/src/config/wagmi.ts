import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  walletConnectWallet,
  coinbaseWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { mock } from "wagmi/connectors";
import type { Address } from "viem";
import { forkChain, robinhoodChain, rpcUrl, targetChain } from "./chains";

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

const walletGroups = [
  {
    groupName: "Wallets",
    wallets: projectId
      ? [injectedWallet, metaMaskWallet, rainbowWallet, coinbaseWallet, walletConnectWallet]
      : [injectedWallet],
  },
];

const rkConnectors = connectorsForWallets(walletGroups, {
  appName: "Holdcredit",
  projectId: projectId || "holdcredit-no-walletconnect",
});

// Local fork only: an account impersonated by `anvil --auto-impersonate` (no key involved anywhere).
const forkAccount = process.env.NEXT_PUBLIC_FORK_DEV_ACCOUNT as Address | undefined;
const forkWallet =
  process.env.NEXT_PUBLIC_ENABLE_FORK_WALLET === "true" && targetChain.id === 31337 && forkAccount
    ? [mock({ accounts: [forkAccount], features: { reconnect: true } })]
    : [];

export const wagmiConfig = createConfig({
  chains: [targetChain],
  connectors: [...rkConnectors, ...forkWallet],
  transports: { [robinhoodChain.id]: http(rpcUrl), [forkChain.id]: http(rpcUrl) },
  ssr: true,
});
