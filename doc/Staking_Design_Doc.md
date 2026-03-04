# StakingRewards Design Doc

## Context and Scope

`StakingRewards` is a lock-up staking contract where users deposit a staking token (`stakingToken`) and earn rewards in another token (`rewardToken`).

The contract supports fixed staking tiers with different lock durations and reward multipliers. Rewards are streamed linearly over time and distributed proportionally by staking weight (not raw principal).

In scope:
- Single-contract staking with per-tier lock-up and weighted rewards
- Owner-managed reward program configuration and funding
- Deterministic accounting for stake/withdraw/claim flows

## Goals 

- Provide predictable reward distribution with O(1) global accounting updates
- Support multiple lock tiers with clear multiplier semantics
- Prevent reward dilution bugs during stake/withdraw by snapshot-based accounting
- Keep user flows simple: stake, withdraw after unlock, claim reward
- Enforce owner-only reward program controls


## The Actual Design

### High-Level Model

The system tracks two layers of state:
- Global reward index state (`rewardPerTokenStored`, `lastUpdateTime`, `rewardRate`, `periodFinish`)
- User state (`userTotalWeight`, `userRewardPerTokenPaid`, `rewards`, and per-tier `userLocks`)

Each stake updates user and global weight. Reward accrual uses an index-delta model:
- Global index grows with elapsed time and `rewardRate`
- User earned amount is computed by `userWeight * indexDelta`

This avoids iterating over users.

### Tier and Position Data

`StakingPeriod`:
- `duration` (seconds)
- `rewardMultiplier` (100 = 1x, 150 = 1.5x, 200 = 2x, 300 = 3x)

`UserLocks` (by `user + periodIndex`):
- `amount`
- `weight`
- `unlockTime`

Default tiers at construction:
- Tier 0: 30 days, 1x
- Tier 1: 90 days, 1.5x
- Tier 2: 180 days, 2x
- Tier 3: 365 days, 3x

### Reward Accounting

Precision constant:
- `PRECISION = 1e18`

Global index function:

```text
if totalWeight == 0:
    return rewardPerTokenStored

return rewardPerTokenStored +
       rewardRate * (lastTimeRewardApplicable - lastUpdateTime) * 1e18 / totalWeight
```

where:

```text
lastTimeRewardApplicable = min(block.timestamp, periodFinish)
```

User earned function:

```text
earned(user) = userTotalWeight[user] *
               (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18
               + rewards[user]
```

### State Sync Strategy (`updateReward` modifier)

Before any state-changing action that affects rewards:
1. Sync global index and timestamp
2. If account is provided, realize user pending rewards into `rewards[user]`
3. Move `userRewardPerTokenPaid[user]` to latest index

Used in:
- `stake`
- `withdraw`
- `getReward`
- `notifyRewardAmount` (with `address(0)` for global-only sync)

This ensures fair sequencing: historical rewards are settled before weight changes.

### User Flows

#### Stake
Input: `amount`, `periodIndex`

Checks:
- `amount > 0`
- valid tier index

Effects:
- compute `weightAdded = amount * multiplier / 100`
- increase `totalWeight` and `userTotalWeight[user]`
- increase per-tier `amount` and `weight`
- reset `unlockTime = now + tier.duration`

Interaction:
- transfer staking tokens from user to contract

#### Withdraw
Input: `amount`, `periodIndex`

Checks:
- `amount > 0`
- valid tier index
- `now >= unlockTime`
- sufficient tier principal

Effects:
- compute `weightRemoved = amount * multiplier / 100`
- decrease global/user weights
- full withdraw: delete tier slot
- partial withdraw: decrement tier `amount` and `weight`

Interaction:
- transfer staking tokens back to user

#### Claim Reward
- read `rewards[user]`
- if non-zero: set to zero first, then transfer reward token

### Admin Flows

#### setRewardsDuration
- owner only
- only after current period is finished (`block.timestamp > periodFinish`)

#### notifyRewardAmount(amount)
- owner only
- sync global index first
- if previous period ended: `rewardRate = amount / rewardsDuration`
- if active: blend remaining rewards and new amount:

```text
remaining = (periodFinish - now) * rewardRate
rewardRate = (remaining + amount) / rewardsDuration
```

- reject zero rate
- reject if contract balance cannot cover `rewardRate * rewardsDuration`
- set `lastUpdateTime = now`, `periodFinish = now + rewardsDuration`

### Events and Errors

Events:
- `Staked(user, amount, periodIndex)`
- `WithDrawn(user, amount, periodIndex)`
- `RewardPaid(user, amount)`

Custom errors cover:
- zero address/amount/rate
- invalid period index
- lock violation (`Locked(unlockTime)`)
- insufficient stake balance
- insufficient reward pool balance
- active-period duration changes



## Testing Strategy (Current Coverage)

`StakingRewards.t.sol` validates:
- single-user linear accrual
- multi-user fair split by weight
- dynamic weighting after additional stakes
- lock enforcement and insufficient-balance reverts
- invalid input paths (zero amount, invalid tier, zero address ctor)
- reward claiming atomicity (transfer + state reset)
- reward-period continuity on re-funding
- non-owner admin access denial
- reward accrual stops after period end
- aggregation across multiple tiers
- fuzzed stake invariants


## References
- Template reference: https://www.industrialempathy.com/posts/design-docs-at-google/
