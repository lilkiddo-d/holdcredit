// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IHoldcredit.sol";

/// @title ComplianceRegistry
/// @notice Optional allowlist gate, OFF by default. When `enabled`, any action flagged in `gated` requires
///         the user to be allowlisted. Repayments, collateral top-ups and liquidations are never gated
///         (gating them would only increase risk). Operators with COMPLIANCE_ROLE manage the list; the
///         Timelock admin flips the global switch and the per-action flags.
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    bool public enabled;
    mapping(bytes32 => bool) public gated;
    mapping(address => bool) public allowed;

    event EnabledSet(bool enabled);
    event ActionGated(bytes32 indexed action, bool gated);
    event AllowedSet(address indexed user, bool allowed);

    constructor(address admin, address complianceOps) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
        if (complianceOps != address(0)) _grantRole(COMPLIANCE_ROLE, complianceOps);
    }

    function setEnabled(bool e) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = e;
        emit EnabledSet(e);
    }

    function setGated(bytes32 action, bool g) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gated[action] = g;
        emit ActionGated(action, g);
    }

    function setAllowed(address[] calldata users, bool a) external onlyRole(COMPLIANCE_ROLE) {
        for (uint256 i; i < users.length; ++i) {
            allowed[users[i]] = a;
            emit AllowedSet(users[i], a);
        }
    }

    function isAllowed(address user, bytes32 action) external view returns (bool) {
        return !enabled || !gated[action] || allowed[user];
    }
}
