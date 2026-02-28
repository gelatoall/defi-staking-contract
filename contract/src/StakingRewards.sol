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
    // State Variables
    // ============================================

    /// @dev Token that users deposit to earn rewards based on their stake.
    IERC20 public stakingToken;

    /// @dev Token distributed to stakers as rewards.
    IERC20 public rewardToken;

    /// @dev Reward rate in rewardToken per second.
    uint256 public rewardRate = 100e18;

    /// @dev Last time the reward rate was updated.
    uint256 public lastUpdateTime;
    
    /// @dev Global accumulated reward per token. (R)
    /// Sum of (rewardRate * dt * 1e18 / totalSupply)
    uint256 public rewardPerTokenStored;

    /// @dev user address => last recorded rewardPerTokenStored value used for reward calculation
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @dev user address => rewards to be claimed
    mapping(address => uint256) public rewards;

    /// @dev total staked
    uint256 public _totalSupply;
    /// @dev user address => staked amount
    mapping(address => uint256) public _balances;

    // ============================================
    // Events
    // ============================================
    event Staked(address indexed user, uint256 amount);
    event WithDrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    // ============================================
    // Custom Errors
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();

    // ============================================
    // Modifiers
    // ============================================
    modifier updateReward(address account) {
        // Global updates
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

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
    }

    
    // ============================================
    // Staking Integration
    // ============================================

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender){
        if (amount == 0) {
            revert ZeroAmount();
        }

        _totalSupply += amount;
        _balances[msg.sender] += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (_balances[msg.sender] < amount) {
            revert InsufficientBalance();
        }

        _totalSupply -= amount;
        _balances[msg.sender] -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit WithDrawn(msg.sender, amount);
    }

    function getReward() external nonReentrant updateReward(msg.sender) {
        uint256 rewardToClaim = rewards[msg.sender];
        if (rewardToClaim > 0 ) {
            delete rewards[msg.sender];
            rewardToken.safeTransfer(msg.sender, rewardToClaim);
            emit RewardPaid(msg.sender, rewardToClaim);
        }
    }

    // ============================================
    // View Functions
    // ============================================
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + 
            (rewardRate * (block.timestamp - lastUpdateTime) * PRECISION / _totalSupply);
    }


    function earned(address account) public view returns (uint256) {
        return _balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION + rewards[account];
    }


    // ============================================
    // Admin Functions
    // ============================================

}