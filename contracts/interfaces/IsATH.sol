// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IsATH is IERC20Upgradeable {
    function rebase(uint256 profit_, uint256 epoch_) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function gonsForBalance(uint256 amount) external view returns (uint256);

    function balanceForGons(uint256 gons) external view returns (uint256);

    function index() external view returns (uint256);

    function changeDebt(uint256 amount, address debtor, bool add) external;

    function debtBalances(address debtor) external view returns (uint256);

    function decimals() external view returns (uint8);
}
