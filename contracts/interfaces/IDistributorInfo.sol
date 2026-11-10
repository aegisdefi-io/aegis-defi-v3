// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal read view of AegisDistributorV2's public getters. `IDistributor`
///         does not expose them; gsATH needs the live rate and BurnToVote needs the
///         in-flight adjustment so a second window builds on the first one's target.
interface IDistributorInfo {
    function info(uint256 index_) external view returns (uint256 rate, address recipient);

    /// @dev `adjustments(index)` public mapping getter: (add, rate per epoch, target). rate == 0 → none pending.
    function adjustments(uint256 index_) external view returns (bool add, uint256 rate, uint256 target);
}
