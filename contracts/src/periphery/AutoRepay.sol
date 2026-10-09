// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Governed} from "../libraries/Governed.sol";
import {ICreditAccountFactory, ICreditAccount, ILenderPool} from "../interfaces/IHoldcredit.sol";

/// @title AutoRepay
/// @notice Owner-configured monthly repayment plan, executed by keepers. Each period it repays
///         min(monthlyAmount, debt) using, in order:
///           1. stablecoin that arrived in the CreditAccount (e.g. salary / dividends sent to it);
///           2. optionally, the owner's wallet (requires an allowance to this contract).
///         Execution is permissionless: it can only move funds the owner pre-authorised, at the
///         owner-chosen cadence, into the owner's own debt.
contract AutoRepay is Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Plan {
        uint128 monthlyAmount;
        uint64 lastExecuted;
        bool pullFromOwner;
        bool active;
    }

    uint256 public constant PERIOD = 30 days;

    ICreditAccountFactory public immutable factory;
    mapping(address => Plan) public plans; // keyed by credit account

    event PlanSet(address indexed account, uint256 monthlyAmount, bool pullFromOwner);
    event PlanCancelled(address indexed account);
    event AutoRepaid(address indexed account, address indexed keeper, uint256 fromAccount, uint256 fromOwner, uint256 repaid);

    error NotAccountOwner();
    error NoActivePlan();
    error NotDue(uint256 nextAt);
    error NothingToRepay();

    constructor(ICreditAccountFactory factory_, address admin, address guardian) Governed(admin, guardian) {
        _nonZero(address(factory_));
        factory = factory_;
    }

    function setPlan(address account, uint128 monthlyAmount, bool pullFromOwner) external {
        _onlyOwnerOf(account);
        if (monthlyAmount == 0) revert InvalidParam();
        Plan storage p = plans[account];
        p.monthlyAmount = monthlyAmount;
        p.pullFromOwner = pullFromOwner;
        p.active = true;
        emit PlanSet(account, monthlyAmount, pullFromOwner);
    }

    function cancelPlan(address account) external {
        _onlyOwnerOf(account);
        delete plans[account];
        emit PlanCancelled(account);
    }

    function nextExecution(address account) public view returns (uint256) {
        Plan memory p = plans[account];
        return p.lastExecuted == 0 ? 0 : uint256(p.lastExecuted) + PERIOD;
    }

    function isDue(address account) external view returns (bool) {
        Plan memory p = plans[account];
        return p.active && block.timestamp >= nextExecution(account) && factory.pool().debtOf(account) != 0;
    }

    function execute(address account) external nonReentrant whenNotPaused returns (uint256 repaid) {
        Plan memory p = plans[account];
        if (!p.active) revert NoActivePlan();
        uint256 next = nextExecution(account);
        if (block.timestamp < next) revert NotDue(next);

        ILenderPool pool = factory.pool();
        IERC20 stable = IERC20(factory.stable());
        uint256 debt = pool.debtOf(account);
        uint256 target = p.monthlyAmount < debt ? p.monthlyAmount : debt;
        if (target == 0) revert NothingToRepay();

        plans[account].lastExecuted = uint64(block.timestamp);

        uint256 fromAccount = ICreditAccount(account).pullStableForAutoRepay(target);
        uint256 fromOwner = 0;
        if (fromAccount < target && p.pullFromOwner) {
            address owner = ICreditAccount(account).owner();
            uint256 want = target - fromAccount;
            uint256 allowance_ = stable.allowance(owner, address(this));
            uint256 bal = stable.balanceOf(owner);
            fromOwner = want;
            if (fromOwner > allowance_) fromOwner = allowance_;
            if (fromOwner > bal) fromOwner = bal;
            // Pulls only from the account owner who opted in (pullFromOwner) and approved this contract; capped
            // by the plan amount and the owner's debt, and the funds can only repay that owner's own debt.
            // `owner` is the account owner who opted in to pullFromOwner and approved AutoRepay; capped by plan and debt, funds only repay that owner's own debt
            // slither-disable-next-line arbitrary-send-erc20
            if (fromOwner != 0) stable.safeTransferFrom(owner, address(this), fromOwner);
        }
        uint256 total = fromAccount + fromOwner;
        if (total == 0) revert NothingToRepay();

        stable.forceApprove(address(pool), total);
        repaid = pool.repay(account, total);
        stable.forceApprove(address(pool), 0);
        if (total > repaid) stable.safeTransfer(account, total - repaid);
        emit AutoRepaid(account, msg.sender, fromAccount, fromOwner, repaid);
    }

    function _onlyOwnerOf(address account) internal view {
        if (!factory.isAccount(account) || ICreditAccount(account).owner() != msg.sender) revert NotAccountOwner();
    }
}
