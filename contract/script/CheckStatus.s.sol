// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/StakingRewards.sol";

contract CheckStatus is Script {
    function run() external view {
        // --- 1. 环境准备 (从 .env 加载) ---
        // 动态读取合约地址
        address stakingAddr = vm.envAddress("STAKING_ADDR");
        // 动态读取 Alice 私钥并派生地址
        uint256 alicePk = vm.envUint("ALICE_PK");
        address alice = vm.addr(alicePk);

        // 实例化合约对象
        StakingRewards staking = StakingRewards(stakingAddr);

        // --- 2. 打印仪表盘头部 ---
        console.log("====================================================");
        console.log("Staking System Status Dashboard");
        console.log("Current Block Time:", block.timestamp);
        console.log("Target Contract:   ", stakingAddr);
        console.log("====================================================");

        // --- 3. 全局指标 (Global Metrics) ---
        console.log(">>> GLOBAL METRICS");
        console.log("Total Weight:      ", staking.totalWeight());
        console.log("Reward Rate:       ", staking.rewardRate());
        console.log("Reward Per Token:  ", staking.rewardPerToken());
        console.log("Undistributed:     ", staking.undistributedRewards());
        console.log("Period Finish:     ", staking.periodFinish());
        
        // --- 4. 用户指标 (User Metrics: Alice) ---
        console.log("");
        console.log(">>> USER: ALICE (Derived from ALICE_PK)");
        console.log("Address:           ", alice);
        console.log("Total Weight:      ", staking.userTotalWeight(alice));
        console.log("Pending Rewards:   ", staking.earned(alice));

        // 遍历所有可能的质押档位 (0-3)
        for (uint256 i = 0; i < 4; i++) {
            (uint256 amount, uint256 weight, uint256 unlockTime) = staking.userLocks(alice, i);
            
            if (amount > 0) {
                console.log("--------------------------------");
                console.log("Tier Index:", i);
                console.log("  Staked Amount:  ", amount);
                console.log("  Weight Contrib: ", weight);
                
                if (block.timestamp < unlockTime) {
                    console.log("  Status:          LOCKED");
                    console.log("  Seconds Left:   ", unlockTime - block.timestamp);
                } else {
                    console.log("  Status:          READY TO WITHDRAW");
                }
            }
        }
        console.log("====================================================");
    }
}