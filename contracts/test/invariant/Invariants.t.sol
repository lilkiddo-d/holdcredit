// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {SoftLiquidator} from "../../src/liquidation/SoftLiquidator.sol";
import {MockERC20, MockAggregator, MockDexAdapter} from "../mocks/Mocks.sol";
import {IRiskEngine} from "../../src/interfaces/IHoldcredit.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";

/// @notice Drives the protocol with random user / keeper / market actions and records ghost violations.
contract Handler is Test {
    SystemDeployer.System internal s;
    MockERC20 internal usdg;
    MockERC20[3] internal toks;
    MockAggregator[3] internal feeds;
    int256[3] internal basePrice;
    MockAggregator internal usdgFeed;
    MockDexAdapter internal dex;
    address internal keeper;

    address[3] public users;
    CreditAccount[3] public accts;
    address public lender = makeAddr("inv-lender");

    // ghost variables
    uint256 public drawOrSwapViolations;
    uint256 public softNotImproved;
    uint256 public softCalls;
    uint256 public hardCalls;
    uint256 public draws;
    uint256 public swaps;

    constructor(
        SystemDeployer.System memory s_,
        MockERC20 usdg_,
        MockERC20[3] memory toks_,
        MockAggregator[3] memory feeds_,
        MockAggregator usdgFeed_,
        MockDexAdapter dex_,
        address keeper_
    ) {
        s = s_;
        usdg = usdg_;
        toks = toks_;
        feeds = feeds_;
        usdgFeed = usdgFeed_;
        dex = dex_;
        keeper = keeper_;
        for (uint256 i; i < 3; ++i) {
            basePrice[i] = feeds_[i].answer();
            users[i] = makeAddr(string.concat("inv-user", vm.toString(i)));
            vm.prank(users[i]);
            accts[i] = CreditAccount(s.factory.createAccount());
        }
    }

    function _touch() internal {
        usdgFeed.set(usdgFeed.answer());
        for (uint256 i; i < 3; ++i) {
            feeds[i].set(feeds[i].answer());
        }
    }

    function _check(CreditAccount a) internal {
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(a));
        if (st.debt != 0 && st.debtValue > st.limit) drawOrSwapViolations++;
    }

    // ------------------------------------------------------------------ user actions

    function deposit(uint256 u, uint256 t, uint256 amt) external {
        u %= 3;
        t %= 3;
        amt = bound(amt, 1e15, 500e18);
        toks[t].mint(users[u], amt);
        vm.startPrank(users[u]);
        toks[t].approve(address(accts[u]), amt);
        accts[u].deposit(address(toks[t]), amt);
        vm.stopPrank();
    }

    function draw(uint256 u, uint256 bps) external {
        u %= 3;
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(accts[u]));
        if (st.limit <= st.debtValue) return;
        uint256 headroom = s.riskEngine.usdToStable(st.limit - st.debtValue);
        uint256 amt = headroom * bound(bps, 1, 10_500) / 10_000; // sometimes try to overdraw
        if (amt == 0) return;
        vm.prank(users[u]);
        try accts[u].draw(amt, users[u]) {
            draws++;
            _check(accts[u]);
        } catch {}
    }

    function repay(uint256 u, uint256 amt) external {
        u %= 3;
        uint256 debt = s.pool.debtOf(address(accts[u]));
        if (debt == 0) return;
        amt = bound(amt, 1, debt);
        usdg.mint(users[u], amt);
        vm.startPrank(users[u]);
        usdg.approve(address(s.pool), amt);
        s.pool.repay(address(accts[u]), amt);
        vm.stopPrank();
    }

    function swap(uint256 u, uint256 from, uint256 to, uint256 bps, uint256 slip) external {
        u %= 3;
        MockERC20 tin = toks[from % 3];
        MockERC20 tout = toks[to % 3];
        uint256 amt = tin.balanceOf(address(accts[u])) * bound(bps, 1, 10_000) / 10_000;
        if (amt == 0) return;
        dex.setSlippage(bound(slip, 0, 300));
        vm.prank(users[u]);
        try accts[u].swap(address(tin), address(tout), amt, 0, block.timestamp) {
            swaps++;
            _check(accts[u]);
        } catch {}
        dex.setSlippage(0);
    }

    function withdraw(uint256 u, uint256 t, uint256 bps) external {
        u %= 3;
        MockERC20 tok = toks[t % 3];
        uint256 amt = tok.balanceOf(address(accts[u])) * bound(bps, 1, 10_000) / 10_000;
        if (amt == 0) return;
        vm.prank(users[u]);
        try accts[u].withdraw(address(tok), amt, users[u]) {
            if (s.pool.debtOf(address(accts[u])) != 0) _check(accts[u]);
        } catch {}
    }

    // ------------------------------------------------------------------ lenders

    function lend(uint256 amt) external {
        amt = bound(amt, 1e6, 1_000_000e6);
        usdg.mint(lender, amt);
        vm.startPrank(lender);
        usdg.approve(address(s.pool), amt);
        s.pool.deposit(amt, lender);
        vm.stopPrank();
    }

    function withdrawLend(uint256 bps) external {
        uint256 max = s.pool.maxWithdraw(lender);
        uint256 amt = max * bound(bps, 1, 10_000) / 10_000;
        if (amt == 0) return;
        vm.prank(lender);
        s.pool.withdraw(amt, lender, lender);
    }

    // ------------------------------------------------------------------ market + keepers

    function movePrice(uint256 t, uint256 pct) external {
        t %= 3;
        int256 p = basePrice[t] * int256(bound(pct, 40, 160)) / 100;
        feeds[t].set(p);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 minutes, 20 days));
        _touch();
    }

    function softLiquidate(uint256 u) external {
        u %= 3;
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(accts[u]));
        if (st.softHealth >= 1e18) return;
        vm.prank(keeper);
        try s.soft.softLiquidate(address(accts[u]), block.timestamp) returns (SoftLiquidator.Result memory) {
            softCalls++;
            IRiskEngine.AccountState memory a = s.riskEngine.accountState(address(accts[u]));
            if (a.softHealth <= st.softHealth) softNotImproved++;
        } catch {}
    }

    function hardLiquidate(uint256 u, uint256 t, uint256 bps) external {
        u %= 3;
        IRiskEngine.AccountState memory st = s.riskEngine.accountState(address(accts[u]));
        if (st.hardHealth >= 1e18) return;
        uint256 amt = st.debt * bound(bps, 1, 10_000) / 10_000;
        if (amt == 0) return;
        address liq = makeAddr("inv-liq");
        usdg.mint(liq, amt);
        vm.startPrank(liq);
        usdg.approve(address(s.hard), amt);
        try s.hard.liquidate(address(accts[u]), address(toks[t % 3]), amt, 0) {
            hardCalls++;
        } catch {}
        vm.stopPrank();
    }

    function collectAndDistribute() external {
        s.pool.collectReserves();
        s.feeCollector.distribute();
    }

    function accountsList() external view returns (CreditAccount[3] memory) {
        return accts;
    }
}

