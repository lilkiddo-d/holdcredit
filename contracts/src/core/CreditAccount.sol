// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "../libraries/Constants.sol";
import {
    ICreditAccount,
    ICreditAccountFactory,
    IRiskEngine,
    IPriceOracle,
    IDexAdapter,
    ILenderPool
} from "../interfaces/IHoldcredit.sol";

/// @title CreditAccount
/// @notice One per user (EIP-1167 minimal proxy). Holds the user's pledged stock tokens; the debt lives in
///         the LenderPool keyed by this account's address. Every action that can reduce the safety margin
///         (draw, swap, collateral withdrawal while indebted) re-checks the RiskEngine limit afterwards.
contract CreditAccount is ICreditAccount, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    ICreditAccountFactory public factory;
    address public owner;

    address[] internal _assets;
    mapping(address => bool) public isHeld;

    /// @dev Closed-market draw bookkeeping (per America/New_York local day).
    uint256 public closedDrawDay;
    uint256 public closedDrawn;

    event Deposited(address indexed asset, uint256 amount);
    event Withdrawn(address indexed asset, uint256 amount, address indexed to);
    event StableWithdrawn(uint256 amount, address indexed to);
    event Drawn(uint256 amount, address indexed to, bool marketOpen);
    event RepaidFromBalance(uint256 amount);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Seized(address indexed by, address indexed asset, uint256 amount, address indexed to);
    event AutoRepayPulled(uint256 amount);
    event AssetTracked(address indexed asset);
    event AssetUntracked(address indexed asset);

    error NotOwner();
    error NotAuthorized();
    error Paused();
    error MarketClosed();
    error NotAllowed();
    error AssetNotAccepted(address asset);
    error TooManyAssets();
    error LimitExceeded(uint256 debtValue, uint256 limit);
    error ClosedDrawCapExceeded(uint256 requested, uint256 remaining);
    error InvalidSwap();
    error SwapLossTooHigh(uint256 valueIn, uint256 valueOut);
    error ZeroAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        factory = ICreditAccountFactory(msg.sender);
        owner = owner_;
    }

    // =============================================================== collateral

    /// @notice Pledge `amount` of an accepted stock token (pulled from the owner). Allowed while paused or
    ///         closed - adding collateral only ever improves health. `amount == 0` just starts tracking a
    ///         token that was transferred in directly.
    function deposit(address asset, uint256 amount) external onlyOwner nonReentrant {
        if (!factory.riskEngine().canReceive(asset)) revert AssetNotAccepted(asset);
        _track(asset);
        emit Deposited(asset, amount);
        if (amount != 0) IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw collateral. With outstanding debt this requires an open market, an unpaused
    ///         protocol and the post-withdrawal position to stay within the credit limit.
    function withdraw(address asset, uint256 amount, address to) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (asset == factory.stable()) revert AssetNotAccepted(asset);
        ILenderPool pool = factory.pool();
        bool indebted = pool.debtOf(address(this)) != 0;
        if (indebted) {
            if (factory.paused()) revert Paused();
            if (!factory.marketClock().isOpen()) revert MarketClosed();
        }
        IERC20(asset).safeTransfer(to, amount);
        _untrackIfEmpty(asset);
        emit Withdrawn(asset, amount, to);
        if (indebted) _requireWithinLimit();
    }

    /// @notice Stablecoin held by the account (e.g. incoming payments for auto-repay) is not collateral.
    function withdrawStable(uint256 amount, address to) external onlyOwner nonReentrant {
        emit StableWithdrawn(amount, to);
        IERC20(factory.stable()).safeTransfer(to, amount);
    }

    // =============================================================== credit line

    /// @notice Draw `amount` stablecoin from the credit line to `to`.
    function draw(uint256 amount, address to) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (factory.paused()) revert Paused();
        if (!factory.isAllowed(owner, Constants.ACTION_DRAW)) revert NotAllowed();
        IRiskEngine re = factory.riskEngine();
        IRiskEngine.AccountState memory s = re.accountState(address(this));

        if (!s.marketOpen) {
            uint256 day = factory.marketClock().currentDay();
            if (day != closedDrawDay) {
                closedDrawDay = day;
                closedDrawn = 0;
            }
            uint256 cap = re.closedDrawCap();
            uint256 remaining = cap > closedDrawn ? cap - closedDrawn : 0;
            if (amount > remaining) revert ClosedDrawCapExceeded(amount, remaining);
            closedDrawn += amount;
        }
        uint256 debtValueAfter = re.stableToUsd(s.debt + amount);
        if (debtValueAfter > s.limit) revert LimitExceeded(debtValueAfter, s.limit);

        emit Drawn(amount, to, s.marketOpen);
        factory.pool().borrow(amount, to);
        // Authoritative post-check on actual state: scaled-debt rounding can add a unit or two of debt.
        _requireWithinLimit();
    }

    /// @notice Repay using stablecoin already sitting in the account. Never paused.
    function repayFromBalance(uint256 amount) external onlyOwner nonReentrant returns (uint256 repaid) {
        ILenderPool pool = factory.pool();
        IERC20 stable = IERC20(factory.stable());
        stable.forceApprove(address(pool), amount);
        repaid = pool.repay(address(this), amount);
        stable.forceApprove(address(pool), 0);
        emit RepaidFromBalance(repaid);
    }

    // =============================================================== in-account trading

    /// @notice Swap collateral (or account stablecoin) for another accepted asset through the DexAdapter.
    ///         Requires an open market, an oracle-bounded execution price and post-swap health within limit.
    // Balance-delta accounting around the governance-set DexAdapter; function is nonReentrant and re-checks limits after.
    // slither-disable-start reentrancy-balance,reentrancy-no-eth
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amountOut)
    {
        if (factory.paused()) revert Paused();
        if (!factory.isAllowed(owner, Constants.ACTION_SWAP)) revert NotAllowed();
        if (!factory.marketClock().isOpen()) revert MarketClosed();
        if (tokenIn == tokenOut || amountIn == 0) revert InvalidSwap();

        IRiskEngine re = factory.riskEngine();
        address stable = factory.stable();
        if (tokenIn != stable && !re.isCollateral(tokenIn)) revert AssetNotAccepted(tokenIn);
        if (tokenOut != stable) {
            if (!re.canReceive(tokenOut)) revert AssetNotAccepted(tokenOut);
            _track(tokenOut);
        }

        IPriceOracle oracle = re.oracle();
        uint256 valueIn = oracle.getValue(tokenIn, amountIn);
        IDexAdapter dex = factory.dexAdapter();
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(address(dex), amountIn);
        uint256 reported = dex.swapExactIn(tokenIn, tokenOut, amountIn, minAmountOut, address(this), deadline);
        IERC20(tokenIn).forceApprove(address(dex), 0);

        // Trust only what actually arrived, and never less than what the adapter claims it delivered.
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (amountOut < minAmountOut || amountOut < reported) revert InvalidSwap();
        uint256 valueOut = oracle.getValue(tokenOut, amountOut);
        if (valueOut < valueIn.mulDiv(Constants.BPS - re.maxSwapLossBps(), Constants.BPS)) {
            revert SwapLossTooHigh(valueIn, valueOut);
        }
        if (tokenIn != stable) _untrackIfEmpty(tokenIn);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    // slither-disable-end reentrancy-balance,reentrancy-no-eth

        if (factory.pool().debtOf(address(this)) != 0) _requireWithinLimit();
    }

    // =============================================================== protocol hooks

    /// @notice Liquidators move collateral out. Their own contracts enforce every liquidation rule.
    function seize(address asset, uint256 amount, address to) external nonReentrant {
        if (msg.sender != factory.softLiquidator() && msg.sender != factory.hardLiquidator()) revert NotAuthorized();
        IERC20(asset).safeTransfer(to, amount);
        _untrackIfEmpty(asset);
        emit Seized(msg.sender, asset, amount, to);
    }

    /// @notice AutoRepay pulls up to `amount` of incoming stablecoin held by the account.
    function pullStableForAutoRepay(uint256 amount) external nonReentrant returns (uint256 pulled) {
        address ar = factory.autoRepay();
        if (msg.sender != ar) revert NotAuthorized();
        IERC20 stable = IERC20(factory.stable());
        uint256 bal = stable.balanceOf(address(this));
        pulled = amount > bal ? bal : amount;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (pulled == 0) return 0;
        emit AutoRepayPulled(pulled);
        stable.safeTransfer(ar, pulled);
    }

    // =============================================================== views

    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    // =============================================================== internals

    function _requireWithinLimit() internal view {
        IRiskEngine.AccountState memory s = factory.riskEngine().accountState(address(this));
        if (s.debtValue > s.limit) revert LimitExceeded(s.debtValue, s.limit);
    }

    function _track(address asset) internal {
        if (isHeld[asset]) return;
        if (_assets.length >= Constants.MAX_ASSETS_PER_ACCOUNT) revert TooManyAssets();
        isHeld[asset] = true;
        _assets.push(asset);
        emit AssetTracked(asset);
    }

    function _untrackIfEmpty(address asset) internal {
        if (!isHeld[asset] || IERC20(asset).balanceOf(address(this)) != 0) return;
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            if (_assets[i] == asset) {
                _assets[i] = _assets[n - 1];
                _assets.pop();
                break;
            }
        }
        isHeld[asset] = false;
        emit AssetUntracked(asset);
    }
}
