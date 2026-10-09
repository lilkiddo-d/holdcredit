// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracle, IMarketClock} from "../interfaces/IHoldcredit.sol";
import {IAggregatorV3, IStockToken} from "../interfaces/IExternal.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title OracleAdapter
/// @notice Chainlink-backed IPriceOracle with:
///   - staleness limits that depend on MarketClock (24/5 equity feeds legitimately go quiet on weekends),
///   - optional secondary feed + max deviation between the two,
///   - optional L2 sequencer-uptime feed with grace period (none is published for Robinhood Chain yet),
///   - the stock token's own `oraclePaused()` corporate-action flag.
///   The whole adapter is swappable: RiskEngine points at any IPriceOracle via the Timelock.
contract OracleAdapter is IPriceOracle, AccessControl {
    using Math for uint256;

    struct FeedConfig {
        address primary;
        address secondary; // optional, address(0) = none
        uint32 maxStalenessOpen; // seconds, used while the market is open
        uint32 maxStalenessClosed; // seconds, used while the market is closed
        uint16 maxDeviationBps; // max primary/secondary disagreement
        uint8 tokenDecimals;
        bool checkTokenPause; // call IStockToken(asset).oraclePaused()
    }

    IMarketClock public marketClock;
    address public sequencerUptimeFeed; // optional
    uint32 public sequencerGracePeriod = 1 hours;
    mapping(address => FeedConfig) internal _feeds;

    event FeedSet(address indexed asset, FeedConfig config);
    event FeedRemoved(address indexed asset);
    event MarketClockSet(address clock);
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error UnsupportedAsset(address asset);
    error InvalidPrice(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error PriceDeviation(address asset, uint256 primary, uint256 secondary);
    error OraclePausedForCorporateAction(address asset);
    error SequencerDown();
    error SequencerGracePeriod();
    error InvalidConfig();

    constructor(address admin, IMarketClock clock) {
        if (admin == address(0) || address(clock) == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        marketClock = clock;
    }

    // ------------------------------------------------------------------ admin

    function setFeed(address asset, FeedConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            asset == address(0) || cfg.primary == address(0) || cfg.maxStalenessOpen == 0
                || cfg.maxStalenessClosed < cfg.maxStalenessOpen || cfg.tokenDecimals > 36
                || IAggregatorV3(cfg.primary).decimals() > 18
                || (cfg.secondary != address(0) && (IAggregatorV3(cfg.secondary).decimals() > 18 || cfg.maxDeviationBps == 0))
        ) revert InvalidConfig();
        _feeds[asset] = cfg;
        emit FeedSet(asset, cfg);
    }

    function removeFeed(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete _feeds[asset];
        emit FeedRemoved(asset);
    }

    function setMarketClock(IMarketClock clock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(clock) == address(0)) revert InvalidConfig();
        marketClock = clock;
        emit MarketClockSet(address(clock));
    }

    function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // ------------------------------------------------------------------ views

    function feedConfig(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function isSupported(address asset) external view returns (bool) {
        return _feeds[asset].primary != address(0);
    }

    function getPrice(address asset) public view returns (uint256) {
        FeedConfig memory cfg = _feeds[asset];
        if (cfg.primary == address(0)) revert UnsupportedAsset(asset);
        _checkSequencer();
        if (cfg.checkTokenPause) {
            // Stock tokens expose oraclePaused() during corporate actions; non-stock assets may not.
            try IStockToken(asset).oraclePaused() returns (bool p) {
                if (p) revert OraclePausedForCorporateAction(asset);
            } catch {}
        }
        uint256 maxAge = marketClock.isOpen() ? cfg.maxStalenessOpen : cfg.maxStalenessClosed;
        uint256 price = _read(cfg.primary, maxAge);
        if (cfg.secondary != address(0)) {
            uint256 p2 = _read(cfg.secondary, maxAge);
            uint256 diff = price > p2 ? price - p2 : p2 - price;
            if (diff * Constants.BPS > Math.min(price, p2) * cfg.maxDeviationBps) {
                revert PriceDeviation(asset, price, p2);
            }
        }
        return price;
    }

    function getValue(address asset, uint256 amount) external view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulDiv(getPrice(asset), 10 ** _feeds[asset].tokenDecimals);
    }

    function getAmount(address asset, uint256 valueWad) external view returns (uint256) {
        if (valueWad == 0) return 0;
        return valueWad.mulDiv(10 ** _feeds[asset].tokenDecimals, getPrice(asset));
    }

    function _read(address feed, uint256 maxAge) internal view returns (uint256) {
        // Chainlink fields deliberately unused (startedAt / roundId semantics per Chainlink docs)
        // slither-disable-next-line unused-return
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(feed);
        if (answeredInRound < roundId) revert StalePrice(feed, updatedAt);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StalePrice(feed, updatedAt);
        }
        uint8 dec = IAggregatorV3(feed).decimals();
        return uint256(answer) * 10 ** (18 - dec);
    }

    function _checkSequencer() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;
        // Chainlink L2 sequencer feed: answer 0 = up, startedAt = last status change (per Chainlink docs).
        // Chainlink fields deliberately unused (startedAt / roundId semantics per Chainlink docs)
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = IAggregatorV3(feed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
    }
}
