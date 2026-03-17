# StakingRewards Design Doc

## Context and Scope

`StakingRewards` is a lock-up staking contract where users deposit a staking token (`stakingToken`) and earn rewards in another token (`rewardToken`).
Design constraint: `stakingToken` and `rewardToken` must be different to avoid mixing principal and rewards in the same balance.

The contract supports fixed staking tiers with different lock durations and reward multipliers. Rewards are streamed linearly over time and distributed proportionally by staking weight (not raw principal).

In scope:
- Single-contract staking with per-tier lock-up and weighted rewards
- Owner-managed reward program configuration and funding
- Deterministic accounting for stake/withdraw/claim flows
- Emergency pause/unpause controls for user flows (stake/withdraw/claim)
- Configurable minimum stake threshold (may be disabled)

Out of scope:
- Frontend/UI, off-chain analytics, and monitoring infrastructure
- Cross-chain staking or bridge integrations
- Token listing/governance processes outside the contract

## Goals and non-goals
### Goals
- Provide predictable reward distribution with O(1) global accounting updates
- Support multiple lock tiers with clear multiplier semantics
- Prevent reward dilution bugs during stake/withdraw by snapshot-based accounting
- Keep user flows simple: stake, withdraw after unlock, claim reward
- Enforce owner-only reward program controls

### Non-Goals
- Upgradeability/proxy-based contract upgrades
- Dynamic modification of existing tier configurations (duration/multiplier)
- Governance-driven parameter changes beyond owner controls


## The Actual Design

### High-Level Model

The system tracks two layers of state:
- Global reward index state (`rewardPerTokenStored`, `lastUpdateTime`, `rewardRate`, `periodFinish`, `undistributedRewards`, `minStakeAmount`, `maxStakePerUser`)
- User state (`userTotalWeight`, `userRewardPerTokenPaid`, `rewards`, and per-tier `userLocks`, `weightRemainder`)

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

`weightRemainder` (by `user + periodIndex`):
- Stores the remainder of `amount * multiplier` under a base-100 weight scheme.
- Used to accumulate fractional weights across multiple small stakes.

Default tiers at construction:
- Tier 0: 30 days, 1x
- Tier 1: 90 days, 1.5x
- Tier 2: 180 days, 2x
- Tier 3: 365 days, 3x
Design note: tier configuration is hard-coded and not mutable. This avoids changing unlock or reward semantics for existing positions. If future adjustments are required, prefer adding new tiers in a new contract deployment (or a carefully designed migration), rather than modifying existing tiers in place.

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

### Boundary Conditions

- `totalWeight == 0`:
  `rewardPerToken()` returns `rewardPerTokenStored` directly, so the global reward index does not increase while nobody is staked. Any emitted rewards during this window are accumulated in `undistributedRewards` and only get scheduled when the owner calls `notifyRewardAmount(...)`.

- `periodFinish == 0` (initial deployment state):
  The initial reward period has not started yet. `setRewardsDuration(...)` is allowed as long as `block.timestamp > periodFinish` (true in normal environments), so owner can override the constructor default before first funding.

- `rewardsDuration == 0` safety:
  `notifyRewardAmount(...)` explicitly checks `rewardsDuration == 0` and reverts with `InvalidRewardsDuration()`, preventing division-by-zero on `amount / rewardsDuration`.

- Reward accumulation after period end:
  `lastTimeRewardApplicable()` uses `min(block.timestamp, periodFinish)`, so reward growth stops once `periodFinish` is reached.

### State Sync Strategy (`updateReward` modifier)

Before any state-changing action that affects rewards:
1. Sync global index and timestamp via `_updateGlobalRewards()` (handles `undistributedRewards` when `totalWeight == 0`)
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
- if `minStakeAmount != 0`, require `amount >= minStakeAmount`
- if `maxStakePerUser != 0`, require `userTotalStaked[user] + amount <= maxStakePerUser`
- `whenNotPaused` (staking is disabled during emergency pause)
- valid tier index

