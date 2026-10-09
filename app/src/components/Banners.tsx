"use client";

import { isDeployed } from "@/config/deployments";
import { targetChain } from "@/config/chains";

export function DeployBanner() {
  if (isDeployed) return null;
  return (
    <p className="banner bad">
      No Holdcredit deployment found for chain {targetChain.id}. Run the deploy script (see DEPLOY.md) so it writes
      src/config/deployments/{targetChain.id}.json, then rebuild.
    </p>
  );
}

export function MarketBanner({ open }: { open?: boolean }) {
  if (open === undefined || open) return null;
  return (
    <p className="banner warn">
      The US equity market is closed. Credit limits are reduced and draws are capped per day; repayments and new pledges
      work as normal. Swaps, withdrawals with debt and soft liquidations resume at the open.
    </p>
  );
}
