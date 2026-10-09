// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {CreditAccountFactory} from "../../src/core/CreditAccountFactory.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {AutoRepay} from "../../src/periphery/AutoRepay.sol";
import {FeeCollector} from "../../src/periphery/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/periphery/ProjectTokenHooks.sol";
import {DexAdapter} from "../../src/periphery/DexAdapter.sol";
import {HoldcreditTimelock} from "../../src/governance/HoldcreditTimelock.sol";
import {Governed} from "../../src/libraries/Governed.sol";
import {MockERC20, MockFeeToken, MockSwapRouter} from "../mocks/Mocks.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";
import {
    IDexAdapter,
    IRiskEngine,
    IMarketClock,
    IComplianceRegistry,
    IProjectTokenHooks,
    ILenderPool
} from "../../src/interfaces/IHoldcredit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AutoRepayTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
        _pledge(alice, acct, bbb, 100e18);
        _draw(alice, acct, 10_000e6);
    }

    function test_plan_fromIncomingStable_thenMonthly() public {
        vm.prank(alice);
        s.autoRepay.setPlan(address(acct), 1000e6, false);
        assertTrue(s.autoRepay.isDue(address(acct)));
        usdg.mint(address(acct), 1500e6); // salary sent to the account
        vm.prank(keeper);
        uint256 repaid = s.autoRepay.execute(address(acct));
        assertEq(repaid, 1000e6);
        assertEq(usdg.balanceOf(address(acct)), 500e6);
        assertEq(s.autoRepay.nextExecution(address(acct)), block.timestamp + 30 days);
        assertFalse(s.autoRepay.isDue(address(acct)));
        vm.expectRevert(abi.encodeWithSelector(AutoRepay.NotDue.selector, block.timestamp + 30 days));
        s.autoRepay.execute(address(acct));
        vm.warp(block.timestamp + 30 days);
        _touchFeeds();
        s.autoRepay.execute(address(acct)); // only 500 available, partial
        assertEq(usdg.balanceOf(address(acct)), 0);
    }

    function test_plan_pullsFromOwnerWallet() public {
        vm.startPrank(alice);
        s.autoRepay.setPlan(address(acct), 2000e6, true);
        usdg.approve(address(s.autoRepay), 1500e6);
        vm.stopPrank();
        usdg.mint(address(acct), 300e6);
        uint256 debtBefore = s.pool.debtOf(address(acct));
        uint256 repaid = s.autoRepay.execute(address(acct));
        assertEq(repaid, 1800e6); // 300 from account + 1500 (allowance-capped) from wallet
        assertEq(s.pool.debtOf(address(acct)), debtBefore - 1800e6);
    }

    function test_plan_cappedByDebt_andNothingToRepay() public {
        CreditAccount b = _open(bob);
        vm.prank(bob);
        s.autoRepay.setPlan(address(b), 100e6, true);
        vm.expectRevert(AutoRepay.NothingToRepay.selector);
        s.autoRepay.execute(address(b)); // no debt
        _pledge(bob, b, bbb, 1e18);
        _draw(bob, b, 50e6);
        vm.expectRevert(AutoRepay.NothingToRepay.selector);
        s.autoRepay.execute(address(b)); // no funds anywhere
        usdg.mint(address(b), 80e6);
        assertEq(s.autoRepay.execute(address(b)), 50e6);
        assertEq(s.pool.debtOf(address(b)), 0);
    }

    function test_plan_auth_cancel_pause() public {
        vm.expectRevert(AutoRepay.NotAccountOwner.selector);
        s.autoRepay.setPlan(address(acct), 1, false);
        vm.prank(alice);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.autoRepay.setPlan(address(acct), 0, false);
        vm.prank(alice);
        s.autoRepay.setPlan(address(acct), 1e6, false);
        vm.prank(guardian);
        s.autoRepay.pause();
        vm.expectRevert();
        s.autoRepay.execute(address(acct));
        vm.prank(guardian);
        s.autoRepay.unpause();
        vm.prank(alice);
        s.autoRepay.cancelPlan(address(acct));
        vm.expectRevert(AutoRepay.NoActivePlan.selector);
        s.autoRepay.execute(address(acct));
        assertFalse(s.autoRepay.isDue(address(acct)));
    }
}

