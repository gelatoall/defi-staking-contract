# DeFi Staking Contract

[English](README.md) | 中文

一个带锁仓与权重奖励的 DeFi staking 合约示例，基于 Foundry 开发与测试。

## 功能亮点

- 多档位锁仓（30/90/180/365 天），倍率权重奖励
- 权重制奖励分配（基于 `totalWeight`）
- 余额精度优化：权重余数累计，避免小额质押精度丢失
- 奖励 rollover：无人质押期间奖励可累积到后续周期
- 安全机制：`nonReentrant`、`SafeERC20`、`Ownable`、`Pausable`
- 应急退出：暂停期间可 `emergencyWithdraw` 仅退回本金

## 合约特性

- 支持最小质押与单用户质押上限（可关闭）
- 同一档位合并锁仓并重置解锁时间（MVP 方案）
- 禁止 `stakingToken == rewardToken`，避免会计混乱
- 管理员可设置奖励周期并注入奖励

## 可配置参数

- `rewardsDuration` 奖励周期（秒），仅在当前周期结束后可设置
- `minStakeAmount` 最小质押额（0 表示不限制）
- `maxStakePerUser` 单用户质押上限（0 表示不限制）
- 奖励注入：`notifyRewardAmount(amount)`，需要先转入 rewardToken

## 已支持

- 多档位锁仓与权重奖励
- rollover 奖励结转
- 余数累计精度优化
- 暂停与紧急提现（仅本金）
- 最小/最大质押约束（可关闭）
- 拒绝 stakingToken 与 rewardToken 相同

## 未支持 / 后续考虑

- **多签 + timelock**：关键参数由多签控制，并引入 timelock 透明化变更窗口。
- **提前解锁 + 罚金**：按剩余锁定期线性衰减罚金，锁定越久罚金越高。
- **多仓位独立解锁**：同一档位追加质押不影响旧仓位的解锁时间。
- **NFT Boost 方向**：持有指定 NFT 可获得权重加成或奖励增幅。
- **邀请返佣 / 邀请加成**：自驱增长机制，邀请人/被邀请人获得奖励加成。
- **可升级合约**：当前不支持升级，后续视需求引入。
- **治理替代 owner**：后续可用治理合约接管参数调整。
- **反女巫 / 反垄断机制**：除限额外的更复杂规则（如地址关联检测等）。

## 风险说明

- 管理员权限较大（设置奖励周期、注入奖励、暂停），生产建议使用多签与 timelock
- 合约未审计，请勿用于生产环境
- 合并锁仓会延长已有仓位锁定期，适合 MVP，未来可迁移到独立仓位合约

## 版本规划

- MVP：合并锁仓、权重奖励、rollover、精度余数、最小/最大质押、紧急退出
- 后续：独立仓位解锁、惩罚性提前解锁、治理替代 owner、审计与上链

## 目录结构

- `contract/` 合约源码、脚本与测试
- `doc/` 设计文档

## 快速开始（本地 Anvil）

1. 启动本地链

```bash
anvil
```

2. 配置环境变量

```bash
cp contract/.env.example contract/.env
cd contract
source .env
```

3. 部署合约

```bash
forge script script/DeployStakingRewards.s.sol:DeployStakingRewards \
  --rpc-url $RPC_URL --broadcast
```

4. 初始化奖励

```bash
forge script script/InitStakingRewards.s.sol:InitStakingRewards \
  --rpc-url $RPC_URL --broadcast
```

5. 查看状态

```bash
forge script script/CheckStatus.s.sol:CheckStatus --rpc-url $RPC_URL
```

6. （可选）为 Alice 充值并质押

```bash
forge script script/SeedAlice.s.sol:SeedAlice --rpc-url $RPC_URL --broadcast
forge script script/CheckStatus.s.sol:CheckStatus --rpc-url $RPC_URL
```

## 测试

```bash
cd contract
forge test
```

## 文档

- 设计文档：[English](doc/Staking_Design_Doc.md) | [中文](doc/Staking_Design_Doc.zh-CN.md)
- 合约部署与脚本说明：`contract/script/README.md`
