// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governed} from "../libraries/Governed.sol";
import {Constants} from "../libraries/Constants.sol";
import {
    ILenderPool,
    ICreditAccount,
    ICreditAccountFactory,
    IInterestRateModel,
    IProjectTokenHooks
} from "../interfaces/IHoldcredit.sol";

/// @title LenderPool
/// @notice ERC-4626 stablecoin vault that funds every credit account.
///  - Interest accrues per second on two borrow indexes: tier 0 (standard) and tier 1 (project-token stakers,
///    rate discounted by `stakerDiscountBps`). Tier 1 is unreachable until the project token is set.
///  - `reserveFactorBps` of interest accrues to `reserves` (the protocol spread), collected to FeeCollector.
///  - Bad debt written off by the HardLiquidator is covered by reserves first, then socialised to lenders.
///  - Repayments are never pausable.
contract LenderPool is ERC4626, Governed, ReentrancyGuard, ILenderPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint8 public constant TIER_STANDARD = 0;
    uint8 public constant TIER_STAKER = 1;
    uint16 public constant MAX_RESERVE_FACTOR_BPS = 5000;
    uint16 public constant MAX_STAKER_DISCOUNT_BPS = 5000;

    ICreditAccountFactory public factory;
    IInterestRateModel public interestRateModel;
    IProjectTokenHooks public hooks; // optional
    address public feeCollector;
    address public hardLiquidator;
    uint16 public reserveFactorBps = 1500;
    uint16 public stakerDiscountBps = 2000;

    uint256[2] public borrowIndex; // RAY
    uint256[2] public totalScaled;
    mapping(address => uint256) public scaledDebt;
    mapping(address => uint8) public tierOf;

    uint256 public reserves; // protocol share of interest not yet collected (asset units)
    uint256 public lastAccrual;

    // Accounting used by invariants and dashboards.
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public totalBadDebt; // realised by lenders (after reserve cover)
    uint256 public totalBadDebtCoveredByReserves;

    event Accrued(uint256 index0, uint256 index1, uint256 reserves, uint256 timestamp);
    event Borrowed(address indexed account, address indexed receiver, uint256 amount, uint8 tier);
    event Repaid(address indexed account, address indexed payer, uint256 amount);
    event BadDebtWrittenOff(address indexed account, uint256 debt, uint256 coveredByReserves, uint256 socialised);
    event TierChanged(address indexed account, uint8 fromTier, uint8 toTier);
    event ReservesCollected(address indexed to, uint256 amount);
    event FactorySet(address factory);
    event InterestRateModelSet(address model);
    event HooksSet(address hooks);
    event FeeCollectorSet(address feeCollector);
    event HardLiquidatorSet(address hardLiquidator);
    event ReserveFactorSet(uint16 bps);
    event StakerDiscountSet(uint16 bps);

    error NotCreditAccount();
    error NotHardLiquidator();
    error InsufficientLiquidity();
    error NotAllowed();
    error ZeroAmount();

    constructor(IERC20 stable, IInterestRateModel irm, address admin, address guardian)
        ERC20("Holdcredit USDG Lender Share", "hcUSDG")
        ERC4626(stable)
        Governed(admin, guardian)
    {
        _nonZero(address(irm));
        interestRateModel = irm;
        borrowIndex[0] = Constants.RAY;
        borrowIndex[1] = Constants.RAY;
        lastAccrual = block.timestamp;
    }

    // =============================================================== admin

    function setFactory(ICreditAccountFactory f) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(f));
        factory = f;
        emit FactorySet(address(f));
    }

    function setInterestRateModel(IInterestRateModel m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(address(m));
        _accrue();
        interestRateModel = m;
        emit InterestRateModelSet(address(m));
    }

    function setHooks(IProjectTokenHooks h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = h;
        emit HooksSet(address(h));
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(fc);
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function setHardLiquidator(address hl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(hl);
        hardLiquidator = hl;
        emit HardLiquidatorSet(hl);
    }

    function setReserveFactor(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_RESERVE_FACTOR_BPS) revert InvalidParam();
        _accrue();
        reserveFactorBps = bps;
        emit ReserveFactorSet(bps);
    }

    function setStakerDiscount(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_DISCOUNT_BPS) revert InvalidParam();
        _accrue();
        stakerDiscountBps = bps;
        emit StakerDiscountSet(bps);
    }

    // =============================================================== borrowing (credit accounts only)

    function borrow(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        if (address(factory) == address(0) || !factory.isAccount(msg.sender)) revert NotCreditAccount();
        if (amount == 0) revert ZeroAmount();
        _accrue();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        if (scaledDebt[msg.sender] == 0) {
            uint8 desired = _desiredTier(msg.sender);
            if (desired != tierOf[msg.sender]) {
                emit TierChanged(msg.sender, tierOf[msg.sender], desired);
                tierOf[msg.sender] = desired;
            }
        }
        uint8 t = tierOf[msg.sender];
        uint256 scaled = amount.mulDiv(Constants.RAY, borrowIndex[t], Math.Rounding.Ceil);
        scaledDebt[msg.sender] += scaled;
        totalScaled[t] += scaled;

        emit Borrowed(msg.sender, receiver, amount, t);
        IERC20(asset()).safeTransfer(receiver, amount);
    }

    /// @notice Repay `amount` (capped at outstanding debt) of `account`'s debt, pulled from msg.sender.
    ///         Never paused: borrowers must always be able to de-risk.
    function repay(address account, uint256 amount) external nonReentrant returns (uint256 repaid) {
        _accrue();
        uint8 t = tierOf[account];
        uint256 idx = borrowIndex[t];
        uint256 scaled = scaledDebt[account];
        uint256 debt = scaled.mulDiv(idx, Constants.RAY, Math.Rounding.Ceil);
        repaid = amount > debt ? debt : amount;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (repaid == 0) return 0;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        uint256 delta = repaid == debt ? scaled : repaid.mulDiv(Constants.RAY, idx);
        scaledDebt[account] = scaled - delta;
        totalScaled[t] -= delta;

        emit Repaid(account, msg.sender, repaid);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repaid);
    }

    /// @notice Remove an insolvent account's residual debt. Reserves absorb it first; the rest is socialised.
    function writeOffBadDebt(address account) external nonReentrant returns (uint256 written) {
        if (msg.sender != hardLiquidator) revert NotHardLiquidator();
        _accrue();
        uint8 t = tierOf[account];
        uint256 scaled = scaledDebt[account];
        written = scaled.mulDiv(borrowIndex[t], Constants.RAY, Math.Rounding.Ceil);
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (written == 0) return 0;
        scaledDebt[account] = 0;
        totalScaled[t] -= scaled;
        uint256 covered = written > reserves ? reserves : written;
        reserves -= covered;
        uint256 socialised = written - covered;
        totalBadDebtCoveredByReserves += covered;
        totalBadDebt += socialised;
        emit BadDebtWrittenOff(account, written, covered, socialised);
    }

    /// @notice Move an account between the standard and staker rate tiers. Callable by anyone (keepers,
    ///         ProjectTokenHooks on stake/unstake) - the outcome is fully determined by on-chain state.
    function syncTier(address account) external nonReentrant {
        if (address(factory) == address(0) || !factory.isAccount(account)) revert NotCreditAccount();
        _accrue();
        uint8 from = tierOf[account];
        uint8 to = _desiredTier(account);
        if (from == to) return;
        uint256 scaled = scaledDebt[account];
        if (scaled != 0) {
            uint256 debt = scaled.mulDiv(borrowIndex[from], Constants.RAY, Math.Rounding.Ceil);
            uint256 newScaled = debt.mulDiv(Constants.RAY, borrowIndex[to], Math.Rounding.Ceil);
            totalScaled[from] -= scaled;
            totalScaled[to] += newScaled;
            scaledDebt[account] = newScaled;
        }
        tierOf[account] = to;
        emit TierChanged(account, from, to);
    }

    /// @notice Send accrued protocol reserves (that are liquid) to the FeeCollector. Permissionless.
    function collectReserves() external nonReentrant returns (uint256 amount) {
        _nonZero(feeCollector);
        _accrue();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        amount = reserves > cash ? cash : reserves;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;
        reserves -= amount;
        emit ReservesCollected(feeCollector, amount);
        IERC20(asset()).safeTransfer(feeCollector, amount);
    }

    function accrue() external {
        _accrue();
    }

    // =============================================================== ERC-4626

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _checkLend(receiver);
        _accrue();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _checkLend(receiver);
        _accrue();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrue();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _accrue();
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Lender-owned assets: cash + outstanding debt - protocol reserves (accrual previewed).
    function totalAssets() public view override returns (uint256) {
        (uint256[2] memory idx, uint256 res) = _preview();
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + _debt(0, idx[0]) + _debt(1, idx[1]);
        return gross > res ? gross - res : 0;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 own = _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
        uint256 liq = availableLiquidityPreview();
        return own < liq ? own : liq;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 bal = balanceOf(owner_);
        uint256 liqShares = _convertToShares(availableLiquidityPreview(), Math.Rounding.Floor);
        return bal < liqShares ? bal : liqShares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        totalDeposited += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        totalWithdrawn += assets;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Virtual shares/assets offset - makes first-depositor inflation attacks uneconomic.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // =============================================================== views

    function debtOf(address account) external view returns (uint256) {
        (uint256[2] memory idx,) = _preview();
        return scaledDebt[account].mulDiv(idx[tierOf[account]], Constants.RAY, Math.Rounding.Ceil);
    }

    function totalDebt() public view returns (uint256) {
        (uint256[2] memory idx,) = _preview();
        return _debt(0, idx[0]) + _debt(1, idx[1]);
    }

    /// @notice Cash that may be lent out or withdrawn (cash not earmarked for reserves). Uses stored reserves.
    function availableLiquidity() public view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return cash > reserves ? cash - reserves : 0;
    }

    function availableLiquidityPreview() public view returns (uint256) {
        (, uint256 res) = _preview();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return cash > res ? cash - res : 0;
    }

    function utilization() public view returns (uint256) {
        return _utilization(totalDebt(), availableLiquidityPreview());
    }

    /// @notice Current annualised borrow rate for a tier (WAD).
    function borrowRatePerYear(uint8 tier) external view returns (uint256) {
        return _tierRate(interestRateModel.borrowRatePerSecond(utilization()), tier) * Constants.SECONDS_PER_YEAR;
    }

    /// @notice Approximate annualised lender yield (WAD), ignoring the staker-tier discount.
    function supplyRatePerYear() external view returns (uint256) {
        uint256 u = utilization();
        uint256 r = interestRateModel.borrowRatePerSecond(u) * Constants.SECONDS_PER_YEAR;
        return r.mulDiv(u, Constants.WAD).mulDiv(Constants.BPS - reserveFactorBps, Constants.BPS);
    }

    // =============================================================== internals

    function _accrue() internal {
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (block.timestamp == lastAccrual) return;
        (uint256[2] memory idx, uint256 res) = _preview();
        borrowIndex[0] = idx[0];
        borrowIndex[1] = idx[1];
        reserves = res;
        lastAccrual = block.timestamp;
        emit Accrued(idx[0], idx[1], res, block.timestamp);
    }

    function _preview() internal view returns (uint256[2] memory idx, uint256 res) {
        idx = borrowIndex;
        res = reserves;
        uint256 dt = block.timestamp - lastAccrual;
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (dt == 0) return (idx, res);
        uint256 debt0 = _debt(0, idx[0]);
        uint256 debt1 = _debt(1, idx[1]);
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (debt0 + debt1 == 0) return (idx, res);
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 avail = cash > res ? cash - res : 0;
        uint256 rate = interestRateModel.borrowRatePerSecond(_utilization(debt0 + debt1, avail));
        uint256 interest = 0;
        for (uint8 t; t < 2; ++t) {
            // zero/equality guard on an exact integer value (no balance-manipulation dependence)
            // slither-disable-next-line incorrect-equality
            if (totalScaled[t] == 0) continue;
            uint256 growth = _tierRate(rate, t) * dt; // WAD
            uint256 newIdx = idx[t] + idx[t].mulDiv(growth, Constants.WAD);
            interest += totalScaled[t].mulDiv(newIdx - idx[t], Constants.RAY);
            idx[t] = newIdx;
        }
        res += interest.mulDiv(reserveFactorBps, Constants.BPS);
    }

    function _tierRate(uint256 rate, uint8 tier) internal view returns (uint256) {
        return tier == TIER_STAKER ? rate.mulDiv(Constants.BPS - stakerDiscountBps, Constants.BPS) : rate;
    }

    function _debt(uint8 t, uint256 idx) internal view returns (uint256) {
        return totalScaled[t].mulDiv(idx, Constants.RAY, Math.Rounding.Ceil);
    }

    function _utilization(uint256 debt, uint256 avail) internal pure returns (uint256) {
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (debt == 0) return 0;
        return debt.mulDiv(Constants.WAD, debt + avail);
    }

    function _desiredTier(address account) internal view returns (uint8) {
        IProjectTokenHooks h = hooks;
        if (address(h) == address(0) || !h.isActive()) return TIER_STANDARD;
        return h.isDiscounted(ICreditAccount(account).owner()) ? TIER_STAKER : TIER_STANDARD;
    }

    function _checkLend(address receiver) internal view {
        if (address(factory) != address(0) && !factory.isAllowed(receiver, Constants.ACTION_LEND)) {
            revert NotAllowed();
        }
    }

    // ERC-4626 decimals come from ERC4626; resolve the multiple-inheritance diamond.
    function decimals() public view override(ERC4626) returns (uint8) {
        return super.decimals();
    }
}
