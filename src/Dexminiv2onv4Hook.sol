// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/types/HookTypes.sol";
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

contract V2OnV4Hook is HookTypes {
    // Virtual reserves tracking for tokens 0 and 1
    uint256 public reserve0;
    uint256 public reserve1;

    // Total supply of fungible LP tokens
    uint256 public totalLPTokens;

    // Mapping of LP token balances
    mapping(address => uint256) public balanceOf;

    // Fixed fee rate (e.g., 0.3%)
    uint256 public constant FEE_RATE = 30; // 30 basis points

    // Address of the PoolManager
    address public immutable poolManager;

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
     * @notice Modifier to restrict function calls to the PoolManager only.
     */
    modifier onlyPoolManager() {
        require(msg.sender == poolManager, "Unauthorized");
        _;
    }

    /**
     * @notice Constructor to initialize the PoolManager address.
     * @param _poolManager The address of the Uniswap v4 PoolManager.
     */
    constructor(address _poolManager) {
        require(_poolManager != address(0), "Invalid PoolManager address");
        poolManager = _poolManager;
    }

    /**
     * @notice Lifecycle function called before adding liquidity.
     * @return selector The function selector to confirm execution.
     */
    function beforeAddLiquidity(
        bytes calldata /* data */
    ) external override onlyPoolManager returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    /**
     * @notice Lifecycle function called after adding liquidity.
     * @param sender The address adding liquidity.
     * @param amount0 The amount of token0 added.
     * @param amount1 The amount of token1 added.
     * @return selector The function selector to confirm execution.
     */
    function afterAddLiquidity(
        address sender,
        uint256 amount0,
        uint256 amount1
    ) external override onlyPoolManager returns (bytes4) {
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

        return this.afterAddLiquidity.selector;
    }

    /**
     * @notice Lifecycle function called before a swap.
     * @param sender The address initiating the swap.
     * @param amountIn The input amount for the swap.
     * @param zeroForOne Whether token0 is being swapped for token1.
     * @param hookData Arbitrary data passed by the caller.
     * @return selector The function selector to confirm execution.
     */
    function beforeSwap(
        address sender,
        uint256 amountIn,
        bool zeroForOne,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        require(amountIn > 0, "Invalid amountIn");

        // Capture the pre-swap product of reserves
        uint256 preSwapProduct = reserve0 * reserve1;

        // Encode preSwapProduct into hookData for atomic context passing
        bytes memory updatedHookData = abi.encode(preSwapProduct, hookData);

        return this.beforeSwap.selector;
    }

    /**
     * @notice Lifecycle function called after a swap.
     * @param sender The address initiating the swap.
     * @param amountIn The input amount for the swap.
     * @param amountOut The output amount from the swap.
     * @param zeroForOne Whether token0 is being swapped for token1.
     * @param hookData Arbitrary data passed by the caller (includes preSwapProduct).
     * @param minAmountOut The minimum acceptable output amount (slippage tolerance).
     * @return selector The function selector to confirm execution.
     */
    function afterSwap(
        address sender,
        uint256 amountIn,
        uint256 amountOut,
        bool zeroForOne,
        bytes calldata hookData,
        uint256 minAmountOut // Configurable slippage tolerance passed from periphery
    ) external override onlyPoolManager returns (bytes4) {
        require(amountOut > 0, "Invalid amountOut");

        // Decode preSwapProduct from hookData
        (uint256 preSwapProduct, ) = abi.decode(hookData, (uint256, bytes));

        // Slippage protection: Ensure the output meets the minimum expected amount
        require(amountOut >= minAmountOut, "Slippage exceeded");

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

        return this.afterSwap.selector;
    }

    /**
     * @notice Lifecycle function called after removing liquidity.
     * @param sender The address removing liquidity.
     * @param lpTokensBurned The amount of LP tokens burned.
     * @return selector The function selector to confirm execution.
     */
    function afterRemoveLiquidity(
        address sender,
        uint256 lpTokensBurned
    ) external override onlyPoolManager returns (bytes4) {
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

        return this.afterRemoveLiquidity.selector;
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
