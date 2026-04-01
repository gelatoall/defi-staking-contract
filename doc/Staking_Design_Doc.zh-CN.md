# StakingRewards 设计文档

中文 | [English](Staking_Design_Doc.md)

## 背景与范围

`StakingRewards` 是一个带锁仓的 staking 合约：用户质押 `stakingToken`，以 `rewardToken` 领取奖励。
设计约束：`stakingToken` 与 `rewardToken` 必须不同，避免本金与奖励在同一余额中混淆。

合约支持固定档位（不同锁定期与倍率）。奖励按时间线性释放，并按“权重”而非本金比例分配。

范围内：
- 单合约质押，按档位锁仓并按权重分配奖励
- 由 owner 管理奖励计划配置与资金注入
- 质押/提现/领奖的确定性记账
- 紧急暂停/恢复控制（stake/withdraw/claim）
- 可配置最小质押门槛（可关闭）

范围外：
- 前端/UI、链下分析与监控基础设施
- 跨链质押或桥接集成
- 合约外的代币上架/治理流程

## 目标与非目标

### 目标
- 提供可预测的奖励分配，且全局更新为 O(1)
- 支持多档位锁定与清晰的倍率语义
- 通过快照式记账，防止 stake/withdraw 过程中的奖励稀释
- 保持用户流程简单：stake → 到期 withdraw → claim reward
- 奖励计划控制由 owner 管理

### 非目标
- 可升级/代理合约
- 动态修改已存在档位（锁定期/倍率）
- 超出 owner 权限范围的治理式参数调整

## 设计细节

### 高层模型

系统跟踪两类状态：
- 全局奖励索引状态（`rewardPerTokenStored`, `lastUpdateTime`, `rewardRate`, `periodFinish`, `undistributedRewards`, `minStakeAmount`, `maxStakePerUser`）
- 用户状态（`userTotalWeight`, `userRewardPerTokenPaid`, `rewards`，以及按档位的 `userLocks` 与 `weightRemainder`）

奖励采用索引增量模型：
- 全局索引随时间和 `rewardRate` 增长
- 用户收益 = `userWeight * indexDelta`

避免遍历所有用户。

### 档位与仓位数据

`StakingPeriod`：
- `duration`（秒）
- `rewardMultiplier`（100 = 1x，150 = 1.5x，200 = 2x，300 = 3x）

`UserLocks`（按 `user + periodIndex`）：
- `amount`
- `weight`
- `unlockTime`

`weightRemainder`（按 `user + periodIndex`）：
- 存储 `amount * multiplier` 在 base-100 权重体系下的余数
- 用于累积小额质押的“分数权重”

构造函数默认档位：
- 档位 0：30 天，1x
- 档位 1：90 天，1.5x
- 档位 2：180 天，2x
- 档位 3：365 天，3x
设计说明：档位配置为硬编码且不可修改，避免改变已存在仓位的解锁/奖励语义。若未来需要调整，建议通过新合约新增档位并迁移，而非就地修改。

### 奖励记账

精度常量：
- `PRECISION = 1e18`

全局索引计算：

```text
if totalWeight == 0:
    return rewardPerTokenStored

return rewardPerTokenStored +
       rewardRate * (lastTimeRewardApplicable - lastUpdateTime) * 1e18 / totalWeight
```

其中：

```text
lastTimeRewardApplicable = min(block.timestamp, periodFinish)
```

用户收益计算：

```text
earned(user) = userTotalWeight[user] *
               (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18
               + rewards[user]
```

### 边界条件

- `totalWeight == 0`：
  `rewardPerToken()` 直接返回 `rewardPerTokenStored`，无人质押时索引不增长。此窗口内产生的奖励累积到 `undistributedRewards`，只有 owner 调用 `notifyRewardAmount(...)` 才会被重新排期。

- `periodFinish == 0`（初始部署状态）：
  初始奖励周期尚未开始。只要 `block.timestamp > periodFinish`（正常环境成立），owner 可在首次注入前修改 `rewardsDuration`。

- `rewardsDuration == 0` 安全性：
  `notifyRewardAmount(...)` 会检查 `rewardsDuration == 0` 并以 `InvalidRewardsDuration()` 回滚，防止除零。

- 周期结束后的奖励停止：
  `lastTimeRewardApplicable()` 使用 `min(block.timestamp, periodFinish)`，因此超过 `periodFinish` 后不再累积。

### 状态同步策略（`updateReward` 修饰器）

在任何影响奖励的状态变更前：
1. 通过 `_updateGlobalRewards()` 同步全局索引与时间（当 `totalWeight == 0` 时处理 `undistributedRewards`）
2. 若传入用户地址，则把用户奖励结算进 `rewards[user]`
3. 更新 `userRewardPerTokenPaid[user]` 到最新索引

