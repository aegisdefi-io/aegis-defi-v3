// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ITreasury {
    function deposit(uint256 amount, address token, uint256 profit) external returns (uint256);

    function mint(address recipient, uint256 amount) external;

    function withdraw(uint256 amount, address token) external;

    function tokenValue(address token, uint256 amount) external view returns (uint256);

    function baseSupply() external view returns (uint256);

    function isReserveToken(address token) external view returns (bool);
}
