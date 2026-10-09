// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {SoftLiquidator} from "../../src/liquidation/SoftLiquidator.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";
import {IRiskEngine} from "../../src/interfaces/IHoldcredit.sol";

contract PropertiesFuzzTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
    }

    function _portfolio(uint256 a, uint256 b, uint256 c) internal {
        a = bound(a, 0, 5000e18);
        b = bound(b, 0, 1000e18);
        c = bound(c, 0, 2000e18);
        if (a + b + c == 0) a = 10e18;
        if (a != 0) _pledge(alice, acct, aaa, a);
        if (b != 0) _pledge(alice, acct, bbb, b);
        if (c != 0) _pledge(alice, acct, ccc, c);
    }

    /// Property: no successful draw can leave the account above its limit (open or closed market).
    function testFuzz_draw_neverAboveLimit(uint256 a, uint256 b, uint256 c, uint256 drawAmt, bool closed) public {
        _portfolio(a, b, c);
        if (closed) _setClosed();
        drawAmt = bound(drawAmt, 1, 900_000e6);
        vm.prank(alice);
        try acct.draw(drawAmt, alice) {
            IRiskEngine.AccountState memory st = _state(acct);
            assertLe(st.debtValue, st.limit, "draw left account above limit");
            if (closed) assertLe(drawAmt, s.riskEngine.closedDrawCap());
        } catch {}
    }

    /// Property: no successful in-account swap can leave an indebted account above its limit.
    function testFuzz_swap_neverAboveLimit(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 drawBps,
        uint8 from,
        uint8 to,
        uint256 amountBps,
        uint256 slippage
    ) public {
        _portfolio(a, b, c);
        IRiskEngine.AccountState memory st0 = _state(acct);
        uint256 drawAmt = s.riskEngine.usdToStable(st0.limit) * bound(drawBps, 0, 10_000) / 10_000;
        if (drawAmt != 0) _draw(alice, acct, drawAmt);
        MockERC20[3] memory toks = [aaa, bbb, ccc];
        MockERC20 tin = toks[from % 3];
        MockERC20 tout = toks[to % 3];
        uint256 bal = tin.balanceOf(address(acct));
        uint256 amountIn = bal * bound(amountBps, 0, 10_000) / 10_000;
        dex.setSlippage(bound(slippage, 0, 400));
        vm.prank(alice);
        try acct.swap(address(tin), address(tout), amountIn, 0, block.timestamp) {
            IRiskEngine.AccountState memory st = _state(acct);
            if (st.debt != 0) assertLe(st.debtValue, st.limit, "swap left account above limit");
        } catch {}
    }

    /// Property: soft liquidation always strictly improves soft health, and it must succeed whenever the
    /// account is in the soft zone but not yet hard-liquidatable.
    function testFuzz_softLiquidation_improvesHealth(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 shockA,
        uint256 shockB,
        uint256 shockC,
        uint256 slippage
    ) public {
        _portfolio(a, b, c);
        IRiskEngine.AccountState memory st0 = _state(acct);
        uint256 drawAmt = s.riskEngine.usdToStable(st0.limit);
        vm.assume(drawAmt > 10e6);
        _draw(alice, acct, drawAmt);
        aaaFeed.set(int256(100e8 * bound(shockA, 50, 100) / 100));
        bbbFeed.set(int256(500e8 * bound(shockB, 50, 100) / 100));
        cccFeed.set(int256(250e8 * bound(shockC, 50, 100) / 100));
        dex.setSlippage(bound(slippage, 0, 150));
        IRiskEngine.AccountState memory before = _state(acct);
        vm.assume(before.softHealth < 1e18);

        vm.prank(keeper);
        try s.soft.softLiquidate(address(acct), block.timestamp) returns (SoftLiquidator.Result memory r) {
            IRiskEngine.AccountState memory afterSt = _state(acct);
            assertGt(afterSt.softHealth, before.softHealth, "soft liquidation did not improve health");
            assertEq(r.healthAfter, afterSt.softHealth);
            assertLt(afterSt.debt, before.debt);
        } catch (bytes memory err) {
            // Only acceptable failure: deep in the hard zone where selling at a discount cannot help.
            assertLt(before.hardHealth, 1e18, "soft liquidation reverted in the soft zone");
            assertEq(bytes4(err), SoftLiquidator.HealthNotImproved.selector);
        }
    }

    /// Property: adding collateral never lowers the credit limit (concentration penalty is monotone).
    function testFuzz_limitMonotoneInCollateral(uint256 a, uint256 b, uint256 c, uint8 which, uint256 extra) public view {
        address[] memory assets = new address[](3);
        uint256[] memory amts = new uint256[](3);
        assets[0] = address(aaa);
        assets[1] = address(bbb);
        assets[2] = address(ccc);
        amts[0] = bound(a, 0, 1e24);
        amts[1] = bound(b, 0, 1e24);
        amts[2] = bound(c, 0, 1e24);
        (, uint256 lo1,) = s.riskEngine.previewLimit(assets, amts);
        amts[which % 3] += bound(extra, 0, 1e24);
        (, uint256 lo2,) = s.riskEngine.previewLimit(assets, amts);
        assertGe(lo2, lo1);
    }

    /// Property: debt is non-decreasing over time and the pool stays solvent-accounted.
    function testFuzz_debtGrowsWithTime(uint256 drawAmt, uint256 dt) public {
        _pledge(alice, acct, bbb, 1000e18);
        _pledge(alice, acct, aaa, 5000e18);
        drawAmt = bound(drawAmt, 1e6, 500_000e6);
        _draw(alice, acct, drawAmt);
        uint256 d0 = s.pool.debtOf(address(acct));
        vm.warp(block.timestamp + bound(dt, 1, 3650 days));
        assertGe(s.pool.debtOf(address(acct)), d0);
        assertGe(s.pool.totalAssets() + 1, LENDER_DEPOSIT);
    }
}
