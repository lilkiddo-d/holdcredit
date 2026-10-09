"use client";

import { useAccount } from "wagmi";
import { creditAccountFactoryAbi } from "@/abi/generated";
import { PledgeBuilder } from "@/components/PledgeBuilder";
import { AccountPanel } from "@/components/AccountPanel";
import { AutoRepayCard } from "@/components/AutoRepayCard";
import { DeployBanner, MarketBanner } from "@/components/Banners";
import { addresses, useCreditAccount, useMarketOpen } from "@/lib/protocol";
import { useTxRunner } from "@/lib/tx";
import { isDeployed } from "@/config/deployments";

export default function BorrowPage() {
  const { isConnected } = useAccount();
  const { account } = useCreditAccount();
  const open = useMarketOpen().data as boolean | undefined;
  const tx = useTxRunner();

  const createAccount = () =>
    tx.run([{ label: "Open credit account", args: { address: addresses.creditAccountFactory, abi: creditAccountFactoryAbi, functionName: "createAccount" } }] as never);

  return (
    <>
      <h1>Borrow against your whole portfolio</h1>
      <p className="sub">Pledge stock tokens, draw a revolving USDG credit line, keep your exposure. No selling.</p>
      <DeployBanner />
      {isDeployed && <MarketBanner open={open} />}
      {isDeployed && isConnected && !account && (
        <div className="card" style={{ marginBottom: 16 }}>
          <h2>Step 1 - open your credit account</h2>
          <p className="muted">A personal smart account (minimal proxy) that holds your pledged stocks. One per wallet.</p>
          <button onClick={createAccount} disabled={tx.busy}>
            Open credit account
          </button>
          <p className="status">{tx.status}</p>
        </div>
      )}
      {!isConnected && <p className="banner">Connect a wallet to see your balances and credit line.</p>}
      {isDeployed && (
        <div className="grid">
          <div className="col-7">
            <PledgeBuilder account={account} marketOpen={open} />
          </div>
          <div className="col-5">
            {account ? <AccountPanel account={account} /> : <div className="card muted">Your credit line appears here once your account is open.</div>}
            {account && (
              <div style={{ marginTop: 16 }}>
                <AutoRepayCard account={account} />
              </div>
            )}
          </div>
        </div>
      )}
    </>
  );
}
