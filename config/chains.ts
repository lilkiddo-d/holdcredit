/**
 * Robinhood Chain network + third-party contract addresses used by Holdcredit.
 *
 * Every address below was taken from an official source (links inline) and
 * cross-checked on-chain on 2026-10-08 (symbol(), decimals(), description(),
 * latestRoundData(), UniswapV3Factory.getPool()). Never add an address here
 * without a source link.
 *
 * Sources
 *  - Network:        https://docs.robinhood.com/chain/connecting
 *                    https://docs.robinhood.com/chain/deploy-smart-contracts
 *  - WETH / USDG:    https://docs.robinhood.com/chain/contracts
 *  - Stock tokens:   https://docs.robinhood.com/chain/contracts  (table is generated from
 *                    the official asset registry: GET https://api.robinhood.com/rhj/assets,
 *                    `deployments[].contractAddress` where chainId == 4663)
 *  - Price feeds:    https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *                    (machine-readable: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json,
 *                    field `proxyAddress`)
 *  - Uniswap v3:     https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *  - Permit2/L2 misc https://docs.robinhood.com/chain/protocol-contracts
 *
 * Known gaps (see docs/ORACLES.md and DECISIONS.md):
 *  - No Chainlink L2 sequencer-uptime feed is published for Robinhood Chain yet.
 *    OracleAdapter supports one (address(0) = disabled); set it via the Timelock once published.
 *  - No on-chain US market calendar exists; Holdcredit ships its own MarketClock.
 */

export type Address = `0x${string}`;

export interface StockAsset {
  symbol: string;
  name: string;
  token: Address; // ERC-20, 18 decimals, ERC-8056 uiMultiplier
  feed: Address; // Chainlink AggregatorV3 proxy, 8 decimals, 24h heartbeat, 0.5% deviation, 24/5 hours
  uniV3Fee: 500 | 3000 | 10000; // deepest stock/USDG Uniswap v3 pool on 2026-10-08
  uniV3Pool: Address;
  tier: "etf" | "megacap" | "volatile" | "highvol";
}

export const robinhoodChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    // Public endpoint is rate-limited; use Alchemy/QuickNode/Chainstack in production.
    public: "https://rpc.mainnet.chain.robinhood.com",
    alchemyTemplate: "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    // forge verify-contract --verifier blockscout --verifier-url <apiUrl>
    apiUrl: "https://robinhoodchain.blockscout.com/api/",
  },
  testnet: {
    id: 46630,
    rpc: "https://rpc.testnet.chain.robinhood.com",
    explorer: "https://explorer.testnet.chain.robinhood.com",
  },
} as const;

export const coreTokens = {
  WETH: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" as Address,
  // Global Dollar (USDG), 6 decimals — Holdcredit's borrow / lend asset.
  USDG: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address,
} as const;

export const chainlinkFeeds = {
  USDG_USD: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" as Address,
  USDC_USD: "0x9e6f4605992a899eE2999999F3Ec80C41F452546" as Address,
  ETH_USD: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as Address,
  // L2 sequencer uptime feed: NOT PUBLISHED for Robinhood Chain as of 2026-10-08.
  SEQUENCER_UPTIME: null,
} as const;

export const uniswapV3 = {
  factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa" as Address,
  swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2" as Address,
  quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7" as Address,
  universalRouter: "0x8876789976decbfcbbbe364623c63652db8c0904" as Address,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
} as const;