contract TokenAndFeesTest is BaseTest {
    MockERC20 internal hold; // mock project token - tests only
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        hold = new MockERC20("Hold", "HOLD", 18);
        acct = _open(alice);
        _pledge(alice, acct, bbb, 1000e18);
        _pledge(alice, acct, aaa, 5000e18);
    }

    function _setToken() internal {
        vm.prank(address(s.timelock));
        s.hooks.setProjectToken(address(hold));
    }

    function _stake(address u, uint256 amt) internal {
        hold.mint(u, amt);
        vm.startPrank(u);
        hold.approve(address(s.hooks), amt);
        s.hooks.stake(amt);
        vm.stopPrank();
    }

    function test_tokenFeaturesDisabledUntilSet() public {
        assertFalse(s.hooks.isActive());
        assertFalse(s.hooks.isDiscounted(alice));
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        s.hooks.stake(1);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        s.hooks.requestUnstake(1);
        // fees all go to treasury
        usdg.mint(address(s.feeCollector), 100e6);
        (uint256 st, uint256 tr) = s.feeCollector.distribute();
        assertEq(st, 0);
        assertEq(tr, 100e6);
        assertEq(usdg.balanceOf(treasury), 100e6);
        (st, tr) = s.feeCollector.distribute();
        assertEq(tr, 0);
    }

    function test_setProjectToken_onceViaAdmin() public {
        vm.expectRevert();
        s.hooks.setProjectToken(address(hold)); // not the timelock
        vm.startPrank(address(s.timelock));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(address(usdg));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        s.hooks.setProjectToken(bob); // EOA
        s.hooks.setProjectToken(address(hold));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        s.hooks.setProjectToken(address(aaa));
        vm.stopPrank();
        assertTrue(s.hooks.isActive());
        assertEq(s.hooks.minStakeForDiscount(), 1000e18);
    }

    function test_stakingGivesDiscountTier_andUnstakeRemovesIt() public {
        _setToken();
        _draw(alice, acct, 100_000e6);
        assertEq(s.pool.tierOf(address(acct)), 0);
        _stake(alice, 1000e18);
        assertTrue(s.hooks.isDiscounted(alice));
        assertEq(s.pool.tierOf(address(acct)), 1); // synced on stake
        vm.prank(alice);
        s.hooks.requestUnstake(1);
        assertEq(s.pool.tierOf(address(acct)), 0); // synced on unstake request
        vm.prank(alice);
        vm.expectRevert();
        s.hooks.withdrawUnstaked();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        s.hooks.withdrawUnstaked();
        assertEq(hold.balanceOf(alice), 1);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        s.hooks.withdrawUnstaked();
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.Insufficient.selector);
        s.hooks.requestUnstake(type(uint128).max);
    }

    function test_interestSpreadStreamsToStakers() public {
        _setToken();
        _stake(bob, 500e18);
        _stake(alice, 1500e18);
        _draw(alice, acct, 300_000e6);
        vm.warp(block.timestamp + 180 days);
        _touchFeeds();
        uint256 collected = s.pool.collectReserves();
        assertGt(collected, 0);
        (uint256 toStakers, uint256 toTreasury) = s.feeCollector.distribute();
        assertEq(toStakers, collected / 2);
        assertEq(toStakers + toTreasury, collected);
        vm.warp(block.timestamp + 7 days);
        uint256 eb = s.hooks.earned(bob);
        uint256 ea = s.hooks.earned(alice);
        assertApproxEqRel(ea, eb * 3, 0.0001e18);
        assertApproxEqAbs(ea + eb, toStakers, 10);
        vm.prank(bob);
        uint256 got = s.hooks.claimRewards();
        assertEq(got, eb);
        assertEq(usdg.balanceOf(bob), eb);
        vm.prank(bob);
        assertEq(s.hooks.claimRewards(), 0);
    }

    function test_rewardStreaming_overlapAndJIT() public {
        _setToken();
        _stake(bob, 1000e18);
        usdg.mint(address(s.feeCollector), 700e6);
        s.feeCollector.distribute(); // 350 to stakers over 7 days
        vm.warp(block.timestamp + 1 days);
        // a just-in-time staker only earns from now on
        _stake(alice, 1000e18);
        usdg.mint(address(s.feeCollector), 700e6);
        s.feeCollector.distribute(); // leftover rolls into new period
        vm.warp(block.timestamp + 7 days);
        assertGt(s.hooks.earned(bob), s.hooks.earned(alice));
        assertApproxEqAbs(s.hooks.earned(bob) + s.hooks.earned(alice), 700e6, 100);
    }

    function test_notifyReward_guards() public {
        vm.expectRevert();
        s.hooks.notifyReward(1);
        vm.startPrank(address(s.feeCollector));
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        s.hooks.notifyReward(1);
        vm.stopPrank();
        _setToken();
        vm.startPrank(address(s.feeCollector));
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        s.hooks.notifyReward(1);
        vm.stopPrank();
        _stake(bob, 1e18);
        vm.startPrank(address(s.feeCollector));
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        s.hooks.notifyReward(0);
        vm.stopPrank();
    }

    function test_feeOnTransferStake() public {
        MockFeeToken fee = new MockFeeToken();
        vm.prank(address(s.timelock));
        s.hooks.setProjectToken(address(fee));
        fee.mint(bob, 100e18);
        vm.startPrank(bob);
        fee.approve(address(s.hooks), 100e18);
        s.hooks.stake(100e18);
        vm.stopPrank();
        assertEq(s.hooks.stakedOf(bob), 99e18);
        assertEq(s.hooks.totalStaked(), 99e18);
    }

    function test_stake_guards() public {
        _setToken();
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        s.hooks.stake(0);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        s.hooks.requestUnstake(0);
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        hold.mint(bob, 1e18);
        vm.startPrank(bob);
        hold.approve(address(s.hooks), 1e18);
        vm.expectRevert(ProjectTokenHooks.NotAllowed.selector);
        s.hooks.stake(1e18);
        vm.stopPrank();
    }

    function test_hooks_admin() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(Governed.InvalidParam.selector);
        s.hooks.setDiscountThreshold(0);
        s.hooks.setDiscountThreshold(5e18);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.hooks.setUnstakeCooldown(31 days);
        s.hooks.setUnstakeCooldown(1 days);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.hooks.setRewardsDuration(1 hours);
        s.hooks.setRewardsDuration(14 days);
        s.hooks.setWiring(s.factory, ILenderPool(address(s.pool)));
        vm.stopPrank();
        assertEq(s.hooks.minStakeForDiscount(), 5e18);
        assertEq(s.hooks.rewardsDuration(), 14 days);
    }

    function test_hooks_noWiring_stakeStillWorks() public {
        ProjectTokenHooks h = new ProjectTokenHooks(IERC20(address(usdg)), address(this), guardian);
        h.setProjectToken(address(hold));
        hold.mint(address(this), 1e18);
        hold.approve(address(h), 1e18);
        h.stake(1e18);
        assertEq(h.totalStaked(), 1e18);
    }

    function test_feeCollector_admin_sweep() public {
        aaa.mint(address(s.feeCollector), 5e18);
        vm.startPrank(address(s.timelock));
        s.feeCollector.sweep(IERC20(address(aaa)), 5e18);
        vm.expectRevert(FeeCollector.CannotSweepStable.selector);
        s.feeCollector.sweep(IERC20(address(usdg)), 1);
        vm.expectRevert(Governed.InvalidParam.selector);
        s.feeCollector.setStakerShare(10_001);
        s.feeCollector.setStakerShare(3000);
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.feeCollector.setTreasury(address(0));
        s.feeCollector.setTreasury(bob);
        s.feeCollector.setHooks(IProjectTokenHooks(address(0)));
        vm.stopPrank();
        assertEq(aaa.balanceOf(treasury), 5e18);
        usdg.mint(address(s.feeCollector), 10e6);
        s.feeCollector.distribute();
        assertEq(usdg.balanceOf(bob), 10e6);
    }
}

