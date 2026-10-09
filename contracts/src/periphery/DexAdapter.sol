// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IDexAdapter} from "../interfaces/IHoldcredit.sol";
import {ISwapRouter02} from "../interfaces/IExternal.sol";

/// @title DexAdapter (Uniswap v3 / SwapRouter02)
/// @notice Routes every swap through a governance-chosen pool: token <-> hub (USDG) single hop, or
///         tokenA -> hub -> tokenB two hops. Callers cannot pick arbitrary pools or paths, which removes
///         "route through my own pool" abuse. Enforces deadline (SwapRouter02 has none) and minimum out
///         measured by the recipient's balance delta. Swappable via CreditAccountFactory.setDexAdapter.
contract DexAdapter is IDexAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    address public immutable hub;
    /// @dev Uniswap v3 fee tier of the token/hub pool; 0 = not routable.
    mapping(address => uint24) public hubFee;

    event HubFeeSet(address indexed token, uint24 fee);
    event Swap(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error Expired();
    error Unroutable(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error InvalidFee();
    error ZeroAddress();

    constructor(ISwapRouter02 router_, address hub_, address admin) {
        if (address(router_) == address(0) || hub_ == address(0) || admin == address(0)) revert ZeroAddress();
        router = router_;
        hub = hub_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setHubFee(address token, uint24 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee != 0 && fee != 100 && fee != 500 && fee != 3000 && fee != 10000) revert InvalidFee();
        if (token == hub) revert InvalidFee();
        hubFee[token] = fee;
        emit HubFeeSet(token, fee);
    }

    function supportsPair(address tokenIn, address tokenOut) public view returns (bool) {
        if (tokenIn == tokenOut) return false;
        if (tokenIn == hub) return hubFee[tokenOut] != 0;
        if (tokenOut == hub) return hubFee[tokenIn] != 0;
        return hubFee[tokenIn] != 0 && hubFee[tokenOut] != 0;
    }

    // Recipient balance delta is the source of truth for output; nonReentrant; router is the canonical Uniswap SwapRouter02.
    // slither-disable-start reentrancy-balance
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!supportsPair(tokenIn, tokenOut)) revert Unroutable(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(recipient);
        uint256 reported = _route(tokenIn, tokenOut, amountIn, minAmountOut, recipient);
        IERC20(tokenIn).forceApprove(address(router), 0);

        amountOut = IERC20(tokenOut).balanceOf(recipient) - before;
        if (amountOut < minAmountOut || reported < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
    // slither-disable-end reentrancy-balance

    /// @dev Single hop when one side is the hub, else tokenIn -> hub -> tokenOut.
    function _route(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        internal
        returns (uint256)
    {
        if (tokenIn == hub || tokenOut == hub) {
            address other = tokenIn == hub ? tokenOut : tokenIn;
            return router.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: hubFee[other],
                    recipient: recipient,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        return router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: abi.encodePacked(tokenIn, hubFee[tokenIn], hub, hubFee[tokenOut], tokenOut),
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
    }
}
