// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title HoldcreditTimelock
/// @notice Owns DEFAULT_ADMIN_ROLE on every Holdcredit contract. Enforces a minimum 48h delay on every
///         parameter change, module swap and `setProjectToken`. The timelock administers itself
///         (admin = address(0)), so changing its own delay or proposers also takes 48h.
contract HoldcreditTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }
}
