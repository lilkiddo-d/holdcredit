// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDexAdapter, IPriceOracle} from "../../src/interfaces/IHoldcredit.sol";
import {ISwapRouter02} from "../../src/interfaces/IExternal.sol";

/// @dev Test-only ERC-20 (also used as the mock $HOLD project token - never deployed by scripts).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    bool public oraclePaused; // mimics Robinhood stock token corporate-action flag

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

/// @dev Fee-on-transfer token for staking robustness tests.
contract MockFeeToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId = 1;
    string public description = "mock";

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setWithTime(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @dev Swaps at the oracle price minus `slippageBps`, minting the output (all tokens are MockERC20).
contract MockDexAdapter is IDexAdapter {
    using SafeERC20 for IERC20;

    IPriceOracle public oracle;
    uint256 public slippageBps;
    uint256 public bonusBps; // venue pays above oracle (e.g. lagging oracle in a rally)
    bool public unsupported;

    constructor(IPriceOracle o) {
        oracle = o;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function setBonus(uint256 bps) external {
        bonusBps = bps;
    }

    function setUnsupported(bool u) external {
        unsupported = u;
    }

    function supportsPair(address, address) external view returns (bool) {
        return !unsupported;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline)
        external
        returns (uint256 out)
    {
        require(block.timestamp <= deadline, "expired");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 value = oracle.getValue(tokenIn, amountIn);
        out = oracle.getAmount(tokenOut, value);
        out = out * (10_000 - slippageBps + bonusBps) / 10_000;
        require(out >= minOut, "minOut");
        MockERC20(tokenOut).mint(recipient, out);
    }
}

/// @dev Minimal SwapRouter02 stand-in: pays out `rateWad` tokenOut per tokenIn (decimal-adjusted by caller).
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    uint256 public rateWad = 1e18;
    bytes public lastPath;
    uint24 public lastFee;
    uint256 public shortfall; // pay less than promised to test adapter checks

    function setRate(uint256 r) external {
        rateWad = r;
    }

    function setShortfall(uint256 s) external {
        shortfall = s;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        lastFee = p.fee;
        out = Math.mulDiv(p.amountIn, rateWad, 1e18);
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, out - shortfall);
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata p) external payable returns (uint256 out) {
        lastPath = p.path;
        address tokenIn;
        address tokenOut;
        bytes memory path = p.path;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(add(path, 32), 46)))
        }
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        out = Math.mulDiv(p.amountIn, rateWad, 1e18);
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(tokenOut).mint(p.recipient, out - shortfall);
    }
}

/// @dev Hooks stand-in that always reports a staker (for pool tier tests without the full staking flow).
contract MockHooks {
    bool public isActive = true;
    mapping(address => bool) public isDiscounted;
    uint256 public totalStaked;

    function setDiscounted(address u, bool d) external {
        isDiscounted[u] = d;
    }

    function setActive(bool a) external {
        isActive = a;
    }

    function setTotalStaked(uint256 t) external {
        totalStaked = t;
    }

    function notifyReward(uint256) external {}
}
