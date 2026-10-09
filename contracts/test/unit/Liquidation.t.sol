// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {SoftLiquidator} from "../../src/liquidation/SoftLiquidator.sol";
import {HardLiquidator} from "../../src/liquidation/HardLiquidator.sol";
import {Governed} from "../../src/libraries/Governed.sol";
import {IRiskEngine} from "../../src/interfaces/IHoldcredit.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LiquidationTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
        _pledge(alice, acct, aaa, 40e18); // $4000
        _pledge(alice, acct, bbb, 8e18); // $4000
        _pledge(alice, acct, ccc, 8e18); // $2000
        _draw(alice, acct, 6200e6); // exactly at the limit
        usdg.mint(liquidator, 1_000_000e6);
        vm.prank(liquidator);
        usdg.approve(address(s.hard), type(uint256).max);
    }

    function _intoSoftZone() internal {
        aaaFeed.set(70e8); // soft health ~ 0.961, hard health ~ 1.05
    }

    function _intoHardZone() internal {
        aaaFeed.set(40e8);
        cccFeed.set(150e8);
    }

    // ------------------------------------------------------------------ soft

    function test_soft_sellsOverweight_improvesHealth() public {
        _intoSoftZone();
        IRiskEngine.AccountState memory b = _state(acct);
        assertLt(b.softHealth, 1e18);
        assertGe(b.hardHealth, 1e18);
        (address asset, uint256 slice,) = s.soft.previewSlice(address(acct));
        assertEq(asset, address(bbb)); // BBB is above the 40% cap
        assertEq(slice, 880e18); // capped at 10% of $8,800

        vm.prank(keeper);
        SoftLiquidator.Result memory r = s.soft.softLiquidate(address(acct), block.timestamp);
        assertEq(r.asset, address(bbb));
        assertEq(r.amountSold, 1.76e18);
        assertEq(r.proceeds, 880e6);
        assertEq(r.keeperFee, 4.4e6);
        assertEq(r.repaid, 875.6e6);
        assertGt(r.healthAfter, r.healthBefore);
        assertGt(r.healthAfter, 1e18);
        assertEq(usdg.balanceOf(keeper), 4.4e6);
    }

    function test_soft_picksMostLiquidWhenNoneOverweight() public {
        // Balanced book: AAA 35%, BBB 35%, CCC 30% (nothing above the 40% cap)
        CreditAccount b = _open(bob);
        _pledge(bob, b, aaa, 35e18);
        _pledge(bob, b, bbb, 7e18);
        _pledge(bob, b, ccc, 12e18);
        _draw(bob, b, 6050e6);
        aaaFeed.set(80e8);
        bbbFeed.set(400e8);
        cccFeed.set(200e8);
        IRiskEngine.AccountState memory st = _state(b);
        assertLt(st.softHealth, 1e18);
        (address asset,,) = s.soft.previewSlice(address(b));
        assertEq(asset, address(bbb)); // highest value x liquidity score (2800 x 90)
        vm.prank(keeper);
        SoftLiquidator.Result memory r = s.soft.softLiquidate(address(b), block.timestamp);
        assertGt(r.healthAfter, r.healthBefore);
    }

    function test_soft_reverts_whenHealthy_closed_cooldown_nonKeeper() public {
        vm.prank(keeper);
        vm.expectRevert();
        s.soft.softLiquidate(address(acct), block.timestamp);

        _intoSoftZone();
        vm.expectRevert(SoftLiquidator.NotKeeper.selector);
        s.soft.softLiquidate(address(acct), block.timestamp);

        vm.prank(keeper);
        vm.expectRevert(SoftLiquidator.NotAccount.selector);
        s.soft.softLiquidate(alice, block.timestamp);

        _setClosed();
        vm.prank(keeper);
        vm.expectRevert(SoftLiquidator.MarketClosed.selector);
        s.soft.softLiquidate(address(acct), block.timestamp);
        _setOpen();

        aaaFeed.set(60e8); // deeper so a second slice is still needed
        vm.prank(keeper);
        s.soft.softLiquidate(address(acct), block.timestamp);
        if (_state(acct).softHealth < 1e18) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(SoftLiquidator.CoolingDown.selector, block.timestamp + 5 minutes));
            s.soft.softLiquidate(address(acct), block.timestamp);
            vm.warp(block.timestamp + 5 minutes);
            vm.prank(keeper);
            s.soft.softLiquidate(address(acct), block.timestamp);
        }
    }

    function test_soft_permissionlessMode_andPause() public {
        _intoSoftZone();
        vm.prank(address(s.timelock));
        s.soft.setPermissionless(true);
        vm.prank(guardian);
        s.soft.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        s.soft.softLiquidate(address(acct), block.timestamp);
        vm.prank(guardian);
        s.soft.unpause();
        vm.prank(guardian);
        s.factory.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        s.soft.softLiquidate(address(acct), block.timestamp);
        vm.prank(guardian);
        s.factory.unpause();
        s.soft.softLiquidate(address(acct), block.timestamp); // anyone
    }

    function test_soft_sandwichBoundedByOracle() public {
        _intoSoftZone();
        dex.setSlippage(200); // venue 2% below oracle: beyond the 1.5% bound
        vm.prank(keeper);
        vm.expectRevert("minOut");
        s.soft.softLiquidate(address(acct), block.timestamp);
        dex.setSlippage(100); // within bound -> executes
        vm.prank(keeper);
        s.soft.softLiquidate(address(acct), block.timestamp);
    }

    function test_soft_repaysEverything_surplusToAccount() public {
        // Venue pays far above a lagging oracle: one slice repays everything, surplus returns to the account.
        CreditAccount b = _open(bob);
        _pledge(bob, b, bbb, 10e18); // $5000 single asset -> limit 0.7 * 3500 = 2450
        _draw(bob, b, 2450e6);
        bbbFeed.set(450e8); // soft = 0.77 * (4500 - 1350) = 2425.5 < 2450
        dex.setBonus(20_000);
        vm.prank(address(s.timelock));
        s.soft.setParams(5000, 150, 50, 0, 2e18); // big slices
        vm.prank(keeper);
        SoftLiquidator.Result memory r = s.soft.softLiquidate(address(b), block.timestamp);
        assertGt(r.healthAfter, r.healthBefore);
        assertEq(s.pool.debtOf(address(b)), 0);
        assertGt(usdg.balanceOf(address(b)), 0);
    }

    function test_soft_admin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(Governed.InvalidParam.selector);
        s.soft.setParams(0, 100, 50, 60, 1.05e18);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.soft.setParams(1000, 100, 50, 60, 0.9e18);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.soft.setParams(1000, 100, 201, 60, 1.05e18);
        s.soft.setParams(2000, 100, 50, 60, 1.1e18);
        vm.stopPrank();
        assertEq(s.soft.maxSliceBps(), 2000);
        (address a, uint256 v, uint256 h) = s.soft.previewSlice(address(acct));
        assertEq(a, address(0));
        assertEq(v, 0);
        assertGe(h, 1e18);
    }

    // ------------------------------------------------------------------ hard

    function test_hard_notLiquidatableInSoftZone() public {
        _intoSoftZone();
        vm.prank(liquidator);
        vm.expectRevert();
        s.hard.liquidate(address(acct), address(bbb), 1000e6, 0);
    }

    function test_hard_fullLiquidationDeepUnderwater() public {
        _intoHardZone();
        IRiskEngine.AccountState memory b = _state(acct);
        assertLt(b.hardHealth, 0.95e18);
        (uint256 qr, uint256 qs, uint256 qc) = s.hard.quote(address(acct), address(bbb), 2000e6);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = s.hard.liquidate(address(acct), address(bbb), 2000e6, 0);
        assertEq(repaid, qr);
        assertEq(seized, qs);
        assertEq(repaid, 2000e6);
        // 2000 * 1.08 / 500 = 4.32 BBB total; bonus = 0.32, 10% of it to protocol
        assertEq(seized + qc, 4.32e18);
        assertApproxEqAbs(qc, 0.032e18, 1);
        assertEq(bbb.balanceOf(liquidator), seized);
        assertEq(bbb.balanceOf(address(s.feeCollector)), qc);
        assertEq(s.pool.debtOf(address(acct)), 4200e6);
    }

    function test_hard_closeFactor() public {
        // Mildly underwater: hard health between 0.95 and 1 -> 50% close factor
        aaaFeed.set(60e8);
        cccFeed.set(230e8);
        IRiskEngine.AccountState memory st = _state(acct);
        assertLt(st.hardHealth, 1e18);
        assertGt(st.hardHealth, 0.95e18);
        vm.prank(liquidator);
        (uint256 repaid,) = s.hard.liquidate(address(acct), address(bbb), 10_000e6, 0);
        assertEq(repaid, 3100e6);
    }

    function test_hard_slippageGuard_andValidation() public {
        _intoHardZone();
        vm.startPrank(liquidator);
        vm.expectRevert();
        s.hard.liquidate(address(acct), address(bbb), 1000e6, 100e18);
        vm.expectRevert(abi.encodeWithSelector(HardLiquidator.NotCollateral.selector, address(usdg)));
        s.hard.liquidate(address(acct), address(usdg), 1000e6, 0);
        vm.expectRevert(HardLiquidator.NotAccount.selector);
        s.hard.liquidate(alice, address(bbb), 1000e6, 0);
        vm.expectRevert(HardLiquidator.ZeroRepay.selector);
        s.hard.liquidate(address(acct), address(bbb), 0, 0);
        vm.stopPrank();
    }

    function test_hard_badDebtWriteOff() public {
        CreditAccount b = _open(bob);
        _pledge(bob, b, aaa, 10e18); // $1000 -> limit 420
        _draw(bob, b, 420e6);
        aaaFeed.set(10e8); // collateral $100
        uint256 assetsBefore = s.pool.totalAssets();
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = s.hard.liquidate(address(b), address(aaa), 420e6, 0);
        assertApproxEqAbs(repaid, 92_592_592, 1); // $100 / 1.08
        assertGt(seized, 9.9e18);
        assertEq(aaa.balanceOf(address(b)), 0);
        assertEq(s.pool.debtOf(address(b)), 0); // residual written off
        assertGt(s.pool.totalBadDebt() + s.pool.totalBadDebtCoveredByReserves(), 0);
        assertLt(s.pool.totalAssets(), assetsBefore);
        vm.expectRevert(HardLiquidator.NotInsolvent.selector);
        s.hard.settleBadDebt(address(b));
    }

    function test_hard_settleBadDebt_permissionless() public {
        CreditAccount b = _open(bob);
        _pledge(bob, b, aaa, 1e18);
        _draw(bob, b, 42e6);
        aaaFeed.set(0.5e8); // $0.50 collateral < $1 dust
        uint256 written = s.hard.settleBadDebt(address(b));
        assertEq(written, 42e6);
        vm.expectRevert(HardLiquidator.NotAccount.selector);
        s.hard.settleBadDebt(alice);
    }

    function test_hard_dustDebtFullyLiquidatable() public {
        CreditAccount b = _open(bob);
        _pledge(bob, b, bbb, 1e18); // $500 -> limit 245
        _draw(bob, b, 90e6);
        bbbFeed.set(150e8); // hard = .83 * (150 - 45) = 87.15 < 90 ; hardHealth .968 > .95
        IRiskEngine.AccountState memory st = _state(b);
        assertLt(st.hardHealth, 1e18);
        assertGt(st.hardHealth, 0.95e18);
        vm.prank(liquidator);
        (uint256 repaid,) = s.hard.liquidate(address(b), address(bbb), 90e6, 0);
        assertEq(repaid, 90e6); // debt <= dust -> no close factor
    }

    function test_hard_runsWhileMarketClosed_butPausable() public {
        _intoHardZone();
        _setClosed();
        vm.prank(liquidator);
        s.hard.liquidate(address(acct), address(bbb), 100e6, 0);
        vm.prank(guardian);
        s.hard.pause();
        vm.prank(liquidator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        s.hard.liquidate(address(acct), address(bbb), 100e6, 0);
    }

    function test_hard_admin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(Governed.InvalidParam.selector);
        s.hard.setParams(0, 0.95e18, 1, 800, 1000);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.hard.setParams(5000, 0.95e18, 1, 2001, 1000);
        s.hard.setParams(6000, 0.9e18, 1, 500, 0);
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.hard.setFeeCollector(address(0));
        s.hard.setFeeCollector(treasury);
        s.hard.setBadDebtDustValue(2e18);
        vm.stopPrank();
        assertEq(s.hard.closeFactorBps(), 6000);
        assertEq(s.hard.badDebtDustValue(), 2e18);
    }
}
