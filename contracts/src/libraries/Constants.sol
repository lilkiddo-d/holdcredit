// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Constants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @dev Hard cap on distinct collateral assets per credit account (bounds every loop).
    uint256 internal constant MAX_ASSETS_PER_ACCOUNT = 15;

    // Compliance action identifiers.
    bytes32 internal constant ACTION_OPEN_ACCOUNT = keccak256("OPEN_ACCOUNT");
    bytes32 internal constant ACTION_DRAW = keccak256("DRAW");
    bytes32 internal constant ACTION_SWAP = keccak256("SWAP");
    bytes32 internal constant ACTION_LEND = keccak256("LEND");
    bytes32 internal constant ACTION_STAKE = keccak256("STAKE");
}
