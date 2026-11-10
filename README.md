# Aegis Protocol — Smart Contracts

Solidity source for the Aegis protocol on Polygon (chain id `137`).

Aegis is an OlympusDAO-style stake-and-bond system built around the reserve
token **ATH**, its rebasing receipt **sATH**, and a burn-to-vote governance
layer that issues **gsATH** (Governance sATH). This repository is a
source-only publication: it contains the contracts and their interfaces, with
no build tooling, tests or deployment scripts.

## Layout

```
contracts/
├── ATH.sol                      Reserve token (9 decimals)
├── GATH.sol                     ILO participation token (18 decimals)
├── ILOV1.sol                    Initial Liquidity Offering (USDC → gATH + NFT)
├── SenatorNFT.sol               NFT issued to ILO participants
├── staking/
│   ├── sATH.sol                 Rebasing staking receipt (gons / index model)
│   ├── AegisStaking.sol         Staking V1: stake / unstake / warmup / epoch rebase
│   ├── AegisStakingV4.sol       Staking V4: adds the bond entrypoint (stakeForBond)
│   ├── AegisStakingV5.sol       Staking V5: rebase anchored to the distributor rate (current)
│   ├── AegisDistributor.sol     Distributor V1: per-epoch inflation to recipients
│   ├── AegisDistributorV2.sol   Distributor V2: rate adjustments (setAdjustment)
│   ├── GsATH.sol                gsATH token: non-transferable, share-based rebasing
│   └── GsATHStaking.sol         gsATH vault: ATH backing, premium rebase, unstake fee
├── governance/
│   └── BurnToVote.sol           sATH burn-to-vote windows for the staking rate
├── treasury/
│   └── AegisTreasury.sol        Single mint gate for ATH; holds reserve tokens
├── bond/
│   ├── AegisBondDepository.sol  Bond market: USDC → ATH at a discount, vested
│   └── types/AegisNoteKeeper.sol Bond note vesting accounting
└── interfaces/                  Public interfaces used across the modules
```

All contracts target `pragma solidity 0.8.24` and are deployed behind
OpenZeppelin `TransparentUpgradeableProxy` instances (OpenZeppelin
Contracts Upgradeable v4.9.x). Access control uses
`AccessControlUpgradeable`; the admin of every role is the protocol multisig.

## Core Protocol

### ATH, sATH and staking

- **ATH** is the reserve token. Minting is restricted to `MINTER_ROLE`, which
  is held only by `AegisTreasury`.
- **sATH** is the staking receipt. Balances are stored as *gons* and scaled by
  a global index, so every rebase grows all balances proportionally.
- **AegisStaking** (V1 → V5 via storage-compatible proxy upgrades) handles
  `stake`, `unstake`, the warmup period and the epoch clock. At the end of
  each epoch it calls the distributor, then rebases sATH. V4 added the bond
  entrypoint (`stakeForBond`). V5, the current implementation, sizes each
  rebase from `distributor.nextRewardFor(staking)` so the minted reward and
  the rebase amount are equal by construction; the earlier balance-surplus
  heuristic (and its `maxRebaseBps` cap) no longer drives the yield.
- **AegisDistributor / AegisDistributorV2** mint the per-epoch reward through
  the treasury. V2 adds `setAdjustment(index, add, step, target)`, which
  drifts a recipient's rate by `step` each epoch until `target` is reached
  (`step` is capped at 10 % of the current rate). The rate uses a denominator
  of `1_000_000`, so `2500` means `0.25 %` per epoch.
- **AegisTreasury** is the only contract that can mint ATH. Reward minting
  requires `REWARD_MANAGER_ROLE`; reserve deposits require
  `RESERVE_DEPOSITOR_ROLE`.

### Bonds

- **AegisBondDepository** sells ATH at a discount for USDC. Payouts are
  staked on behalf of the buyer through `stakeForBond` (`BOND_ROLE` on
  staking) and vest according to **AegisNoteKeeper**.

### ILO

- **ILOV1** accepts USDC and mints **GATH** plus a **SenatorNFT** to the
  participant. A referrer, when present, receives a 10 % gATH bonus. The
  referrer lookup is an optional external call; the ILO works without it.

## Governance: Burn-to-Vote and gsATH

The governance layer lets sATH holders vote on the staking reward rate by
giving up their sATH. It is made of three contracts.

### BurnToVote (`contracts/governance/BurnToVote.sol`)

