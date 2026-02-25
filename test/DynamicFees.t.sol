// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;
 
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
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
        

    }
}