contract DexAdapterTest is BaseTest {
    MockSwapRouter internal router;
    DexAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        router = new MockSwapRouter();
        adapter = new DexAdapter(ISwapRouter02(address(router)), address(usdg), address(this));
        adapter.setHubFee(address(aaa), 500);
        adapter.setHubFee(address(bbb), 3000);
        aaa.mint(address(this), 100e18);
        aaa.approve(address(adapter), type(uint256).max);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(adapter), type(uint256).max);
    }

    function test_singleHop_bothDirections() public {
        router.setRate(100e6); // 1 AAA (1e18) -> 100 USDG (1e8 units)
        uint256 out = adapter.swapExactIn(address(aaa), address(usdg), 1e18, 99e6, bob, block.timestamp);
        assertEq(out, 100e6);
        assertEq(router.lastFee(), 500);
        router.setRate(1e28); // 1 USDG unit -> 1e10 BBB units
        out = adapter.swapExactIn(address(usdg), address(bbb), 1e6, 0, bob, block.timestamp);
        assertEq(router.lastFee(), 3000);
        assertEq(out, 1e16);
    }

    function test_twoHop_viaHub() public {
        router.setRate(0.2e18);
        uint256 out = adapter.swapExactIn(address(aaa), address(bbb), 10e18, 2e18, bob, block.timestamp);
        assertEq(out, 2e18);
        assertEq(
            router.lastPath(), abi.encodePacked(address(aaa), uint24(500), address(usdg), uint24(3000), address(bbb))
        );
    }

    function test_guards() public {
        vm.expectRevert(DexAdapter.Expired.selector);
        adapter.swapExactIn(address(aaa), address(usdg), 1, 0, bob, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.Unroutable.selector, address(ccc), address(usdg)));
        adapter.swapExactIn(address(ccc), address(usdg), 1, 0, bob, block.timestamp);
        assertFalse(adapter.supportsPair(address(aaa), address(aaa)));
        assertFalse(adapter.supportsPair(address(usdg), address(ccc)));
        assertTrue(adapter.supportsPair(address(usdg), address(aaa)));
        router.setShortfall(1);
        vm.expectRevert(abi.encodeWithSelector(DexAdapter.InsufficientOutput.selector, 1e18 - 1, 1e18));
        adapter.swapExactIn(address(aaa), address(usdg), 1e18, 1e18, bob, block.timestamp);
        vm.expectRevert(DexAdapter.InvalidFee.selector);
        adapter.setHubFee(address(aaa), 123);
        vm.expectRevert(DexAdapter.InvalidFee.selector);
        adapter.setHubFee(address(usdg), 500);
        adapter.setHubFee(address(aaa), 0);
        vm.expectRevert(DexAdapter.ZeroAddress.selector);
        new DexAdapter(ISwapRouter02(address(0)), address(usdg), address(this));
    }
}

