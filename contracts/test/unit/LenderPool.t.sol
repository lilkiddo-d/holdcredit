// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {LenderPool} from "../../src/core/LenderPool.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {MockHooks} from "../mocks/Mocks.sol";
import {IProjectTokenHooks, IInterestRateModel, ICreditAccountFactory} from "../../src/interfaces/IHoldcredit.sol";
import {Governed} from "../../src/libraries/Governed.sol";

contract LenderPoolTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
        _pledge(alice, acct, bbb, 1000e18); // $500k
        _pledge(alice, acct, aaa, 5000e18); // $500k
        _pledge(alice, acct, ccc, 2000e18); // $500k -> limit $900k
    }

    function test_erc4626_basics() public view {
        assertEq(s.pool.totalAssets(), LENDER_DEPOSIT);
        assertEq(s.pool.decimals(), 12);
        assertEq(s.pool.asset(), address(usdg));
        assertEq(s.pool.totalDeposited(), LENDER_DEPOSIT);
        assertEq(s.pool.maxWithdraw(lender), LENDER_DEPOSIT);
        assertEq(s.pool.maxDeposit(lender), type(uint256).max);
    }

    function test_interestAccrues_andLendersEarn() public {
        _draw(alice, acct, 500_000e6); // 50% utilisation
        assertEq(s.pool.utilization(), 0.5e18);
        vm.warp(block.timestamp + 365 days);
        _touchFeeds();
        uint256 debt = s.pool.debtOf(address(acct));
        // rate at 50% util = 3% + 9% * 0.5/0.85 ~ 8.29% simple
        assertApproxEqRel(debt, 500_000e6 * 10829 / 10_000, 0.001e18);
        uint256 interest = debt - 500_000e6;
        // lenders get 85% of interest
        assertApproxEqAbs(s.pool.totalAssets(), LENDER_DEPOSIT + interest * 85 / 100, 2);
        assertGt(s.pool.borrowRatePerYear(0), 0.08e18);
        assertGt(s.pool.supplyRatePerYear(), 0);
    }

    function test_repay_full_andReserves() public {
        _draw(alice, acct, 100_000e6);
        vm.warp(block.timestamp + 30 days);
        _touchFeeds();
        uint256 debt = s.pool.debtOf(address(acct));
        usdg.mint(alice, debt);
        vm.startPrank(alice);
        usdg.approve(address(s.pool), type(uint256).max);
        uint256 repaid = s.pool.repay(address(acct), type(uint256).max);
        vm.stopPrank();
        assertEq(repaid, debt);
        assertEq(s.pool.debtOf(address(acct)), 0);
        assertEq(s.pool.scaledDebt(address(acct)), 0);
        assertGt(s.pool.reserves(), 0);
        uint256 res = s.pool.reserves();
        uint256 got = s.pool.collectReserves();
        assertEq(got, res);
        assertEq(usdg.balanceOf(address(s.feeCollector)), res);
        assertEq(s.pool.collectReserves(), 0);
        // repaying zero debt is a no-op
        vm.prank(alice);
        assertEq(s.pool.repay(address(acct), 1), 0);
    }

    function test_withdraw_limitedByLiquidity() public {
        _draw(alice, acct, 300_000e6);
        assertEq(s.pool.maxWithdraw(lender), 700_000e6);
        uint256 shares = s.pool.balanceOf(lender);
        assertLt(s.pool.maxRedeem(lender), shares);
        vm.prank(lender);
        vm.expectRevert();
        s.pool.withdraw(700_001e6, lender, lender);
        vm.prank(lender);
        s.pool.withdraw(700_000e6, lender, lender);
        assertEq(s.pool.totalWithdrawn(), 700_000e6);
    }

    function test_borrow_insufficientLiquidity() public {
        _pledge(alice, acct, bbb, 10_000e18);
        vm.prank(alice);
        vm.expectRevert(LenderPool.InsufficientLiquidity.selector);
        acct.draw(LENDER_DEPOSIT + 1, alice);
    }

    function test_borrow_onlyAccounts() public {
        vm.expectRevert(LenderPool.NotCreditAccount.selector);
        s.pool.borrow(1, address(this));
        vm.prank(address(acct));
        vm.expectRevert(LenderPool.ZeroAmount.selector);
        s.pool.borrow(0, alice);
    }

    function test_mint_redeem_paths() public {
        usdg.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdg.approve(address(s.pool), type(uint256).max);
        uint256 shares = s.pool.previewDeposit(1000e6);
        s.pool.mint(shares, bob);
        assertEq(s.pool.balanceOf(bob), shares);
        uint256 assets = s.pool.redeem(shares, bob, bob);
        vm.stopPrank();
        assertApproxEqAbs(assets, 1000e6, 1);
    }

    function test_pause_blocksLendingButNotRepay() public {
        _draw(alice, acct, 1000e6);
        vm.prank(guardian);
        s.pool.pause();
        assertEq(s.pool.maxDeposit(bob), 0);
        assertEq(s.pool.maxMint(bob), 0);
        assertEq(s.pool.maxWithdraw(lender), 0);
        assertEq(s.pool.maxRedeem(lender), 0);
        vm.prank(lender);
        vm.expectRevert();
        s.pool.withdraw(1, lender, lender);
        vm.prank(lender);
        vm.expectRevert();
        s.pool.redeem(1, lender, lender);
        vm.expectRevert();
        s.pool.deposit(1, address(this));
        vm.expectRevert();
        s.pool.mint(1, address(this));
        vm.startPrank(alice);
        usdg.approve(address(s.pool), 1000e6);
        s.pool.repay(address(acct), 1000e6);
        vm.stopPrank();
        vm.prank(guardian);
        s.pool.unpause();
    }

    function test_lendComplianceGate() public {
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        usdg.mint(bob, 10e6);
        vm.startPrank(bob);
        usdg.approve(address(s.pool), 10e6);
        vm.expectRevert(LenderPool.NotAllowed.selector);
        s.pool.deposit(10e6, bob);
        vm.stopPrank();
    }

    function test_writeOff_onlyHardLiquidator_reservesFirst() public {
        _draw(alice, acct, 100_000e6);
        vm.warp(block.timestamp + 365 days);
        _touchFeeds();
        s.pool.accrue();
        uint256 res = s.pool.reserves();
        uint256 debt = s.pool.debtOf(address(acct));
        vm.expectRevert(LenderPool.NotHardLiquidator.selector);
        s.pool.writeOffBadDebt(address(acct));
        vm.prank(address(s.hard));
        uint256 written = s.pool.writeOffBadDebt(address(acct));
        assertEq(written, debt);
        assertEq(s.pool.reserves(), 0);
        assertEq(s.pool.totalBadDebtCoveredByReserves(), res);
        assertEq(s.pool.totalBadDebt(), debt - res);
        vm.prank(address(s.hard));
        assertEq(s.pool.writeOffBadDebt(address(acct)), 0);
    }

    function test_tiers_stakerDiscount() public {
        MockHooks h = new MockHooks();
        vm.prank(address(s.timelock));
        s.pool.setHooks(IProjectTokenHooks(address(h)));
        h.setDiscounted(alice, true);

        _draw(alice, acct, 100_000e6); // first borrow picks the staker tier
        assertEq(s.pool.tierOf(address(acct)), 1);
        CreditAccount b = _open(bob);
        _pledge(bob, b, bbb, 1000e18);
        _draw(bob, b, 100_000e6);
        assertEq(s.pool.tierOf(address(b)), 0);

        vm.warp(block.timestamp + 365 days);
        _touchFeeds();
        uint256 da = s.pool.debtOf(address(acct)) - 100_000e6;
        uint256 db = s.pool.debtOf(address(b)) - 100_000e6;
        assertApproxEqRel(da, db * 8000 / 10_000, 0.001e18); // 20% cheaper
        assertLt(s.pool.borrowRatePerYear(1), s.pool.borrowRatePerYear(0));

        // Unstaking => tier sync moves debt back without changing its value
        h.setDiscounted(alice, false);
        uint256 before = s.pool.debtOf(address(acct));
        s.pool.syncTier(address(acct));
        assertEq(s.pool.tierOf(address(acct)), 0);
        assertApproxEqAbs(s.pool.debtOf(address(acct)), before, 1);
        s.pool.syncTier(address(acct)); // no-op
        // inactive hooks => standard tier
        h.setActive(false);
        h.setDiscounted(bob, true);
        s.pool.syncTier(address(b));
        assertEq(s.pool.tierOf(address(b)), 0);
        vm.expectRevert(LenderPool.NotCreditAccount.selector);
        s.pool.syncTier(alice);
    }

    function test_tier_syncWithoutDebt() public {
        MockHooks h = new MockHooks();
        vm.prank(address(s.timelock));
        s.pool.setHooks(IProjectTokenHooks(address(h)));
        h.setDiscounted(alice, true);
        s.pool.syncTier(address(acct));
        assertEq(s.pool.tierOf(address(acct)), 1);
    }

    function test_admin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(Governed.InvalidParam.selector);
        s.pool.setReserveFactor(5001);
        s.pool.setReserveFactor(2000);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.pool.setStakerDiscount(5001);
        s.pool.setStakerDiscount(1000);
        InterestRateModel m = new InterestRateModel(0, 0.1e18, 1e18, 0.8e18);
        s.pool.setInterestRateModel(m);
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.pool.setInterestRateModel(IInterestRateModel(address(0)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.pool.setFactory(ICreditAccountFactory(address(0)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.pool.setFeeCollector(address(0));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.pool.setHardLiquidator(address(0));
        vm.stopPrank();
        assertEq(s.pool.reserveFactorBps(), 2000);
        vm.expectRevert();
        s.pool.setReserveFactor(1);
        vm.expectRevert();
        s.pool.pause();
    }

    function test_firstDepositorInflationResistance() public {
        LenderPool fresh = new LenderPool(usdg, s.irm, address(this), guardian);
        address attacker = makeAddr("attacker");
        usdg.mint(attacker, 10_001e6);
        vm.startPrank(attacker);
        usdg.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        usdg.transfer(address(fresh), 10_000e6); // donation
        vm.stopPrank();
        usdg.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdg.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(1000e6, bob);
        vm.stopPrank();
        assertGt(shares, 0);
        assertApproxEqRel(fresh.previewRedeem(shares), 1000e6, 0.001e18);
    }
}
