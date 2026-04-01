# DeFi Staking Contract

English | [中文](README.zh-CN.md)

A time-locked, weight-based DeFi staking contract example built and tested with Foundry.

## Highlights

- Multi-tier lockups (30/90/180/365 days) with reward multipliers
- Weight-based reward distribution (via `totalWeight`)
- Precision handling with remainder accumulation to reduce small-stake loss
- Reward rollover when there are no stakers
- Safety mechanisms: `nonReentrant`, `SafeERC20`, `Ownable`, `Pausable`
- Emergency exit: `emergencyWithdraw` returns principal only while paused

## Contract Features

- Optional minimum stake and per-user stake cap
- Same-tier restake merges position and resets unlock time (MVP choice)
- Disallows `stakingToken == rewardToken` to avoid accounting issues
- Admin can set reward duration and inject rewards

## Configurable Parameters

- `rewardsDuration` reward period (seconds), only after current period ends
- `minStakeAmount` minimum stake amount (0 disables)
- `maxStakePerUser` per-user cap (0 disables)
- Reward injection: `notifyRewardAmount(amount)` requires pre-funded reward tokens

## Supported

- Multi-tier lockups with weighted rewards
- Reward rollover
- Remainder-based precision handling
- Pause and emergency withdraw (principal only)
- Optional min/max stake constraints
- Disallow stakingToken == rewardToken

## Not Yet Supported / Roadmap

- **Multisig + timelock**: govern critical parameters with transparent change windows
- **Early unlock + penalty**: linear decay by remaining lock time
- **Independent lock positions**: restake does not affect previous unlock times
- **NFT boost**: weight bonus for holding specific NFTs
- **Referral incentives**: referral rebates or reward boosts
- **Upgradeable contracts**: consider proxy upgradeability if needed
- **Governance replacing owner**: use governance contracts for parameter control
- **Sybil/anti-whale**: more complex limits beyond simple caps

## Risks

- Owner has powerful controls (reward duration, reward injection, pause); use multisig + timelock in production
- Not audited; do not use in production without review
- Merge-lock behavior extends existing lock periods; suitable for MVP but may migrate later

## Version Plan

- MVP: merge-lock, weighted rewards, rollover, precision remainder, min/max stake, emergency exit
- Next: independent positions, early-exit penalty, governance, audit, mainnet release

## Repository Layout

- `contract/` contracts, scripts, tests
- `doc/` design docs

## Quick Start (Local Anvil)

1. Start local chain

```bash
anvil
```

2. Configure environment

```bash
cp contract/.env.example contract/.env
cd contract
source .env
```

3. Deploy

```bash
forge script script/DeployStakingRewards.s.sol:DeployStakingRewards \
  --rpc-url $RPC_URL --broadcast
```

4. Initialize rewards

```bash
forge script script/InitStakingRewards.s.sol:InitStakingRewards \
  --rpc-url $RPC_URL --broadcast
```

5. Check status

```bash
forge script script/CheckStatus.s.sol:CheckStatus --rpc-url $RPC_URL
```

6. (Optional) Seed Alice and stake

```bash
forge script script/SeedAlice.s.sol:SeedAlice --rpc-url $RPC_URL --broadcast
forge script script/CheckStatus.s.sol:CheckStatus --rpc-url $RPC_URL
```

## Tests

```bash
cd contract
forge test
```

## Docs

- Design doc: [English](doc/Staking_Design_Doc.md) | [中文](doc/Staking_Design_Doc.zh-CN.md)
- Scripts: `contract/script/README.md`
