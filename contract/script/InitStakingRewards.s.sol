// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/StakingRewards.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Initialization script for StakingRewards (set duration + fund rewards).
contract InitStakingRewards is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address stakingAddr = vm.envAddress("STAKING_ADDR");
        address rewardTokenAddr = vm.envAddress("REWARD_TOKEN");
        uint256 rewardsDuration = vm.envOr("REWARDS_DURATION", uint256(7 days));
        uint256 rewardAmount = vm.envUint("REWARD_AMOUNT");

        vm.startBroadcast(deployerPk);

        // Optional duration override (skip if unchanged).
        if (rewardsDuration != 7 days) {
            StakingRewards(stakingAddr).setRewardsDuration(rewardsDuration);
        }

        // Fund and start rewards.
        IERC20(rewardTokenAddr).transfer(stakingAddr, rewardAmount);
        StakingRewards(stakingAddr).notifyRewardAmount(rewardAmount);

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("StakingRewards Initialized:", stakingAddr);
        console.log("Reward Amount:          ", rewardAmount);
        console.log("Rewards Duration:       ", rewardsDuration);
        console.log("==========================================");
    }
}
