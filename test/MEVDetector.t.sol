// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {MEVDetector} from "../src/MEVDetector.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract MEVDetectorTest is Test {
    MEVDetector public detector;

    address public governance   = address(0x1);
    address public hook         = address(0x2);
    address public oracleRelayer = address(0x3);

    PoolKey   public testKey;
    bytes32   public poolId;

    // Shared params reused across tests
    ModifyLiquidityParams internal addParams =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

    SwapParams internal swapParams =
        SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

    event JITConfirmed(bytes32 indexed poolId, address indexed lp, bool isAtomic);

    // ─── setUp ───────────────────────────────────────────────────────
    function setUp() public {
        detector = new MEVDetector(governance, hook, oracleRelayer);

        testKey = PoolKey({
            currency0:   Currency.wrap(address(0x100)),
            currency1:   Currency.wrap(address(0x200)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });

        poolId = PoolId.unwrap(testKey.toId());
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   PRIORITY FEE ANOMALY (+25)
    // ═══════════════════════════════════════════════════════════════════

    function test_PriorityFeeAnomalySignal() public {
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei);

        vm.startPrank(hook);

        // Priority fee 15 gwei <= 2 * 10 gwei (20 gwei) → 0 pts
        vm.txGasPrice(25 gwei);
        vm.fee(10 gwei);
        assertEq(detector.scoreSwap(testKey, swapParams, address(this), ""), 0,
            "Normal priority fee should add 0 pts");

        // Priority fee 25 gwei > 20 gwei → +25 pts
        vm.txGasPrice(35 gwei);
        vm.fee(10 gwei);
        assertEq(detector.scoreSwap(testKey, swapParams, address(this), ""), 25,
            "Priority fee anomaly should add 25 pts");

        vm.stopPrank();
    }

    function test_PriorityFeeBoundary() public {
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei); // threshold = 20 gwei

        vm.startPrank(hook);

        // Exactly 20 gwei → 0 pts (> operator, not >=)
        vm.txGasPrice(30 gwei);
        vm.fee(10 gwei);
        assertEq(detector.scoreSwap(testKey, swapParams, address(this), ""), 0,
            "Exact threshold should be 0 pts");

        // 20 gwei + 1 wei → 25 pts
        vm.txGasPrice(30 gwei + 1);
        vm.fee(10 gwei);
        assertEq(detector.scoreSwap(testKey, swapParams, address(this), ""), 25,
            "Above threshold should be 25 pts");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   REVERSAL PATTERN (+30)
    // ═══════════════════════════════════════════════════════════════════

    function test_ReversalSignal_SameBlock() public {
        vm.startPrank(hook);
        SwapParams memory p0 = SwapParams({zeroForOne: true,  amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory p1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        assertEq(detector.scoreSwap(testKey, p0, address(this), ""), 0,
            "First swap should have no reversal score");
        assertEq(detector.scoreSwap(testKey, p1, address(this), ""), 30,
            "Reversal swap should add 30 pts");
        vm.stopPrank();
    }

    function test_ReversalSignal_CrossBlock_Inclusive() public {
        vm.startPrank(hook);
        SwapParams memory p0 = SwapParams({zeroForOne: true,  amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory p1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        detector.scoreSwap(testKey, p0, address(this), "");
        vm.roll(block.number + detector.reversalWindowBlocks());
        assertEq(detector.scoreSwap(testKey, p1, address(this), ""), 30,
            "Reversal on boundary block should add 30 pts");
        vm.stopPrank();
    }

    function test_ReversalSignal_CrossBlock_Exclusive() public {
        vm.startPrank(hook);
        SwapParams memory p0 = SwapParams({zeroForOne: true,  amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory p1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        detector.scoreSwap(testKey, p0, address(this), "");
        vm.roll(block.number + detector.reversalWindowBlocks() + 1);
        assertEq(detector.scoreSwap(testKey, p1, address(this), ""), 0,
            "Reversal past boundary block should add 0 pts");
        vm.stopPrank();
    }

    function test_ReversalSignal_SameDirection_NoReversal() public {
        vm.startPrank(hook);
        SwapParams memory p0 = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        detector.scoreSwap(testKey, p0, address(this), "");
        vm.roll(block.number + 5);
        assertEq(detector.scoreSwap(testKey, p0, address(this), ""), 0,
            "Same direction swap should add 0 pts");
        vm.stopPrank();
    }

    function test_ReversalSignal_DifferentPools_NoReversal() public {
        vm.startPrank(hook);
        SwapParams memory p0 = SwapParams({zeroForOne: true,  amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        SwapParams memory p1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        detector.scoreSwap(testKey, p0, address(this), "");

        PoolKey memory key2 = PoolKey({
            currency0:   Currency.wrap(address(0x300)),
            currency1:   Currency.wrap(address(0x400)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });
        assertEq(detector.scoreSwap(key2, p1, address(this), ""), 0,
            "Reversal in different pool should add 0 pts");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   LARGE PRICE IMPACT (+20)
    // ═══════════════════════════════════════════════════════════════════

    function test_LargePriceImpactSignal() public {
        vm.startPrank(hook);
        SwapParams memory pNorm  = SwapParams({zeroForOne: true, amountSpecified: -5 ether,  sqrtPriceLimitX96: 0});
        SwapParams memory pLarge = SwapParams({zeroForOne: true, amountSpecified: -15 ether, sqrtPriceLimitX96: 0});

        assertEq(detector.scoreSwap(testKey, pNorm,  address(this), ""), 0,  "Normal amount 0 pts");
        assertEq(detector.scoreSwap(testKey, pLarge, address(this), ""), 20, "Large impact +20 pts");
        vm.stopPrank();
    }

    function test_PriceImpactBoundary() public {
        vm.prank(governance);
        detector.setPriceImpactThreshold(poolId, 10 ether);

        vm.startPrank(hook);

        SwapParams memory pExact = SwapParams({zeroForOne: true, amountSpecified: -10 ether,     sqrtPriceLimitX96: 0});
        SwapParams memory pAbove = SwapParams({zeroForOne: true, amountSpecified: -10 ether - 1, sqrtPriceLimitX96: 0});

        assertEq(detector.scoreSwap(testKey, pExact, address(this), ""), 0,  "Exact threshold 0 pts");
        assertEq(detector.scoreSwap(testKey, pAbove, address(this), ""), 20, "Above threshold +20 pts");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   SCORE AGGREGATION & CAP
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Signal aggregation: priority fee (+25) + reversal (+30) + price impact (+20) = 75.
    function test_ScoreAggregationAndCap() public {
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei);

        // Seed reversal state (swap 1: zeroForOne = false)
        SwapParams memory params1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(hook, address(0x123));
        detector.scoreSwap(testKey, params1, address(0x123), "");

        // High gas for priority fee anomaly
        vm.txGasPrice(35 gwei);
        vm.fee(10 gwei); // priority fee = 25 gwei > 20 gwei → +25

        // Attack swap: opposite direction (+30), large amount (+20)
        SwapParams memory attackParams = SwapParams({zeroForOne: true, amountSpecified: -15 ether, sqrtPriceLimitX96: 0});
        vm.prank(hook, address(0x123));
        uint256 finalScore = detector.scoreSwap(testKey, attackParams, address(0x123), "");
        assertEq(finalScore, 75, "Aggregated score should be 25 + 30 + 20 = 75");
    }
}