contract GovernanceTest is BaseTest {
    function test_timelock_48hDelay_setProjectToken() public {
        MockERC20 hold = new MockERC20("Hold", "HOLD", 18);
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(hold)));
        s.timelock.schedule(address(s.hooks), 0, data, bytes32(0), bytes32("hold"), 48 hours);
        vm.expectRevert();
        s.timelock.execute(address(s.hooks), 0, data, bytes32(0), bytes32("hold"));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(bob); // anyone may execute once matured
        s.timelock.execute(address(s.hooks), 0, data, bytes32(0), bytes32("hold"));
        assertEq(s.hooks.projectToken(), address(hold));
    }

    function test_timelock_rejectsShortDelay() public {
        address[] memory a = new address[](0);
        vm.expectRevert(HoldcreditTimelock.DelayTooShort.selector);
        new HoldcreditTimelock(47 hours, a, a);
        vm.expectRevert();
        s.timelock.schedule(address(s.hooks), 0, "", bytes32(0), bytes32(0), 1 hours);
    }

    function test_deployerHasNoPowersAfterHandover() public {
        bytes32 admin = 0x00;
        assertFalse(s.pool.hasRole(admin, address(this)));
        assertFalse(s.factory.hasRole(admin, address(this)));
        assertFalse(s.riskEngine.hasRole(s.riskEngine.RISK_ADMIN_ROLE(), address(this)));
        assertTrue(s.pool.hasRole(admin, address(s.timelock)));
        assertTrue(s.riskEngine.hasRole(s.riskEngine.RISK_ADMIN_ROLE(), address(s.timelock)));
        assertTrue(s.hooks.hasRole(admin, address(s.timelock)));
        assertTrue(s.pool.hasRole(s.pool.GUARDIAN_ROLE(), guardian));
        assertTrue(s.soft.hasRole(s.soft.KEEPER_ROLE(), keeper));
    }

    function test_factory_setters() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setDexAdapter(IDexAdapter(address(0)));
        s.factory.setDexAdapter(IDexAdapter(address(dex)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setRiskEngine(IRiskEngine(address(0)));
        s.factory.setRiskEngine(IRiskEngine(address(s.riskEngine)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setMarketClock(IMarketClock(address(0)));
        s.factory.setMarketClock(IMarketClock(address(s.clock)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setLiquidators(address(0), address(1));
        s.factory.setLiquidators(address(s.soft), address(s.hard));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setAutoRepay(address(0));
        s.factory.setAutoRepay(address(s.autoRepay));
        s.factory.setCompliance(IComplianceRegistry(address(0)));
        vm.expectRevert(Governed.ZeroAddress.selector);
        s.factory.setModules(
            ILenderPool(address(0)), IRiskEngine(address(1)), IDexAdapter(address(1)), IMarketClock(address(1)), address(1), address(1), address(1)
        );
        vm.stopPrank();
        assertTrue(s.factory.isAllowed(bob, keccak256("DRAW")));
        vm.expectRevert(Governed.ZeroAddress.selector);
        new CreditAccountFactory(address(0), address(usdg), address(this), guardian);
    }

    function test_irm() public {
        InterestRateModel m = s.irm;
        assertEq(m.borrowRatePerYear(0), 0.03e18);
        assertEq(m.borrowRatePerYear(0.85e18), 0.12e18);
        assertEq(m.borrowRatePerYear(1e18), 0.92e18);
        assertEq(m.borrowRatePerYear(2e18), 0.92e18);
        assertEq(m.borrowRatePerSecond(1e18), uint256(0.92e18) / 365 days);
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(0, 0, 0, 0);
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(0, 0, 0, 1e18);
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(5e18, 5e18, 1e18, 0.5e18);
    }

    function test_compliance_registry() public {
        assertTrue(s.compliance.isAllowed(bob, keccak256("DRAW")));
        vm.prank(address(s.timelock));
        s.compliance.setEnabled(true);
        assertFalse(s.compliance.isAllowed(bob, keccak256("DRAW")));
        assertTrue(s.compliance.isAllowed(bob, keccak256("REPAY"))); // never gated
        vm.prank(address(s.timelock));
        s.compliance.setGated(keccak256("DRAW"), false);
        assertTrue(s.compliance.isAllowed(bob, keccak256("DRAW")));
        vm.expectRevert();
        s.compliance.setEnabled(false);
    }

    function test_guardianPauseUnpause_onlyGuardian() public {
        vm.expectRevert();
        s.factory.pause();
        vm.prank(guardian);
        s.factory.pause();
        assertTrue(s.factory.paused());
        vm.prank(guardian);
        s.factory.unpause();
        assertFalse(s.factory.paused());
    }

    function test_governed_zeroAdmin() public {
        vm.expectRevert(Governed.ZeroAddress.selector);
        new FeeCollector(IERC20(address(usdg)), treasury, address(0), guardian);
    }
}
