// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice gsATH vault: holds the ATH backing, pays the premium rebase and
///         handles unstaking with the burned exit fee.
interface IGsATHStaking {
    function mintFor(address voter, uint256 amount) external returns (uint256 sharesMinted);

    function unstake(uint256 amount) external returns (uint256 athOut);

    function rebase() external returns (uint256 epochsProcessed);

    function currentRate() external view returns (uint256);

    function pendingEpochs() external view returns (uint256);

    function previewUnstake(uint256 amount) external view returns (uint256 athOut, uint256 fee);
}
