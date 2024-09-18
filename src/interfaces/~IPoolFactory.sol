// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;


// e this is probably the interface of the pool factory contract from tSwap protocol
interface IPoolFactory {
    function getPool(address tokenAddress) external view returns (address);
}
