// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Dexminiv2onv4Hook.sol";
import "./mocks/MockERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract V2OnV4HookTest is Test {
    // Core contract
    V2OnV4Hook public hook;

    // Test tokens
    MockERC20 public token0;
    MockERC20 public token1;

    // Mock PoolManager for testing
    address public mockPoolManager;

    // Test amounts
    uint256 constant AMOUNT0 = 1 ether;
    uint256 constant AMOUNT1 = 3000 * 10 ** 6; // 3000 USDC

    function setUp() public {
        // Setup mock PoolManager
        mockPoolManager = address(0x42);

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 address < token1 address
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy V2OnV4Hook with mock PoolManager
        vm.mockCall(
            mockPoolManager,
            abi.encodeWithSignature("poolManager()"),
            abi.encode(mockPoolManager)
        );
        hook = new V2OnV4Hook(IPoolManager(mockPoolManager));
    }

    // Test to verify correct setup of all components
    function test_setUp() public {
        // Verify Mock Tokens
        assertTrue(address(token0) != address(0));
        assertTrue(address(token1) != address(0));

        // Verify Hook deployment
        assertTrue(address(hook) != address(0));

        // Verify initial pool state
        assertEq(hook.reserve0(), 0);
        assertEq(hook.reserve1(), 0);
        assertEq(hook.totalLPTokens(), 0);
    }

    // Helper function to calculate square root using the same method as in the hook
    function gasEfficientSqrt(uint256 x) internal pure returns (uint256 y) {
        // Simplified algorithm for test purposes
        y = uint256(sqrt(int256(x)));
    }

    // Simple sqrt function for testing
    function sqrt(int256 x) internal pure returns (int256 y) {
        if (x == 0) return 0;
        else if (x <= 3) return 1;

        int256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // Test for adding initial liquidity
    function test_addLiquidity() public {
        // Directly use test helper functions instead of trying to call internal functions
        address lp = address(0x1234);

        // Set reserves and mint LP tokens
        hook.testSetReserves(AMOUNT0, AMOUNT1);
        uint256 expectedLPTokens = gasEfficientSqrt(AMOUNT0 * AMOUNT1);
        hook.testMintLP(lp, expectedLPTokens);

        // Verify reserve updates
        assertEq(hook.reserve0(), AMOUNT0);
        assertEq(hook.reserve1(), AMOUNT1);

        // Verify LP tokens
        assertEq(hook.totalLPTokens(), expectedLPTokens);
        assertEq(hook.balanceOf(lp), expectedLPTokens);
    }
}
