// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Governed} from "../libraries/Governed.sol";
import {Constants} from "../libraries/Constants.sol";
import {IProjectTokenHooks, ICreditAccountFactory, ILenderPool} from "../interfaces/IHoldcredit.sol";

/// @title ProjectTokenHooks
/// @notice Everything $HOLD-related lives here, and all of it is inert until governance (the Timelock)
///         calls `setProjectToken(address)` - exactly once. Holdcredit never deploys or mints a token.
///  Features once active:
///   1. Staking with a 7-day unstake cooldown (cooling tokens earn nothing and give no discount).
///   2. Borrow-rate tier: stakers holding >= `minStakeForDiscount` get the LenderPool staker tier. Stake
///      changes immediately re-sync the staker's credit-account tier.
///   3. Interest-spread sharing: FeeCollector streams a share of protocol reserves (USDG) to stakers over
///      `rewardsDuration` (Synthetix-style), which neutralises just-in-time staking.
contract ProjectTokenHooks is IProjectTokenHooks, Governed, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant REWARD_NOTIFIER_ROLE = keccak256("REWARD_NOTIFIER_ROLE");
    uint256 private constant PRECISION = 1e36;

    IERC20 public immutable rewardToken; // the stablecoin
    address public projectToken; // zero until set

    ICreditAccountFactory public factory;
    ILenderPool public pool;

    uint256 public minStakeForDiscount;
    uint256 public unstakeCooldown = 7 days;
    uint256 public rewardsDuration = 7 days;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;

    struct Cooling {
        uint256 amount;
        uint256 unlockAt;
    }

    mapping(address => Cooling) public cooling;

    // Reward streaming state (rate is reward units per second scaled by 1e18).
    uint256 public periodFinish;
    uint256 public rewardRateWad;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event ProjectTokenSet(address indexed token, uint256 minStakeForDiscount);
    event WiringSet(address factory, address pool);
    event DiscountThresholdSet(uint256 minStake);
    event CooldownSet(uint256 cooldown);
    event RewardsDurationSet(uint256 duration);
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rewardRateWad, uint256 periodFinish);
    event RewardPaid(address indexed user, uint256 amount);

    error TokenNotSet();
    error TokenAlreadySet();
    error InvalidToken();
    error ZeroAmount();
    error Insufficient();
    error StillCooling(uint256 unlockAt);
    error NotAllowed();
    error NoStakers();
    error RewardTooHigh();

    constructor(IERC20 rewardToken_, address admin, address guardian) Governed(admin, guardian) {
        _nonZero(address(rewardToken_));
        rewardToken = rewardToken_;
    }

    modifier updateReward(address user) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (user != address(0)) {
            rewards[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
        _;
    }

    // =============================================================== governance

    /// @notice One-shot. Called by the Timelock after the token launches on the launchpad.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (projectToken != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token == address(rewardToken) || token.code.length == 0) revert InvalidToken();
        uint8 dec = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {}
        if (dec > 36) revert InvalidToken();
        projectToken = token;
        minStakeForDiscount = 1000 * 10 ** dec;
        emit ProjectTokenSet(token, minStakeForDiscount);
    }

    function setWiring(ICreditAccountFactory factory_, ILenderPool pool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        factory = factory_;
        pool = pool_;
        emit WiringSet(address(factory_), address(pool_));
    }

    function setDiscountThreshold(uint256 minStake) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minStake == 0) revert InvalidParam();
        minStakeForDiscount = minStake;
        emit DiscountThresholdSet(minStake);
    }

    function setUnstakeCooldown(uint256 c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (c > 30 days) revert InvalidParam();
        unstakeCooldown = c;
        emit CooldownSet(c);
    }

    function setRewardsDuration(uint256 d) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (d < 1 days || d > 90 days || block.timestamp < periodFinish) revert InvalidParam();
        rewardsDuration = d;
        emit RewardsDurationSet(d);
    }

    // =============================================================== views

    function isActive() public view returns (bool) {
        return projectToken != address(0);
    }

    function isDiscounted(address user) external view returns (bool) {
        return isActive() && stakedOf[user] >= minStakeForDiscount;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 dt = lastTimeRewardApplicable() - lastUpdateTime;
        // rewardRateWad * dt / 1e18 reward units, spread per staked unit with PRECISION.
        return rewardPerTokenStored + (rewardRateWad * dt).mulDiv(PRECISION / Constants.WAD, totalStaked);
    }

    function earned(address user) public view returns (uint256) {
        return stakedOf[user].mulDiv(rewardPerToken() - userRewardPerTokenPaid[user], PRECISION) + rewards[user];
    }

    // =============================================================== staking

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        address token = projectToken;
        if (token == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        if (address(factory) != address(0) && !factory.isAllowed(msg.sender, Constants.ACTION_STAKE)) {
            revert NotAllowed();
        }
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before; // fee-on-transfer safe
        stakedOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
        _syncTier(msg.sender);
    }

    function requestUnstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (projectToken == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedOf[msg.sender]) revert Insufficient();
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        Cooling storage c = cooling[msg.sender];
        c.amount += amount;
        c.unlockAt = block.timestamp + unstakeCooldown;
        emit UnstakeRequested(msg.sender, amount, c.unlockAt);
        _syncTier(msg.sender);
    }

    function withdrawUnstaked() external nonReentrant {
        Cooling memory c = cooling[msg.sender];
        if (c.amount == 0) revert ZeroAmount();
        if (block.timestamp < c.unlockAt) revert StillCooling(c.unlockAt);
        delete cooling[msg.sender];
        emit Unstaked(msg.sender, c.amount);
        IERC20(projectToken).safeTransfer(msg.sender, c.amount);
    }

    function claimRewards() external nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];
        // zero/equality guard on an exact integer value (no balance-manipulation dependence)
        // slither-disable-next-line incorrect-equality
        if (reward == 0) return 0;
        rewards[msg.sender] = 0;
        emit RewardPaid(msg.sender, reward);
        rewardToken.safeTransfer(msg.sender, reward);
    }

    // =============================================================== rewards in

    // Synthetix-style streaming: rate is WAD-scaled so the division loses < 1 wei-per-second of reward.
    // slither-disable-start divide-before-multiply,incorrect-equality,timestamp
    function notifyReward(uint256 amount) external nonReentrant onlyRole(REWARD_NOTIFIER_ROLE) updateReward(address(0)) {
        if (projectToken == address(0)) revert TokenNotSet();
        if (totalStaked == 0) revert NoStakers();
        if (amount == 0) revert ZeroAmount();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 leftover = 0;
        if (block.timestamp < periodFinish) {
            leftover = (periodFinish - block.timestamp) * rewardRateWad;
        }
        rewardRateWad = (amount * Constants.WAD + leftover) / rewardsDuration;
        // Never promise more than the contract holds (excluding nothing else: staked tokens are a different asset).
        if (rewardRateWad * rewardsDuration / Constants.WAD > rewardToken.balanceOf(address(this))) {
            revert RewardTooHigh();
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardNotified(amount, rewardRateWad, periodFinish);
    // slither-disable-end divide-before-multiply,incorrect-equality,timestamp
    }

    function _syncTier(address user) internal {
        if (address(factory) == address(0) || address(pool) == address(0)) return;
        address account = factory.accountOf(user);
        if (account != address(0)) pool.syncTier(account);
    }
}
