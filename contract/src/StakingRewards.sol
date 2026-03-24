// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingRewards is Ownable, ReentrancyGuard, Pausable {
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

    /// @dev Minimum Stake Amount
    uint256 public minStakeAmount;

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

    /// @dev Max Stake Amount per user
    uint256 public maxStakePerUser;
    /// @dev user address => total staked amount per user
    mapping(address => uint256) public userTotalStaked;

    // ============================================
    // Events
    // ============================================
    event Staked(address indexed user, uint256 amount, uint256 periodIndex);
    event Withdrawn(address indexed user, uint256 amount, uint256 periodIndex);
    event EmergencyWithdrawn(address indexed user, uint256 amount, uint256 periodIndex);
    event RewardPaid(address indexed user, uint256 amount);
    event SetMinStakeAmount(uint256 amount);
    event SetMaxStakePerUser(uint256 amount);
    event SetRewardsDuration(uint256 duration);
    event NotifyRewardAmount(uint256 amount);

    // ============================================
    // Custom Errors
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error ZeroRewardRate();
    error SameTokenNotAllowed();
    error InsufficientBalance();
    error InsufficientRewardBalance();
    error RewardPeriodActive();
    error InvalidPeriodIndex();
    error InvalidRewardsDuration();
    error Locked(uint256 availableAt);
    error StakeBelowMinimum(uint256 minAmount);
    error StakeAboveUserCap(uint256 maxAmount);

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
    /// @dev Initialize staking and reward tokens and set default tiers.
    /// @param _stakingToken ERC20 token used for staking.
    /// @param _rewardToken ERC20 token used for rewards.
    constructor(address _stakingToken, address _rewardToken) Ownable(msg.sender) {
        if (_stakingToken == address(0) || _rewardToken == address(0)) {
            revert ZeroAddress();
        }

        if (_stakingToken == _rewardToken) {
            revert SameTokenNotAllowed();
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

    /// @dev Stake into a tier; merges positions within the same tier and resets unlock time.
    /// @param amount Amount of staking tokens to deposit.
    /// @param periodIndex Tier index to stake into.
    function stake(uint256 amount, uint256 periodIndex) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (minStakeAmount != 0 && amount < minStakeAmount) {
            revert StakeBelowMinimum(minStakeAmount);
        }

        if (periodIndex >= stakingPeriods.length) {
            revert InvalidPeriodIndex();
        }

        if (maxStakePerUser != 0 && userTotalStaked[msg.sender] + amount > maxStakePerUser) {
            revert StakeAboveUserCap(maxStakePerUser);
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

        userTotalStaked[msg.sender] += amount;

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

    /// @dev Withdraw principal after unlock; proportional weight reduction for partial exits.
    /// @param amount Amount of principal to withdraw.
    /// @param periodIndex Tier index to withdraw from.
    function withdraw(uint256 amount, uint256 periodIndex) external nonReentrant whenNotPaused updateReward(msg.sender) {
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

        // 1. Calculate the weight that needs to be removed in this withdrawal.
        uint256 weightRemoved = amount * lockedBalances.weight / lockedBalances.amount;

        // 2. Update global and user-specific aggregate indices
        totalWeight -= weightRemoved;
        userTotalWeight[msg.sender] -= weightRemoved;

        userTotalStaked[msg.sender] -= amount;

        // 3. Update specific positions
        // Remove amount/weight from positions at the same amount level
        uint256 oldAmount = lockedBalances.amount;
        if (lockedBalances.amount == amount) {
            delete userLocks[msg.sender][periodIndex];
            delete weightRemainder[msg.sender][periodIndex];
        } else {
            lockedBalances.amount -= amount;
            lockedBalances.weight -= weightRemoved;

            uint256 oldRemainder = weightRemainder[msg.sender][periodIndex];
            uint256 newRemainder = oldRemainder * lockedBalances.amount / oldAmount;
            weightRemainder[msg.sender][periodIndex] = newRemainder;
        }

        // 4. Transfer
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, periodIndex);
    }

    /// @dev Claim accrued rewards.
    function getReward() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 rewardToClaim = rewards[msg.sender];
        if (rewardToClaim > 0) {
            delete rewards[msg.sender];
            rewardToken.safeTransfer(msg.sender, rewardToClaim);
            emit RewardPaid(msg.sender, rewardToClaim);
        }
    }

    /// @dev Emergency escape hatch during pause: returns principal only, skips rewards, and ignores lock time.
    /// @param amount Amount of principal to withdraw.
    /// @param periodIndex Tier index to withdraw from.
    function emergencyWithdraw(uint256 amount, uint256 periodIndex) external nonReentrant whenPaused {
        _updateGlobalRewards();
        
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (periodIndex >= stakingPeriods.length) {
            revert InvalidPeriodIndex();
        }

        UserLocks storage lockedBalances = userLocks[msg.sender][periodIndex];
        if (lockedBalances.amount < amount) {
            revert InsufficientBalance();
        }

        uint256 weightRemoved = amount * lockedBalances.weight / lockedBalances.amount;

        totalWeight -= weightRemoved;
        userTotalWeight[msg.sender] -= weightRemoved;

        userTotalStaked[msg.sender] -= amount;

        uint256 oldAmount = lockedBalances.amount;
        if (lockedBalances.amount == amount) {
            delete userLocks[msg.sender][periodIndex];
            delete weightRemainder[msg.sender][periodIndex];
        } else {
            lockedBalances.amount -= amount;
            lockedBalances.weight -= weightRemoved;

            uint256 oldRemainder = weightRemainder[msg.sender][periodIndex];
            uint256 newRemainder = oldRemainder * lockedBalances.amount / oldAmount;
            weightRemainder[msg.sender][periodIndex] = newRemainder;
        }

        delete rewards[msg.sender];

        stakingToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawn(msg.sender, amount, periodIndex);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @dev Current global reward index per unit of weight.
    /// @return rewardPerTokenStored Current accumulated reward per unit weight.
    function rewardPerToken() public view returns (uint256) {
        if (totalWeight == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored
                + (rewardRate * (lastTimeRewardApplicable() - lastUpdateTime) * PRECISION / totalWeight);
    }

    /// @dev Pending rewards for an account, including stored rewards.
    /// @param account User address.
    /// @return totalEarned Total rewards accrued for the account.
    function earned(address account) public view returns (uint256) {
        return
            userTotalWeight[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION
                + rewards[account];
    }

    // Ensure once the reward period ends, the calculation must stop at the endpoint.
    /// @dev Clamp reward accrual to the reward period.
    /// @return timestamp The last timestamp at which rewards accrue.
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
    /// @dev Pause user flows (stake/withdraw/claim).
    function pause() external onlyOwner {
        _pause();
    }

    /// @dev Resume user flows.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Set minimum stake amount; 0 disables the check.
    /// @param _min Minimum stake amount (0 to disable).
    function setMinStakeAmount(uint256 _min) external onlyOwner {
        minStakeAmount = _min;
        emit SetMinStakeAmount(_min);
    }

    /// @dev Set per-user stake cap; 0 disables the cap.
    /// @param _max Maximum stake per user (0 to disable).
    function setMaxStakePerUser(uint256 _max) external onlyOwner {
        maxStakePerUser = _max;
        emit SetMaxStakePerUser(_max);
    }

    /// @dev Configure rewards duration (only after current period ends).
    /// @param _rewardsDuration Reward duration in seconds.
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp <= periodFinish) {
            revert RewardPeriodActive();
        }

        if (_rewardsDuration == 0) {
            revert InvalidRewardsDuration();
        }

        rewardsDuration = _rewardsDuration;
        emit SetRewardsDuration(_rewardsDuration);
    }

    /// @dev Start or update reward emission for the next period.
    /// @param amount Amount of reward tokens to inject for the next period.
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

        emit NotifyRewardAmount(amount);
    }
}
