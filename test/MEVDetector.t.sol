// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MEVDetector} from "../src/MEVDetector.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract MEVDetectorTest is Test {
    MEVDetector public detector;
    
    address public governance = address(0x1);
    address public hook = address(0x2);
    address public oracleRelayer = address(0x3);

    PoolKey public testKey;
    bytes32 public poolId;

    event JITConfirmed(bytes32 indexed poolId, address indexed lp, bool isAtomic);

    function setUp() public {
        detector = new MEVDetector(governance, hook, oracleRelayer);

        testKey = PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        poolId = PoolId.unwrap(testKey.toId());
    }

    function test_PriorityFeeAnomalySignal() public {
        vm.startPrank(hook);

        // Baseline avg set to 10 gwei
        vm.stopPrank();
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei);

        vm.startPrank(hook);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // 1. Priority fee = 15 gwei <= 2 * 10 gwei (20 gwei) -> 0 pts
        vm.txGasPrice(25 gwei);
        vm.fee(10 gwei); // Priority fee = 15 gwei
        uint256 scoreNormal = detector.scoreSwap(testKey, params, address(this), "");
        assertEq(scoreNormal, 0, "Normal priority fee should add 0 points");

        // 2. Priority fee = 25 gwei > 20 gwei -> +25 pts
        vm.txGasPrice(35 gwei);
        vm.fee(10 gwei); // Priority fee = 25 gwei
        uint256 scoreAnomaly = detector.scoreSwap(testKey, params, address(this), "");
        assertEq(scoreAnomaly, 25, "Priority fee anomaly should add 25 points");

        vm.stopPrank();
    }

    function test_PriorityFeeBoundary() public {
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei); // Threshold = 20 gwei

        vm.startPrank(hook);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // Priority fee exactly 20 gwei (<= 20 gwei) -> 0 pts (> operator test)
        vm.txGasPrice(30 gwei);
        vm.fee(10 gwei); // Priority fee = 20 gwei
        assertEq(detector.scoreSwap(testKey, params, address(this), ""), 0, "Exact threshold should be 0 pts");

        // Priority fee 20 gwei + 1 wei (> 20 gwei) -> 25 pts
        vm.txGasPrice(30 gwei + 1);
        vm.fee(10 gwei); // Priority fee = 20 gwei + 1 wei
        assertEq(detector.scoreSwap(testKey, params, address(this), ""), 25, "Above threshold should be 25 pts");

        vm.stopPrank();
    }

    function test_ReversalSignal_SameBlock() public {
        vm.startPrank(hook);

        SwapParams memory params0For1 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory params1For0 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // Swap 1: zeroForOne = true
        uint256 score1 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score1, 0, "First swap should have no reversal score");

        // Swap 2: zeroForOne = false (same block, opposite direction) -> +30 pts
        uint256 score2 = detector.scoreSwap(testKey, params1For0, address(this), "");
        assertEq(score2, 30, "Reversal swap should add 30 points");

        vm.stopPrank();
    }

    function test_ReversalSignal_CrossBlock_Inclusive() public {
        vm.startPrank(hook);

        SwapParams memory params0For1 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory params1For0 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        uint256 score1 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score1, 0);

        // Advance to exactly reversalWindowBlocks
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.reversalWindowBlocks());

        uint256 score2 = detector.scoreSwap(testKey, params1For0, address(this), "");
        assertEq(score2, 30, "Reversal swap on boundary block should add 30 points");

        vm.stopPrank();
    }

    function test_ReversalSignal_CrossBlock_Exclusive() public {
        vm.startPrank(hook);

        SwapParams memory params0For1 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory params1For0 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        uint256 score1 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score1, 0);

        // Advance to reversalWindowBlocks + 1
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.reversalWindowBlocks() + 1);

        uint256 score2 = detector.scoreSwap(testKey, params1For0, address(this), "");
        assertEq(score2, 0, "Reversal swap past boundary block should not add points");

        vm.stopPrank();
    }

    function test_ReversalSignal_SameDirection_NoReversal() public {
        vm.startPrank(hook);

        SwapParams memory params0For1 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // Swap 1: zeroForOne = true
        uint256 score1 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score1, 0);

        // Swap 2: zeroForOne = true (same direction) -> 0 pts
        vm.roll(block.number + 5);
        uint256 score2 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score2, 0, "Same direction swap in window should add 0 points");

        vm.stopPrank();
    }

    function test_ReversalSignal_DifferentPools_NoReversal() public {
        vm.startPrank(hook);

        SwapParams memory params0For1 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory params1For0 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        uint256 score1 = detector.scoreSwap(testKey, params0For1, address(this), "");
        assertEq(score1, 0);

        // Create second pool key
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0x300)),
            currency1: Currency.wrap(address(0x400)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        uint256 score2 = detector.scoreSwap(key2, params1For0, address(this), "");
        assertEq(score2, 0, "Swap in different pool should not trigger reversal");

        vm.stopPrank();
    }

    function test_LargePriceImpactSignal() public {
        vm.startPrank(hook);

        // Default threshold is 10 ether
        SwapParams memory paramsNormal = SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: 0});
        SwapParams memory paramsLarge = SwapParams({zeroForOne: true, amountSpecified: -15 ether, sqrtPriceLimitX96: 0});

        assertEq(detector.scoreSwap(testKey, paramsNormal, address(this), ""), 0, "Normal amount should add 0 pts");
        assertEq(detector.scoreSwap(testKey, paramsLarge, address(this), ""), 20, "Large price impact should add 20 pts");

        vm.stopPrank();
    }

    function test_PriceImpactBoundary() public {
        vm.prank(governance);
        detector.setPriceImpactThreshold(poolId, 10 ether);

        vm.startPrank(hook);

        // Exact threshold (-10 ether) -> 0 pts (> operator test)
        SwapParams memory paramsExact = SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: 0});
        assertEq(detector.scoreSwap(testKey, paramsExact, address(this), ""), 0, "Exact impact threshold should add 0 pts");

        // 1 wei above (-10 ether - 1 wei) -> 20 pts
        SwapParams memory paramsAbove = SwapParams({zeroForOne: true, amountSpecified: -10 ether - 1, sqrtPriceLimitX96: 0});
        assertEq(detector.scoreSwap(testKey, paramsAbove, address(this), ""), 20, "Above impact threshold should add 20 pts");

        vm.stopPrank();
    }

    function test_JITSignal_SameBlock() public {
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(hook);

        // 1. Swap without prior addLiquidity -> 0 pts
        assertEq(detector.scoreSwap(testKey, swapParams, address(this), ""), 0);

        // 2. Call onBeforeAddLiquidity then swap in same block -> +40 pts
        detector.onBeforeAddLiquidity(testKey, modParams, address(this), "");
        vm.stopPrank();
        
        vm.prank(hook, address(0x123));
        assertEq(detector.scoreSwap(testKey, swapParams, address(0x123), ""), 40, "JIT pattern should add 40 pts");
    }

    function test_JITSignal_CrossBlock_Inclusive() public {
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, modParams, address(this), "");

        // Advance to exactly jitWindowBlocks
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.jitWindowBlocks());
        vm.stopPrank();

        vm.prank(hook, address(0x123));
        assertEq(detector.scoreSwap(testKey, swapParams, address(0x123), ""), 40, "JIT pattern on boundary block should add 40 pts");
    }

    function test_JITSignal_CrossBlock_Exclusive() public {
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, modParams, address(this), "");

        // Advance to jitWindowBlocks + 1
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.jitWindowBlocks() + 1);
        vm.stopPrank();

        vm.prank(hook, address(0x123));
        assertEq(detector.scoreSwap(testKey, swapParams, address(0x123), ""), 0, "JIT pattern past boundary block should not add points");
    }

    function test_JITSignal_DifferentPools_NoJIT() public {
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, modParams, address(this), "");

        // Create second pool key
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0x300)),
            currency1: Currency.wrap(address(0x400)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        assertEq(detector.scoreSwap(key2, swapParams, address(this), ""), 0, "JIT in different pool should not trigger score");
        vm.stopPrank();
    }

    function test_ScoreAggregationAndCap() public {
        // Trigger all 4 signals:
        // Priority fee (+25)
        // Reversal (+30)
        // Price impact (+20)
        // JIT (+40)
        // Sum = 115 -> capped at 100

        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei);

        vm.startPrank(hook);

        // Seed reversal state (swap 1: zeroForOne = false)
        SwapParams memory params1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.stopPrank();
        vm.prank(hook, address(0x123));
        detector.scoreSwap(testKey, params1, address(0x123), "");

        // Set JIT flag
        vm.prank(hook);
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        detector.onBeforeAddLiquidity(testKey, modParams, address(this), "");

        // Set high gas price for priority fee anomaly
        vm.txGasPrice(35 gwei);
        vm.fee(10 gwei); // Priority fee = 25 gwei > 20 gwei (+25)

        // Attack swap: zeroForOne = true (opposite to swap 1 -> +30), amount = -15 ether (> 10 ether -> +20), JIT flag active (+40)
        SwapParams memory attackParams = SwapParams({zeroForOne: true, amountSpecified: -15 ether, sqrtPriceLimitX96: 0});

        vm.prank(hook, address(0x123));
        uint256 finalScore = detector.scoreSwap(testKey, attackParams, address(0x123), "");
        assertEq(finalScore, 100, "Aggregated score 115 should cap at 100");
    }

    function test_JITConfirmation_CrossTx() public {
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // 1. LP Alice adds liquidity
        vm.prank(hook, address(0xAA));
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // Simulate transition to new transaction by clearing transient storage
        detector.clearTransientState();

        // 2. Swapper Bob swaps (Alice's position is JIT candidate)
        vm.prank(hook, address(0xBB));
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");

        // Simulate transition to new transaction by clearing transient storage
        detector.clearTransientState();

        // 3. LP Alice removes liquidity (JIT Confirmed)
        vm.prank(hook, address(0xAA));
        vm.expectEmit(true, true, false, true);
        emit JITConfirmed(poolId, address(0xAA), false);
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));
    }

    function test_JITConfirmation_Atomic() public {
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // Atomic JIT: Alice adds, Bob swaps, Alice removes in SAME tx
        vm.startPrank(hook, address(0xAA));
        
        // 1. ADD
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // 2. SWAP (by Bob)
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");

        // 3. REMOVE
        vm.expectEmit(true, true, false, true);
        emit JITConfirmed(poolId, address(0xAA), true);
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));
        
        vm.stopPrank();
    }
}
