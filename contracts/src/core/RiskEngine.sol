// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "../libraries/Constants.sol";
import {
    IRiskEngine,
    IPriceOracle,
    IMarketClock,
    ILenderPool,
    ICreditAccount
} from "../interfaces/IHoldcredit.sol";

/// @title RiskEngine
/// @notice Portfolio-margin maths. For an account holding values v_i (USD, from the oracle):
///   T          = sum v_i
///   excess_i   = max(0, v_i - capBps*T)                      (the part of a position above the concentration cap)
///   adj_i      = v_i - excess_i * penaltyBps                 (concentration haircut on the excess only)
///   limitOpen  = sum adj_i * ltv_i
///   limit      = limitOpen                (market open)
///              = limitOpen * closedFactor (market closed)
///   soft       = sum adj_i * soft_i  ;  hard = sum adj_i * hard_i
///  adj_i is non-decreasing in every v_j (penalty <= 100%), so adding collateral never lowers a limit.
///  Debt is the LenderPool stablecoin debt valued through the oracle (USDG/USD feed), rounded up.
contract RiskEngine is IRiskEngine, AccessControl {
    using Math for uint256;

    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");

    IPriceOracle public oracle;
    IMarketClock public marketClock;
    ILenderPool public immutable pool;
    address public immutable stable;
    uint8 public immutable stableDecimals;

    uint16 public concentrationCapBps = 4000; // any single asset above 40% of the portfolio...
    uint16 public concentrationPenaltyBps = 5000; // ...has 50% of its excess value ignored
    uint16 public closedLimitFactorBps = 8000; // limits shrink to 80% while the market is closed
    uint256 public closedDrawCap; // max stablecoin an account may draw per closed local day
    uint16 public maxSwapLossBps = 300; // in-account swaps may lose at most 3% vs oracle

    mapping(address => AssetConfig) internal _configs;
    address[] public listedAssets;
    mapping(address => bool) public isListed;

    event AssetConfigured(address indexed asset, AssetConfig config);
    event ConcentrationSet(uint16 capBps, uint16 penaltyBps);
    event ClosedMarketParamsSet(uint16 factorBps, uint256 drawCap);
    event MaxSwapLossSet(uint16 bps);
    event OracleSet(address oracle);
    event MarketClockSet(address clock);

    error InvalidConfig();
    error LengthMismatch();
    error TooManyAssets();

    constructor(
        address admin,
        IPriceOracle oracle_,
        IMarketClock clock_,
        ILenderPool pool_,
        address stable_,
        uint8 stableDecimals_,
        uint256 closedDrawCap_
    ) {
        if (
            admin == address(0) || address(oracle_) == address(0) || address(clock_) == address(0)
                || address(pool_) == address(0) || stable_ == address(0) || stableDecimals_ > 18
        ) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);
        oracle = oracle_;
        marketClock = clock_;
        pool = pool_;
        stable = stable_;
        stableDecimals = stableDecimals_;
        closedDrawCap = closedDrawCap_;
    }

    // =============================================================== admin (Timelock)

    function setAssetConfig(address asset, AssetConfig calldata c) external onlyRole(RISK_ADMIN_ROLE) {
        if (asset == address(0) || asset == stable) revert InvalidConfig();
        if (c.enabled) {
            if (
                c.ltvBps == 0 || c.ltvBps >= c.softBps || c.softBps >= c.hardBps || c.hardBps >= Constants.BPS
                    || c.liquidityScore == 0 || c.liquidityScore > 100 || !oracle.isSupported(asset)
            ) revert InvalidConfig();
        }
        _configs[asset] = c;
        if (!isListed[asset]) {
            isListed[asset] = true;
            listedAssets.push(asset);
        }
        emit AssetConfigured(asset, c);
    }

    function setConcentration(uint16 capBps, uint16 penaltyBps) external onlyRole(RISK_ADMIN_ROLE) {
        if (capBps == 0 || capBps > Constants.BPS || penaltyBps > Constants.BPS) revert InvalidConfig();
        concentrationCapBps = capBps;
        concentrationPenaltyBps = penaltyBps;
        emit ConcentrationSet(capBps, penaltyBps);
    }

    function setClosedMarketParams(uint16 factorBps, uint256 drawCap) external onlyRole(RISK_ADMIN_ROLE) {
        if (factorBps > Constants.BPS) revert InvalidConfig();
        closedLimitFactorBps = factorBps;
        closedDrawCap = drawCap;
        emit ClosedMarketParamsSet(factorBps, drawCap);
    }

    function setMaxSwapLoss(uint16 bps) external onlyRole(RISK_ADMIN_ROLE) {
        if (bps > 2000) revert InvalidConfig();
        maxSwapLossBps = bps;
        emit MaxSwapLossSet(bps);
    }

    function setOracle(IPriceOracle o) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(o) == address(0)) revert InvalidConfig();
        oracle = o;
        emit OracleSet(address(o));
    }

    function setMarketClock(IMarketClock c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(c) == address(0)) revert InvalidConfig();
        marketClock = c;
        emit MarketClockSet(address(c));
    }

    // =============================================================== views

    function assetConfig(address asset) external view returns (AssetConfig memory) {
        return _configs[asset];
    }

    function listedAssetCount() external view returns (uint256) {
        return listedAssets.length;
    }

    function getListedAssets() external view returns (address[] memory) {
        return listedAssets;
    }

    function isCollateral(address asset) public view returns (bool) {
        return _configs[asset].enabled;
    }

    /// @notice Whether an account may add (deposit / swap into) this asset.
    function canReceive(address asset) external view returns (bool) {
        AssetConfig memory c = _configs[asset];
        return c.enabled && !c.frozen;
    }

    function accountState(address account) external view returns (AccountState memory s) {
        (,, s) = accountBreakdown(account);
    }

    function accountBreakdown(address account)
        public
        view
        returns (address[] memory assets, uint256[] memory values, AccountState memory s)
    {
        assets = ICreditAccount(account).getAssets();
        uint256 n = assets.length;
        if (n > Constants.MAX_ASSETS_PER_ACCOUNT) revert TooManyAssets();
        values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (!_configs[assets[i]].enabled) continue;
            uint256 bal = _balanceOf(assets[i], account);
            if (bal != 0) values[i] = oracle.getValue(assets[i], bal);
        }
        s = _compute(assets, values);
        s.debt = pool.debtOf(account);
        s.debtValue = stableToUsd(s.debt);
        s.softHealth = _health(s.softThreshold, s.debtValue);
        s.hardHealth = _health(s.hardThreshold, s.debtValue);
    }

    /// @notice Credit limit for a hypothetical portfolio (used by the build-your-pledge screen).
    function previewLimit(address[] calldata assets, uint256[] calldata amounts)
        external
        view
        returns (uint256 collateralValue, uint256 limitOpen, uint256 limitNow)
    {
        uint256 n = assets.length;
        if (n != amounts.length) revert LengthMismatch();
        if (n > Constants.MAX_ASSETS_PER_ACCOUNT) revert TooManyAssets();
        uint256[] memory values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (_configs[assets[i]].enabled && amounts[i] != 0) values[i] = oracle.getValue(assets[i], amounts[i]);
        }
        AccountState memory s = _compute(assets, values);
        return (s.collateralValue, s.limitOpen, s.limit);
    }

    function stableToUsd(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        uint256 scaled = amount * 10 ** (18 - stableDecimals);
        return scaled.mulDiv(oracle.getPrice(stable), Constants.WAD, Math.Rounding.Ceil);
    }

    function usdToStable(uint256 valueWad) public view returns (uint256) {
        if (valueWad == 0) return 0;
        return valueWad.mulDiv(Constants.WAD, oracle.getPrice(stable)) / 10 ** (18 - stableDecimals);
    }

    // =============================================================== internals

    function _compute(address[] memory assets, uint256[] memory values) internal view returns (AccountState memory s) {
        uint256 n = assets.length;
        uint256 total = 0;
        for (uint256 i; i < n; ++i) {
            total += values[i];
        }
        s.collateralValue = total;
        s.marketOpen = marketClock.isOpen();
        if (total == 0) return s;
        uint256 cap = total.mulDiv(concentrationCapBps, Constants.BPS);
        for (uint256 i; i < n; ++i) {
            uint256 v = values[i];
            if (v == 0) continue;
            if (v > cap) v -= (v - cap).mulDiv(concentrationPenaltyBps, Constants.BPS);
            AssetConfig memory c = _configs[assets[i]];
            s.adjustedValue += v;
            s.limitOpen += v.mulDiv(c.ltvBps, Constants.BPS);
            s.softThreshold += v.mulDiv(c.softBps, Constants.BPS);
            s.hardThreshold += v.mulDiv(c.hardBps, Constants.BPS);
        }
        s.limit = s.marketOpen ? s.limitOpen : s.limitOpen.mulDiv(closedLimitFactorBps, Constants.BPS);
    }

    function _health(uint256 threshold, uint256 debtValue) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        return threshold.mulDiv(Constants.WAD, debtValue);
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }
}
