// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import { ITSwapPool } from "../interfaces/ITSwapPool.sol";
import { IPoolFactory } from "../interfaces/IPoolFactory.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract OracleUpgradeable is Initializable {
    address private s_poolFactory;

    function __Oracle_init(address poolFactoryAddress) internal onlyInitializing {
        // @audit-info check poolFactoryAddress is a non-zero address
        __Oracle_init_unchained(poolFactoryAddress);
    }

    function __Oracle_init_unchained(address poolFactoryAddress) internal onlyInitializing {
        s_poolFactory = poolFactoryAddress;
    }

    // This calls an external contract (TSwapPool) to get the price of a token in WETH
    // q What if price is manipulated in TSwapPool contract ???
    // q How can we manipulate the price in TSwapPool contract ???
    // q Reentrancy attack is possible here ???
    function getPriceInWeth(address token) public view returns (uint256) {
        // q are we sure that the pool factory created a pool for this token ???
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
        return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }

    // Redundant function, we could call getPriceInWeth directly
    function getPrice(address token) external view returns (uint256) {
        return getPriceInWeth(token);
    }

    function getPoolFactoryAddress() external view returns (address) {
        return s_poolFactory;
    }
}
