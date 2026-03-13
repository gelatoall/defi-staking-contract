// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakingRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // Constants
    // ============================================
    uint256 public constant PRECISION = 1e18;

    // ============================================
    // Type Definitions
    // ============================================
    /// @dev Configuration for a staking tier. Packed into a single slot (32 + 16 < 256 bits).
    struct StakingPeriod {
        uint32 duration; // Lock-up duration in seconds
        uint16 rewardMultiplier; // Reward multiplier (e.g., 100 = 1x, 150 = 1.5x)
    }

    /// @dev User's position data for a specific tier.
    struct UserLocks {
        uint256 amount;
        uint256 weight; // Logical weight used for reward calculation (amount * multiplier)
        uint256 unlockTime; // Unix timestamp when the position becomes withdrawable
    }

    // ============================================
    // State Variables
    // ============================================

    /// @dev Token that users deposit to earn rewards based on their stake.
    IERC20 public stakingToken;

    /// @dev Token distributed to stakers as rewards.
    IERC20 public rewardToken;

    /// @dev Reward rate in rewardToken per second.
    uint256 public rewardRate;

    /// @dev Last time the reward rate was updated.
    uint256 public lastUpdateTime;

    /// @dev Global accumulated reward per token. (R)
    /// Sum of (rewardRate * dt * 1e18 / totalSupply)
    uint256 public rewardPerTokenStored;

    /// @dev Total duration (in seconds) over which the injected reward amount is distributed.
    uint256 public rewardsDuration;

    /// @dev The Unix timestamp marking the end of the current reward distribution period.
    uint256 public periodFinish;

    /// @dev Accumulate unallocated rewards during periods of inactivity.
    uint256 public undistributedRewards;

    /// @dev Array of all available staking tiers
    StakingPeriod[] public stakingPeriods;

    /// For O(1) complexity for reward distribution
    /// @dev Global aggregate indices
    uint256 public totalWeight;
    /// @dev User-specific aggregate indices
    mapping(address => uint256) public userTotalWeight;

    /// @dev user address => Tier index => Position-specific data
    mapping(address => mapping(uint256 => UserLocks)) public userLocks;

    /// @dev user address => Tier index => User weight remainder
    mapping(address => mapping(uint256 => uint256)) public weightRemainder;

    /// @dev user address => last recorded rewardPerTokenStored value used for reward calculation
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @dev user address => rewards to be claimed
    mapping(address => uint256) public rewards;

    /// @dev total staked
    // uint256 public _totalSupply;
    /// @dev user address => staked amount
    // mapping(address => uint256) public _balances;

    // ============================================
    // Events
    // ============================================
    event Staked(address indexed user, uint256 amount, uint256 periodIndex);
    event WithDrawn(address indexed user, uint256 amount, uint256 periodIndex);
    event RewardPaid(address indexed user, uint256 amount);

    // ============================================
    // Custom Errors
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error ZeroRewardRate();
    error InsufficientBalance();
    error InsufficientRewardBalance();
    error RewardPeriodActive();
    error InvalidPeriodIndex();
    error InvalidRewardsDuration();
    error Locked(uint256 availableAt);

    // ============================================
    // Modifiers
    // ============================================
    modifier updateReward(address account) {
        // Global updates
        _updateGlobalRewards();
        
        // Personal updates
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    // ============================================
    // Constructor
    // ============================================
    constructor(address _stakingToken, address _rewardToken) Ownable(msg.sender) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) {
            revert ZeroAddress();
        }

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);

        rewardsDuration = 7 days;

        // Initialize 4 tiers of StakingPeriod
        // tier 0: 30 days, 1x
        stakingPeriods.push(StakingPeriod({duration: 30 days, rewardMultiplier: 100}));
        // tier 1: 90 days, 1.5x
        stakingPeriods.push(StakingPeriod({duration: 90 days, rewardMultiplier: 150}));
        // tier 2: 180 days, 2x
        stakingPeriods.push(StakingPeriod({duration: 180 days, rewardMultiplier: 200}));
        // tier 3: 365 days, 3x
        stakingPeriods.push(StakingPeriod({duration: 365 days, rewardMultiplier: 300}));
    }

    // ============================================
    // Staking Integration
    // ============================================

    function stake(uint256 amount, uint256 periodIndex) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (periodIndex >= stakingPeriods.length) {
            revert InvalidPeriodIndex();
        }

        // 1. Get stakingPeriod (one-time SLOAD)
        StakingPeriod memory stakingPeriod = stakingPeriods[periodIndex];

        // 2. Calculate logical weights
        uint256 raw = amount * stakingPeriod.rewardMultiplier + weightRemainder[msg.sender][periodIndex];
        uint256 weightAdded = raw / 100;
        weightRemainder[msg.sender][periodIndex] = raw % 100;

        // 3. Update global and user-specific aggregate indices
        totalWeight += weightAdded;
        userTotalWeight[msg.sender] += weightAdded;

        // 4. Update specific positions
        UserLocks storage lockedBalances = userLocks[msg.sender][periodIndex];
        // Add amount/weight to positions at the same amount level
        lockedBalances.amount += amount;
        lockedBalances.weight += weightAdded;
        // Reset timestamp
        lockedBalances.unlockTime = block.timestamp + stakingPeriod.duration;

        // 5. Transfer
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, periodIndex);
    }

    function withdraw(uint256 amount, uint256 periodIndex) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (periodIndex >= stakingPeriods.length) {
            revert InvalidPeriodIndex();
        }

        UserLocks storage lockedBalances = userLocks[msg.sender][periodIndex];
        if (block.timestamp < lockedBalances.unlockTime) {
            revert Locked(lockedBalances.unlockTime);
        }

        if (lockedBalances.amount < amount) {
            revert InsufficientBalance();
        }

        // 1. Get stakingPeriod (one-time SLOAD)
        StakingPeriod memory stakingPeriod = stakingPeriods[periodIndex];
        // 2. Calculate the weight that needs to be removed in this withdrawal.
        uint256 weightRemoved = amount * lockedBalances.weight / lockedBalances.amount;

        // 3. Update global and user-specific aggregate indices
        totalWeight -= weightRemoved;
        userTotalWeight[msg.sender] -= weightRemoved;

        // 4. Update specific positions
        // Remove amount/weight from positions at the same amount level
        if (lockedBalances.amount == amount) {
            delete userLocks[msg.sender][periodIndex];
            delete weightRemainder[msg.sender][periodIndex];
        } else {
            lockedBalances.amount -= amount;
            lockedBalances.weight -= weightRemoved;
        }

        // 5. Transfer
        stakingToken.safeTransfer(msg.sender, amount);

        emit WithDrawn(msg.sender, amount, periodIndex);
    }

    function getReward() external nonReentrant updateReward(msg.sender) {
        uint256 rewardToClaim = rewards[msg.sender];
        if (rewardToClaim > 0) {
            delete rewards[msg.sender];
            rewardToken.safeTransfer(msg.sender, rewardToClaim);
            emit RewardPaid(msg.sender, rewardToClaim);
        }
    }

    // ============================================
    // View Functions
    // ============================================
    function rewardPerToken() public view returns (uint256) {
        if (totalWeight == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored
                + (rewardRate * (lastTimeRewardApplicable() - lastUpdateTime) * PRECISION / totalWeight);
    }

    function earned(address account) public view returns (uint256) {
        return
            userTotalWeight[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION
                + rewards[account];
    }

    // Ensure once the reward period ends, the calculation must stop at the endpoint.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // ============================================
    // Internal Functions
    // ============================================
    function _updateGlobalRewards() internal {
        uint256 applicable = lastTimeRewardApplicable();
        uint256 dt = applicable - lastUpdateTime;

        if (dt > 0) {
            if (totalWeight == 0) { // No stake
                undistributedRewards += dt * rewardRate;
            } else {
                rewardPerTokenStored += (dt * rewardRate * PRECISION) / totalWeight;
            }

            lastUpdateTime = applicable;
        }
    }

    // ============================================
    // Admin Functions
    // ============================================
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp <= periodFinish) {
            revert RewardPeriodActive();
        }

        if (_rewardsDuration == 0) {
            revert InvalidRewardsDuration();
        }

        rewardsDuration = _rewardsDuration;
    }

    function notifyRewardAmount(uint256 amount) external onlyOwner updateReward(address(0)) {
        if (rewardsDuration == 0) {
            revert InvalidRewardsDuration();
        }

        uint256 remaining = 0;
        if (block.timestamp < periodFinish) {
            remaining = (periodFinish - block.timestamp) * rewardRate;
        }
        rewardRate = (amount + remaining + undistributedRewards) / rewardsDuration;

        if (rewardRate == 0) {
            revert ZeroRewardRate();
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate * rewardsDuration > balance) {
            revert InsufficientRewardBalance();
        }

        undistributedRewards = 0;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }
}
