// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {OracleAdapter} from "../../src/periphery/OracleAdapter.sol";
import {MarketClock} from "../../src/periphery/MarketClock.sol";
import {MockAggregator, MockERC20} from "../mocks/Mocks.sol";
import {IMarketClock} from "../../src/interfaces/IHoldcredit.sol";

contract OracleAdapterTest is BaseTest {
    function test_price_scaling() public view {
        assertEq(s.oracle.getPrice(address(aaa)), 100e18);
        assertEq(s.oracle.getValue(address(aaa), 2e18), 200e18);
        assertEq(s.oracle.getAmount(address(aaa), 200e18), 2e18);
        assertEq(s.oracle.getValue(address(usdg), 5e6), 5e18);
        assertEq(s.oracle.getValue(address(aaa), 0), 0);
        assertEq(s.oracle.getAmount(address(aaa), 0), 0);
        assertTrue(s.oracle.isSupported(address(aaa)));
        assertEq(s.oracle.feedConfig(address(aaa)).primary, address(aaaFeed));
    }

    function test_staleness_dependsOnMarket() public {
        vm.warp(block.timestamp + 26 hours);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(aaaFeed), aaaFeed.updatedAt()));
        s.oracle.getPrice(address(aaa));
        _setClosed(); // weekend tolerance (4 days)
        assertEq(s.oracle.getPrice(address(aaa)), 100e18);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert();
        s.oracle.getPrice(address(aaa));
    }

    function test_invalidAnswers() public {
        aaaFeed.set(0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(aaaFeed)));
        s.oracle.getPrice(address(aaa));
        aaaFeed.set(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(aaaFeed)));
        s.oracle.getPrice(address(aaa));
        aaaFeed.setWithTime(100e8, block.timestamp + 1);
        vm.expectRevert();
        s.oracle.getPrice(address(aaa));
        aaaFeed.setWithTime(100e8, 0);
        vm.expectRevert();
        s.oracle.getPrice(address(aaa));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedAsset.selector, address(this)));
        s.oracle.getPrice(address(this));
    }

    function test_secondaryDeviation() public {
        MockAggregator second = new MockAggregator(18, 101e18);
        vm.prank(address(s.timelock));
        s.oracle.setFeed(
            address(aaa),
            OracleAdapter.FeedConfig({
                primary: address(aaaFeed),
                secondary: address(second),
                maxStalenessOpen: 90_000,
                maxStalenessClosed: 345_600,
                maxDeviationBps: 200,
                tokenDecimals: 18,
                checkTokenPause: true
            })
        );
        assertEq(s.oracle.getPrice(address(aaa)), 100e18);
        second.set(103e18);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceDeviation.selector, address(aaa), 100e18, 103e18));
        s.oracle.getPrice(address(aaa));
    }

    function test_tokenOraclePaused() public {
        aaa.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.OraclePausedForCorporateAction.selector, address(aaa)));
        s.oracle.getPrice(address(aaa));
        // assets without the flag (USDG) are fine even if checkTokenPause were set
        assertEq(s.oracle.getPrice(address(usdg)), 1e18);
    }

    function test_tokenWithoutPauseFlag_ignored() public {
        MockAggregator f = new MockAggregator(8, 7e8);
        vm.prank(address(s.timelock));
        s.oracle.setFeed(
            address(f), // an address with no oraclePaused() -> try/catch path
            OracleAdapter.FeedConfig({
                primary: address(f),
                secondary: address(0),
                maxStalenessOpen: 100,
                maxStalenessClosed: 100,
                maxDeviationBps: 0,
                tokenDecimals: 18,
                checkTokenPause: true
            })
        );
        assertEq(s.oracle.getPrice(address(f)), 7e18);
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        vm.prank(address(s.timelock));
        s.oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerGracePeriod.selector);
        s.oracle.getPrice(address(aaa));
        vm.warp(block.timestamp + 2 hours);
        _touchFeeds();
        assertEq(s.oracle.getPrice(address(aaa)), 100e18);
        seq.set(1);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        s.oracle.getPrice(address(aaa));
    }

    function test_setFeed_validation() public {
        vm.startPrank(address(s.timelock));
        OracleAdapter.FeedConfig memory c = OracleAdapter.FeedConfig({
            primary: address(0),
            secondary: address(0),
            maxStalenessOpen: 1,
            maxStalenessClosed: 1,
            maxDeviationBps: 0,
            tokenDecimals: 18,
            checkTokenPause: false
        });
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(aaa), c);
        c.primary = address(aaaFeed);
        c.maxStalenessOpen = 0;
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(aaa), c);
        c.maxStalenessOpen = 10;
        c.maxStalenessClosed = 5;
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(aaa), c);
        c.maxStalenessClosed = 10;
        c.tokenDecimals = 37;
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(aaa), c);
        c.tokenDecimals = 18;
        MockAggregator d19 = new MockAggregator(19, 1);
        c.primary = address(d19);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(aaa), c);
        c.primary = address(aaaFeed);
        c.secondary = address(aaaFeed);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector); // deviation 0 with a secondary
        s.oracle.setFeed(address(aaa), c);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setFeed(address(0), c);
        s.oracle.removeFeed(address(ccc));
        assertFalse(s.oracle.isSupported(address(ccc)));
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        s.oracle.setMarketClock(IMarketClock(address(0)));
        s.oracle.setMarketClock(IMarketClock(address(s.clock)));
        vm.stopPrank();
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        new OracleAdapter(address(0), IMarketClock(address(s.clock)));
    }
}

