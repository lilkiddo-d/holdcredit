// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {CreditAccountFactory} from "../../src/core/CreditAccountFactory.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IRiskEngine} from "../../src/interfaces/IHoldcredit.sol";
import {Constants} from "../../src/libraries/Constants.sol";

contract CreditAccountTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
    }

    // ------------------------------------------------------------------ factory

    function test_factory_oneAccountPerOwner_deterministic() public {
        assertEq(s.factory.accountOf(alice), address(acct));
        assertEq(s.factory.predictAccount(alice), address(acct));
        assertTrue(s.factory.isAccount(address(acct)));
        assertEq(acct.owner(), alice);
        assertEq(address(acct.factory()), address(s.factory));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccountFactory.AccountExists.selector, address(acct)));
        s.factory.createAccount();
        assertEq(s.factory.accountsLength(), 1);
        address[] memory page = s.factory.getAccounts(0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], address(acct));
        assertEq(s.factory.getAccounts(5, 10).length, 0);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        acct.initialize(bob);
        CreditAccount impl = s.implementation;
        vm.expectRevert();
        impl.initialize(bob);
    }

    function test_factory_pausedBlocksCreate() public {
        vm.prank(guardian);
        s.factory.pause();
        vm.prank(bob);
        vm.expectRevert();
        s.factory.createAccount();
    }

    // ------------------------------------------------------------------ deposits

    function test_deposit_tracksAsset() public {
        _pledge(alice, acct, aaa, 10e18);
        assertEq(aaa.balanceOf(address(acct)), 10e18);
        address[] memory a = acct.getAssets();
        assertEq(a.length, 1);
        assertEq(a[0], address(aaa));
        assertTrue(acct.isHeld(address(aaa)));
        assertEq(acct.assetCount(), 1);
    }

    function test_deposit_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(CreditAccount.NotOwner.selector);
        acct.deposit(address(aaa), 1);
    }

    function test_deposit_rejectsUnknownAndFrozen() public {
        MockERC20 junk = new MockERC20("J", "J", 18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.AssetNotAccepted.selector, address(junk)));
        acct.deposit(address(junk), 1);

        vm.prank(address(s.timelock));
        s.riskEngine.setAssetConfig(
            address(aaa),
            IRiskEngine.AssetConfig({enabled: true, frozen: true, ltvBps: 6000, softBps: 6800, hardBps: 7500, liquidityScore: 80})
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.AssetNotAccepted.selector, address(aaa)));
        acct.deposit(address(aaa), 1);
    }

    function test_deposit_assetCap15() public {
        for (uint256 i; i < 15; ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            vm.startPrank(address(s.timelock));
            _feed(address(t), address(aaaFeed), 18, false);
            s.riskEngine.setAssetConfig(
                address(t),
                IRiskEngine.AssetConfig({enabled: true, frozen: false, ltvBps: 5000, softBps: 6000, hardBps: 7000, liquidityScore: 50})
            );
            vm.stopPrank();
            _pledge(alice, acct, t, 1e18);
        }
        assertEq(acct.assetCount(), 15);
        vm.prank(alice);
        vm.expectRevert(CreditAccount.TooManyAssets.selector);
        acct.deposit(address(aaa), 0);
        // the risk engine still prices the full portfolio within bounds
        assertEq(_state(acct).collateralValue, 1500e18);
    }

    // ------------------------------------------------------------------ draw / repay

    function test_draw_withinLimit_concentrated() public {
        _pledge(alice, acct, aaa, 100e18); // $10,000 in a single stock
        IRiskEngine.AccountState memory st = _state(acct);
        // 100% weight: excess 6000 * 50% penalty => adjusted 7000 * 60% = 4200
        assertEq(st.limit, 4200e18);
        _draw(alice, acct, 4200e6);
        assertEq(usdg.balanceOf(alice), 4200e6);
        assertEq(s.pool.debtOf(address(acct)), 4200e6);
        vm.prank(alice);
        vm.expectRevert();
        acct.draw(1, alice);
    }

    function test_draw_diversifiedGetsHigherLimit() public {
        _pledge(alice, acct, aaa, 40e18); // 4000
        _pledge(alice, acct, bbb, 8e18); // 4000
        _pledge(alice, acct, ccc, 8e18); // 2000
        IRiskEngine.AccountState memory st = _state(acct);
        assertEq(st.collateralValue, 10_000e18);
        assertEq(st.limit, 6200e18);
        _draw(alice, acct, 6200e6);
    }

    function test_draw_revertsAboveLimit() public {
        _pledge(alice, acct, aaa, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.LimitExceeded.selector, 4200e18 + 1e12, 4200e18));
        acct.draw(4200e6 + 1, alice);
    }

    function test_draw_zeroAndAuth() public {
        vm.prank(alice);
        vm.expectRevert(CreditAccount.ZeroAmount.selector);
        acct.draw(0, alice);
        vm.prank(bob);
        vm.expectRevert(CreditAccount.NotOwner.selector);
        acct.draw(1, bob);
    }

    function test_draw_pausedReverts_repayStillWorks() public {
        _pledge(alice, acct, aaa, 100e18);
        _draw(alice, acct, 1000e6);
        vm.prank(guardian);
        s.factory.pause();
        vm.prank(alice);
        vm.expectRevert(CreditAccount.Paused.selector);
        acct.draw(1, alice);

        vm.startPrank(alice);
        usdg.approve(address(s.pool), 400e6);
        s.pool.repay(address(acct), 400e6);
        vm.stopPrank();
        assertEq(s.pool.debtOf(address(acct)), 600e6);
        // depositing more collateral still allowed while paused
        _pledge(alice, acct, bbb, 1e18);
    }

    function test_draw_closedMarket_capAndShrunkLimit() public {
        _pledge(alice, acct, bbb, 100e18); // $50,000
        _setClosed();
        IRiskEngine.AccountState memory st = _state(acct);
        assertFalse(st.marketOpen);
        assertEq(st.limit, st.limitOpen * 8000 / 10_000);
        _draw(alice, acct, 300e6);
        _draw(alice, acct, 200e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.ClosedDrawCapExceeded.selector, 1, 0));
        acct.draw(1, alice);
        // next local day the cap resets
        vm.warp(block.timestamp + 1 days);
        _touchFeeds();
        _draw(alice, acct, 500e6);
        assertEq(acct.closedDrawn(), 500e6);
        // once open, the cap no longer applies
        _setOpen();
        _draw(alice, acct, 10_000e6);
    }

    function test_draw_closedMarket_respectsShrunkLimit() public {
        _pledge(alice, acct, aaa, 10e18); // $1000, limit open 420, closed 336
        _setClosed();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.LimitExceeded.selector, 337e18, 336e18));
        acct.draw(337e6, alice);
        _draw(alice, acct, 336e6);
    }

    function test_draw_complianceGate() public {
        _pledge(alice, acct, aaa, 100e18);
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(CreditAccount.NotAllowed.selector);
        acct.draw(1e6, alice);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(guardian);
        s.compliance.setAllowed(users, true);
        _draw(alice, acct, 1e6);
        // new accounts are gated too
        vm.prank(bob);
        vm.expectRevert(CreditAccountFactory.NotAllowed.selector);
        s.factory.createAccount();
    }

    function test_repayFromBalance_andIncomingStable() public {
        _pledge(alice, acct, aaa, 100e18);
        _draw(alice, acct, 1000e6);
        usdg.mint(address(acct), 300e6); // e.g. a payment sent to the account
        vm.prank(alice);
        uint256 repaid = acct.repayFromBalance(300e6);
        assertEq(repaid, 300e6);
        assertEq(s.pool.debtOf(address(acct)), 700e6);
        usdg.mint(address(acct), 50e6);
        vm.prank(alice);
        acct.withdrawStable(50e6, bob);
        assertEq(usdg.balanceOf(bob), 50e6);
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_noDebt_anytime() public {
        _pledge(alice, acct, aaa, 10e18);
        _setClosed();
        vm.prank(guardian);
        s.factory.pause();
        vm.prank(alice);
        acct.withdraw(address(aaa), 10e18, alice);
        assertEq(aaa.balanceOf(alice), 10e18);
        assertEq(acct.assetCount(), 0);
    }

    function test_withdraw_withDebt_checksLimit() public {
        _pledge(alice, acct, aaa, 40e18);
        _pledge(alice, acct, bbb, 8e18);
        _pledge(alice, acct, ccc, 8e18);
        _draw(alice, acct, 3000e6);
        vm.prank(alice);
        acct.withdraw(address(ccc), 4e18, alice); // still fine
        vm.prank(alice);
        vm.expectRevert();
        acct.withdraw(address(bbb), 8e18, alice); // would breach the limit
    }

    function test_withdraw_withDebt_closedOrPaused() public {
        _pledge(alice, acct, aaa, 100e18);
        _draw(alice, acct, 100e6);
        _setClosed();
        vm.prank(alice);
        vm.expectRevert(CreditAccount.MarketClosed.selector);
        acct.withdraw(address(aaa), 1e18, alice);
        _setOpen();
        vm.prank(guardian);
        s.factory.pause();
        vm.prank(alice);
        vm.expectRevert(CreditAccount.Paused.selector);
        acct.withdraw(address(aaa), 1e18, alice);
    }

    function test_withdraw_rejectsStableAndZero() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.AssetNotAccepted.selector, address(usdg)));
        acct.withdraw(address(usdg), 1, alice);
        vm.expectRevert(CreditAccount.ZeroAmount.selector);
        acct.withdraw(address(aaa), 0, alice);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ swaps

    function test_swap_rebalanceWithinLimit() public {
        _pledge(alice, acct, aaa, 100e18); // concentrated
        _draw(alice, acct, 4000e6);
        // Diversify: sell 60 AAA for BBB -> limit rises
        vm.prank(alice);
        uint256 out = acct.swap(address(aaa), address(bbb), 60e18, 0, block.timestamp);
        assertEq(out, 12e18);
        IRiskEngine.AccountState memory st = _state(acct);
        assertGt(st.limit, 4200e18);
        assertEq(acct.assetCount(), 2);
    }

    function test_swap_cannotLeaveAccountAboveLimit() public {
        _pledge(alice, acct, aaa, 40e18);
        _pledge(alice, acct, bbb, 8e18);
        _pledge(alice, acct, ccc, 8e18);
        _draw(alice, acct, 6200e6); // at the limit
        // Swapping ETF (70%) into volatile (50%) lowers the limit => must revert
        vm.prank(alice);
        vm.expectRevert();
        acct.swap(address(bbb), address(ccc), 4e18, 0, block.timestamp);
    }

    function test_swap_oracleBoundedLoss() public {
        _pledge(alice, acct, aaa, 10e18);
        dex.setSlippage(500); // 5% worse than oracle, cap is 3%
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.SwapLossTooHigh.selector, 1000e18, 950e18));
        acct.swap(address(aaa), address(bbb), 10e18, 0, block.timestamp);
    }

    function test_swap_guards() public {
        _pledge(alice, acct, aaa, 10e18);
        vm.startPrank(alice);
        vm.expectRevert(CreditAccount.InvalidSwap.selector);
        acct.swap(address(aaa), address(aaa), 1e18, 0, block.timestamp);
        vm.expectRevert(CreditAccount.InvalidSwap.selector);
        acct.swap(address(aaa), address(bbb), 0, 0, block.timestamp);
        MockERC20 junk = new MockERC20("J", "J", 18);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.AssetNotAccepted.selector, address(junk)));
        acct.swap(address(aaa), address(junk), 1e18, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(CreditAccount.AssetNotAccepted.selector, address(junk)));
        acct.swap(address(junk), address(aaa), 1e18, 0, block.timestamp);
        vm.expectRevert("expired");
        acct.swap(address(aaa), address(bbb), 1e18, 0, block.timestamp - 1);
        vm.expectRevert("minOut");
        acct.swap(address(aaa), address(bbb), 1e18, 1e18, block.timestamp);
        vm.stopPrank();

        _setClosed();
        vm.prank(alice);
        vm.expectRevert(CreditAccount.MarketClosed.selector);
        acct.swap(address(aaa), address(bbb), 1e18, 0, block.timestamp);
        _setOpen();

        vm.prank(guardian);
        s.factory.pause();
        vm.prank(alice);
        vm.expectRevert(CreditAccount.Paused.selector);
        acct.swap(address(aaa), address(bbb), 1e18, 0, block.timestamp);
    }

    function test_swap_toAndFromStable() public {
        _pledge(alice, acct, aaa, 10e18);
        _draw(alice, acct, 100e6);
        vm.prank(alice);
        uint256 out = acct.swap(address(aaa), address(usdg), 5e18, 0, block.timestamp);
        assertEq(out, 500e6);
        vm.prank(alice);
        uint256 back = acct.swap(address(usdg), address(bbb), 500e6, 0, block.timestamp);
        assertEq(back, 1e18);
    }

    function test_swap_complianceGate() public {
        _pledge(alice, acct, aaa, 10e18);
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(CreditAccount.NotAllowed.selector);
        acct.swap(address(aaa), address(bbb), 1e18, 0, block.timestamp);
    }

    // ------------------------------------------------------------------ protocol hooks

    function test_seizeAndAutoRepayPull_onlyProtocol() public {
        vm.expectRevert(CreditAccount.NotAuthorized.selector);
        acct.seize(address(aaa), 1, bob);
        vm.expectRevert(CreditAccount.NotAuthorized.selector);
        acct.pullStableForAutoRepay(1);
        vm.prank(address(s.autoRepay));
        assertEq(acct.pullStableForAutoRepay(1), 0);
    }
}
