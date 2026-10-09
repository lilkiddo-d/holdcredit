// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governed} from "../libraries/Governed.sol";
import {Constants} from "../libraries/Constants.sol";
import {
    ICreditAccountFactory,
    ICreditAccount,
    IRiskEngine,
    IPriceOracle,
    IDexAdapter,
    ILenderPool
} from "../interfaces/IHoldcredit.sol";

/// @title SoftLiquidator
/// @notice Gentle deleveraging. When debt crosses the soft threshold (softHealth < 1), a keeper sells a
///         small slice of the account's most overweight (else most liquid x largest) stock into stablecoin
///         and repays debt. Anti-sandwich design:
///           - the contract (not the keeper) chooses the asset, the size and the venue;
///           - minimum output is derived on-chain from the oracle (max `maxSlippageBps` below oracle value);
///           - slices are capped at `maxSliceBps` of the portfolio, with a per-account cooldown;
///           - only while the US market is open (fresh prices, deepest liquidity);
///           - the transaction reverts unless soft health strictly improves.
contract SoftLiquidator is Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    ICreditAccountFactory public immutable factory;

    uint16 public maxSliceBps = 1000; // <=10% of portfolio value per call
    uint16 public maxSlippageBps = 150; // <=1.5% below oracle
    uint16 public keeperFeeBps = 50; // 0.5% of proceeds
    uint32 public cooldown = 5 minutes;
    uint256 public targetSoftHealth = 1.05e18;
    bool public permissionless;

    mapping(address => uint256) public lastSoftLiquidation;

    struct Result {
        address asset;
        uint256 amountSold;
        uint256 proceeds;
        uint256 repaid;
        uint256 keeperFee;
        uint256 healthBefore;
        uint256 healthAfter;
    }

    event SoftLiquidated(
        address indexed account,
        address indexed keeper,
        address indexed asset,
        uint256 amountSold,
        uint256 proceeds,
        uint256 repaid,
        uint256 keeperFee,
        uint256 healthBefore,
        uint256 healthAfter
    );
    event ParamsSet(uint16 maxSliceBps, uint16 maxSlippageBps, uint16 keeperFeeBps, uint32 cooldown, uint256 target);
    event PermissionlessSet(bool enabled);

    error NotKeeper();
    error NotAccount();
    error MarketClosed();
    error Healthy(uint256 softHealth);
    error CoolingDown(uint256 readyAt);
    error NothingToSell();
    error HealthNotImproved(uint256 before, uint256 afterwards);

    constructor(ICreditAccountFactory factory_, address admin, address guardian) Governed(admin, guardian) {
        _nonZero(address(factory_));
        factory = factory_;
    }

    function setParams(uint16 sliceBps, uint16 slippageBps, uint16 feeBps, uint32 cooldown_, uint256 target)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            sliceBps == 0 || sliceBps > 5000 || slippageBps > 1000 || feeBps > 200 || target < Constants.WAD
                || target > 2e18
        ) revert InvalidParam();
        maxSliceBps = sliceBps;
        maxSlippageBps = slippageBps;
        keeperFeeBps = feeBps;
        cooldown = cooldown_;
        targetSoftHealth = target;
        emit ParamsSet(sliceBps, slippageBps, feeBps, cooldown_, target);
    }

    function setPermissionless(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        permissionless = enabled;
        emit PermissionlessSet(enabled);
    }

    // =============================================================== keeper entry point

    // healthBefore is an intentional pre-trade snapshot; every external callee is protocol-owned and non-reentrant.
    // slither-disable-start reentrancy-balance
    function softLiquidate(address account, uint256 deadline) external nonReentrant whenNotPaused returns (Result memory r) {
        if (!permissionless && !hasRole(KEEPER_ROLE, msg.sender)) revert NotKeeper();
        if (!factory.isAccount(account)) revert NotAccount();
        if (factory.paused()) revert EnforcedPause();
        IRiskEngine re = factory.riskEngine();
        if (!re.marketClock().isOpen()) revert MarketClosed();
        uint256 readyAt = lastSoftLiquidation[account] + cooldown;
        if (lastSoftLiquidation[account] != 0 && block.timestamp < readyAt) revert CoolingDown(readyAt);

        uint256 minOut;
        (r.asset, r.amountSold, minOut, r.healthBefore) = _plan(re, account);
        lastSoftLiquidation[account] = block.timestamp;

        // Interactions: pull the slice, sell it, repay.
        ICreditAccount(account).seize(r.asset, r.amountSold, address(this));
        r.proceeds = _sell(r.asset, r.amountSold, minOut, deadline);
        r.keeperFee = r.proceeds.mulDiv(keeperFeeBps, Constants.BPS);
        uint256 toRepay = r.proceeds - r.keeperFee;
        r.repaid = _repay(account, toRepay);

        r.healthAfter = re.accountState(account).softHealth;
        if (r.healthAfter <= r.healthBefore) revert HealthNotImproved(r.healthBefore, r.healthAfter);

        emit SoftLiquidated(
    // slither-disable-end reentrancy-balance
            account, msg.sender, r.asset, r.amountSold, r.proceeds, r.repaid, r.keeperFee, r.healthBefore, r.healthAfter
        );
        if (r.keeperFee != 0) IERC20(factory.stable()).safeTransfer(msg.sender, r.keeperFee);
    }

    // =============================================================== views

    /// @notice Preview which asset would be sold and how much value (USD 1e18), for keepers / UI.
    function previewSlice(address account) external view returns (address asset, uint256 sliceValue, uint256 softHealth) {
        IRiskEngine re = factory.riskEngine();
        IRiskEngine.AccountState memory s = re.accountState(account);
        if (s.softHealth >= Constants.WAD || s.collateralValue == 0) return (address(0), 0, s.softHealth);
        return _choose(re, account);
    }

    // =============================================================== internals

    function _plan(IRiskEngine re, address account)
        internal
        view
        returns (address asset, uint256 amount, uint256 minOut, uint256 healthBefore)
    {
        uint256 sliceValue;
        (asset, sliceValue, healthBefore) = _choose(re, account);
        IPriceOracle oracle = re.oracle();
        amount = oracle.getAmount(asset, sliceValue);
        uint256 bal = IERC20(asset).balanceOf(account);
        if (amount > bal) amount = bal;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert NothingToSell();
        minOut = re.usdToStable(oracle.getValue(asset, amount)).mulDiv(Constants.BPS - maxSlippageBps, Constants.BPS);
    }

    function _choose(IRiskEngine re, address account)
        internal
        view
        returns (address asset, uint256 sliceValue, uint256 softHealth)
    {
        (address[] memory assets, uint256[] memory values, IRiskEngine.AccountState memory s) =
            re.accountBreakdown(account);
        if (s.softHealth >= Constants.WAD) revert Healthy(s.softHealth);
        uint256 idx = _pick(re, assets, values, s.collateralValue);
        asset = assets[idx];
        sliceValue = _sliceValue(re, asset, s, values[idx]);
        softHealth = s.softHealth;
    }

    /// @dev Most overweight asset (largest value above the concentration cap); if none is overweight,
    ///      the asset with the largest value x liquidityScore. Bounded by MAX_ASSETS_PER_ACCOUNT.
    function _pick(IRiskEngine re, address[] memory assets, uint256[] memory values, uint256 total)
        internal
        view
        returns (uint256 best)
    {
        uint256 cap = total.mulDiv(re.concentrationCapBps(), Constants.BPS);
        uint256 bestExcess = 0;
        uint256 bestScore = 0;
        bool found = false;
        for (uint256 i; i < assets.length; ++i) {
            if (values[i] > cap && values[i] - cap > bestExcess) {
                bestExcess = values[i] - cap;
                best = i;
            }
        }
        if (bestExcess != 0) return best;
        for (uint256 i; i < assets.length; ++i) {
            if (values[i] == 0) continue;
            uint256 score = values[i] * re.assetConfig(assets[i]).liquidityScore;
            if (!found || score > bestScore) {
                bestScore = score;
                best = i;
                found = true;
            }
        }
        if (!found) revert NothingToSell();
    }

    /// @dev Value V to sell so that (C - s*V) / (D - (1-f)*V) reaches the target soft health T:
    ///      V = (T*D - C) / (T*(1-f) - s). Capped by the slice limit and the position size.
    function _sliceValue(IRiskEngine re, address asset, IRiskEngine.AccountState memory s, uint256 positionValue)
        internal
        view
        returns (uint256 v)
    {
        uint256 maxSlice = s.collateralValue.mulDiv(maxSliceBps, Constants.BPS);
        uint256 t = targetSoftHealth;
        uint256 num = t.mulDiv(s.debtValue, Constants.WAD);
        num = num > s.softThreshold ? num - s.softThreshold : 0;
        uint256 lhs = t.mulDiv(Constants.BPS - maxSlippageBps - keeperFeeBps, Constants.BPS);
        uint256 sw = uint256(re.assetConfig(asset).softBps) * 1e14; // bps -> WAD
        v = lhs > sw ? num.mulDiv(Constants.WAD, lhs - sw) : maxSlice;
        if (v > maxSlice) v = maxSlice;
        if (v > positionValue) v = positionValue;
    }

    // Stablecoin balance delta measures real proceeds from the DEX call.
    // slither-disable-start reentrancy-balance
    function _sell(address asset, uint256 amount, uint256 minOut, uint256 deadline) internal returns (uint256 out) {
        IDexAdapter dex = factory.dexAdapter();
        IERC20 stable = IERC20(factory.stable());
        uint256 before = stable.balanceOf(address(this));
        IERC20(asset).forceApprove(address(dex), amount);
        uint256 reported = dex.swapExactIn(asset, address(stable), amount, minOut, address(this), deadline);
        IERC20(asset).forceApprove(address(dex), 0);
        out = stable.balanceOf(address(this)) - before;
        if (out < minOut || out < reported) revert NothingToSell();
    // slither-disable-end reentrancy-balance
    }

    function _repay(address account, uint256 amount) internal returns (uint256 repaid) {
        ILenderPool pool = factory.pool();
        IERC20 stable = IERC20(factory.stable());
        stable.forceApprove(address(pool), amount);
        repaid = pool.repay(account, amount);
        stable.forceApprove(address(pool), 0);
        if (amount > repaid) stable.safeTransfer(account, amount - repaid); // surplus stays with the owner
    }
}
