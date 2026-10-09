export const metadata = { title: "Risk disclosure - Holdcredit" };

export default function RiskPage() {
  return (
    <div className="prose">
      <h1>Risk disclosure</h1>
      <p className="sub">Read this before pledging collateral, drawing credit or lending. If any part is unclear, do not use Holdcredit.</p>

      <h2>What Holdcredit is</h2>
      <p>
        Holdcredit is non-custodial, experimental smart-contract software. You pledge tokenized-stock ERC-20s to your own
        credit account and borrow the USDG stablecoin from a pool funded by lenders. Nothing here is investment, tax or
        legal advice, and no one guarantees outcomes.
      </p>

      <h2>Liquidation risk (borrowers)</h2>
      <ul>
        <li>Your credit limit is computed from oracle prices with haircuts. Prices move; your limit moves with them.</li>
        <li>
          <strong>Soft liquidation:</strong> when debt passes the soft threshold, keepers sell small slices (max 10% of
          the portfolio per step, at most 1.5% below oracle) of your most overweight or most liquid stock to repay debt.
          You pay a 0.5% keeper fee on each slice. This is automatic and does not require your consent.
        </li>
        <li>
          <strong>Hard liquidation:</strong> below the hard threshold anyone may repay up to 50% (100% if deeply underwater)
          of your debt and take collateral at an 8% discount to the oracle price. You can lose most or all of your pledged
          collateral.
        </li>
        <li>
          <strong>Gap risk:</strong> stock prices can jump when markets reopen, after news or corporate actions. A
          weekend or overnight gap can move you straight from healthy to hard liquidation.
        </li>
        <li>
          <strong>Correlated crashes:</strong> diversification only helps if your stocks do not fall together. In a broad
          market sell-off, all positions can fall at once.
        </li>
        <li>
          <strong>Concentration:</strong> any single stock above 40% of your pledge gets an extra haircut. Rebalancing
          inside the account changes your limit immediately.
        </li>
      </ul>

      <h2>Market hours</h2>
      <p>
        Outside the US regular session (weekends, holidays, nights) limits shrink, draws are capped per day, and in-account
        swaps, withdrawals with debt and soft liquidations are paused. Hard liquidations can still occur at any time if
        prices are valid. The on-chain calendar is maintained by an operations multisig and could be wrong.
      </p>

      <h2>Interest rates</h2>
      <p>
        Interest accrues every second at a variable rate that rises steeply when the pool is highly utilized. Your debt
        grows even if prices do not move. Auto-repay only runs if a keeper executes it and funds are available.
      </p>

      <h2>Lender risk</h2>
      <ul>
        <li>If liquidations cannot cover a borrower&apos;s debt, the loss is covered by protocol reserves first and then shared by all lenders.</li>
        <li>Withdrawals are limited to idle liquidity. At high utilization you may have to wait for repayments.</li>
      </ul>

      <h2>Asset and third-party risk</h2>
      <ul>
        <li>
          Stock tokens are issued by a third party, give price exposure only, and carry no shareholder or voting rights.
          The issuer can pause oracles during corporate actions, change token behaviour, or restrict transfers.
        </li>
        <li>Stock tokens are not available to US persons and are restricted in other jurisdictions. You are responsible for complying with the laws that apply to you.</li>
        <li>Prices come from Chainlink feeds. Stale, paused or wrong prices can block actions or cause unfair liquidations.</li>
        <li>Swaps use third-party Uniswap v3 pools whose liquidity can be thin or manipulated.</li>
        <li>USDG is a third-party stablecoin and could lose its peg.</li>
      </ul>

      <h2>Smart-contract and governance risk</h2>
      <ul>
        <li>The contracts may contain bugs. They have been tested and statically analysed but not audited by a third party at launch.</li>
        <li>Parameters (haircuts, thresholds, rates, oracles) can be changed by governance through a 48-hour Timelock.</li>
        <li>A guardian multisig can pause borrowing, swaps, lending and liquidations instantly. Repayments and new pledges are never paused.</li>
        <li>An optional compliance allowlist can be switched on by governance, which may stop new draws for non-listed addresses.</li>
      </ul>

      <h2>No affiliation</h2>
      <p>Holdcredit is an independent protocol and is not affiliated with, endorsed by, or operated by any stock token issuer, exchange or broker.</p>
    </div>
  );
}
