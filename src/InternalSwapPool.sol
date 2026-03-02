// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
// import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";

// 1. User calls swap on Swap Router
// 2. Swap Router calls swap on Pool Manager
// 3. Pool Manager calls beforeSwap on Hook
// 4. If there are Currency1 tokens held within our hook, the hook should return a BeforeSwapDelta such that it consumes some, or all, the input token, and returns an equal amount of the opposite token
// 5. Core swap logic may be skipped (NoOp)
// 6. Pool Manager returns final BalanceDelta
// 7. Hook captures fees in afterSwap
// 8. Swap Router accounts for the balances

// Basically, LPs are settled for transactions using donations.

contract InternalSwapPool is BaseHook {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /**
     * Amount of claimable tokens that are available to be distributed for a PoolId
     */
    struct ClaimableFees {
        uint256 amount0;
        uint256 amount1;
    }

    error MustUseDynamicFees();

    // Minimum threshold for donations into the pool
    uint256 public constant DONATE_THRESHOLD_MIN = 0.0001 ether;
    // Native token address
    address public immutable NATIVE_TOKEN;

    // mapping of fee claims to individual pool
    mapping(PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    constructor(IPoolManager _poolManager, address _NATIVE_TOKEN) BaseHook(_poolManager) {
        NATIVE_TOKEN = _NATIVE_TOKEN;
    }

    /// Hook permission selector
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Hook functions

    /// ensure that no pool can be initialized with this hook attached that
    /// did not identify itself as a pool with dynamic fees - otherwise nobody will be able to conduct swaps on that pool
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_)
    {
        PoolId poolId = key.toId();
        if (!params.zeroForOne && _poolFees[poolId].amount1 != 0) {
            uint256 tokenIn;
            uint256 ethOut;

            // Get the current price for the pool to use as a price basis for the swap
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            // token0 for token1 with exact output for input
            if (params.amountSpecified >= 0) {
                // If the amount specified for token1 is greater than what we have in the pool fees from deposit fees,
                // we use poolFees amount1 otherwise, we use amountSpecified for the swap
                // We want to determine the maximum value
                uint256 amountSpecified = (uint256(params.amountSpecified) > _poolFees[poolId].amount1)
                    ? _poolFees[poolId].amount1
                    : uint256(params.amountSpecified);

                // We want to determine the amount of ETH token required to get the amount of token1 specified at the current pool state
                (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int256(amountSpecified),
                    feePips: 0
                });
                // Update our hook delta to reduce the upcoming swap amount to show that we have
                // already spent some of the ETH and received some of the underlying ERC20.
                beforeSwapDelta_ = toBeforeSwapDelta(-int128(int256(tokenIn)), int128(int256(ethOut)));
            } else {
                // token0 for token1 with exact input for output
                // amountSpecified is negative
                // Since we already know the amount of token0 required, we just need to
                // determine the amount we will receive if we convert all of the pool fees.
                (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int256(_poolFees[poolId].amount1),
                    feePips: 0
                });

                if (ethOut > uint256(-params.amountSpecified)) {
                    uint256 percentage = (uint256(-params.amountSpecified) * 1e18) / ethOut;
                    tokenIn = (tokenIn * percentage) / 100;
                }
                beforeSwapDelta_ = toBeforeSwapDelta(int128(int256(ethOut)), -int128(int256(tokenIn)));
            }
            _poolFees[poolId].amount0 += ethOut;
            _poolFees[poolId].amount1 -= tokenIn;
            poolManager.sync(key.currency0);
            poolManager.sync(key.currency1);

            // Transfer tokens to the PoolManager
            poolManager.take(key.currency0, address(this), ethOut);
            key.currency1.settle(poolManager, address(this), tokenIn, false);
        }
        selector_ = IHooks.beforeSwap.selector;
        swapFee_ = 0;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4 selector_, int128 hookDeltaUnspecified_)
    {
        // Currency that we will be taking fee from
        Currency swapFeeCurrency = params.amountSpecified < 0 == params.zeroForOne ? key.currency1 : key.currency0;
        // amount received from the swap
        int128 swapAmount = params.amountSpecified < 0 == params.zeroForOne ? delta.amount1() : delta.amount0();
        // Determine the swap fee
        uint256 swapFee = uint256(uint128(swapAmount < 0 ? -swapAmount : swapAmount)) * 99 / 100;
        _depositFees(key, params.zeroForOne ? swapFee : 0, params.zeroForOne ? 0 : swapFee);
        // take swap fes from the pool manager
        swapFeeCurrency.take(poolManager, address(this), swapFee, false);
        // Set our hookDelta to remove the amount of fees from the amount that the user will receive
        hookDeltaUnspecified_ = -int128(int256(swapFee));
        // distribute fees to the LPs
        _distributeFees(key);
        selector_ = IHooks.afterSwap.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4 selector_, BalanceDelta balanceDelta_) {
        _distributeFees(key);
        selector_ = IHooks.afterRemoveLiquidity.selector;
        balanceDelta_ = BalanceDelta.wrap(0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4 selector_, BalanceDelta balanceDelta_) {
        _distributeFees(key);
        selector_ = IHooks.afterAddLiquidity.selector;
        balanceDelta_ = BalanceDelta.wrap(0);
    }

    // Helper and external functions
    ///
    /// Return claimable pool key
    /// @param _poolKey The pool key of the pool
    /// @return The {ClaimableFees} of the pool
    ///
    function poolFees(PoolKey calldata _poolKey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    /// Deposit claimable fees from a swap operation to its respective pool
    /// @param _poolKey The key of the pool
    /// @param _amount0 Amount of currency0 to deposit which is the NATIVE_TOKEN provided
    /// @param _amount1 Amount of currency1 to deposit
    function _depositFees(PoolKey calldata _poolKey, uint256 _amount0, uint256 _amount1) public {
        _poolFees[_poolKey.toId()].amount0 += _amount0;
        _poolFees[_poolKey.toId()].amount1 += _amount1;
    }

    /// Takes a collection address and, if there is sufficient fees available to
    /// claim, will call the `donate` function against the mapped Uniswap V4 pool.
    ///
    /// @dev This call could be checked in a Uniswap V4 interactions hook to
    /// dynamically process fees when they hit a threshold.
    ///
    /// @param _poolKey The PoolKey reference that will have fees distributed
    function _distributeFees(PoolKey calldata _poolKey) internal {
        PoolId poolId = _poolKey.toId();
        uint256 donationAmount = _poolFees[poolId].amount0;

        // Ensure that the collection has sufficient fees available
        if (donationAmount < DONATE_THRESHOLD_MIN) return;

        BalanceDelta delta = poolManager.donate(_poolKey, donationAmount, 0, "");

        // Settle tokens
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }

        // Reduce the fees by the donation amount
        _poolFees[poolId].amount0 -= donationAmount;
    }
}