contract InvariantsTest is BaseTest {
    Handler internal h;

    function setUp() public override {
        super.setUp();
        h = new Handler(s, usdg, [aaa, bbb, ccc], [aaaFeed, bbbFeed, cccFeed], usdgFeed, dex, keeper);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](13);
        sel[0] = Handler.deposit.selector;
        sel[1] = Handler.draw.selector;
        sel[2] = Handler.repay.selector;
        sel[3] = Handler.swap.selector;
        sel[4] = Handler.withdraw.selector;
        sel[5] = Handler.lend.selector;
        sel[6] = Handler.withdrawLend.selector;
        sel[7] = Handler.movePrice.selector;
        sel[8] = Handler.warp.selector;
        sel[9] = Handler.softLiquidate.selector;
        sel[10] = Handler.hardLiquidate.selector;
        sel[11] = Handler.collectAndDistribute.selector;
        sel[12] = Handler.draw.selector; // weight draws
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// No draw, swap or indebted withdrawal can leave an account below its limit.
    function invariant_drawSwapWithdrawNeverBreachLimit() public view {
        assertEq(h.drawOrSwapViolations(), 0);
    }

    /// Soft liquidation always improves health.
    function invariant_softLiquidationImprovesHealth() public view {
        assertEq(h.softNotImproved(), 0);
    }

    /// Lender pool assets >= deposits - withdrawals - realised bad debt (interest only ever adds).
    function invariant_lenderAssetsCoverDepositsMinusBadDebt() public view {
        uint256 net = s.pool.totalDeposited() - s.pool.totalWithdrawn();
        uint256 floor = net > s.pool.totalBadDebt() ? net - s.pool.totalBadDebt() : 0;
        // +10 wei tolerance for ERC-4626 rounding across many operations
        assertGe(s.pool.totalAssets() + 10, floor);
    }

    /// Debt bookkeeping: per-account scaled debts sum to the tier totals.
    function invariant_scaledDebtAccounting() public view {
        CreditAccount[3] memory accts = h.accountsList();
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += s.pool.scaledDebt(address(accts[i]));
        }
        assertEq(sum, s.pool.totalScaled(0) + s.pool.totalScaled(1));
    }

    /// Every account respects the 15-asset cap.
    function invariant_assetCap() public view {
        CreditAccount[3] memory accts = h.accountsList();
        for (uint256 i; i < 3; ++i) {
            assertLe(accts[i].assetCount(), 15);
        }
    }

    function invariant_callSummary() public view {
        // Not an assertion of correctness; keeps the summary visible with -vv.
        h.draws();
        h.swaps();
        h.softCalls();
        h.hardCalls();
    }
}