Effects:
- compute `raw = amount * multiplier + weightRemainder[user][periodIndex]`
- compute `weightAdded = raw / 100` and update `weightRemainder[user][periodIndex] = raw % 100`
- increase `totalWeight` and `userTotalWeight[user]`
- increase `userTotalStaked[user]`
- increase per-tier `amount` and `weight`
- reset `unlockTime = now + tier.duration`
  Design intent: positions within the same tier are merged, so any add-on stake resets the tier's unlock time to prevent end-of-period micro-stake arbitrage and keep incentives aligned with lock duration.
  Alternative (independent positions) would preserve original unlock times, improving UX for partial top-ups but increasing storage/gas costs and operational complexity (tracking multiple positions, more withdrawal paths, and more test surface). Given this is an MVP, the design prioritizes simplicity, lower gas, and predictable incentive alignment. If user demand for independent unlocks is strong, a future version can add per-deposit positions, likely via a new contract deployment and migration path.

Interaction:
- transfer staking tokens from user to contract

#### Withdraw
Input: `amount`, `periodIndex`

Checks:
- `amount > 0`
- valid tier index
- `whenNotPaused` (withdrawals are disabled during emergency pause)
- `now >= unlockTime`
- sufficient tier principal

Effects:
- compute `weightRemoved = locked.weight * amount / locked.amount` (proportional removal)
- decrease global/user weights
- decrease `userTotalStaked[user]`
- full withdraw: delete tier slot
- partial withdraw: decrement tier `amount` and `weight`

Interaction:
- transfer staking tokens back to user

#### Claim Reward
- read `rewards[user]`
- if non-zero: set to zero first, then transfer reward token
- guarded by `whenNotPaused` (claims are disabled during emergency pause)

### Admin Flows

#### setRewardsDuration
- owner only
- only after current period is finished (`block.timestamp > periodFinish`)
- `_rewardsDuration` must be non-zero, otherwise revert with `InvalidRewardsDuration()`

#### setMinStakeAmount(_min)
- owner only
- `_min = 0` disables the minimum-stake constraint

#### setMaxStakePerUser(_max)
- owner only
- `_max = 0` disables the per-user cap
  Rationale: optional anti-concentration control to reduce single-address dominance of reward weight.

#### pause / unpause
- owner only
- `pause()` disables `stake`, `withdraw`, and `getReward`
- `unpause()` re-enables those flows

#### notifyRewardAmount(amount)
- owner only
- sync global index first
- require `rewardsDuration > 0` (`InvalidRewardsDuration()` if not)
- if previous period ended: `rewardRate = amount / rewardsDuration`
- if active: blend remaining rewards and new amount:

```text
remaining = (periodFinish - now) * rewardRate
rewardRate = (remaining + amount) / rewardsDuration
```

- reject zero rate
- reject if contract balance cannot cover `rewardRate * rewardsDuration`
- operational flow: transfer sufficient `rewardToken` into the staking contract before calling `notifyRewardAmount(amount)`; the call reverts if the contract balance is insufficient
- set `lastUpdateTime = now`, `periodFinish = now + rewardsDuration`
- clear `undistributedRewards` after it is merged into the new schedule

### Events and Errors

Events:
- `Staked(user, amount, periodIndex)`
- `WithDrawn(user, amount, periodIndex)`
- `RewardPaid(user, amount)`
- `SetMinStakeAmount(amount)`
- `SetMaxStakePerUser(amount)`
- `SetRewardsDuration(duration)`
- `NotifyRewardAmount(amount)`

Custom errors cover:
- zero address/amount/rate
- invalid period index
- invalid reward duration (`InvalidRewardsDuration`)
- stake below minimum (`StakeBelowMinimum`)
- same staking/reward token not allowed (`SameTokenNotAllowed`)
- stake above user cap (`StakeAboveUserCap`)
- lock violation (`Locked(unlockTime)`)
- insufficient stake balance
- insufficient reward pool balance
- active-period duration changes

## Security Considerations

This contract includes multiple built-in security mechanisms:

- `ReentrancyGuard` + `nonReentrant`:
  Applied to external state-changing user functions (`stake`, `withdraw`, `getReward`) to reduce reentrancy risk around token transfers and state mutations.

- `SafeERC20`:
  All token transfers use `safeTransfer` / `safeTransferFrom`, which improves compatibility with non-standard ERC20 implementations and avoids silent transfer failures.

