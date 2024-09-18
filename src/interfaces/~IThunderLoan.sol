// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// @audit-info This interface is not implemented by ThunderLoan contract !!!
interface IThunderLoan {
    // q this function shouldn't be public ???
    // q repay parameter are wrong, it should be (IERC20 token, uint256 amount)
    function repay(address token, uint256 amount) external;
}
