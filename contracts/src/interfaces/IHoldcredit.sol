// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. Prices are USD per 1 whole token, scaled to 1e18.
interface IPriceOracle {
    function isSupported(address asset) external view returns (bool);
    /// @dev MUST revert when the price is stale, non-positive, or fails a deviation check.
    function getPrice(address asset) external view returns (uint256 priceWad);
    /// @dev USD value (1e18) of `amount` raw units of `asset`, rounded down.
    function getValue(address asset, uint256 amount) external view returns (uint256 valueWad);
    /// @dev Raw units of `asset` worth `valueWad` USD, rounded down.
    function getAmount(address asset, uint256 valueWad) external view returns (uint256 amount);
}

interface IMarketClock {
    /// @notice True while the US regular equity session is open.
    function isOpen() external view returns (bool);
    /// @notice America/New_York calendar day index (days since 1970-01-01 in local time).
    function currentDay() external view returns (uint256);
}

/// @notice Swappable swap venue. Pulls `amountIn` of `tokenIn` from msg.sender.
interface IDexAdapter {
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function supportsPair(address tokenIn, address tokenOut) external view returns (bool);
}

interface IInterestRateModel {
    /// @return Borrow rate per second, 1e18 = 100%.
    function borrowRatePerSecond(uint256 utilizationWad) external view returns (uint256);
}

interface IComplianceRegistry {
    function isAllowed(address user, bytes32 action) external view returns (bool);
}

interface IProjectTokenHooks {
    /// @notice True once governance has set the project token.
    function isActive() external view returns (bool);
    /// @notice Whether `user` qualifies for the discounted borrow-rate tier.
    function isDiscounted(address user) external view returns (bool);
    function totalStaked() external view returns (uint256);
    /// @notice Stream `amount` stablecoin to stakers (pulled from msg.sender).
    function notifyReward(uint256 amount) external;
}

interface ILenderPool {
    function debtOf(address account) external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
    function borrow(uint256 amount, address receiver) external;
    function repay(address account, uint256 amount) external returns (uint256 repaid);
    function writeOffBadDebt(address account) external returns (uint256 written);
    function syncTier(address account) external;
}

interface ICreditAccount {
    function owner() external view returns (address);
    function getAssets() external view returns (address[] memory);
    function seize(address asset, uint256 amount, address to) external;
    function pullStableForAutoRepay(uint256 amount) external returns (uint256 pulled);
}

interface IRiskEngine {
    struct AssetConfig {
        bool enabled; // counts as collateral
        bool frozen; // no new deposits / swaps into it; existing balance still counts
        uint16 ltvBps; // credit-limit weight
        uint16 softBps; // soft-liquidation weight (> ltv)
        uint16 hardBps; // hard-liquidation weight (> soft)
        uint16 liquidityScore; // 1..100, ranks what soft liquidation sells first
    }

    /// @dev USD values are 1e18-scaled.
    struct AccountState {
        uint256 collateralValue; // oracle value of all collateral
        uint256 adjustedValue; // after concentration penalty
        uint256 limitOpen; // credit limit while the market is open
        uint256 limit; // credit limit right now (shrunk while closed)
        uint256 softThreshold; // debt value above this => soft liquidation
        uint256 hardThreshold; // debt value above this => hard liquidation
        uint256 debtValue; // USD value of stablecoin debt (rounded up)
        uint256 debt; // raw stablecoin debt
        uint256 softHealth; // softThreshold / debtValue (1e18 = boundary); max if no debt
        uint256 hardHealth; // hardThreshold / debtValue
        bool marketOpen;
    }

    function assetConfig(address asset) external view returns (AssetConfig memory);
    function isCollateral(address asset) external view returns (bool);
    function canReceive(address asset) external view returns (bool);
    function accountState(address account) external view returns (AccountState memory);
    function accountBreakdown(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory values, AccountState memory state);
    function previewLimit(address[] calldata assets, uint256[] calldata amounts)
        external
        view
        returns (uint256 collateralValue, uint256 limitOpen, uint256 limitNow);
    function stableToUsd(uint256 amount) external view returns (uint256);
    function usdToStable(uint256 valueWad) external view returns (uint256);
    function closedDrawCap() external view returns (uint256);
    function maxSwapLossBps() external view returns (uint16);
    function concentrationCapBps() external view returns (uint16);
    function oracle() external view returns (IPriceOracle);
    function marketClock() external view returns (IMarketClock);
}

interface ICreditAccountFactory {
    function stable() external view returns (address);
    function pool() external view returns (ILenderPool);
    function riskEngine() external view returns (IRiskEngine);
    function dexAdapter() external view returns (IDexAdapter);
    function marketClock() external view returns (IMarketClock);
    function softLiquidator() external view returns (address);
    function hardLiquidator() external view returns (address);
    function autoRepay() external view returns (address);
    function paused() external view returns (bool);
    function isAccount(address account) external view returns (bool);
    function accountOf(address owner) external view returns (address);
    function isAllowed(address user, bytes32 action) external view returns (bool);
}
