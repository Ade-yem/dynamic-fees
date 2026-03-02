// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

// For this smart contract, we are going to use the the afterSwap and afterInitialize hooks to handle orders placed

contract LimitOrder is BaseHook, ERC1155 {
    // Add stateLibrary to extend the pool manager to read storage values
    using StateLibrary for IPoolManager;
    // Math operations
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Mappings
    // Basically, we can have multiple orders for thesame tickToSellAt, for that tickToSellAt, we can have multiple zeroForOne orders or non zeroForOne orders
    // pendingOrders[poolId][tickToSellAt][zeroForOne] = inputAmount
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;
    // Claim token supply
    mapping(uint256 orderId => uint256 claimsSupply) public claimsTokenSupply;
    // Output tokens
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    /// Hook permission selector
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        // implement afterInitialize hook
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // Should we try to find and execute orders? True initially
        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            // Try executing pending orders for this pool

            // `tryMore` is true if we successfully found and executed an order
            // which shifted the tick value
            // and therefore we need to look again if there are any pending orders
            // within the new tick range

            // `tickAfterExecutingOrder` is the tick value of the pool
            // after executing an order
            // if no order was executed, `tickAfterExecutingOrder` will be
            // the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(key, !params.zeroForOne);
        }

        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // Placing orders

    /// @notice Places a limit order to sell tokens when the pool price reaches a specific tick.
    /// @dev This function calculates the nearest valid tick based on the pool's tick spacing,
    /// records the order in the `pendingOrders` mapping, and mints ERC1155 claim tokens to the caller.
    /// The caller must have approved this contract to spend the `inputAmount` of the `sellToken`.
    /// @param key The PoolKey of the Uniswap V4 pool.
    /// @param tickToSellAt The target tick price at which the order should be executed.
    /// @param zeroForOne Boolean indicating the swap direction: true for currency0 to currency1, false for currency1 to currency0.
    /// @param inputAmount The amount of the input token to be placed in the limit order.
    /// @return tick The actual lower usable tick where the order is stored.
    /// @custom:example
    /// // To sell 1 WETH (currency0) for USDC (currency1) when the tick reaches -200000:
    /// limitOrder.placeOrder(poolKey, -200000, true, 1e18)
    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        // Lower usable tick for given tick
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Creating a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tojens for the user equal to their `inputAmount`
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimsTokenSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");

        // We transfer those tokens to this contract depending on the direction
        // of the swap. We also select the inputTokens
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        return tick;
    }

    /// @notice Cancels a previously placed limit order and returns the input tokens to the caller.
    /// @dev This function burns the caller's ERC1155 claim tokens, updates the pending order state,
    /// and transfers the original input tokens back to the caller.
    /// @param key The PoolKey of the Uniswap V4 pool.
    /// @param tickToSellAt The target tick price of the order to be cancelled.
    /// @param zeroForOne Boolean indicating the swap direction of the order.
    /// @param amountToCancel The amount of input tokens to cancel from the order.
    /// @custom:example
    /// // To cancel 1 WETH (currency0) from a previously placed
    /// limitOrder.cancelOrder(poolKey, -200000, true, 1e18)
    function cancelOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 amountToCancel) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        // check how many tokens the sender has for this position
        uint256 positionTokens = balanceOf(msg.sender, orderId);
        if (positionTokens < amountToCancel) revert NotEnoughToClaim();

        // remove amount to cancel from pending orders
        pendingOrders[key.toId()][tickToSellAt][zeroForOne] -= amountToCancel;
        claimsTokenSupply[orderId] -= amountToCancel;
        _burn(msg.sender, orderId, amountToCancel);

        // Send back the sender's tokens
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    function redeem(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 amountToClaim) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();
        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < amountToClaim) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimsTokenSupply[orderId];

        // outputAmount = (amountToClaim * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = amountToClaim.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);
        claimableOutputTokens[orderId] -= outputAmount;
        claimsTokenSupply[orderId] -= amountToClaim;
        _burn(msg.sender, orderId, amountToClaim);

        // Transfer output tokens to the sender
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function executeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -inputAmount.toInt256(), // we provide negative value to signify exact input for output
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        // remove the input amount from the pending orders
        pendingOrders[key.toId()][tickToSellAt][zeroForOne] -= inputAmount;
        uint256 orderId = getOrderId(key, tickToSellAt, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        // add to claimable output tokens
        claimableOutputTokens[orderId] += outputAmount;
    }

    // Helper functions

    /// The lowest tick we can use.
    /// e.g tick = -100, tickSpacing = 60, we will use -120 for tick
    /// @param tick tick provided by the user
    /// @param tickSpacing tick spacing
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals -= 1;
        }
        return intervals * tickSpacing;
    }

    /// @notice Generates a unique identifier for a limit order based on the pool, tick, and direction.
    /// @dev This ID is used as the ERC1155 token ID for claim tokens and to track the supply of filled orders.
    /// @param key The PoolKey representing the pool.
    /// @param tick The tick at which the order is placed.
    /// @param zeroForOne The swap direction; true if currency0 is being sold for currency1.
    /// @return The unique uint256 ID for the order.
    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    function swapAndSettleBalances(PoolKey calldata key, SwapParams memory params) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");
        // If it is a zeroForOne swap, we send token0 to PM and receive token1
        if (params.zeroForOne) {
            // delta.amount0 will be -ve, settle with PM - Money leaving user's wallet
            if (delta.amount0() < 0) _settle(key.currency0, uint128(-delta.amount0()));
            // Take from PM, amount1 will be +ve, - Money going into user's wallet
            if (delta.amount1() > 0) _take(key.currency1, uint128(delta.amount1()));
        } else {
            // delta.amount1 will be -ve, settle with PM - Money leaving user's wallet
            if (delta.amount1() < 0) _settle(key.currency1, uint128(-delta.amount1()));
            // Take from PM, amount1 will be +ve, - Money going into user's wallet
            if (delta.amount0() > 0) _take(key.currency0, uint128(delta.amount0()));
        }
        return delta;
    }

    function tryExecutingOrders(PoolKey calldata key, bool executeZeroForOne)
        internal
        returns (bool tryMore, int24 newTick)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
        // Tick is +ve, price of token0 has increased by selling token1
        if (currentTick > lastTick) {
            // go through all ticks from last tick to current tick and execute their orders
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    // We fufill all thesame orders as a single swap regardless of the amount of users who placed thesame order
                    // They can get their amount from the claimables
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // tick has gone down, token1 has increased in price relative to token0
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }
        return (false, currentTick);
    }
}
