// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {MarketClock} from "../../src/periphery/MarketClock.sol";
import {SoftLiquidator} from "../../src/liquidation/SoftLiquidator.sol";
import {IRiskEngine} from "../../src/interfaces/IHoldcredit.sol";
import {IAggregatorV3} from "../../src/interfaces/IExternal.sol";
import {OracleAdapter as OracleAdapterLike} from "../../src/periphery/OracleAdapter.sol";

/// @notice Runs the real deploy script against a Robinhood Chain mainnet fork and exercises the protocol
///         with the real USDG, real stock tokens, real Chainlink feeds and real Uniswap v3 pools.
///         RPC: $RH_RPC_URL (defaults to the public endpoint). Set SKIP_FORK=true to skip.
contract RobinhoodForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    // Uniswap v3 pools used as token sources (verified via UniswapV3Factory.getPool on 2026-10-08).
    address constant NVDA_USDG_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant SPY_USDG_POOL = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167;
    address constant TSLA_USDG_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3;
    address constant CRCL_USDG_POOL = 0x654E4143e82a5824445Ade0824351C2A9ACD95a8; // deepest USDG source

    SystemDeployer.System internal s;
    bool internal skipFork;
    address internal alice = makeAddr("fork-alice");
    address internal lender = makeAddr("fork-lender");

    function setUp() public {
        if (vm.envOr("SKIP_FORK", false)) {
            skipFork = true;
            return;
        }
        vm.createSelectFork(vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        assertEq(block.chainid, 4663);
        Deploy d = new Deploy();
        s = d.run(); // deployer/keeper/guardian/proposer = this test contract (msg.sender)
        // Make the session deterministic regardless of the real wall clock.
        vm.prank(address(s.timelock));
        s.clock.setMode(MarketClock.Mode.ForceOpen);
        _freshenFeeds();

        _take(USDG, CRCL_USDG_POOL, lender, 200_000e6);
        vm.startPrank(lender);
        IERC20(USDG).approve(address(s.pool), type(uint256).max);
        s.pool.deposit(200_000e6, lender);
        vm.stopPrank();
    }

    /// @dev 24/5 equity feeds go quiet on weekends. When the fork is taken then, the open-market staleness
    ///      window is widened (via the Timelock) for the assets these tests trade, so results do not depend
    ///      on the day the suite runs. On weekdays the production configuration is used unchanged.
    function _freshenFeeds() internal {
        address[4] memory used = [NVDA, SPY, TSLA, USDG];
        for (uint256 i; i < used.length; ++i) {
            OracleAdapterLike.FeedConfig memory c = OracleAdapterLike(address(s.oracle)).feedConfig(used[i]);
            (,,, uint256 updatedAt,) = IAggregatorV3(c.primary).latestRoundData();
            if (block.timestamp - updatedAt > c.maxStalenessOpen) {
                c.maxStalenessOpen = c.maxStalenessClosed;
                vm.prank(address(s.timelock));
                OracleAdapterLike(address(s.oracle)).setFeed(used[i], c);
            }
        }
    }

    function _take(address token, address from, address to, uint256 amount) internal {
        vm.prank(from);
        IERC20(token).transfer(to, amount);
    }

    function _pledge(CreditAccount acct, address token, address pool, uint256 amount) internal {
        _take(token, pool, alice, amount);
        vm.startPrank(alice);
        IERC20(token).approve(address(acct), amount);
        acct.deposit(token, amount);
        vm.stopPrank();
    }

    function test_fork_deploymentWiredAndHandedOver() public {
        if (skipFork) return;
        s.clock.setMode(MarketClock.Mode.ForceClosed); // guardian (= this test) may force-close: weekend-safe staleness
        assertEq(address(s.factory.pool()), address(s.pool));
        assertEq(s.pool.asset(), USDG);
        assertTrue(s.pool.hasRole(0x00, address(s.timelock)));
        assertEq(s.timelock.getMinDelay(), 48 hours);
        assertFalse(s.hooks.isActive()); // no project token until governance sets it
        assertEq(s.riskEngine.listedAssetCount(), 16);
        // every configured asset prices through its real Chainlink feed
        address[] memory assets = s.riskEngine.getListedAssets();
        for (uint256 i; i < assets.length; ++i) {
            uint256 p = s.oracle.getPrice(assets[i]);
            assertGt(p, 1e18); // > $1
            assertLt(p, 100_000e18);
        }
        assertApproxEqRel(s.oracle.getPrice(USDG), 1e18, 0.02e18);
    }

    function test_fork_pledgeDrawRepay_realTokens() public {
        if (skipFork) return;
        vm.prank(alice);
        CreditAccount acct = CreditAccount(s.factory.createAccount());
        _pledge(acct, NVDA, NVDA_USDG_POOL, 20e18);
        _pledge(acct, SPY, SPY_USDG_POOL, 5e18);
        _pledge(acct, TSLA, TSLA_USDG_POOL, 5e18);
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(acct));
        assertGt(st.collateralValue, 0);
        assertGt(st.limit, 0);
        uint256 drawAmt = s.riskEngine.usdToStable(st.limit) / 2;
        vm.prank(alice);
        acct.draw(drawAmt, alice);
        assertEq(IERC20(USDG).balanceOf(alice), drawAmt);
        vm.warp(block.timestamp + 1 hours);
        uint256 debt = s.pool.debtOf(address(acct));
        assertGt(debt, drawAmt);
        _take(USDG, CRCL_USDG_POOL, alice, debt - drawAmt);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(s.pool), debt);
        s.pool.repay(address(acct), debt);
        acct.withdraw(NVDA, 20e18, alice);
        vm.stopPrank();
        assertEq(s.pool.debtOf(address(acct)), 0);
    }

    function test_fork_inAccountSwap_realUniswap() public {
        if (skipFork) return;
        vm.prank(alice);
        CreditAccount acct = CreditAccount(s.factory.createAccount());
        _pledge(acct, NVDA, NVDA_USDG_POOL, 10e18);
        vm.prank(alice);
        acct.draw(100e6, alice);
        // NVDA -> USDG -> SPY through the governance-configured pools
        vm.prank(alice);
        uint256 out = acct.swap(NVDA, SPY, 2e18, 1, block.timestamp + 60);
        assertGt(out, 0);
        assertEq(IERC20(SPY).balanceOf(address(acct)), out);
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(acct));
        assertLe(st.debtValue, st.limit);
    }

    function test_fork_softLiquidation_realUniswap() public {
        if (skipFork) return;
        vm.prank(alice);
        CreditAccount acct = CreditAccount(s.factory.createAccount());
        _pledge(acct, NVDA, NVDA_USDG_POOL, 10e18);
        _pledge(acct, SPY, SPY_USDG_POOL, 2e18);
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(acct));
        uint256 maxDraw = s.riskEngine.usdToStable(st.limit) - 1;
        vm.prank(alice);
        acct.draw(maxDraw, alice);

        // Oracle reports NVDA 20% lower (DEX unchanged) -> account enters the soft zone.
        (uint80 r, int256 ans,, uint256 upd, uint80 ar) = IAggregatorV3(NVDA_FEED).latestRoundData();
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, ans * 80 / 100, upd, upd, ar)
        );
        IRiskEngine.AccountState memory b = s.riskEngine.accountState(address(acct));
        assertLt(b.softHealth, 1e18);
        SoftLiquidator.Result memory res = s.soft.softLiquidate(address(acct), block.timestamp + 60);
        assertEq(res.asset, NVDA);
        assertGt(res.healthAfter, res.healthBefore);
        assertGt(res.repaid, 0);
    }

    function test_fork_hardLiquidation() public {
        if (skipFork) return;
        vm.prank(alice);
        CreditAccount acct = CreditAccount(s.factory.createAccount());
        _pledge(acct, NVDA, NVDA_USDG_POOL, 10e18);
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(acct));
        uint256 maxDraw = s.riskEngine.usdToStable(st.limit) - 1;
        vm.prank(alice);
        acct.draw(maxDraw, alice);
        (uint80 r, int256 ans,, uint256 upd, uint80 ar) = IAggregatorV3(NVDA_FEED).latestRoundData();
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, ans * 70 / 100, upd, upd, ar)
        );
        address liq = makeAddr("fork-liq");
        _take(USDG, CRCL_USDG_POOL, liq, 10_000e6);
        vm.startPrank(liq);
        IERC20(USDG).approve(address(s.hard), type(uint256).max);
        (uint256 repaid, uint256 seized) = s.hard.liquidate(address(acct), NVDA, 10_000e6, 0);
        vm.stopPrank();
        assertGt(repaid, 0);
        assertEq(IERC20(NVDA).balanceOf(liq), seized);
    }

    function test_fork_marketClosedBehaviour() public {
        if (skipFork) return;
        s.clock.setMode(MarketClock.Mode.Auto); // calendar ops role (guardian = this test)
        // Saturday 2026-10-10 15:00 UTC: closed; prices may be older but within the closed staleness window.
        uint256 sat = s.clock.daysFromCivil(2026, 10, 10) * 1 days + 15 hours;
        if (block.timestamp < sat) {
            assertFalse(s.clock.isOpenAt(sat));
        }
        assertTrue(s.clock.isOpenAt(s.clock.daysFromCivil(2026, 10, 8) * 1 days + 15 hours));
    }
}
