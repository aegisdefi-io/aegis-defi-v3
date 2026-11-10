// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @notice Governance sATH — non-transferable, share-based rebasing token.
///         Only the gsATH staking vault may mint, burn and rebase.
interface IGsATH is IERC20Upgradeable {
    function mint(address to, uint256 amount) external returns (uint256 sharesMinted);

    function burn(address from, uint256 amount) external returns (uint256 sharesBurned);

    function burnAll(address from) external returns (uint256 amountBurned);

    function rebase(uint256 profit, uint256 epoch) external returns (uint256 newTotalSupply);

    function sharesOf(address account) external view returns (uint256);

    function totalShares() external view returns (uint256);

    function index() external view returns (uint256);

    function decimals() external view returns (uint8);
}
