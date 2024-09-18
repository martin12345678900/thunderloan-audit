// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

// e this is probably the interface of the swap pool from tSwap protocol
interface ITSwapPool {
    function getPriceOfOnePoolTokenInWeth() external view returns (uint256);
}
