// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/StakingRewards.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock token for local deployments.
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10**18);
    }
}

/// @dev Deploy-only script for StakingRewards (Anvil-friendly).
contract DeployStakingRewards is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address stakingTokenAddr = vm.envOr("STAKING_TOKEN", address(0));
        address rewardTokenAddr = vm.envOr("REWARD_TOKEN", address(0));

        vm.startBroadcast(deployerPk);

        if (stakingTokenAddr == address(0)) {
            MockToken stakingToken = new MockToken("Staking Token", "STK");
            stakingTokenAddr = address(stakingToken);
        }

        if (rewardTokenAddr == address(0)) {
            MockToken rewardToken = new MockToken("Reward Token", "RWD");
            rewardTokenAddr = address(rewardToken);
        }

        StakingRewards staking = new StakingRewards(stakingTokenAddr, rewardTokenAddr);

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("StakingRewards Address:", address(staking));
        console.log("StakingToken Address:  ", stakingTokenAddr);
        console.log("RewardToken Address:   ", rewardTokenAddr);
        console.log("==========================================");
    }
}