contract MarketClockTest is BaseTest {
    MarketClock internal clock;

    function setUp() public override {
        super.setUp();
        clock = new MarketClock(address(this), guardian);
    }

    function _ts(uint256 y, uint256 m, uint256 d, uint256 hourUtc, uint256 minuteUtc) internal view returns (uint256) {
        return clock.daysFromCivil(y, m, d) * 1 days + hourUtc * 1 hours + minuteUtc * 1 minutes;
    }

    function test_calendarMath_roundTrip() public view {
        assertEq(clock.daysFromCivil(1970, 1, 1), 0);
        assertEq(clock.daysFromCivil(2026, 10, 8), 20_734);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(20_734);
        assertEq(y, 2026);
        assertEq(m, 10);
        assertEq(d, 8);
        (y, m, d) = clock.civilFromDays(clock.daysFromCivil(2028, 2, 29));
        assertEq(y * 10_000 + m * 100 + d, 20_280_229);
        (y, m, d) = clock.civilFromDays(clock.daysFromCivil(2027, 1, 15));
        assertEq(y * 10_000 + m * 100 + d, 20_270_115);
    }

    function test_dstBoundaries_2026() public view {
        assertFalse(clock.isDst(_ts(2026, 3, 8, 6, 59)));
        assertTrue(clock.isDst(_ts(2026, 3, 8, 7, 0)));
        assertTrue(clock.isDst(_ts(2026, 11, 1, 5, 59)));
        assertFalse(clock.isDst(_ts(2026, 11, 1, 6, 0)));
    }

    function test_regularSession_summer() public view {
        // Thu 2026-10-08 (EDT, UTC-4)
        assertFalse(clock.isOpenAt(_ts(2026, 10, 8, 13, 29))); // 09:29 ET
        assertTrue(clock.isOpenAt(_ts(2026, 10, 8, 13, 30))); // 09:30 ET
        assertTrue(clock.isOpenAt(_ts(2026, 10, 8, 19, 59))); // 15:59 ET
        assertFalse(clock.isOpenAt(_ts(2026, 10, 8, 20, 0))); // 16:00 ET
        assertFalse(clock.isOpenAt(_ts(2026, 10, 10, 15, 0))); // Saturday
        assertFalse(clock.isOpenAt(_ts(2026, 10, 11, 15, 0))); // Sunday
    }

    function test_regularSession_winter() public view {
        // Wed 2026-12-02 (EST, UTC-5)
        assertFalse(clock.isOpenAt(_ts(2026, 12, 2, 14, 29)));
        assertTrue(clock.isOpenAt(_ts(2026, 12, 2, 14, 30)));
        assertFalse(clock.isOpenAt(_ts(2026, 12, 2, 21, 0)));
    }

    function test_holidaysAndEarlyClose() public {
        uint256 thanksgiving = clock.daysFromCivil(2026, 11, 26);
        uint256[] memory days_ = new uint256[](1);
        days_[0] = thanksgiving;
        vm.prank(guardian);
        clock.setHolidays(days_, true);
        assertFalse(clock.isOpenAt(_ts(2026, 11, 26, 16, 0)));
        vm.prank(guardian);
        clock.setEarlyClose(thanksgiving + 1, 780); // 13:00 ET Friday
        assertTrue(clock.isOpenAt(_ts(2026, 11, 27, 17, 59))); // 12:59 EST
        assertFalse(clock.isOpenAt(_ts(2026, 11, 27, 18, 0))); // 13:00 EST
        vm.expectRevert(MarketClock.InvalidSession.selector);
        vm.prank(guardian);
        clock.setEarlyClose(thanksgiving, 1441);
    }

    function test_modes_andPermissions() public {
        vm.warp(_ts(2026, 10, 8, 15, 0));
        assertTrue(clock.isOpen());
        assertEq(clock.currentDay(), 20_734);
        vm.prank(guardian);
        clock.setMode(MarketClock.Mode.ForceClosed);
        assertFalse(clock.isOpen());
        vm.prank(guardian);
        vm.expectRevert(MarketClock.Unauthorized.selector);
        clock.setMode(MarketClock.Mode.ForceOpen);
        vm.prank(bob);
        vm.expectRevert(MarketClock.Unauthorized.selector);
        clock.setMode(MarketClock.Mode.Auto);
        clock.setMode(MarketClock.Mode.ForceOpen);
        vm.warp(_ts(2026, 10, 10, 15, 0));
        assertTrue(clock.isOpen());
        vm.prank(guardian);
        clock.setMode(MarketClock.Mode.Auto);
        assertFalse(clock.isOpen());
    }

    function test_setSession() public {
        vm.expectRevert(MarketClock.InvalidSession.selector);
        clock.setSession(600, 500);
        vm.expectRevert(MarketClock.InvalidSession.selector);
        clock.setSession(0, 1441);
        clock.setSession(240, 1200); // 04:00-20:00 ET (extended hours)
        assertTrue(clock.isOpenAt(_ts(2026, 10, 8, 9, 0))); // 05:00 ET
        vm.prank(guardian);
        vm.expectRevert();
        clock.setSession(1, 2);
    }
}