- `Ownable`:
  Administrative functions (`setRewardsDuration`, `notifyRewardAmount`) are restricted with `onlyOwner`, preventing unauthorized reward schedule changes.
  Production recommendation: use a multi-signature wallet as the owner to reduce key risk and improve governance safety.
  Operational guidance:
  - Use a timelock for sensitive parameter changes (reward duration, reward injection, min stake, pause/unpause) to give users advance notice.
  - Owner action scope and intended use:
    - `setRewardsDuration`: adjust program length between reward cycles; only after the current period ends.
    - `notifyRewardAmount`: start or extend reward emission after transferring reward tokens into the contract.
    - `setMinStakeAmount`: set or remove a minimum stake to reduce dust/spam activity.
    - `pause`: emergency stop for incidents (e.g., critical bug, exploit, or unexpected token behavior).
    - `unpause`: resume normal operations after incident resolution and verification.
  - For stronger decentralization, migrate ownership to a governance contract (typically via timelock + DAO) once the product matures.

- `Pausable`:
  `stake`, `withdraw`, and `getReward` are gated by `whenNotPaused`, allowing emergency stop in case of incidents.

- Defensive input/state checks:
  The contract uses explicit validation and custom errors for invalid amounts, invalid tier index, lock violations, insufficient balances, and reward-funding insufficiency.

- Checks-effects-interactions pattern in reward claim:
  In `getReward`, pending rewards are cleared before external token transfer, reducing the chance of double-claim behavior during unexpected external call flows.

## Deployment Checklist

Use the following initialization order after deployment:

1. Verify constructor inputs:
   Confirm `stakingToken` and `rewardToken` are non-zero addresses, different from each other, and point to the intended ERC20 contracts.

2. (Optional) Override reward duration:
   Constructor sets a default `rewardsDuration = 7 days`. If a different duration is needed, owner can call `setRewardsDuration(...)` before first funding.

3. Fund reward pool:
   Transfer enough `rewardToken` into the staking contract address.

4. Start reward program:
   Owner calls `notifyRewardAmount(amount)` to set `rewardRate` and `periodFinish`.

5. User onboarding:
   Users approve `stakingToken` allowance, then call `stake(...)`.

Important constraint:
- `notifyRewardAmount(...)` requires `rewardsDuration > 0`. With the current implementation this is satisfied by default (`7 days`), but setting duration to zero is disallowed and reverts with `InvalidRewardsDuration()`.

### Initialization Safety Requirement

- Current behavior:
  `rewardsDuration` is initialized to `7 days` in the constructor.

- Init sequence:
  Owner may call `setRewardsDuration(...)` to override the default, then fund rewards and call `notifyRewardAmount(...)`.

- Failure mode if sequence is violated:
  If `rewardsDuration` is ever zero (misconfiguration in future refactors), `notifyRewardAmount(...)` reverts early with `InvalidRewardsDuration()` instead of reaching division.

Operational checks:
- Before each `notifyRewardAmount(...)`, ensure contract `rewardToken` balance can cover `rewardRate * rewardsDuration` (the function enforces this).
- `setRewardsDuration(...)` can only be changed after current period ends (`block.timestamp > periodFinish`).

## Testing Strategy (Current Coverage)

`StakingRewards.t.sol` validates:
- single-user linear accrual
- multi-user fair split by weight
- dynamic weighting after additional stakes
- lock enforcement and insufficient-balance reverts
- invalid input paths (zero amount, invalid tier, zero address ctor)
- min stake amount enforcement and owner-only setter
- max stake per user enforcement and owner-only setter
- pause/unpause behavior for stake, withdraw, and claim
- reward claiming atomicity (transfer + state reset)
- reward-period continuity on re-funding
- rollover behavior: zero-weight windows do not back-pay, merge only once, and are included in notify formula
- weight remainder behavior: small-stake precision is accumulated per user/tier; withdrawals remove weight proportionally
- non-owner admin access denial
- reward accrual stops after period end
- aggregation across multiple tiers
- fuzzed stake invariants


## References
- Template reference: https://www.industrialempathy.com/posts/design-docs-at-google/
