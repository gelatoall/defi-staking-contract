# Scripts Overview

This folder contains Foundry scripts for deploying and operating the staking system.

## Prerequisites

- `foundry` installed
- `anvil` running locally

## Start Anvil

```bash
anvil
```

Note: Keep Anvil running in one terminal, and run the `forge script` commands in a separate terminal.

## Configure `.env`

Copy `contract/.env.example` to `contract/.env`, then edit and set:

- `RPC_URL`
- `PRIVATE_KEY` (deployer)
- `STAKING_ADDR` (filled after deploy)
- `REWARDS_DURATION`
- `REWARD_AMOUNT`

Optional:
- `STAKING_TOKEN`
- `REWARD_TOKEN`

Load env vars before running scripts:

```bash
cd contract
source .env
```

## Scripts

- `DeployStakingRewards.s.sol`
  - Deploys `StakingRewards`.
  - If `STAKING_TOKEN` / `REWARD_TOKEN` are not provided, deploys local `MockToken` contracts.

- `InitStakingRewards.s.sol`
  - Initializes rewards by setting duration and calling `notifyRewardAmount`.
  - Requires `STAKING_ADDR`, `REWARD_TOKEN`, `REWARDS_DURATION`, `REWARD_AMOUNT`.

- `SeedAlice.s.sol`
  - Dev-only helper. Transfers STK from deployer to Alice, then approves and stakes.
  - Requires `ALICE_PK`, `ALICE_STAKE_AMOUNT`, `ALICE_TIER_INDEX`.

- `CheckStatus.s.sol`
  - Read-only status dashboard for contract and Alice.

## Typical Local Flow (Anvil)

1. Deploy

```bash
forge script script/DeployStakingRewards.s.sol:DeployStakingRewards \
  --rpc-url $RPC_URL --broadcast
```
Update your `.env` file by pasting the deployed addresses for `StakingRewards`, `stakingToken` and `rewardToken` into their respective variables (`STAKING_ADDR`, `STAKING_TOKEN` and `REWARD_TOKEN`).

2. Initialize rewards

```bash
forge script script/InitStakingRewards.s.sol:InitStakingRewards \
  --rpc-url $RPC_URL --broadcast
```

3. Check status (Alice has no locked position yet)

```bash
forge script script/CheckStatus.s.sol:CheckStatus \
  --rpc-url $RPC_URL
```

4. Seed Alice stake

```bash
forge script script/SeedAlice.s.sol:SeedAlice \
  --rpc-url $RPC_URL --broadcast
```

5. Check status again (Alice should now have a locked position)

```bash
forge script script/CheckStatus.s.sol:CheckStatus \
  --rpc-url $RPC_URL
```
