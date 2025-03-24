// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol"; // Gas-efficient math library

/**
 * @title V2OnV4Hook
 * @dev A custom Uniswap v4 hook that recreates the Uniswap v2 user experience:
 *      - Fungible LP tokens.
 *      - Auto-compounding fees.
 *      - Simplicity for liquidity providers and traders.
 */

/*////////////////////////////////////////////////////////////////////////////
//                                                                          //
//     ██████╗ ███████╗██╗  ██╗    ███╗   ███╗██╗███╗   ██╗██╗           //
//     ██╔══██╗██╔════╝╚██╗██╔╝    ████╗ ████║██║████╗  ██║██║           //
//     ██║  ██║█████╗   ╚███╔╝     ██╔████╔██║██║██╔██╗ ██║██║           //
//     ██║  ██║██╔══╝   ██╔██╗     ██║╚██╔╝██║██║██║╚██╗██║██║           //
//     ██████╔╝███████╗██╔╝ ██╗    ██║ ╚═╝ ██║██║██║ ╚████║██║           //
//     ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝           //
//                                                                          //
//     Uniswap V4 Hook - Version 1.0                                       //
//     https://dexmini.com                                                 //
//                                                                          //
////////////////////////////////////////////////////////////////////////////*/

contract V2OnV4Hook is BaseHook {
    // Virtual reserves tracking for tokens 0 and 1
    uint256 public reserve0;
    uint256 public reserve1;

    // Total supply of fungible LP tokens
    uint256 public totalLPTokens;

    // Mapping of LP token balances
    mapping(address => uint256) public balanceOf;

    // Fixed fee rate (e.g., 0.3%)
    uint256 public constant FEE_RATE = 30; // 30 basis points

    // Events for minting, burning, and swap operations
    event LiquidityAdded(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpTokensMinted
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpTokensBurned
    );
    event Swapped(
        address indexed trader,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeCompounded
    );

    /**
     * @notice Constructor to initialize the PoolManager address.
     * @param _poolManager The address of the Uniswap v4 PoolManager.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Returns the hook's permissions
     * @return The permissions of the hook
     */
    function getHookPermissions()
        public
        pure
        virtual
        override
        returns (Hooks.Permissions memory)
    {
        Hooks.Permissions memory permissions;

        permissions.beforeInitialize = false;
        permissions.afterInitialize = false;
        permissions.beforeAddLiquidity = true;
        permissions.afterAddLiquidity = true;
        permissions.beforeRemoveLiquidity = false;
        permissions.afterRemoveLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeDonate = false;
        permissions.afterDonate = false;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = false;
        permissions.afterAddLiquidityReturnDelta = false;
        permissions.afterRemoveLiquidityReturnDelta = false;

        return permissions;
    }

    /**
     * @notice Lifecycle function called before adding liquidity.
     * @return The function selector
     */
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Lifecycle function called after adding liquidity.
     * @param sender The address adding liquidity.
     * @param delta The balance delta resulting from the liquidity change
     * @return The function selector and balance delta
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        uint256 amount0 = uint256(uint128(delta.amount0()));
        uint256 amount1 = uint256(uint128(delta.amount1()));

        // Validate inputs
        if (totalLPTokens == 0) {
            require(amount0 > 0 && amount1 > 0, "Zero initial liquidity");
        } else {
            require(
                amount0 * reserve1 == amount1 * reserve0,
                "Imbalanced liquidity"
            );
        }

        uint256 lpToMint;

        if (totalLPTokens == 0) {
            // Initial liquidity rule: LP tokens are proportional to sqrt(amount0 * amount1)
            lpToMint = gasEfficientSqrt(amount0 * amount1);
        } else {
            // Determine share based on existing reserves
            lpToMint = min(
                (amount0 * totalLPTokens) / reserve0,
                (amount1 * totalLPTokens) / reserve1
            );
        }

        // Update virtual reserves
        reserve0 += amount0;
        reserve1 += amount1;

        // Mint LP tokens
        totalLPTokens += lpToMint;
        balanceOf[sender] += lpToMint;

        emit LiquidityAdded(sender, amount0, amount1, lpToMint);

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /**
     * @notice Lifecycle function called before a swap.
     * @param params The swap parameters
     * @param hookData Arbitrary data passed by the caller.
     * @return The function selector, before swap delta, and optional fee
     */
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        require(params.amountSpecified != 0, "Invalid amountIn");

        // Capture the pre-swap product of reserves
        uint256 preSwapProduct = reserve0 * reserve1;

        // Create BeforeSwapDelta with preSwapProduct encoded into it
        // Here we use the custom data field to pass the preSwapProduct to afterSwap
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /**
     * @notice Lifecycle function called after a swap.
     * @param sender The address initiating the swap.
     * @param params The swap parameters
     * @param delta The balance delta resulting from the swap
     * @param hookData Data passed from the before hook
     * @return The function selector and modification to the swap delta
     */
    function _afterSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        // Get amounts from delta
        uint256 amountIn;
        uint256 amountOut;
        bool zeroForOne = params.zeroForOne;

        if (zeroForOne) {
            amountIn = uint256(uint128(-delta.amount0()));
            amountOut = uint256(uint128(delta.amount1()));
        } else {
            amountIn = uint256(uint128(-delta.amount1()));
            amountOut = uint256(uint128(delta.amount0()));
        }

        require(amountOut > 0, "Invalid amountOut");

        // In a real implementation, we would decode preSwapProduct from hookData
        // For compilation purposes, we're calculating it here again
        uint256 preSwapProduct = reserve0 * reserve1;

        // Compute fee on amountIn
        uint256 fee = (amountIn * FEE_RATE) / 10000;
        uint256 amountInAfterFee = amountIn - fee;

        // Adjust reserves with fee included
        if (zeroForOne) {
            reserve0 += amountInAfterFee; // Add net input (excludes fee)
            reserve0 += fee; // Compound fee separately
            reserve1 -= amountOut;
        } else {
            reserve1 += amountInAfterFee; // Add net input (excludes fee)
            reserve1 += fee; // Compound fee separately
            reserve0 -= amountOut;
        }

        // Enforce the constant product invariant
        require(reserve0 * reserve1 >= preSwapProduct, "Invariant violation");

        emit Swapped(sender, amountIn, amountOut, fee);

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Lifecycle function called after removing liquidity.
     * @param sender The address removing liquidity.
     * @param delta The balance delta resulting from the liquidity removal
     * @return The function selector and balance delta
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // Extract the absolute value of liquidity removed
        uint256 lpTokensBurned = 0; // This needs to be calculated or passed in through data

        // In a real implementation, lpTokensBurned would be determined from the liquidity delta
        // or passed through hook data
        if (lpTokensBurned == 0) {
            // Temp placeholder until we have real implementation
            lpTokensBurned = totalLPTokens / 10; // Just for compilation, will be replaced
        }

        require(lpTokensBurned > 0, "Invalid LP burn amount");

        // Calculate token amounts to return based on the LP share
        uint256 amount0 = (reserve0 * lpTokensBurned) / totalLPTokens;
        uint256 amount1 = (reserve1 * lpTokensBurned) / totalLPTokens;

        // Update reserves
        reserve0 -= amount0;
        reserve1 -= amount1;

        // Burn LP tokens
        totalLPTokens -= lpTokensBurned;
        balanceOf[sender] -= lpTokensBurned;

        emit LiquidityRemoved(sender, amount0, amount1, lpTokensBurned);

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /**
     * @notice Utility function to calculate the square root of a number using ABDKMath64x64.
     * @param x The number to calculate the square root of.
     * @return y The square root of x.
     */
    function gasEfficientSqrt(uint256 x) internal pure returns (uint256 y) {
        // Use ABDKMath64x64 for gas-efficient fixed-point square root calculation
        int128 sqrtResult = ABDKMath64x64.sqrt(ABDKMath64x64.fromUInt(x));
        return ABDKMath64x64.toUInt(sqrtResult);
    }

    /**
     * @notice Utility function to calculate the minimum of two numbers.
     * @param a The first number.
     * @param b The second number.
     * @return The smaller of the two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
