// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Shared access-control base.
///  - DEFAULT_ADMIN_ROLE: the 48h Timelock after deployment (parameter changes, upgrades of wiring).
///  - GUARDIAN_ROLE: emergency multisig that can pause/unpause instantly but cannot change parameters.
abstract contract Governed is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    error ZeroAddress();
    error InvalidParam();

    constructor(address admin, address guardian) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function _nonZero(address a) internal pure {
        if (a == address(0)) revert ZeroAddress();
    }
}
