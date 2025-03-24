// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Dexminiv2onv4Hook.sol";
import "./mocks/MockERC20.sol";

// Simplified mock of V2OnV4Hook without inheriting from BaseHook
contract MockV2OnV4Hook {
    // Virtual reserves tracking for tokens 0 and 1
    uint256 public reserve0;
    uint256 public reserve1;

    // Total supply of fungible LP tokens
    uint256 public totalLPTokens;

    // Mapping of LP token balances
    mapping(address => uint256) public balanceOf;

    // Fixed fee rate (e.g., 0.3%)
    uint256 public constant FEE_RATE = 30; // 30 basis points

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
     * @notice Adds liquidity to the mock contract
     * @param sender The address adding liquidity
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @return lpTokens The amount of LP tokens minted
     */
    function addLiquidity(
        address sender,
        uint256 amount0,
        uint256 amount1
    ) external returns (uint256 lpTokens) {
        // Validate inputs
        if (totalLPTokens == 0) {
            require(amount0 > 0 && amount1 > 0, "Zero initial liquidity");
        } else {
            require(
                amount0 * reserve1 == amount1 * reserve0,
                "Imbalanced liquidity"
            );
        }

        if (totalLPTokens == 0) {
            // Initial liquidity rule: LP tokens are proportional to sqrt(amount0 * amount1)
            lpTokens = gasEfficientSqrt(amount0 * amount1);
        } else {
            // Determine share based on existing reserves
            lpTokens = min(
                (amount0 * totalLPTokens) / reserve0,
                (amount1 * totalLPTokens) / reserve1
            );
        }

        // Update virtual reserves
        reserve0 += amount0;
        reserve1 += amount1;

        // Mint LP tokens
        totalLPTokens += lpTokens;
        balanceOf[sender] += lpTokens;

        emit LiquidityAdded(sender, amount0, amount1, lpTokens);

        return lpTokens;
    }

    /**
     * @notice Removes liquidity from the mock contract
     * @param sender The address removing liquidity
     * @param lpTokensBurned Amount of LP tokens to burn
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function removeLiquidity(
        address sender,
        uint256 lpTokensBurned
    ) external returns (uint256 amount0, uint256 amount1) {
        require(lpTokensBurned > 0, "Cannot remove zero liquidity");
        require(balanceOf[sender] >= lpTokensBurned, "Insufficient LP tokens");

        // Calculate token amounts to return based on the LP share
        amount0 = (reserve0 * lpTokensBurned) / totalLPTokens;
        amount1 = (reserve1 * lpTokensBurned) / totalLPTokens;

        // Update reserves
        reserve0 -= amount0;
        reserve1 -= amount1;

        // Burn LP tokens
        totalLPTokens -= lpTokensBurned;
        balanceOf[sender] -= lpTokensBurned;

        emit LiquidityRemoved(sender, amount0, amount1, lpTokensBurned);

        return (amount0, amount1);
    }

    /**
     * @notice Simulates a token swap in the mock contract
     * @param sender The address performing the swap
     * @param zeroForOne Whether the swap is from token0 to token1
     * @param amountIn The input amount of tokens
     * @return amountOut The output amount of tokens
     */
    function swap(
        address sender,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid amountIn");

        // Capture the pre-swap product of reserves
        uint256 preSwapProduct = reserve0 * reserve1;

        // Compute fee on amountIn
        uint256 fee = (amountIn * FEE_RATE) / 10000;
        uint256 amountInAfterFee = amountIn - fee;

        if (zeroForOne) {
            // Calculate amountOut based on constant product formula
            // (reserve0 + amountInAfterFee) * (reserve1 - amountOut) = reserve0 * reserve1
            amountOut =
                (reserve1 * amountInAfterFee) /
                (reserve0 + amountInAfterFee);

            // Adjust reserves with fee included
            reserve0 += amountInAfterFee; // Add net input (excludes fee)
            reserve0 += fee; // Compound fee separately
            reserve1 -= amountOut;
        } else {
            // Calculate amountOut based on constant product formula
            amountOut =
                (reserve0 * amountInAfterFee) /
                (reserve1 + amountInAfterFee);

            // Adjust reserves with fee included
            reserve1 += amountInAfterFee; // Add net input (excludes fee)
            reserve1 += fee; // Compound fee separately
            reserve0 -= amountOut;
        }

        // Enforce the constant product invariant
        require(reserve0 * reserve1 >= preSwapProduct, "Invariant violation");

        emit Swapped(sender, amountIn, amountOut, fee);

        return amountOut;
    }

    /**
     * @notice Utility function to calculate the square root of a number.
     * @param x The number to calculate the square root of.
     * @return y The square root of x.
     */
    function gasEfficientSqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;

        // Using a simplified algorithm for tests
        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
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

contract V2OnV4HookMocksTest is Test {
    // Mock implementation of V2OnV4Hook
    MockV2OnV4Hook public mock;

    // Test tokens
    MockERC20 public token0;
    MockERC20 public token1;

    // Test amounts
    uint256 constant AMOUNT0 = 1 ether;
    uint256 constant AMOUNT1 = 3000 * 10 ** 6; // 3000 USDC

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 address < token1 address
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy mock implementation
        mock = new MockV2OnV4Hook();
    }

    // Test to verify correct setup of all components
    function test_setUp() public {
        // Verify Mock Tokens
        assertTrue(address(token0) != address(0));
        assertTrue(address(token1) != address(0));

        // Verify mock deployment
        assertTrue(address(mock) != address(0));

        // Verify initial pool state
        assertEq(mock.reserve0(), 0);
        assertEq(mock.reserve1(), 0);
        assertEq(mock.totalLPTokens(), 0);
    }

    // Test for adding initial liquidity
    function test_addLiquidity() public {
        address lp = address(0x1234);

        // Add initial liquidity
        uint256 lpTokens = mock.addLiquidity(lp, AMOUNT0, AMOUNT1);

        // Calculate expected LP tokens
        uint256 expectedLPTokens = mock.gasEfficientSqrt(AMOUNT0 * AMOUNT1);

        // Verify LP token minting
        assertEq(lpTokens, expectedLPTokens);
        assertEq(mock.totalLPTokens(), expectedLPTokens);
        assertEq(mock.balanceOf(lp), expectedLPTokens);

        // Verify reserve updates
        assertEq(mock.reserve0(), AMOUNT0);
        assertEq(mock.reserve1(), AMOUNT1);
    }

    // Test for adding subsequent liquidity
    function test_addSubsequentLiquidity() public {
        address lp1 = address(0x1234);
        address lp2 = address(0x5678);

        // Add initial liquidity from lp1
        uint256 initialLPTokens = mock.addLiquidity(lp1, AMOUNT0, AMOUNT1);
        uint256 expectedInitialLPTokens = mock.gasEfficientSqrt(
            AMOUNT0 * AMOUNT1
        );
        assertEq(initialLPTokens, expectedInitialLPTokens);

        // Verify initial state
        assertEq(mock.reserve0(), AMOUNT0);
        assertEq(mock.reserve1(), AMOUNT1);
        assertEq(mock.totalLPTokens(), expectedInitialLPTokens);
        assertEq(mock.balanceOf(lp1), expectedInitialLPTokens);

        // Add subsequent liquidity from lp2 (2x the initial amount)
        uint256 amount0_2 = AMOUNT0 * 2;
        uint256 amount1_2 = AMOUNT1 * 2;

        // Calculate expected LP tokens for subsequent addition
        uint256 expectedSubsequentLPTokens = (amount0_2 *
            mock.totalLPTokens()) / mock.reserve0();

        uint256 subsequentLPTokens = mock.addLiquidity(
            lp2,
            amount0_2,
            amount1_2
        );

        // Verify LP token minting for second deposit
        assertEq(subsequentLPTokens, expectedSubsequentLPTokens);
        assertEq(mock.balanceOf(lp2), expectedSubsequentLPTokens);

        // Verify updated total supply
        assertEq(
            mock.totalLPTokens(),
            expectedInitialLPTokens + expectedSubsequentLPTokens
        );

        // Verify final reserves
        assertEq(mock.reserve0(), AMOUNT0 + amount0_2);
        assertEq(mock.reserve1(), AMOUNT1 + amount1_2);
    }

    // Test for token swaps
    function test_swap() public {
        address lp = address(0x1234);
        address trader = address(0x5678);

        // Add initial liquidity
        mock.addLiquidity(lp, AMOUNT0, AMOUNT1);

        // Save initial reserves
        uint256 initialReserve0 = mock.reserve0();
        uint256 initialReserve1 = mock.reserve1();

        // Perform a swap (token0 for token1)
        uint256 swapAmount = 0.1 ether;
        bool zeroForOne = true;

        // Calculate expected output
        uint256 fee = (swapAmount * mock.FEE_RATE()) / 10000;
        uint256 amountInAfterFee = swapAmount - fee;
        uint256 expectedAmountOut = (initialReserve1 * amountInAfterFee) /
            (initialReserve0 + amountInAfterFee);

        uint256 amountOut = mock.swap(trader, zeroForOne, swapAmount);

        // Verify swap results
        assertEq(amountOut, expectedAmountOut);

        // Verify reserve updates
        assertEq(mock.reserve0(), initialReserve0 + swapAmount);
        assertEq(mock.reserve1(), initialReserve1 - amountOut);

        // Verify the constant product invariant is maintained or improved
        assertTrue(
            mock.reserve0() * mock.reserve1() >=
                initialReserve0 * initialReserve1
        );
    }

    // Test for removing liquidity
    function test_removeLiquidity() public {
        address lp = address(0x1234);

        // Add initial liquidity
        uint256 lpTokens = mock.addLiquidity(lp, AMOUNT0, AMOUNT1);

        // Verify initial state
        assertEq(mock.reserve0(), AMOUNT0);
        assertEq(mock.reserve1(), AMOUNT1);
        assertEq(mock.totalLPTokens(), lpTokens);
        assertEq(mock.balanceOf(lp), lpTokens);

        // Remove half of the liquidity
        uint256 lpToBurn = lpTokens / 2;
        (uint256 amount0Removed, uint256 amount1Removed) = mock.removeLiquidity(
            lp,
            lpToBurn
        );

        // Calculate expected token amounts
        uint256 expectedAmount0 = (AMOUNT0 * lpToBurn) / lpTokens;
        uint256 expectedAmount1 = (AMOUNT1 * lpToBurn) / lpTokens;

        // Verify removed amounts
        assertEq(amount0Removed, expectedAmount0);
        assertEq(amount1Removed, expectedAmount1);

        // Verify updated reserves
        assertEq(mock.reserve0(), AMOUNT0 - expectedAmount0);
        assertEq(mock.reserve1(), AMOUNT1 - expectedAmount1);

        // Verify updated LP tokens
        assertEq(mock.totalLPTokens(), lpTokens - lpToBurn);
        assertEq(mock.balanceOf(lp), lpTokens - lpToBurn);
    }

    // Comprehensive test for LP lifecycle with fees
    function test_lpTokensEarnFees() public {
        // Setup users
        address lp = address(0x1234);
        address trader = address(0x5678);

        // 1. Add initial liquidity
        uint256 lpTokens = mock.addLiquidity(lp, AMOUNT0, AMOUNT1);

        // Record initial state
        uint256 initialReserve0 = mock.reserve0();
        uint256 initialReserve1 = mock.reserve1();
        uint256 initialProduct = initialReserve0 * initialReserve1;

        // 2. Perform swaps to generate fees
        uint256 swapAmount = 0.1 ether;

        // Do multiple swaps in both directions
        for (uint i = 0; i < 3; i++) {
            // Swap token0 for token1
            mock.swap(trader, true, swapAmount);

            // Swap back - approximately the same value
            mock.swap(trader, false, (swapAmount * 3000) / 1000);
        }

        // 3. Check that reserves have grown due to fees
        uint256 finalReserve0 = mock.reserve0();
        uint256 finalReserve1 = mock.reserve1();
        uint256 finalProduct = finalReserve0 * finalReserve1;

        // The constant product should have increased due to fees
        assertTrue(
            finalProduct > initialProduct,
            "Fees should increase reserves"
        );

        // 4. When LP removes liquidity, they get a share of accumulated fees
        (uint256 amount0Removed, uint256 amount1Removed) = mock.removeLiquidity(
            lp,
            lpTokens
        );

        // The LP should get more tokens back than they put in, due to fees
        assertTrue(
            amount0Removed > initialReserve0 ||
                amount1Removed > initialReserve1,
            "LP should get a share of accumulated fees"
        );

        // Verify reserves are now zero
        assertEq(mock.reserve0(), 0);
        assertEq(mock.reserve1(), 0);
        assertEq(mock.totalLPTokens(), 0);
    }
}
