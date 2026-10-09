// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {CreditAccount} from "../../src/core/CreditAccount.sol";
import {RiskEngine} from "../../src/core/RiskEngine.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IRiskEngine, IPriceOracle, IMarketClock} from "../../src/interfaces/IHoldcredit.sol";

contract RiskEngineTest is BaseTest {
    CreditAccount internal acct;

    function setUp() public override {
        super.setUp();
        acct = _open(alice);
    }

    function test_emptyAccount() public view {
        IRiskEngine.AccountState memory st = _state(acct);
        assertEq(st.collateralValue, 0);
        assertEq(st.limit, 0);
        assertEq(st.softHealth, type(uint256).max);
        assertEq(st.hardHealth, type(uint256).max);
        assertTrue(st.marketOpen);
    }

    function test_thresholdOrdering_andHealth() public {
        _pledge(alice, acct, aaa, 40e18);
        _pledge(alice, acct, bbb, 8e18);
        _pledge(alice, acct, ccc, 8e18);
        _draw(alice, acct, 5000e6);
        IRiskEngine.AccountState memory st = _state(acct);
        assertEq(st.limitOpen, 6200e18);
        assertEq(st.softThreshold, 4000e18 * 68 / 100 + 4000e18 * 77 / 100 + 2000e18 * 58 / 100);
        assertEq(st.hardThreshold, 4000e18 * 75 / 100 + 4000e18 * 83 / 100 + 2000e18 * 66 / 100);
        assertEq(st.debtValue, 5000e18);
        assertEq(st.softHealth, st.softThreshold * 1e18 / 5000e18);
        assertGt(st.hardHealth, st.softHealth);
    }

    function test_concentrationPenalty_onlyOnExcess() public {
        _pledge(alice, acct, aaa, 50e18); // 5000
        _pledge(alice, acct, bbb, 10e18); // 5000
        // 50/50: each excess 1000 over the 4000 cap, penalised 50% => adj 4500 each
        IRiskEngine.AccountState memory st = _state(acct);
        assertEq(st.adjustedValue, 9000e18);
        assertEq(st.limitOpen, 4500e18 * 60 / 100 + 4500e18 * 70 / 100);
    }

    function test_concentrationParamsChange() public {
        _pledge(alice, acct, aaa, 100e18);
        vm.prank(address(s.timelock));
        s.riskEngine.setConcentration(10_000, 0); // no penalty
        assertEq(_state(acct).limit, 6000e18);
        vm.prank(address(s.timelock));
        s.riskEngine.setConcentration(4000, 10_000); // full penalty on excess
        assertEq(_state(acct).limit, 2400e18);
    }

    function test_disabledAssetCountsZero() public {
        _pledge(alice, acct, aaa, 10e18);
        vm.prank(address(s.timelock));
        s.riskEngine.setAssetConfig(
            address(aaa),
            IRiskEngine.AssetConfig({enabled: false, frozen: false, ltvBps: 0, softBps: 0, hardBps: 0, liquidityScore: 0})
        );
        assertEq(_state(acct).collateralValue, 0);
        assertFalse(s.riskEngine.isCollateral(address(aaa)));
    }

    function test_previewLimit() public view {
        address[] memory a = new address[](3);
        uint256[] memory amt = new uint256[](3);
        a[0] = address(aaa);
        a[1] = address(bbb);
        a[2] = address(ccc);
        amt[0] = 40e18;
        amt[1] = 8e18;
        amt[2] = 8e18;
        (uint256 v, uint256 lo, uint256 ln) = s.riskEngine.previewLimit(a, amt);
        assertEq(v, 10_000e18);
        assertEq(lo, 6200e18);
        assertEq(ln, 6200e18);
    }

    function test_previewLimit_lengthMismatch() public {
        address[] memory a = new address[](1);
        uint256[] memory amt = new uint256[](2);
        vm.expectRevert(RiskEngine.LengthMismatch.selector);
        s.riskEngine.previewLimit(a, amt);
        address[] memory big = new address[](16);
        uint256[] memory bigAmt = new uint256[](16);
        vm.expectRevert(RiskEngine.TooManyAssets.selector);
        s.riskEngine.previewLimit(big, bigAmt);
    }

    function test_stableDepegRaisesDebtValue() public {
        _pledge(alice, acct, aaa, 100e18);
        _draw(alice, acct, 1000e6);
        usdgFeed.set(1.02e8);
        assertEq(_state(acct).debtValue, 1020e18);
        assertEq(s.riskEngine.usdToStable(1020e18), 1000e6);
        assertEq(s.riskEngine.stableToUsd(0), 0);
        assertEq(s.riskEngine.usdToStable(0), 0);
    }

    function test_listedAssets() public view {
        assertEq(s.riskEngine.listedAssetCount(), 3);
        assertEq(s.riskEngine.getListedAssets()[1], address(bbb));
        assertTrue(s.riskEngine.canReceive(address(aaa)));
        assertEq(s.riskEngine.assetConfig(address(bbb)).ltvBps, 7000);
    }

    function test_admin_validation() public {
        vm.startPrank(address(s.timelock));
        IRiskEngine.AssetConfig memory bad =
            IRiskEngine.AssetConfig({enabled: true, frozen: false, ltvBps: 7000, softBps: 6000, hardBps: 8000, liquidityScore: 50});
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setAssetConfig(address(aaa), bad);
        bad.softBps = 7500;
        bad.hardBps = 10_000;
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setAssetConfig(address(aaa), bad);
        bad.hardBps = 8000;
        bad.liquidityScore = 0;
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setAssetConfig(address(aaa), bad);
        bad.liquidityScore = 50;
        MockERC20 noFeed = new MockERC20("N", "N", 18);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setAssetConfig(address(noFeed), bad);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setAssetConfig(address(usdg), bad);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setConcentration(0, 100);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setConcentration(100, 10_001);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setClosedMarketParams(10_001, 1);
        s.riskEngine.setClosedMarketParams(5000, 10e6);
        assertEq(s.riskEngine.closedDrawCap(), 10e6);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setMaxSwapLoss(2001);
        s.riskEngine.setMaxSwapLoss(100);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setOracle(IPriceOracle(address(0)));
        s.riskEngine.setOracle(IPriceOracle(address(s.oracle)));
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        s.riskEngine.setMarketClock(IMarketClock(address(0)));
        s.riskEngine.setMarketClock(IMarketClock(address(s.clock)));
        vm.stopPrank();

        vm.expectRevert();
        s.riskEngine.setMaxSwapLoss(1);
    }

    function test_constructor_validation() public {
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        new RiskEngine(address(0), IPriceOracle(address(s.oracle)), IMarketClock(address(s.clock)), s.pool, address(usdg), 6, 0);
        vm.expectRevert(RiskEngine.InvalidConfig.selector);
        new RiskEngine(address(this), IPriceOracle(address(s.oracle)), IMarketClock(address(s.clock)), s.pool, address(usdg), 19, 0);
    }
}
