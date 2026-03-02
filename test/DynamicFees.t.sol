// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;
 
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {DynamicFees} from "../src/DynamicFees.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";
 
contract TestDynamicFeesHook is Test, Deployers {
    DynamicFees hook;
 
	function setUp() public {
		deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Hook flags
        address hookAddress = address(
            uint160(
                Hooks.ALL_HOOK_MASK
            )
        );
        vm.txGasPrice(10 gwei);
        deployCodeTo("DynamicFees.sol", abi.encode(manager), hookAddress);

        hook = DynamicFees(hookAddress);

        assertEq(address(hook), hookAddress);

        (key, ) = initPool(
            currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        // Adding liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60,
                liquidityDelta: 100 ether, salt: bytes32(0)
            }),
            ZERO_BYTES
        );
	}

    function test_feeUpdateWithGasPrice() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false, settleUsingBurn: false
        });
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // First test for confirmation
        uint128 gasPrice = uint128(tx.gasprice);
        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        console.log("Moving average gas price", movingAverageGasPrice);
        uint128 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        console.log("Moving average gas price count", movingAverageGasPriceCount);
        assertEq(gasPrice, 10 gwei);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 5);

        // Second test - Conduct first swap at price at 10 gwei
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        console.log("Output from base fee swap", outputFromBaseFeeSwap);
        assertGt(balanceOfToken1After, balanceOfToken1Before);
        // We should check if the movingPriceAverage has not changed from 10 gwei since we are using thesame swap price
        movingAverageGasPrice = hook.movingAverageGasPrice();
        console.log("Moving average gas price after swap", movingAverageGasPrice);
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        console.log("Moving average gas price count after swap", movingAverageGasPriceCount);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 7);

        // Third test - Conduct first swap at price at 4 gwei
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        console.log("Output from base fee swap", outputFromBaseFeeSwap);
        assertGt(balanceOfToken1After, balanceOfToken1Before);
        // We should check if the movingPriceAverage has changed from 10 gwei since we are using less swap price
        movingAverageGasPrice = hook.movingAverageGasPrice();
        console.log("Moving average gas price after swap", movingAverageGasPrice);
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        console.log("Moving average gas price count after swap", movingAverageGasPriceCount);
        assertEq(movingAverageGasPrice, 8.666666666 gwei);
        assertEq(movingAverageGasPriceCount, 9);

        // Fourth test - Conduct third swap at price at 15 gwei
        vm.txGasPrice(15 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        console.log("Output from base fee swap", outputFromBaseFeeSwap);
        assertGt(balanceOfToken1After, balanceOfToken1Before);
        // We should check if the movingPriceAverage has not changed from 10 gwei since we are using thesame swap price
        movingAverageGasPrice = hook.movingAverageGasPrice();
        console.log("Moving average gas price after swap", movingAverageGasPrice);
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        console.log("Moving average gas price count after swap", movingAverageGasPriceCount);
        assertEq(movingAverageGasPrice, 9.818181817 gwei);
        assertEq(movingAverageGasPriceCount, 11);




    }
}