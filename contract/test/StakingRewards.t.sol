// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/StakingRewards.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract StakingRewardsTest is Test {
    StakingRewards public staking;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // 1. 部署环境
        stakingToken = new MockERC20("Staking Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RTK");

        // 2. 部署合约
        staking = new StakingRewards(address(stakingToken), address(rewardToken));

        // -----------------------------------------------------------
        // 3. 系统配置阶段
        // -----------------------------------------------------------
        // 显式设置奖励周期
        uint256 duration = 7 days;
        staking.setRewardsDuration(duration);

        // 4. 资金注入与初始化
        uint256 initRate = 100e18;
        uint256 totalReward = initRate * duration;
        rewardToken.mint(address(staking), totalReward);
        staking.notifyRewardAmount(totalReward);

        // 5. 用户初始化
        stakingToken.mint(alice, 1000e18);
        stakingToken.mint(bob, 1000e18);
        // 预先授权：让 Alice 和 Bob 允许合约划转他们的 STK
        vm.prank(alice);
        stakingToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(staking), type(uint256).max);
    }

    /// @dev 用例 1：验证单用户线性收益
    function test_SingleUserRewards() public {
        uint256 amount = 100e18;
        // Alice 质押
        vm.prank(alice);
        staking.stake(amount, 0);

        // --- 时空传送：快进 10 秒 ---
        vm.warp(block.timestamp + 10);

        // 预期收益 = 10s * 100 rate = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");
    }

    /// @dev 用例 2：验证多用户分摊收益 (核心算法)
    function test_MultiUserFairSplit() public {
        // T=0: Alice 存 100，weight tier 0 1x
        vm.prank(alice);
        staking.stake(100e18, 0);

        // T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 独享 10 * 100 = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");

        // T=10: Bob 也存 100，weight tier 3 3x
        // weight：Alice是100（占0.25），Bob是300（占0.75），总weight是400
        vm.prank(bob);
        staking.stake(100e18, 3);

        // T=20: 再快进 10 秒
        vm.warp(block.timestamp + 10);

        // 此时这 10 秒产生的 1000 奖励按比例分 (250/750)
        // Alice 总计: 1000 + 250 = 1250
        // Bob 总计: 750
        assertEq(staking.earned(alice), 1250e18, "Alice should earn 1250 tokens");
        assertEq(staking.earned(bob), 750e18, "Bob should earn 750 tokens");
    }

    /// @dev 用例 3：验证同一用户在增减本金后，后续收益的计算是否即时调整。
    function test_SingleUserDynamicWeighting() public {
        // T=0: Alice 存 100，weight tier0 1x
        vm.prank(alice);
        staking.stake(100e18, 0);

        // T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 独享 10 * 100 = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");

        // T=10: Alice 再存 100，weight tier3 3x
        vm.prank(alice);
        staking.stake(100e18, 3);

        // T=20: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 还是独享 10 * 100 = 1000
        // Alice earn：1000 + 1000 = 2000 
        assertEq(staking.earned(alice), 2000e18, "Alice should earn 2000 tokens");

        // T=20: Bob 存 100，weight tier0 1x
        // weight：Alice 400 占 80%，Bob 100 占 20%
        vm.prank(bob);
        staking.stake(100e18, 0);

        // T=30: 快进 10 秒
        // 此时这 10 秒产生的 1000 奖励按比例分 (800/200)
        // Alice 总计: 2000 + 800 = 2800
        // Bob 总计: 200
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 2800e18, "Alice should earn 2800 tokens");
        assertEq(staking.earned(bob), 200e18, "Bob should earn 200 tokens");
    }

    /// @dev 用例 4：确保 stake 和 withdraw 不仅仅是修改了变量，还要真实地转移了代币，
    /// 且 totalSupply 永远等于所有用户 balance 的总和。
    function test_FundFlowIntegrity() public {
        uint256 stakeAmount = 100e18;
        uint256 tierIndex = 3;
        uint256 expectedWeight = stakeAmount * tierIndex;

        // 1. 记录操作前的状态 (Snapshots)
        uint256 aliceStakingBefore = stakingToken.balanceOf(alice);
        uint256 contractStakingBefore = stakingToken.balanceOf(address(staking));

        // 2. 执行质押操作
        vm.prank(alice);
        staking.stake(stakeAmount, tierIndex);

        // 3. 验证质押后的物理账本 (Token Flow)
        uint256 aliceStakingAfter = stakingToken.balanceOf(alice);
        uint256 contractStakingAfter = stakingToken.balanceOf(address(staking));
        // 验证 Alice 的代币确实减少了
        assertEq(aliceStakingBefore - aliceStakingAfter, stakeAmount, "Alice's token balance should decrease by stakeAmount");
        // 验证合约收到了这笔钱
        assertEq(contractStakingAfter - contractStakingBefore, stakeAmount, "Contract's token balance should increase by stakeAmount");

        // 4. 验证质押后的逻辑账本 (Internal Accounting)
        // 检查具体档位的本金和权重
        (uint256 amount, uint256 weight, uint256 unlockTime) = staking.userLocks(alice, tierIndex);
        assertEq(amount, stakeAmount, "Tier principal should match stakeAmount");
        assertEq(weight, expectedWeight, "Tier weight should be 3x");
        assertEq(unlockTime, block.timestamp + 365 days, "Unlock time should be 1 year from now");

        // 检查全局和用户总权重
        assertEq(staking.userTotalWeight(alice), expectedWeight, "User total weight should match");
        assertEq(staking.totalWeight(), expectedWeight, "Global total weight should match");
        
        // 5. 尝试提前取钱：预期失败 (Safety Check)
        uint256 withdrawAmount = 40e18;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.Locked.selector, unlockTime));
        staking.withdraw(withdrawAmount, tierIndex);

        // 6. 拨动时钟：快进 1 年零 1 秒 (Time Warp)
        vm.warp(block.timestamp + 365 days + 1);

        // 7. 执行取钱操作
        vm.prank(alice);
        staking.withdraw(withdrawAmount, tierIndex);

        // 8. 验证取钱后的最终账本
        uint256 expectedRemainAmount = stakeAmount - withdrawAmount;
        uint256 expectedRemainWeight = expectedRemainAmount * tierIndex;

        // 验证物理代币
        assertEq(stakingToken.balanceOf(address(staking)), contractStakingBefore + expectedRemainAmount);        
        
        // 验证逻辑权重更新
        assertEq(staking.userTotalWeight(alice), expectedRemainWeight, "User total weight should decrease proportionally");
        assertEq(staking.totalWeight(), expectedRemainWeight, "Global total weight should decrease proportionally");
        
        // 验证该档位的本金更新
        (uint256 finalAmount, ,) = staking.userLocks(alice, tierIndex);
        assertEq(finalAmount, expectedRemainAmount, "Tier principal should match remaining");
    }

    /// @dev 用例 5：验证 getReward 是否正确触发了“转账 + 清零”的原子操作。
    function test_ClaimingAtomicity_WithWeight() public {
        // 1. T=0: Alice 质押 100 STK，选择 Tier 1 (90 days, 1.5x multiplier)
        uint256 stakeAmount = 100e18;
        uint256 tierIndex = 1; // 1.5x 权重
        
        vm.prank(alice);
        staking.stake(stakeAmount, tierIndex);

        // 2. T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);

        // 计算预期收益：由于 Alice 是当前唯一质押者，她拥有 100% 的权重
        // 预期收益 = 10秒 * 每秒奖励速率
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected - 100, "Should match after rounding loss");

        // 3. 第一次领取奖励
        // aliceRewardBefore = 0
        uint256 aliceRewardBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.getReward();

        uint256 aliceRewardAfter = rewardToken.balanceOf(alice);

        // --- 验证点 1: 奖励代币真实到账 ---
        assertEq(aliceRewardAfter - aliceRewardBefore, expected - 100, "Alice should receive exactly 1000 reward tokens");

        // --- 验证点 2: 逻辑账本状态重置 ---
        // 即使 Alice 的本金还在锁定期（90天），她的“已实现收益”在领取后必须归零
        assertEq(staking.earned(alice), 0, "Earned rewards should be reset to 0");
        assertEq(staking.rewards(alice), 0, "Internal rewards mapping should be deleted");

        // --- 验证点 3: 锁仓状态不受领取影响 ---
        // 确保领取奖励后，Alice 的本金和解锁时间依然完好无损
        (uint256 lockAmount, , uint256 unlockTime) = staking.userLocks(alice, tierIndex);
        assertEq(lockAmount, stakeAmount, "Principal should still be locked");
        assertTrue(block.timestamp < unlockTime, "Position should still be within lock-up period");
        
        // 4. 再次调用 getReward() (防二次领取测试)
        vm.prank(alice);
        staking.getReward();

        uint256 balanceAfterSecondClaim = rewardToken.balanceOf(alice);

        // --- 验证点 3: 余额不应再增加 ---
        // assertEq(aliceRewardAfter, balanceAfterSecondClaim);
        assertEq(balanceAfterSecondClaim, aliceRewardAfter, "Second claim should not transfer any tokens");
    }

    /// @dev 用例 6：超支提现 (Insufficient Balance)
    function test_RevertInsufficientBalance() public {
        uint256 stakeAmount = 100e18;
        uint256 tierIndex = 0; // 假设选 30 天的档位
        vm.startPrank(alice);
        staking.stake(stakeAmount, tierIndex);

        vm.warp(block.timestamp + 31 days);

        // 告诉虚拟机：下一行代码必须报错，且报错信息要包含 InsufficientBalance
        vm.expectRevert(StakingRewards.InsufficientBalance.selector);
        staking.withdraw(stakeAmount + 1, tierIndex);
        vm.stopPrank();
    }

    /// @dev 用例7：测试 stake 的鲁棒性
    function testFuzz_Stake(uint256 amount, uint256 tierIndex) public {
        // 1. 约束输入范围 (Constraints)
        // 限制金额：1 wei 到 Alice 的初始余额 (1000e18)
        amount = bound(amount, 1, 1000e18);
        // 限制档位：必须在 stakingPeriods 数组范围内 (0 到 3)
        tierIndex = bound(tierIndex, 0, 3);

        // 2. 获取预期的配置数据 (用于计算预期值)
        (uint32 duration, uint16 multiplier) = staking.stakingPeriods(tierIndex);
        uint256 expectedWeight = (amount * uint256(multiplier)) / 100;
        uint256 expectedUnlockTime = block.timestamp + duration;
        
        // 3. 执行操作
        vm.prank(alice);
        staking.stake(amount, tierIndex);

        // 4. 验证物理不变性 (Physical Invariants)
        // 合约里存的 Token 必须等于本次质押的 amount
        assertEq(stakingToken.balanceOf(address(staking)), amount, "Contract token balance mismatch");

        // 5. 验证逻辑不变性 (Logical Invariants)
        // 验证特定档位的账本记录
        (uint256 actualAmount, uint256 actualWeight, uint256 actualUnlockTime) = staking.userLocks(alice, tierIndex);
        assertEq(actualAmount, amount, "Stored amount mismatch");
        assertEq(actualWeight, expectedWeight, "Calculated weight mismatch");
        assertEq(actualUnlockTime, expectedUnlockTime, "Unlock time mismatch");

        // 验证聚合索引
        assertEq(staking.userTotalWeight(alice), expectedWeight, "User total weight mismatch");
        assertEq(staking.totalWeight(), expectedWeight, "Global total weight mismatch");
    }

    /// @dev 用例8：构造函数“零地址”检查
    function test_RevertIfAddressZero() public {
        // 验证 Staking Token 为零地址
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(address(0), address(rewardToken));

        // 验证 Reward Token 为零地址
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(address(stakingToken), address(0));
    }

    /// @dev 用例9A：存零金额拦截
    function test_RevertIfStakeZero() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.stake(0, 0);
    }

    /// @dev 用例9B：取零金额拦截
    function test_RevertIfWithdrawZero() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.withdraw(0, 0);
    }

    /// @dev 用例10：验证“平滑合并”逻辑
    function test_NotifyRewardAmount_ContinuousInjection() public {
        // 1. T=0 初始状态 (setUp 已注入 100/s)
        assertEq(staking.rewardRate(), 100e18);

        // 2. 快进到 3.5 天（周期刚好过半）
        vm.warp(block.timestamp + 3.5 days);

        // 此时剩余奖励应该还有一半：100 * 3.5 days
        uint256 oldRate = staking.rewardRate();
        uint256 remaining = 0;
        if (block.timestamp < staking.periodFinish()) {
            remaining = (staking.periodFinish() - block.timestamp) * oldRate;
        }
        uint256 applicable = staking.lastTimeRewardApplicable();
        uint256 elapsed = applicable - staking.lastUpdateTime();
        uint256 undistributed = elapsed * oldRate;

        // 3. 管理员再次注入一笔新的奖励
        uint256 newAmount = 7000e18;
        rewardToken.mint(address(staking), newAmount);
        staking.notifyRewardAmount(newAmount);

        // 4. 验证新流速是否符合公式：(剩余 + 新增) / 7天
        uint256 expectedRate = (remaining + newAmount + undistributed) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expectedRate, "Reward rate should merge smoothly");
        assertEq(staking.undistributedRewards(), 0, "undistributedRewards should be empty");
    }

    /// @dev 用例11：setRewardsDuration 报错路径
    function test_RevertIf_SetDurationDuringActivePeriod() public {
        // 因为 setUp 已经启动了奖励，此时 periodFinish 在未来
        vm.expectRevert(StakingRewards.RewardPeriodActive.selector);
        staking.setRewardsDuration(14 days);
    }

    /// @dev 用例12：setRewardsDuration 成功路径 + Funcs 覆盖
    function test_SetDurationAfterPeriodFinish() public {
        // 快进到当前奖励周期结束之后
        vm.warp(staking.periodFinish() + 1);

        uint256 newDuration = 14 days;
        staking.setRewardsDuration(newDuration);
        assertEq(staking.rewardsDuration(), newDuration);
    }

    /// @dev 用例13：getReward 的 "if (rewardToClaim > 0)" 为假的情况
    function test_GetReward_WithZeroRewards() public {
        // 让一个从未质押过的地址（比如新创建的 charlie）去领钱
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        staking.getReward();

        // 验证 charlie 依然没钱，且合约没有因为 zero transfer 报错
        assertEq(rewardToken.balanceOf(charlie), 0);
    }

    /// @dev 用例14: rewardPerToken() 当 totalSupply 为 0 时的分支
    function test_RewardPerToken_ZeroSupply() public view {
        // 此时没有任何人质押
        assertEq(staking.totalWeight(), 0);
        // 验证它直接返回 rewardPerTokenStored (初始为 0)
        assertEq(staking.rewardPerToken(), 0);
    }

    /// @dev 用例15: notifyRewardAmount 偿付能力不足的报错分支
    function test_RevertIf_AdminNotifyWithoutEnoughBalance() public {
        // 假设要注入 1000e18，但我们不给合约打钱
        uint256 hugeAmount = 1000e18;

        // 预期报错 InsufficientBalance
        vm.expectRevert(StakingRewards.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(hugeAmount);
    }

    /// @dev 用例16: 验证全额提现后的状态清理，以及二次质押时解锁时间的重新计算
    function test_StateResetAfterFullWithdraw() public {
        uint256 stakeAmount = 100e18;
        uint256 tierIndex = 2; // Tier 2: 180 days
        (uint32 duration, ) = staking.stakingPeriods(tierIndex);

        // --- 第一阶段：质押并彻底清空 ---
        vm.prank(alice);
        staking.stake(stakeAmount, tierIndex);

        // 快进 180 天 + 1 秒，确保已经解锁
        vm.warp(block.timestamp + duration + 1);

        vm.prank(alice);
        staking.withdraw(stakeAmount, tierIndex);

        // 【核心验证点 1】：检查 delete 关键字是否生效（存储回收）
        // 在全额提现后，对应的映射记录应该被重置为初始状态（全 0）
        (uint256 amount, uint256 weight, uint256 unlockTime) = staking.userLocks(alice, tierIndex);

        assertEq(amount, 0, "Principal record should be cleared");
        assertEq(weight, 0, "Weight record should be cleared");
        assertEq(unlockTime, 0, "Unlock time should be reset to 0");
        assertEq(staking.userTotalWeight(alice), 0, "User's global total weight should be set to 0.");

        // --- 第二阶段：冷启动验证（重新质押） ---
        // 再次快进 20 天，模拟不连续的操作时间点
        uint256 secondWarp = 20 days;
        vm.warp(block.timestamp + secondWarp);

        // 计算本次质押预期的解锁时间：当前时间 + 180 天
        uint256 expectedUnlockTime = block.timestamp + 180 days;

        vm.prank(alice);
        staking.stake(stakeAmount, tierIndex);

        // 【核心验证点 2】：验证解锁时间是否是“新鲜”计算的
        // 确保 unlockTime 是基于“当前时间”重新开始的，而不是基于“旧时间”或者累加的
        (,, uint256 newUnlockTime) = staking.userLocks(alice, tierIndex);

        assertEq(newUnlockTime, expectedUnlockTime, "New unlockTime should be calculated from current timestamp");
        // 逻辑验证：新的解锁时间必须远晚于第一次质押的解锁时间
        assertTrue(newUnlockTime > unlockTime, "New unlock must be far in the future");
    }

    /// @dev 用例 17: 验证非法档位索引拦截
    function test_RevertIf_InvalidTierIndex() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.InvalidPeriodIndex.selector);
        staking.stake(100e18, 4);
    }

    /// @dev 用例 18: 验证同档位加仓后，解锁时间是否按当前时间重新顺延
    function test_CompoundLockTimeReset() public {
        uint256 tierIndex = 1; // 90 days
        vm.startPrank(alice);

        // 第一次质押
        staking.stake(100e18, tierIndex);
        (,, uint256 firstUnlock) = staking.userLocks(alice, tierIndex);

        // 快进 10 天
        vm.warp(block.timestamp + 10 days);

        // 第二次质押
        staking.stake(500e18, tierIndex);
        (,, uint256 secondUnlock) = staking.userLocks(alice, tierIndex);

        // 验证：解锁时间应该是“当前时间 + 90天”，而不是“旧时间 + 90天”
        assertEq(secondUnlock, block.timestamp + 90 days, "The unlock time should be reset according to the time of adding to the position.");
        assertTrue(secondUnlock > firstUnlock, "The unlock time must be postponed to prevent arbitrage by adding positions at the end of the trading day.");

        vm.stopPrank();
    }

    /// @dev 用例 19: 验证非管理员无法修改奖励周期
    function test_RevertIf_NonOwnerSetsDuration() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setRewardsDuration(7 days);
    }

    /// @dev 用例 20: 验证奖励周期结束后，收益停止增长
    function test_RewardsStopAtPeriodFinish() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        // 快进到奖励周期结束之后
        vm.warp(staking.periodFinish() + 100 days);

        uint256 rewardAtFinish = staking.earned(alice);
        // 再快进 10 天
        vm.warp(block.timestamp + 10 days);
        // 收益应该保持不变
        assertEq(staking.earned(alice), rewardAtFinish, "Reward should cease accumulating at the end of the period.");
    }

    /// @dev 用例 21: 验证用户在多个档位质押时，收益是否正确聚合
    function test_EarnedAggregationAcrossTiers() public {
        // Alice 在 Tier 0 (1x) 存 100 -> 权重 100
        vm.prank(alice);
        staking.stake(100e18, 0);

        // Alice 在 Tier 3 (3x) 存 100 -> 权重 300
        vm.prank(alice);
        staking.stake(100e18, 3);

        // 总权重应为 400
        assertEq(staking.userTotalWeight(alice), 400e18);

        vm.warp(block.timestamp + 10);
        // 预期收益 = 10s * 100 rate = 1000 RTK (因为 Alice 是唯一质押者)
        uint256 expect = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expect);
    }

    /// @dev 用例22 Rollover: no one can back-claim rewards from a zero-weight window
    function test_Rollover_NoStake_UserCannotBackClaim() public {
        // T0 -> T+1day, no staker
        vm.warp(block.timestamp + 1 days);

        // Alice stakes after zero-weight window
        vm.prank(alice);
        staking.stake(100e18, 0);

        // Immediately after staking, should not include previous zero-weight window
        assertEq(staking.earned(alice), 0, "Should not back-claim zero-weight window rewards");

        // Move 10s forward, now Alice should earn normally
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 10 * staking.rewardRate(), "Should accrue after stake time only");
    }

    /// @dev 用例23 Rollover: undistributed rewards accumulate across multiple zero-weight windows
    function test_Rollover_AccumulatesAcrossMultipleZeroWeightWindows() public {
        // Window A: 空仓 1 天，产生的奖励应进入未分配池
        vm.warp(block.timestamp + 1 days);

        // 通过 notify(0) 触发全局结算，把 Window A 的未分配奖励并入新周期并清零
        staking.notifyRewardAmount(0);
        uint256 a = staking.undistributedRewards();
        // 当前实现中 notify 会立刻合并并清空未分配池
        assertEq(a, 0, "If notify merges queued rewards, this should be zero after notify");

        // Window B 前插入一段“有质押窗口”，确保未分配只来自空仓时间
        vm.prank(alice);
        staking.stake(100e18, 0);
        // 等锁仓结束后提现，回到 totalWeight == 0
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(alice);
        staking.withdraw(100e18, 0);

        // Window B: 再空仓 1 天，产生新的未分配奖励
        vm.warp(block.timestamp + 1 days);

        // 按合约真实逻辑计算期望：remaining + newAmount + undistributed
        uint256 oldRate = staking.rewardRate();
        uint256 remaining = 0;
        if (block.timestamp < staking.periodFinish()) {
            remaining = (staking.periodFinish() - block.timestamp) * oldRate;
        }
        // 必须用 lastTimeRewardApplicable() 截断到 periodFinish
        uint256 undistributed = (staking.lastTimeRewardApplicable() - staking.lastUpdateTime()) * oldRate;

        uint256 newAmount = 1000e18;
        rewardToken.mint(address(staking), newAmount);
        staking.notifyRewardAmount(newAmount);

        uint256 expectedRate = (remaining + newAmount + undistributed) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expectedRate, "Rollover should include latest zero-weight window");
        assertEq(staking.undistributedRewards(), 0, "Queued rewards should be consumed");
    }

    /// @dev 用例24 Rollover: no double counting after first notify consumed queued rewards
    function test_Rollover_NoDoubleCount_AfterNotifyTwice() public {
        // 先空仓一段时间，制造可被 rollover 的未分配奖励
        vm.warp(block.timestamp + 1 days);

        // 第一次 notify：应把 undistributed 合并进 rewardRate
        uint256 oldRate1 = staking.rewardRate();
        uint256 remaining1 = 0;
        if (block.timestamp < staking.periodFinish()) {
            remaining1 = (staking.periodFinish() - block.timestamp) * oldRate1;
        }
        uint256 applicable1 = staking.lastTimeRewardApplicable();
        uint256 undistributed1 = (applicable1 - staking.lastUpdateTime()) * oldRate1;
        
        uint256 amt1 = 1000e18;
        rewardToken.mint(address(staking), amt1);
        staking.notifyRewardAmount(amt1);

        uint256 expected1 = (remaining1 + amt1 + undistributed1) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expected1, "First notify should consume queued rewards");
        assertEq(staking.undistributedRewards(), 0);

        // 立即第二次 notify：elapsed ~= 0，不应重复合并上一次已消费的 undistributed
        uint256 oldRate2 = staking.rewardRate();
        uint256 remaining2 = 0;
        if (block.timestamp < staking.periodFinish()) {
            remaining2 = (staking.periodFinish() - block.timestamp) * oldRate2;
        }
        uint256 applicable2 = staking.lastTimeRewardApplicable();
        uint256 undistributed2 = (applicable2 - staking.lastUpdateTime()) * oldRate2;
        assertEq(undistributed2, 0, "undistributed2 should be 0 because elapsed2 is 0");

        uint256 amt2 = 500e18;
        rewardToken.mint(address(staking), amt2);
        staking.notifyRewardAmount(amt2);

        uint256 expected2 = (remaining2 + amt2 + undistributed2) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expected2, "Second notify must not double-count prior queued rewards");
        assertEq(staking.undistributedRewards(), 0);
    }

    /// @dev 用例25 Rollover: active-period notify includes remaining + newAmount + queued
    function test_Rollover_WithActivePeriodRemainingAndNewAmount() public {
        // Keep zero-weight, advance half period
        vm.warp(block.timestamp + 3.5 days);

        uint256 oldRate = staking.rewardRate();
        uint256 remaining = 0;
        if (block.timestamp < staking.periodFinish()) {
            remaining = (staking.periodFinish() - block.timestamp) * oldRate;
        }
        uint256 applicable = staking.lastTimeRewardApplicable();
        uint256 undistributed = (applicable - staking.lastUpdateTime()) * oldRate;
    
        uint256 newAmount = 7000e18;
        rewardToken.mint(address(staking), newAmount);
        staking.notifyRewardAmount(newAmount);

        uint256 expectedRate = (remaining + newAmount + undistributed) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expectedRate, "Rate must merge remaining + new + rollover");
        assertEq(staking.undistributedRewards(), 0, "Rollover pool should be cleared after merge");
    }

    /// @dev 用例26 余数累计：同用户同档位小额多次质押能凑整
    function test_RemainderAccumulation_SameUserSameTier() public {
        uint256 tier = 1;

        // 第一次质押 1，raw=150 -> weight=1, remainder=50
        vm.prank(alice);
        staking.stake(1, tier);

        (uint256 am1, uint256 w1, ) = staking.userLocks(alice, tier);
        assertEq(am1, 1, "amount after first tiny stake");
        assertEq(w1, 1, "weight after first tiny stake");
        assertEq(staking.weightRemainder(alice, tier), 50, "remainder after first stake");

        // 第二次质押 1，raw=1*150 + 50 = 200 -> weight=2, remainder=0
        vm.prank(alice);
        staking.stake(1, tier);
        (uint256 am2, uint256 w2, ) = staking.userLocks(alice, tier);
        assertEq(am2, 2, "amount after second tiny stake, amount should increase by 1 on second stake");
        assertEq(w2, 3, "weight after second tiny stake, weight should increase by 2 on second stake");
        assertEq(staking.weightRemainder(alice, tier), 0, "remainder should be consumed");
    }

    /// @dev 用例27 余数隔离：不同档位余数互不影响
    function test_RemainderIsolation_DifferentTiers() public {
        vm.prank(alice);
        staking.stake(1, 1); // remainder 50
        vm.prank(alice);
        staking.stake(1, 0); // remainder 0

        assertEq(staking.weightRemainder(alice, 1), 50);
        assertEq(staking.weightRemainder(alice, 0), 0);
    }

    /// @dev 用例28 余数隔离：不同用户余数互不影响
    function test_RemainderIsolation_DifferentUsers() public {
        vm.prank(alice);
        staking.stake(1, 1); // remainder 50
        vm.prank(bob);
        staking.stake(1, 1); // remainder 50

        assertEq(staking.weightRemainder(alice, 1), 50);
        assertEq(staking.weightRemainder(bob, 1), 50);
    }

    /// @dev 用例29 部分提现：按仓位比例扣减权重
    function test_Withdraw_ProportionalWeightRemoval_WithRemainder() public {
        uint256 tier = 1; // 1.5x
        vm.prank(alice);
        staking.stake(3, tier); // raw=450 -> weight=4, remainder=50

        // 解锁
        (uint256 oldAmount, uint256 oldWeight, uint256 unlock) = staking.userLocks(alice, tier);
        assertEq(oldAmount, 3, "oldAmount should be 3");
        assertEq(oldWeight, 4, "oldWeight should be 4");
        assertEq(staking.weightRemainder(alice, tier), 50, "oldRemainder should be 50");
        
        vm.warp(unlock + 1);

        // 提现 1/3
        vm.prank(alice);
        staking.withdraw(1, tier);

        (uint256 newAmount, uint256 newWeight,) = staking.userLocks(alice, tier);
        assertEq(newAmount, 2, "newAmount should be 2");
        // 原 weight=4，按比例扣 1/3 => remove 1 (floor), remaining 3
        assertEq(newWeight, 3, "newWeight should be 3");
        assertEq(staking.userTotalWeight(alice), 3);
    }

    /// @dev 用例30 全额提现：清理余数
    function test_Withdraw_FullExit_ClearsRemainder() public {
        uint256 tier = 1;
        vm.prank(alice);
        staking.stake(1, tier);

        (, , uint256 unlock) = staking.userLocks(alice, tier);
        vm.warp(unlock + 1);

        vm.prank(alice);
        staking.withdraw(1, tier);

         (uint256 amount, uint256 weight, uint256 unlockTime) = staking.userLocks(alice, tier);
        assertEq(amount, 0);
        assertEq(weight, 0);
        assertEq(unlockTime, 0);
        assertEq(staking.weightRemainder(alice, tier), 0);
    }

    /// @dev 用例31 设置 minStakeAmount 门槛后，小于门槛应回退
    function test_RevertIf_StakeBelowMinimum() public {
        vm.prank(staking.owner());
        staking.setMinStakeAmount(100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StakeBelowMinimum.selector, 100));
        staking.stake(99, 0);
    }
    
    /// @dev 用例32 非 owner 不能设置门槛
    function test_RevertIf_NonOwnerSetMinStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setMinStakeAmount(100);
    }

    /// @dev 用例33 关闭门槛后可再次小额质押
    function test_MinStake_ToggleOff() public {
        vm.prank(staking.owner());
        staking.setMinStakeAmount(100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StakeBelowMinimum.selector, 100));
        staking.stake(99, 0);

        vm.prank(staking.owner());
        staking.setMinStakeAmount(0);

        vm.prank(alice);
        staking.stake(1, 0);
    }

    /// @dev 用例34 pause 阻止 stake
    function test_PauseBlocksStake() public {
        vm.prank(staking.owner());
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        staking.stake(100e18, 0);
    }

    /// @dev 用例35 pause 阻止 withdraw
    function test_PauseBlocksWithdraw() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        vm.prank(staking.owner());
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        staking.withdraw(1e18, 0);
    }

    /// @dev 用例36 pause 阻止 getReward
    function test_PauseBlocksGetReward() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        vm.prank(staking.owner());
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        staking.getReward();
    }

    /// @dev 用例37 unpause 恢复 stake
    function test_UnpauseRestores() public {
        vm.prank(staking.owner());
        staking.pause();
        vm.prank(staking.owner());
        staking.unpause();

        vm.prank(alice);
        staking.stake(100e18, 0);
    }

    /// @dev 用例38 超过上限应回退
    function test_RevertIf_StakeAboveUserCap() public {
        vm.prank(staking.owner());
        staking.setMaxStakePerUser(100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StakeAboveUserCap.selector, 100));
        staking.stake(101, 0);
    }

    /// @dev 用例39 等于上限可质押
    function test_StakeAtUserCap_Succeeds() public {
        vm.prank(staking.owner());
        staking.setMaxStakePerUser(100);

        vm.prank(alice);
        staking.stake(100, 0);
        assertEq(staking.userTotalStaked(alice), 100);
    }

    /// @dev 用例40 提现后可继续质押（上限重新腾出）
    function test_UserCap_AllowsRestakeAfterWithdraw() public {
        vm.prank(staking.owner());
        staking.setMaxStakePerUser(100);

        vm.prank(alice);
        staking.stake(100, 0);

        (, , uint256 unlock) = staking.userLocks(alice, 0);
        vm.warp(unlock + 1);

        vm.prank(alice);
        staking.withdraw(60, 0);

        vm.prank(alice);
        staking.stake(60, 0);

        assertEq(staking.userTotalStaked(alice), 100);
    }

    /// @dev 用例41 非 owner 不能设置上限
    function test_RevertIf_NonOwnerSetsMaxStakePerUser() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setMaxStakePerUser(100);
    }

    /// @dev 用例42 关闭上限（0）后可任意质押
    function test_MaxStake_ToggleOff() public {
        vm.prank(staking.owner());
        staking.setMaxStakePerUser(100);

        vm.prank(staking.owner());
        staking.setMaxStakePerUser(0);

        vm.prank(alice);
        staking.stake(1000, 0);
    }

    /// @dev 用例43 余数在部分提现后应按比例缩减，避免权重虚增
    function test_Remainder_ScalesDown_OnPartialWithdraw() public {
        uint256 tier = 1;
        // stake(3): raw=450 -> weight=4, remainder=50
        vm.prank(alice);
        staking.stake(3, tier);

        (uint256 amount1, uint256 weight1, uint256 unlock) = staking.userLocks(alice, tier);
        assertEq(amount1, 3);
        assertEq(weight1, 4);
        assertEq(staking.weightRemainder(alice, tier), 50);

        // 解锁后部分提现 1
        vm.warp(unlock + 1);
        vm.prank(alice);
        staking.withdraw(1, tier);

        (uint256 amount2, uint256 weight2, ) = staking.userLocks(alice, tier);
        assertEq(amount2, 2);
        assertEq(weight2, 3);
        // 余数应按比例缩为 50 * 2 / 3 = 33 (floor)
        assertEq(staking.weightRemainder(alice, tier), 33);
        
        // 再 stake(1): raw=150+33=183 -> weightAdded=1 -> total weight=4
        vm.prank(alice);
        staking.stake(1, tier);

        (uint256 amount3, uint256 weight3, ) = staking.userLocks(alice, tier);
        assertEq(amount3, 3);
        assertEq(weight3, 4);
        assertEq(staking.weightRemainder(alice, tier), 83);
    }

    /// @dev 用例44 emergencyWithdraw：暂停期可无视锁仓提回本金，且不发奖励
    function test_EmergencyWithdraw_BypassesLockAndSkipsRewards() public {
        // 先质押
        vm.prank(alice);
        staking.stake(100e18, 0);

        // 产生一些奖励
        vm.warp(block.timestamp + 10);

        // 暂停
        vm.prank(staking.owner());
        staking.pause();

        // 紧急退出：不需要等解锁
        uint256 aliceBefore = stakingToken.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyWithdraw(40e18, 0);

        uint256 aliceAfter = stakingToken.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 40e18, "principal should be returned");

        // 奖励应被清零
        assertEq(staking.rewards(alice), 0, "rewards should be cleared on emergency withdraw");
    }

    /// @dev 用例45 emergencyWithdraw：部分退出后权重与余数同步更新
    function test_EmergencyWithdraw_PartialUpdatesState() public {
        uint256 tier = 1; // 1.5x
        vm.prank(alice);
        staking.stake(3, tier); // weight=4, remainder=50

        vm.prank(staking.owner());
        staking.pause();

        vm.prank(alice);
        staking.emergencyWithdraw(1, tier);

        (uint256 amount, uint256 weight, ) = staking.userLocks(alice, tier);
        assertEq(amount, 2);
        assertEq(weight, 3);
        // 余数按比例缩减：50 * 2 / 3 = 33
        assertEq(staking.weightRemainder(alice, tier), 33);
    }

    /// @dev 用例46 emergencyWithdraw：仅在暂停期可用
    function test_EmergencyWithdraw_RevertsWhenNotPaused() public {
        vm.prank(alice);
        staking.stake(100e18, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        staking.emergencyWithdraw(10e18, 0);
    }

    /// @dev 用例47 emergencyWithdraw：全额退出清理仓位和余数
    function test_EmergencyWithdraw_FullExitClearsState() public {
        uint256 tier = 1;
        vm.prank(alice);
        staking.stake(1, tier);

        vm.prank(staking.owner());
        staking.pause();

        vm.prank(alice);
        staking.emergencyWithdraw(1, tier);

        (uint256 amount, uint256 weight, uint256 unlockTime) = staking.userLocks(alice, tier);
        assertEq(amount, 0);
        assertEq(weight, 0);
        assertEq(unlockTime, 0);
        assertEq(staking.weightRemainder(alice, tier), 0);
    }

}