用于：
- `stake`
- `withdraw`
- `getReward`
- `notifyRewardAmount`（用 `address(0)` 做全局同步）

确保在权重变化前结算历史奖励。

### 用户流程

#### 质押（Stake）
输入：`amount`, `periodIndex`

检查：
- `amount > 0`
- 若 `minStakeAmount != 0`，则 `amount >= minStakeAmount`
- 若 `maxStakePerUser != 0`，则 `userTotalStaked[user] + amount <= maxStakePerUser`
- `whenNotPaused`（暂停时不可质押）
- 档位索引合法

效果：
- `raw = amount * multiplier + weightRemainder[user][periodIndex]`
- `weightAdded = raw / 100`，并更新 `weightRemainder[user][periodIndex] = raw % 100`
- 增加 `totalWeight` 与 `userTotalWeight[user]`
- 增加 `userTotalStaked[user]`
- 增加档位 `amount` 与 `weight`
- 重置 `unlockTime = now + tier.duration`
  设计意图：同一档位追加质押合并仓位并重置解锁时间，避免临近解锁的小额加仓套利，且保持锁定期激励一致。
  可选方案（独立仓位）能保留原解锁时间、提升 UX，但会增加存储/测试复杂度与 gas。作为 MVP，本设计优先简单与可预测性。若需求明确，可在未来通过新合约实现独立仓位并迁移。

交互：
- 从用户转入 staking token 到合约

#### 提现（Withdraw）
输入：`amount`, `periodIndex`

检查：
- `amount > 0`
- 档位索引合法
- `whenNotPaused`（暂停时不可提现）
- `now >= unlockTime`
- 档位余额充足

效果：
- `weightRemoved = locked.weight * amount / locked.amount`（按比例扣权重）
- 减少全局/用户权重
- 减少 `userTotalStaked[user]`
- 全提则清空档位
- 部分提则减少档位 `amount`、`weight`，并按剩余金额缩放 `weightRemainder`：
  `newRemainder = oldRemainder * newAmount / oldAmount`

交互：
- 转回 staking token 给用户

#### 紧急提现（Emergency Withdraw）
输入：`amount`, `periodIndex`

检查：
- `amount > 0`
- 档位索引合法
- `whenPaused`（仅暂停期间可用）

效果：
- 在变更权重前调用 `_updateGlobalRewards()`，保证其他用户奖励准确
- 跳过解锁时间，仅退回本金，清除奖励
- `weightRemoved = locked.weight * amount / locked.amount`（按比例扣权重）
- 减少全局/用户权重
- 减少 `userTotalStaked[user]`
- 更新 `userLocks`，部分提现时同步缩放 `weightRemainder`

交互：
- 转回 staking token 给用户

#### 领奖（Claim Reward）
- 读取 `rewards[user]`
- 若非零：先清零再转账
- `whenNotPaused`（暂停时不可领取）

### 管理员流程

#### setRewardsDuration
- owner only
- 仅在当前周期结束后可改（`block.timestamp > periodFinish`）
- `_rewardsDuration` 必须非零，否则 `InvalidRewardsDuration()`

#### setMinStakeAmount(_min)
- owner only
- `_min = 0` 关闭最小质押限制

#### setMaxStakePerUser(_max)
- owner only
- `_max = 0` 关闭单用户上限
  设计动机：可选的反集中化控制，降低单一地址权重占比。

#### pause / unpause
- owner only
- `pause()` 禁用 `stake`、`withdraw`、`getReward`
- `unpause()` 恢复上述流程

#### notifyRewardAmount(amount)
- owner only
- 先同步全局索引
- `rewardsDuration > 0`（否则 `InvalidRewardsDuration()`）
- 若旧周期结束：`rewardRate = amount / rewardsDuration`
- 若仍在周期内：把剩余奖励与新增奖励合并：

```text
remaining = (periodFinish - now) * rewardRate
rewardRate = (remaining + amount + undistributedRewards) / rewardsDuration
```

- 拒绝零速率
- 若合约余额不足以覆盖 `rewardRate * rewardsDuration` 则回滚
- 运维流程：先转入足额 `rewardToken` 到合约，再调用 `notifyRewardAmount(amount)`；余额不足会回滚
- 注意：当没有剩余或未分配奖励时，`notifyRewardAmount(0)` 会触发 `ZeroRewardRate`，无法作为纯“空结算”调用
- 设置 `lastUpdateTime = now`, `periodFinish = now + rewardsDuration`
- 合并完成后清空 `undistributedRewards`

### 事件与错误

事件：
- `Staked(user, amount, periodIndex)`
- `Withdrawn(user, amount, periodIndex)`
- `EmergencyWithdrawn(user, amount, periodIndex)`
- `RewardPaid(user, amount)`
- `SetMinStakeAmount(amount)`
- `SetMaxStakePerUser(amount)`
- `SetRewardsDuration(duration)`
- `NotifyRewardAmount(amount)`

