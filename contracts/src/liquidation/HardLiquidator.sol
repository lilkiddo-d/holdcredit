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
    ILenderPool
} from "../interfaces/IHoldcredit.sol";

/// @title HardLiquidator
/// @notice Last-resort, permissionless liquidation once debt exceeds the hard threshold (hardHealth < 1).
///         The liquidator repays stablecoin debt and receives collateral at an oracle price plus a bonus.
///         Runs at any hour (oracle staleness rules still apply). Close factor 50% unless the account is
///         deeply underwater or the debt is dust. Residual debt on an emptied account is written off.
contract HardLiquidator is Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    ICreditAccountFactory public immutable factory;
    address public feeCollector;

    uint16 public closeFactorBps = 5000;
    uint256 public fullLiquidationHealth = 0.95e18; // below this, 100% may be repaid
    uint256 public dustDebt; // stablecoin units; at or below, 100% may be repaid
    uint16 public bonusBps = 800; // 8% liquidation bonus
    uint16 public protocolShareBps = 1000; // 10% of the bonus goes to the FeeCollector
    uint256 public badDebtDustValue = 1e18; // collateral below $1 counts as empty for write-offs

    event HardLiquidated(
        address indexed account,
        address indexed liquidator,
        address indexed asset,
        uint256 repaid,
        uint256 seizedToLiquidator,
        uint256 protocolCut,
        uint256 hardHealthBefore
    );
    event BadDebtSettled(address indexed account, uint256 amount);
    event ParamsSet(uint16 closeFactorBps, uint256 fullLiqHealth, uint256 dustDebt, uint16 bonusBps, uint16 protocolShareBps);
    event FeeCollectorSet(address feeCollector);
    event BadDebtDustSet(uint256 value);

    error NotAccount();
    error NotLiquidatable(uint256 hardHealth);
    error NotCollateral(address asset);
    error ZeroRepay();
    error SlippageExceeded(uint256 seized, uint256 minSeized);
    error NotInsolvent();

    constructor(ICreditAccountFactory factory_, address feeCollector_, uint256 dustDebt_, address admin, address guardian)
        Governed(admin, guardian)
    {
        _nonZero(address(factory_));
        _nonZero(feeCollector_);
        factory = factory_;
        feeCollector = feeCollector_;
        dustDebt = dustDebt_;
    }

    function setParams(uint16 cf, uint256 fullHealth, uint256 dust, uint16 bonus, uint16 share)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (cf == 0 || cf > Constants.BPS || fullHealth > Constants.WAD || bonus > 2000 || share > Constants.BPS) {
            revert InvalidParam();
        }
        closeFactorBps = cf;
        fullLiquidationHealth = fullHealth;
        dustDebt = dust;
        bonusBps = bonus;
        protocolShareBps = share;
        emit ParamsSet(cf, fullHealth, dust, bonus, share);
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(fc);
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function setBadDebtDustValue(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        badDebtDustValue = v;
        emit BadDebtDustSet(v);
    }

    /// @notice Repay up to `repayAmount` of `account`'s debt and seize `asset` collateral (+bonus).
    /// @param minSeized Minimum collateral the liquidator accepts (slippage guard vs. oracle moves).
    function liquidate(address account, address asset, uint256 repayAmount, uint256 minSeized)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 repaid, uint256 seized)
    {
        if (!factory.isAccount(account)) revert NotAccount();
        IRiskEngine re = factory.riskEngine();
        if (!re.isCollateral(asset)) revert NotCollateral(asset);
        IRiskEngine.AccountState memory s = re.accountState(account);
        if (s.hardHealth >= Constants.WAD) revert NotLiquidatable(s.hardHealth);

        uint256 maxRepay = (s.hardHealth < fullLiquidationHealth || s.debt <= dustDebt)
            ? s.debt
            : s.debt.mulDiv(closeFactorBps, Constants.BPS);
        uint256 cut;
        (repaid, seized, cut) = _size(re, account, asset, repayAmount > maxRepay ? maxRepay : repayAmount);
        if (seized < minSeized) revert SlippageExceeded(seized, minSeized);

        emit HardLiquidated(account, msg.sender, asset, repaid, seized, cut, s.hardHealth);

        ILenderPool pool = factory.pool();
        IERC20 stable = IERC20(factory.stable());
        stable.safeTransferFrom(msg.sender, address(this), repaid);
        stable.forceApprove(address(pool), repaid);
        uint256 actual = pool.repay(account, repaid);
        stable.forceApprove(address(pool), 0);
        if (actual < repaid) {
            stable.safeTransfer(msg.sender, repaid - actual); // refund anything the pool did not need
            repaid = actual;
        }

        ICreditAccount(account).seize(asset, seized, msg.sender);
        if (cut != 0) ICreditAccount(account).seize(asset, cut, feeCollector);

        _maybeWriteOff(re, pool, account);
    }

    /// @notice Quote a liquidation: stablecoin to repay, collateral to the liquidator, protocol cut.
    function quote(address account, address asset, uint256 repayAmount)
        external
        view
        returns (uint256 repaid, uint256 seized, uint256 cut)
    {
        return _size(factory.riskEngine(), account, asset, repayAmount);
    }

    function _size(IRiskEngine re, address account, address asset, uint256 repay)
        internal
        view
        returns (uint256 repaid, uint256 seized, uint256 cut)
    {
        if (repay == 0) revert ZeroRepay();
        repaid = repay;
        IPriceOracle oracle = re.oracle();
        uint256 total = oracle.getAmount(asset, re.stableToUsd(repaid).mulDiv(Constants.BPS + bonusBps, Constants.BPS));
        uint256 bal = IERC20(asset).balanceOf(account);
        if (total > bal) {
            // Not enough of this asset: take all of it and shrink the repayment accordingly.
            total = bal;
            repaid = re.usdToStable(oracle.getValue(asset, bal).mulDiv(Constants.BPS, Constants.BPS + bonusBps));
            // zero/equality guard on an exact integer value (no balance-manipulation dependence)
            // slither-disable-next-line incorrect-equality
            if (repaid == 0) revert ZeroRepay();
        }
        uint256 bonusPart = total - total.mulDiv(Constants.BPS, Constants.BPS + bonusBps);
        cut = bonusPart.mulDiv(protocolShareBps, Constants.BPS);
        seized = total - cut;
    }

    /// @notice Write off residual debt of an account whose collateral is (practically) gone. Permissionless.
    function settleBadDebt(address account) external nonReentrant returns (uint256 written) {
        if (!factory.isAccount(account)) revert NotAccount();
        written = _maybeWriteOff(factory.riskEngine(), factory.pool(), account);
        if (written == 0) revert NotInsolvent();
    }

    function _maybeWriteOff(IRiskEngine re, ILenderPool pool, address account) internal returns (uint256 written) {
        IRiskEngine.AccountState memory s = re.accountState(account);
        if (s.debt == 0 || s.collateralValue >= badDebtDustValue) return 0;
        written = pool.writeOffBadDebt(account);
        emit BadDebtSettled(account, written);
    }
}
