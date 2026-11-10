// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Bond-only staking entry point exposed by AegisStakingV4 (and later).
///         Sends sATH to `to` immediately, bypassing per-address warmup —
///         only callable by holders of `BOND_ROLE` on the staking contract.
interface IStakingBond {
    function stakeForBond(address _to, uint256 _amount) external returns (uint256);
}
