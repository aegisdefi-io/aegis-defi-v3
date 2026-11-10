// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IStaking {
    function stake(address _to, uint256 _amount, bool _claim) external returns (uint256);

    function claim(address _to) external returns (uint256);

    function forfeit() external returns (uint256);

    function unstake(address _to, uint256 _amount, bool _trigger) external returns (uint256);

    function rebase() external returns (uint256);

    function index() external view returns (uint256);

    function supplyInWarmup() external view returns (uint256);

    function secondsToNextEpoch() external view returns (uint256);

    function epoch() external view returns (uint256 length, uint256 number, uint256 end, uint256 distribute);
}
