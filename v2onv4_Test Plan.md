# V2OnV4Hook Test Plan

## Overview
This test plan outlines comprehensive testing for the V2OnV4Hook contract, focusing on core functionality, security, and edge cases. The V2OnV4Hook is a critical component that bridges Uniswap V2's user-friendly features with V4's gas-optimized architecture. Our testing strategy ensures both functionality and security while maintaining optimal gas efficiency.

## Test Structure

### 1. Setup and Initialization Tests
**Purpose**: Verify the correct deployment and initialization of all core components.
**Why**: A proper setup is crucial for the entire system to function correctly. Any issues in initialization could lead to system-wide failures.
**Expected Outcome**: All components should be properly deployed with correct initial states.

```solidity
function test_setUp() public {
    // Verify PoolManager deployment
    assertTrue(address(manager) != address(0));
    
    // Verify Router deployments
    assertTrue(address(swapRouter) != address(0));
    assertTrue(address(modifyLiquidityRouter) != address(0));
    
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
```

### 2. Core Functionality Tests

#### 2.1 Liquidity Management
**Purpose**: Test the fundamental liquidity provision and removal mechanisms.
**Why**: These are the core operations that determine the pool's ability to facilitate trades and maintain proper token ratios.
**Expected Outcome**: 
- Liquidity addition should correctly mint LP tokens
- Liquidity removal should correctly burn LP tokens
- Token ratios should be maintained
- No funds should be lost during operations

```solidity
function test_addLiquidity() public {
    // Initial liquidity provision
    uint256 amount0 = 1 ether;
    uint256 amount1 = 3000 * 10**6; // 3000 USDC
    
    // Add liquidity
    modifyLiquidityRouter.modifyLiquidity{value: amount0}(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: int256(uint256(amount0)),
            salt: bytes32(0)
        }),
        ""
    );
    
    // Verify LP token minting
    assertEq(hook.totalLPTokens(), gasEfficientSqrt(amount0 * amount1));
    assertEq(hook.balanceOf(address(this)), gasEfficientSqrt(amount0 * amount1));
}

function test_removeLiquidity() public {
    // Add initial liquidity
    test_addLiquidity();
    
    uint256 initialLPBalance = hook.balanceOf(address(this));
    uint256 lpToRemove = initialLPBalance / 2;
    
    // Remove liquidity
    modifyLiquidityRouter.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -int256(lpToRemove),
            salt: bytes32(0)
        }),
        ""
    );
    
    // Verify LP token burning
    assertEq(hook.balanceOf(address(this)), initialLPBalance - lpToRemove);
    assertEq(hook.totalLPTokens(), initialLPBalance - lpToRemove);
}
```

#### 2.2 Swap Operations
**Purpose**: Verify the swap mechanism and fee compounding functionality.
**Why**: Swaps are the primary interaction point for users, and fee compounding is crucial for LP returns.
**Expected Outcome**:
- Swaps should execute at correct prices
- Fees should be properly calculated and compounded
- Slippage protection should work as expected
- No price manipulation should be possible

```solidity
function test_swap() public {
    // Setup initial liquidity
    test_addLiquidity();
    
    uint256 amountIn = 0.1 ether;
    uint256 preSwapBalance = token1.balanceOf(address(this));
    
    // Execute swap
    swapRouter.swap{value: amountIn}(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
    
    // Verify swap execution and fee compounding
    assertTrue(token1.balanceOf(address(this)) > preSwapBalance);
    assertTrue(hook.reserve0() > amountIn); // Verify fee compounding
}
```

### 3. Security Tests

#### 3.1 Reentrancy Protection
**Purpose**: Ensure the contract is protected against reentrancy attacks.
**Why**: Reentrancy attacks can lead to fund loss and system manipulation.
**Expected Outcome**: All reentrancy attempts should be blocked.

```solidity
function test_reentrancyProtection() public {
    // Deploy malicious contract attempting reentrancy
    MaliciousContract malicious = new MaliciousContract(address(hook));
    
    // Attempt reentrancy during swap
    vm.expectRevert("ReentrancyGuard: reentrant call");
    malicious.attemptReentrancy{value: 0.1 ether}(address(hook));
}
```