- The multisig (`WINDOW_MANAGER_ROLE`) opens a window with
  `openWindow(start, end, maxSteps)` and closes it with `closeWindow()`.
  Only one window can be active at a time.
- During an open window a holder calls `vote(amount)` (or
  `voteWithPermit`). The contract pulls the sATH, unstakes it through the
  main staking contract so it leaves `circulatingSupply`, and forwards the
  resulting ATH to the gsATH vault, which mints gsATH 1:1 to the voter.
- Tally: every `SATH_PER_STEP` (10,000 sATH) burned in a window equals one
  step of `RATE_PER_STEP` (`100`, i.e. +0.01 % per epoch) on the distributor
  rate, capped at the window's `maxSteps`. Votes beyond the cap are still
  accepted and still mint gsATH, but add no further step.
- The contract does **not** change the rate itself. After the window closes,
  `suggestedAdjustment(id)` returns the `setAdjustment` parameters and the
  multisig submits them to `AegisDistributorV2`. No new role is granted on
  the live distributor.

### GsATH (`contracts/staking/GsATH.sol`)

- Non-transferable rebasing token (9 decimals). `transfer`, `transferFrom`,
  `approve` and the allowance helpers revert with `NonTransferable()`; the
  ERC-20 views and `Transfer` events on mint and burn are kept so wallets can
  display balances.
- Accounting is share based (`balance = shares × totalPooled / totalShares`),
  so supply can start at zero and grow with each rebase. `index()` starts at
  `1e9`, mirroring sATH.
- Only the vault (`staking()`) may `mint`, `burn`, `burnAll` and `rebase`.

### GsATHStaking (`contracts/staking/GsATHStaking.sol`)

- Holds the ATH that backs gsATH 1:1 (`backing()` must stay ≥ 0; there is no
  rescue path for ATH).
- Pays one rebase per main staking epoch. The reward is
  `gsATH.totalSupply() × (sATH rate + premiumRate) / 1e6`, minted through the
  treasury (`REWARD_MANAGER_ROLE`). The sATH rate is read live from the
  distributor, so a passed vote raises gsATH yield automatically. The premium
  defaults to `100` (+0.01 % per epoch) and is capped by `MAX_PREMIUM_RATE`.
- `unstake(amount)` burns gsATH and returns ATH minus an exit fee
  (`feeBps`, default 5 %, capped by `MAX_FEE_BPS`). The fee is burned from
  ATH supply.
- `mintFor` is restricted to `VOTE_ROLE` (held by `BurnToVote`) and refuses
  to mint while rebases are still pending, so a late voter is never paid for
  epochs before their deposit. `unstake` never depends on the reward leg: a
  failing treasury mint makes that epoch's reward zero instead of reverting.

### Flow

```
voter ──sATH──▶ BurnToVote ──unstake──▶ AegisStaking ──ATH──▶ BurnToVote
                                                                  │ ATH
                                                                  ▼
                                   GsATH ◀──mint 1:1── GsATHStaking (vault)
                                     ▲                     │
                                     └── rebase ◀── treasury.mint (every epoch)
holder ──unstake(gsATH)──▶ GsATHStaking: 95 % ATH returned, 5 % ATH burned
multisig ──setAdjustment──▶ AegisDistributorV2   (after the window closes)
```

## Roles

| Role | Contract | Holder |
| --- | --- | --- |
| `MINTER_ROLE` | `ATH` | `AegisTreasury` |
| `REWARD_MANAGER_ROLE` | `AegisTreasury` | `AegisDistributorV2`, `AegisBondDepository`, `GsATHStaking` |
| `RESERVE_DEPOSITOR_ROLE` | `AegisTreasury` | `AegisBondDepository` |
| `RATE_MANAGER_ROLE` | `AegisDistributorV2` | multisig |
| `BOND_ROLE` | `AegisStaking` | `AegisBondDepository` |
| `VOTE_ROLE` | `GsATHStaking` | `BurnToVote` |
| `WINDOW_MANAGER_ROLE` | `BurnToVote` | multisig |
| `ADMIN_ROLE` | all | multisig |

Proxy admin ownership and multisig membership are exogenous trust
assumptions.

## Building

This repository ships source only. To compile, place `contracts/` in a
Hardhat or Foundry project with `@openzeppelin/contracts-upgradeable@4.9.x`
installed and compile with Solidity `0.8.24` (optimizer enabled, 200 runs,
EVM target `paris`).

## License

MIT. See the SPDX header in each file.
