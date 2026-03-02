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
        staking.stake(amount);

        // --- 时空传送：快进 10 秒 ---
        vm.warp(block.timestamp + 10);

        // 预期收益 = 10s * 100 rate = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");
    }

    /// @dev 用例 2：验证多用户分摊收益 (核心算法)
    function test_MultiUserFairSplit() public {
        // T=0: Alice 存 100
        vm.prank(alice);
        staking.stake(100e18);

        // T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 独享 10 * 100 = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");

        // T=10: Bob 也存 100，总额变为 200，各占 50%
        vm.prank(bob);
        staking.stake(100e18);

        // T=20: 再快进 10 秒
        vm.warp(block.timestamp + 10);

        // 此时这 10 秒产生的 1000 奖励应平分 (500/500)
        // Alice 总计: 1000 + 500 = 1500
        // Bob 总计: 500
        assertEq(staking.earned(alice), 1500e18, "Alice should earn 1500 tokens");
        assertEq(staking.earned(bob), 500e18, "Bob should earn 500 tokens");
    }

    /// @dev 用例 3：验证同一用户在增减本金后，后续收益的计算是否即时调整。
    function test_SingleUserDynamicWeighting() public {
        // T=0: Alice 存 100
        vm.prank(alice);
        staking.stake(100e18);

        // T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 独享 10 * 100 = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");

        // T=10: Alice 再存 300
        vm.prank(alice);
        staking.stake(300e18);

        // T=20: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时虽然本金变了，但 Alice 还是独享 10 * 100 = 1000
        assertEq(staking.earned(alice), 2000e18, "Alice should earn 2000 tokens");

        // T=20: Bob 存 100，总额变为 500，Alice 占 80%，Bob 占 20%
        vm.prank(bob);
        staking.stake(100e18);

        // T=30: 快进 10 秒
        // 此时这 10 秒产生的 1000 奖励按比例分 (800/200)
        // Alice 总计: 2000 + 800 = 2800
        // Bob 总计: 200
        vm.warp(block.timestamp + 10);
        assertEq(staking.earned(alice), 2800e18, "Alice should earn 2500 tokens");
        assertEq(staking.earned(bob), 200e18, "Bob should earn 500 tokens");
    }

    /// @dev 用例 4：确保 stake 和 withdraw 不仅仅是修改了变量，还要真实地转移了代币，
    /// 且 totalSupply 永远等于所有用户 balance 的总和。
    function test_FundFlowIntegrity() public {
        uint256 stakeAmount = 100e18;

        // 1. 记录操作前的状态 (Snapshots)
        uint256 aliceStakingBefore = stakingToken.balanceOf(alice);
        uint256 contractStakingBefore = stakingToken.balanceOf(address(staking));

        // 2. 执行质押操作
        vm.prank(alice);
        staking.stake(stakeAmount);

        // 3. 记录操作后的状态
        uint256 aliceStakingAfter = stakingToken.balanceOf(alice);
        uint256 contractStakingAfter = stakingToken.balanceOf(address(staking));

        // 4. 断言验证 (Assertions)

        // 验证 Alice 的代币确实减少了
        assertEq(
            aliceStakingBefore - aliceStakingAfter, stakeAmount, "Alice's token balance should decrease by stakeAmount"
        );

        // 验证合约收到了这笔钱
        assertEq(
            contractStakingAfter - contractStakingBefore,
            stakeAmount,
            "Contract's token balance should increase by stakeAmount"
        );

        // 5. 额外验证：合约内部的记账 (Internal Accounting)
        assertEq(staking._balances(alice), stakeAmount, "Internal balance should match");
        assertEq(staking._totalSupply(), stakeAmount, "Total supply should match");

        // 6. 执行取钱操作
        uint256 withdrawAmount = 40e18;
        vm.prank(alice);
        staking.withdraw(withdrawAmount);

        // 7. 记录操作后的状态
        uint256 aliceWithdawAfter = stakingToken.balanceOf(alice);
        uint256 contractWithdawAfter = stakingToken.balanceOf(address(staking));

        // 8. 断言验证 (Assertions)
        assertEq(staking._balances(alice), stakeAmount - withdrawAmount, "Internal balance should match");
        assertEq(staking._totalSupply(), stakeAmount - withdrawAmount, "Total supply should match");
        assertEq(contractWithdawAfter, stakeAmount - withdrawAmount, "Contract balance should match");
    }

    /// @dev 用例 5：验证 getReward 是否正确触发了“转账 + 清零”的原子操作。
    function test_ClaimingAtomicity() public {
        // 1. T=0: Alice 存 100
        vm.prank(alice);
        staking.stake(100e18);

        // 2. T=10: 快进 10 秒
        vm.warp(block.timestamp + 10);
        // 此时 Alice 独享 10 * 100 = 1000
        uint256 expected = 10 * staking.rewardRate();
        assertEq(staking.earned(alice), expected, "Alice should earn 1000 tokens");

        // 3. 第一次领取奖励
        // aliceRewardBefore = 0
        uint256 aliceRewardBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.getReward();

        uint256 aliceRewardAfter = rewardToken.balanceOf(alice);

        // --- 验证点 1: 钱确实到账了 ---
        assertEq(aliceRewardAfter - aliceRewardBefore, expected, "Alice should receive exactly 1000 reward tokens");

        // --- 验证点 2: 账本必须清零 ---
        // 虽然 updateReward 还在跑，但因为 Alice 没提现本金，
        // 在 getReward 触发的一瞬间，earned(alice) 应该变回 0（或者接近 0 的极小值，取决于 block.timestamp）
        assertEq(staking.earned(alice), 0, "Earned rewards should be reset to 0");
        assertEq(staking.rewards(alice), 0, "Internal rewards mapping should be deleted");

        // 4. 再次调用 getReward() (防二次领取测试)
        vm.prank(alice);
        staking.getReward();

        uint256 balanceAfterSecondClaim = rewardToken.balanceOf(alice);

        // --- 验证点 3: 余额不应再增加 ---
        assertEq(balanceAfterSecondClaim, aliceRewardAfter, "Second claim should not transfer any tokens");
    }

    /// @dev 用例 6：超支提现 (Insufficient Balance)
    function test_RevertInsufficientBalance() public {
        vm.startPrank(alice);
        staking.stake(100e18);

        // 告诉虚拟机：下一行代码必须报错，且报错信息要包含 InsufficientBalance
        vm.expectRevert(StakingRewards.InsufficientBalance.selector);
        staking.withdraw(101e18);
        vm.stopPrank();
    }

    /// @dev 用例7：测试 stake 的鲁棒性
    function testFuzz_Stake(uint256 amount) public {
        // 1. 约束输入范围 (Constraints)
        // 必须排除 0，且不能超过 Alice 的初始余额
        amount = bound(amount, 1, 1000e18);

        // 2. 执行操作
        vm.prank(alice);
        staking.stake(amount);

        // 3. 验证不变性 (Invariants)
        assertEq(staking._balances(alice), amount);
        assertEq(staking._totalSupply(), amount);
        assertEq(stakingToken.balanceOf(address(staking)), amount);
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
        staking.stake(0);
    }

    /// @dev 用例9B：取零金额拦截
    function test_RevertIfWithdrawZero() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.withdraw(0);
    }

    /// @dev 用例10：验证“平滑合并”逻辑
    function test_NotifyRewardAmount_ContinuousInjection() public {
        // 1. T=0 初始状态 (setUp 已注入 100/s)
        assertEq(staking.rewardRate(), 100e18);

        // 2. 快进到 3.5 天（周期刚好过半）
        vm.warp(block.timestamp + 3.5 days);

        // 此时剩余奖励应该还有一半：100 * 3.5 days
        uint256 remaining = (staking.periodFinish() - block.timestamp) * staking.rewardRate();

        // 3. 管理员再次注入一笔新的奖励
        uint256 newAmount = 7000e18;
        rewardToken.mint(address(staking), newAmount);
        staking.notifyRewardAmount(newAmount);

        // 4. 验证新流速是否符合公式：(剩余 + 新增) / 7天
        uint256 expectedRate = (remaining + newAmount) / staking.rewardsDuration();
        assertEq(staking.rewardRate(), expectedRate, "Reward rate should merge smoothly");
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
        assertEq(staking._totalSupply(), 0);
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
}