自定义错误覆盖：
- 零地址/零金额/零速率
- 非法档位索引
- 非法奖励周期（`InvalidRewardsDuration`）
- 低于最小质押（`StakeBelowMinimum`）
- staking/reward 代币相同不允许（`SameTokenNotAllowed`）
- 超过单用户上限（`StakeAboveUserCap`）
- 锁定期未到（`Locked(unlockTime)`）
- 质押余额不足
- 奖励池余额不足
- 周期内禁止修改奖励周期

## 安全性说明

本合约包含多种安全机制：

- `ReentrancyGuard` + `nonReentrant`：
  对外部状态变更函数（`stake`、`withdraw`、`getReward`）加防重入，降低外部调用风险。

- `SafeERC20`：
  所有转账使用 `safeTransfer` / `safeTransferFrom`，兼容非标准 ERC20。

- `Ownable`：
  管理员操作（`setRewardsDuration`、`notifyRewardAmount` 等）限制为 `onlyOwner`。
  生产建议：使用多签作为 owner，并引入 timelock。
  运维建议：
  - 关键参数（奖励周期、奖励注入、最小质押、暂停）通过 timelock 提供预告期
  - Owner 操作范围与使用场景：
    - `setRewardsDuration`：调整奖励周期，仅在旧周期结束后
    - `notifyRewardAmount`：转入奖励后启动/续期
    - `setMinStakeAmount`：设置或移除最小质押，降低尘埃/刷单
    - `pause`：紧急停机（漏洞、异常、代币行为风险）
    - `unpause`：事故处理完成后恢复
  - 若需更强去中心化，可迁移 owner 至治理合约（通常配合 timelock + DAO）

- `Pausable`：
  `stake`、`withdraw`、`getReward` 受 `whenNotPaused` 限制，用于紧急暂停。

- 防御性检查：
  对金额、档位、锁定期、余额与奖励池资金做显式校验，并使用自定义错误。

- 先记账再交互：
  `getReward` 在转账前清零奖励余额，降低异常外部调用导致的重复领取风险。

## 部署检查清单

推荐部署后按以下顺序初始化：

1. 校验构造参数：
   确认 `stakingToken` 与 `rewardToken` 地址非零、互不相同，且为目标 ERC20。

2. （可选）覆盖奖励周期：
   构造函数默认 `rewardsDuration = 7 days`。如需不同周期，可在首次注入前调用 `setRewardsDuration(...)`。

3. 注入奖励池资金：
   将足额 `rewardToken` 转入合约地址。

4. 启动奖励计划：
   owner 调用 `notifyRewardAmount(amount)` 设置 `rewardRate` 与 `periodFinish`。

5. 用户入场：
   用户授权 `stakingToken` 后调用 `stake(...)`。

重要约束：
- `notifyRewardAmount(...)` 要求 `rewardsDuration > 0`。当前实现默认为 `7 days`，但若未来被错误设置为 0 会以 `InvalidRewardsDuration()` 回滚。

### 初始化安全要求

- 当前行为：
  `rewardsDuration` 在构造函数中初始化为 `7 days`。

- 推荐顺序：
  若需修改周期，先 `setRewardsDuration(...)`，再注入奖励并调用 `notifyRewardAmount(...)`。

- 违反顺序的风险：
  若 `rewardsDuration` 为 0（未来改动引入），`notifyRewardAmount(...)` 将提前回滚，不会触发除零。

运维检查：
- 每次 `notifyRewardAmount(...)` 前确保合约 `rewardToken` 余额可覆盖 `rewardRate * rewardsDuration`（函数内部会校验）。
- `setRewardsDuration(...)` 只能在周期结束后执行（`block.timestamp > periodFinish`）。

## 测试策略（当前覆盖）

`StakingRewards.t.sol` 覆盖：
- 单用户线性奖励
- 多用户按权重公平分配
- 追加质押后的动态权重
- 锁仓限制与余额不足回滚
- 非法输入路径（零金额、非法档位、零地址构造）
- 最小质押与 owner-only setter
- 单用户上限与 owner-only setter
- pause/unpause 行为（stake/withdraw/claim）
- emergencyWithdraw 行为（仅暂停期、仅本金、保护其他用户奖励）
- 领奖原子性（转账 + 状态清零）
- 续期注入的奖励连续性
- rollover 行为：无人质押窗口不可追溯、仅合并一次、notify 公式包含
- 余数精度：小额质押累积、按比例提现
- 非 owner 管理函数拒绝
- 奖励周期结束后停止增长
- 多档位奖励聚合
- Fuzz 质押不变式

## 参考
- 模板参考：https://www.industrialempathy.com/posts/design-docs-at-google/