/** Launch collateral set: tokens with an official feed AND >= ~$100k USDG depth on Uniswap v3. */
export const stockAssets: StockAsset[] = [
  { symbol: "SPY", name: "SPDR S&P 500 ETF Trust", token: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A", uniV3Fee: 500, uniV3Pool: "0xa7bb1ac63bbab0c44316e6c8c455213441689167", tier: "etf" },
  { symbol: "QQQ", name: "Invesco QQQ", token: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae", uniV3Fee: 500, uniV3Pool: "0xd60a5d14db690b7afad71f76b108071d7175597d", tier: "etf" },
  { symbol: "NVDA", name: "NVIDIA", token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", uniV3Fee: 500, uniV3Pool: "0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3", tier: "megacap" },
  { symbol: "GOOGL", name: "Alphabet Class A", token: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b", uniV3Fee: 500, uniV3Pool: "0x34d0dc122cf9a8eb296fc5e0d3a233625d7d19b7", tier: "megacap" },
  { symbol: "MSFT", name: "Microsoft", token: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", uniV3Fee: 3000, uniV3Pool: "0xeb60bcd1d920ad6e102690ccfc6fb488899e1510", tier: "megacap" },
  { symbol: "AAPL", name: "Apple", token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", uniV3Fee: 500, uniV3Pool: "0xaae0d815ee56e4092a5e5c2911e676fea50b2d6d", tier: "megacap" },
  { symbol: "AMZN", name: "Amazon", token: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C", uniV3Fee: 3000, uniV3Pool: "0x8ac92da74ab5f3b1d024dc1943ad7e15dc4179ef", tier: "megacap" },
  { symbol: "META", name: "Meta Platforms", token: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1", uniV3Fee: 3000, uniV3Pool: "0x107a7cb40d8665360ba10e59471af06150a50922", tier: "megacap" },
  { symbol: "TSLA", name: "Tesla", token: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", feed: "0x4A1166a659A55625345e9515b32adECea5547C38", uniV3Fee: 3000, uniV3Pool: "0xf4acdaeeb7022862a763c9b1b885e11191c889e3", tier: "volatile" },
  { symbol: "MU", name: "Micron Technology", token: "0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD", feed: "0x425EEFdCf05ed6526C3cE61Af99429A228a6d596", uniV3Fee: 3000, uniV3Pool: "0xd057b1bc54917855bbee58ead58647f47cab35e5", tier: "volatile" },
  { symbol: "PLTR", name: "Palantir Technologies", token: "0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A", feed: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c", uniV3Fee: 3000, uniV3Pool: "0x851680416a4f4e1c463d45171d61acddbc8554c0", tier: "volatile" },
  { symbol: "USO", name: "United States Oil Fund", token: "0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344", feed: "0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c", uniV3Fee: 3000, uniV3Pool: "0x02175608f1b5e6b5ed221ccfdc7be197d111d915", tier: "volatile" },
  { symbol: "CRCL", name: "Circle Internet Group", token: "0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5", feed: "0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a", uniV3Fee: 3000, uniV3Pool: "0x654e4143e82a5824445ade0824351c2a9acd95a8", tier: "highvol" },
  { symbol: "SPCX", name: "Space Exploration Technologies Class A", token: "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa", feed: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb", uniV3Fee: 500, uniV3Pool: "0xc61284332117c3fb23a2a56cceffd07f7af60029", tier: "highvol" },
  { symbol: "GME", name: "GameStop", token: "0x1b0E319c6A659F002271B69dB8A7df2F911c153E", feed: "0x27C71df6A64fB476468EdF256CF72c038baB5B67", uniV3Fee: 10000, uniV3Pool: "0xe9713f453adb9245b19559790c96f470a18f2fdf", tier: "highvol" },
  { symbol: "MSTR", name: "Strategy Inc.", token: "0xec262a75e413fAfD0dF80480274532C79D42da09", feed: "0x396118bdFB181e6240E74D243F266B061c0edc3D", uniV3Fee: 10000, uniV3Pool: "0x17578c0e0d15da44f31677263114f71ae76653ea", tier: "highvol" },
];

/** Risk tiers (basis points). ltv < soft < hard. See RiskEngine.sol and docs/RISK.md. */
export const riskTiers = {
  etf: { ltvBps: 7000, softBps: 7700, hardBps: 8300, liquidityScore: 90 },
  megacap: { ltvBps: 6000, softBps: 6800, hardBps: 7500, liquidityScore: 80 },
  volatile: { ltvBps: 5000, softBps: 5800, hardBps: 6600, liquidityScore: 60 },
  highvol: { ltvBps: 3500, softBps: 4300, hardBps: 5000, liquidityScore: 40 },
} as const;