#### 3.2 Oracle Manipulation
**Purpose**: Test price manipulation protection mechanisms.
**Why**: Price manipulation can lead to incorrect swap execution and fund loss.
**Expected Outcome**: Large trades that could manipulate prices should be rejected.

```solidity
function test_oracleManipulation() public {
    // Setup initial liquidity
    test_addLiquidity();
    
    // Attempt large swap to manipulate price
    uint256 largeAmount = 100 ether;
    
    // Verify price impact limits
    vm.expectRevert("Price impact too high");
    swapRouter.swap{value: largeAmount}(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(largeAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
}
```

#### 3.3 Sandwich Attack Mitigation
**Purpose**: Verify protection against sandwich attacks.
**Why**: Sandwich attacks can lead to unfavorable execution prices and fund loss.
**Expected Outcome**: Users should receive at least the minimum expected output amount.

```solidity
function test_sandwichAttackMitigation() public {
    // Setup initial liquidity
    test_addLiquidity();
    
    // Simulate frontrun transaction
    address frontrunner = address(0x1);
    vm.deal(frontrunner, 1 ether);
    vm.prank(frontrunner);
    
    // Attempt frontrun
    swapRouter.swap{value: 0.1 ether}(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(0.1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
    
    // Verify slippage protection
    uint256 minAmountOut = calculateMinAmountOut(0.1 ether);
    assertTrue(token1.balanceOf(address(this)) >= minAmountOut);
}
```

### 4. Edge Cases

#### 4.1 Extreme Price Movements
**Purpose**: Test system behavior under extreme market conditions.
**Why**: Extreme price movements can lead to system instability and fund loss.
**Expected Outcome**: System should have circuit breakers to prevent extreme price movements.

```solidity
function test_extremePriceMovements() public {
    // Setup initial liquidity
    test_addLiquidity();
    
    // Simulate extreme price movement
    uint256 largeSwap = 50 ether;
    
    // Verify circuit breakers
    vm.expectRevert("Circuit breaker triggered");
    swapRouter.swap{value: largeSwap}(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(largeSwap),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
}
```

#### 4.2 Zero Liquidity Scenarios
**Purpose**: Test system behavior when no liquidity is available.
**Why**: Zero liquidity scenarios can lead to failed transactions and poor user experience.
**Expected Outcome**: System should gracefully handle zero liquidity situations.

```solidity
function test_zeroLiquidityScenarios() public {
    // Attempt swap with zero liquidity
    vm.expectRevert("Insufficient liquidity");
    swapRouter.swap{value: 0.1 ether}(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(0.1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
}
```

### 5. Gas Optimization Tests
**Purpose**: Verify gas efficiency of core operations.
**Why**: Gas costs directly impact user experience and protocol competitiveness.
**Expected Outcome**: All operations should stay within acceptable gas limits.

```solidity
function test_gasOptimization() public {
    // Setup initial liquidity
    test_addLiquidity();
    
    // Measure gas for swap operation
    uint256 gasStart = gasleft();
    test_swap();
    uint256 gasUsed = gasStart - gasleft();
    
    // Verify gas usage is within acceptable range
    assertTrue(gasUsed < 150000); // Adjust threshold as needed
}
```

## Test Setup Requirements

1. Deploy mock tokens (ERC20)
2. Deploy PoolManager
3. Deploy V2OnV4Hook
4. Deploy Router contracts
5. Initialize pool with hook
6. Mint initial tokens to test contract
7. Approve tokens for router contracts

## Test Environment

- Foundry testing framework
- Anvil for local Ethereum node
- Mock tokens for testing
- Gas reporting enabled
- Coverage reporting enabled

## Running Tests

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/V2OnV4Hook.t.sol

# Run with gas reporting
forge test --gas-report

# Run with coverage
forge coverage
```

## Expected Results

1. All core functionality tests should pass
2. Security tests should demonstrate proper protection mechanisms
3. Edge cases should be handled gracefully
4. Gas usage should be optimized
5. No funds should be lost in any scenario

## Notes

- All tests should be run with different token pairs
- Test with various fee tiers
- Include fuzzing tests for amount variations
- Test with different price ranges
- Verify all events are emitted correctly 