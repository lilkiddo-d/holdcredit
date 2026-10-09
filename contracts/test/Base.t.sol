// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SystemDeployer} from "../script/SystemDeployer.sol";
import {MockERC20, MockAggregator, MockDexAdapter} from "./mocks/Mocks.sol";
import {OracleAdapter} from "../src/periphery/OracleAdapter.sol";
import {MarketClock} from "../src/periphery/MarketClock.sol";
import {CreditAccount} from "../src/core/CreditAccount.sol";
import {IRiskEngine, IDexAdapter, IPriceOracle} from "../src/interfaces/IHoldcredit.sol";

/// @notice Full protocol with mock tokens/feeds/DEX. The test contract is the deployer; admin powers are
///         handed to the Timelock exactly like production, and tests use `asTimelock` to change params.
abstract contract BaseTest is Test, SystemDeployer {
    System internal s;
    Params internal p;

    MockERC20 internal usdg;
    MockERC20 internal aaa; // megacap, $100
    MockERC20 internal bbb; // ETF, $500
    MockERC20 internal ccc; // volatile, $250
    MockAggregator internal usdgFeed;
    MockAggregator internal aaaFeed;
    MockAggregator internal bbbFeed;
    MockAggregator internal cccFeed;
    MockDexAdapter internal dex;

    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant LENDER_DEPOSIT = 1_000_000e6;

    function setUp() public virtual {
        vm.warp(1_790_000_000); // 2026-09-21 (a Monday), arbitrary realistic time
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aaa = new MockERC20("AAA Stock", "AAA", 18);
        bbb = new MockERC20("BBB ETF", "BBB", 18);
        ccc = new MockERC20("CCC Stock", "CCC", 18);
        usdgFeed = new MockAggregator(8, 1e8);
        aaaFeed = new MockAggregator(8, 100e8);
        bbbFeed = new MockAggregator(8, 500e8);
        cccFeed = new MockAggregator(8, 250e8);

        p = Params({
            deployer: address(this),
            stable: address(usdg),
            stableDecimals: 6,
            guardian: guardian,
            proposer: address(this),
            treasury: treasury,
            keeper: keeper,
            closedDrawCap: 500e6,
            dustDebt: 100e6,
            timelockDelay: 48 hours,
            irmBase: 0.03e18,
            irmSlope1: 0.09e18,
            irmSlope2: 0.8e18,
            irmKink: 0.85e18
        });
        s = _deployBase(p);
        dex = new MockDexAdapter(IPriceOracle(address(s.oracle)));
        _wire(s, p, IDexAdapter(address(dex)));

        _feed(address(usdg), address(usdgFeed), 6, false);
        _feed(address(aaa), address(aaaFeed), 18, true);
        _feed(address(bbb), address(bbbFeed), 18, true);
        _feed(address(ccc), address(cccFeed), 18, true);
        _asset(address(aaa), 6000, 6800, 7500, 80);
        _asset(address(bbb), 7000, 7700, 8300, 90);
        _asset(address(ccc), 5000, 5800, 6600, 60);
        s.clock.setMode(MarketClock.Mode.ForceOpen);

        _handOver(s, p);

        // Liquidity
        usdg.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdg.approve(address(s.pool), type(uint256).max);
        s.pool.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        vm.label(address(s.pool), "LenderPool");
        vm.label(address(s.factory), "Factory");
        vm.label(address(s.riskEngine), "RiskEngine");
    }

    // ------------------------------------------------------------------ helpers

    function _feed(address asset, address feed, uint8 dec, bool pauseCheck) internal {
        s.oracle.setFeed(
            asset,
            OracleAdapter.FeedConfig({
                primary: feed,
                secondary: address(0),
                maxStalenessOpen: 90_000,
                maxStalenessClosed: 345_600,
                maxDeviationBps: 0,
                tokenDecimals: dec,
                checkTokenPause: pauseCheck
            })
        );
    }

    function _asset(address a, uint16 ltv, uint16 soft, uint16 hard, uint16 score) internal {
        s.riskEngine.setAssetConfig(
            a,
            IRiskEngine.AssetConfig({
                enabled: true,
                frozen: false,
                ltvBps: ltv,
                softBps: soft,
                hardBps: hard,
                liquidityScore: score
            })
        );
    }

    /// @dev Execute an admin call as the Timelock (bypassing the delay, which is tested separately).
    modifier asTimelock() {
        vm.startPrank(address(s.timelock));
        _;
        vm.stopPrank();
    }

    function _open(address user) internal returns (CreditAccount acct) {
        vm.prank(user);
        acct = CreditAccount(s.factory.createAccount());
    }

    function _pledge(address user, CreditAccount acct, MockERC20 token, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(acct), amount);
        acct.deposit(address(token), amount);
        vm.stopPrank();
    }

    function _draw(address user, CreditAccount acct, uint256 amount) internal {
        vm.prank(user);
        acct.draw(amount, user);
    }

    function _state(CreditAccount acct) internal view returns (IRiskEngine.AccountState memory) {
        return s.riskEngine.accountState(address(acct));
    }

    function _setPrice(MockAggregator f, int256 price8) internal {
        f.set(price8);
    }

    /// @dev Refresh all feeds' timestamps (after warps) keeping prices.
    function _touchFeeds() internal {
        usdgFeed.set(usdgFeed.answer());
        aaaFeed.set(aaaFeed.answer());
        bbbFeed.set(bbbFeed.answer());
        cccFeed.set(cccFeed.answer());
    }

    function _setClosed() internal {
        vm.prank(guardian);
        s.clock.setMode(MarketClock.Mode.ForceClosed);
    }

    function _setOpen() internal {
        vm.prank(address(s.timelock));
        s.clock.setMode(MarketClock.Mode.ForceOpen);
    }
}
