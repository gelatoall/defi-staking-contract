// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/StakingRewards.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Seed script: approve and stake from ALICE_PK.
contract SeedAlice is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 alicePk = vm.envUint("ALICE_PK");
        address stakingAddr = vm.envAddress("STAKING_ADDR");
        address stakingTokenAddr = vm.envAddress("STAKING_TOKEN");
        uint256 stakeAmount = vm.envOr("ALICE_STAKE_AMOUNT", uint256(100e18));
        uint256 tierIndex = vm.envOr("ALICE_TIER_INDEX", uint256(0));

        address alice = vm.addr(alicePk);

        // Fund Alice with staking tokens from deployer.
        vm.startBroadcast(deployerPk);
        IERC20(stakingTokenAddr).transfer(alice, stakeAmount);
        vm.stopBroadcast();

        vm.startBroadcast(alicePk);

        IERC20(stakingTokenAddr).approve(stakingAddr, stakeAmount);
        StakingRewards(stakingAddr).stake(stakeAmount, tierIndex);

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("Seeded Alice stake:", stakeAmount);
        console.log("Tier Index:        ", tierIndex);
        console.log("Alice Address:     ", alice);
        console.log("==========================================");
    }
}
