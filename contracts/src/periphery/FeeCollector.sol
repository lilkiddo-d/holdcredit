// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governed} from "../libraries/Governed.sol";
import {Constants} from "../libraries/Constants.sol";
import {IProjectTokenHooks} from "../interfaces/IHoldcredit.sol";

/// @title FeeCollector
/// @notice Receives the protocol's interest spread (LenderPool reserves) and the protocol share of hard
///         liquidation bonuses. `distribute()` splits stablecoin between project-token stakers (only once
///         the token is live and someone stakes) and the treasury. Without the token, 100% -> treasury.
contract FeeCollector is Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public immutable stable;
    address public treasury;
    IProjectTokenHooks public hooks; // optional
    uint16 public stakerShareBps = 5000;

    event Distributed(uint256 toStakers, uint256 toTreasury);
    event TreasurySet(address treasury);
    event HooksSet(address hooks);
    event StakerShareSet(uint16 bps);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error CannotSweepStable();

    constructor(IERC20 stable_, address treasury_, address admin, address guardian) Governed(admin, guardian) {
        _nonZero(address(stable_));
        _nonZero(treasury_);
        stable = stable_;
        treasury = treasury_;
    }

    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _nonZero(t);
        treasury = t;
        emit TreasurySet(t);
    }

    function setHooks(IProjectTokenHooks h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = h;
        emit HooksSet(address(h));
    }

    function setStakerShare(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > Constants.BPS) revert InvalidParam();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    /// @notice Permissionless: split the stablecoin balance between stakers and the treasury.
    function distribute() external nonReentrant whenNotPaused returns (uint256 toStakers, uint256 toTreasury) {
        uint256 bal = stable.balanceOf(address(this));
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (bal == 0) return (0, 0);
        IProjectTokenHooks h = hooks;
        if (address(h) != address(0) && h.isActive() && h.totalStaked() != 0) {
            toStakers = bal.mulDiv(stakerShareBps, Constants.BPS);
        }
        toTreasury = bal - toStakers;
        emit Distributed(toStakers, toTreasury);
        if (toStakers != 0) {
            stable.forceApprove(address(h), toStakers);
            h.notifyReward(toStakers);
            stable.forceApprove(address(h), 0);
        }
        if (toTreasury != 0) stable.safeTransfer(treasury, toTreasury);
    }

    /// @notice Move non-stablecoin assets (e.g. seized collateral cuts) to the treasury for disposal.
    function sweep(IERC20 token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == address(stable)) revert CannotSweepStable();
        emit Swept(address(token), treasury, amount);
        token.safeTransfer(treasury, amount);
    }
}
