// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakingRewards {
    using SafeERC20 for IERC20;
    
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

    /// @dev user address => rewardPerTokenStored
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
    // event Staked();
    // event WithDrawn();

    // ============================================
    // Custom Errors
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    // ============================================
    // Modifiers
    // ============================================

    

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

    // ============================================
    // User Functions
    // ============================================

    

    
    

    // ============================================
    // View Functions
    // ============================================



    // ============================================
    // Admin Functions
    // ============================================






}