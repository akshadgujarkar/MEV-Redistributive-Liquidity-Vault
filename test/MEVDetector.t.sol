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
    //           LIQUIDITY MATURATION — hasImmatureLiquidity()
    // ═══════════════════════════════════════════════════════════════════
    // liquidityMaturityBlocks = 5 (default)
    // MATURE when: block.number >= addedBlock + 5
    //   added=100 → immature: 100-104, mature: 105+

    function test_hasImmatureLiquidity_NoLP_ReturnsFalse() public view {
        // No LP has ever added to this pool
        assertFalse(detector.hasImmatureLiquidity(poolId),
            "Empty pool should not be immature");
    }

    function test_hasImmatureLiquidity_True_Block1AfterAdd() public {
        // Add at block 100
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // Check at block 101 — immature
        vm.roll(101);
        assertTrue(detector.hasImmatureLiquidity(poolId),
            "Block 101 (1 after add) should be immature");
    }

    function test_hasImmatureLiquidity_True_Block4AfterAdd() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // Block 104 = addedBlock + 4 → still immature
        vm.roll(104);
        assertTrue(detector.hasImmatureLiquidity(poolId),
            "Block 104 (4 after add) should be immature");
    }

    function test_hasImmatureLiquidity_False_AtMaturity() public {
        // Maturity boundary: block 105 = addedBlock(100) + maturityBlocks(5)
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        vm.roll(105);
        assertFalse(detector.hasImmatureLiquidity(poolId),
            "Block 105 (addedBlock + maturityBlocks) should be MATURE");
    }

    function test_hasImmatureLiquidity_False_AfterMaturity() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        vm.roll(115);
        assertFalse(detector.hasImmatureLiquidity(poolId),
            "Block 115 is well past maturity");
    }

    // ═══════════════════════════════════════════════════════════════════
    //              JIT SUSPICION SCORING — _checkJITSuspicion()
    // ═══════════════════════════════════════════════════════════════════
    //
    // JIT_POINTS (+40) require: mature AND within jitWindowBlocks (10).
    // Immature positions must NOT score +40.

    /// @notice Test 1 — immediate swap after add: no JIT points (immature)
    function test_ImmatureLiquidity_NoJITScore_Block1() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // swap at block 101 — LP is immature → 0 JIT pts
        vm.roll(101);
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        assertEq(score, 0, "Immature LP (block+1) must not trigger JIT score");
    }

    /// @notice Test 2 — swap before maturity (block +3): no JIT points
    function test_ImmatureLiquidity_NoJITScore_Block3() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        vm.roll(103);
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        assertEq(score, 0, "Immature LP (block+3) must not trigger JIT score");
    }

    /// @notice Test 3 — swap at exact maturity boundary (+5 blocks): JIT score fires
    function test_MatureLiquidity_JITScore_AtExactBoundary() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // Block 105 = addedBlock(100) + maturityBlocks(5) — first MATURE block
        vm.roll(105);
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        assertEq(score, 40, "Mature LP at exact boundary should score +40 JIT pts");
    }

    /// @notice Test 4 — swap 7 blocks after add (mature, within jitWindow): JIT score fires
    function test_MatureLiquidity_JITScore_AfterBoundary() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        vm.roll(107);
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        assertEq(score, 40, "Mature LP within jitWindow should score +40 JIT pts");
    }

    /// @notice Old test preserved — same-block swap after add must now score 0 (not 40)
    ///         because the LP is immature (age = 0 < maturityBlocks = 5).
    function test_JITSignal_SameBlock_NoScore_WhenImmature() public {
        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(this), "");
        vm.stopPrank();

        vm.prank(hook, address(0x123));
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0x123), "");
        assertEq(score, 0,
            "Same-block swap after add is immature (age<maturity) -> must score 0 (no false-positive JIT)");
    }

    /// @notice JIT window boundary — liquidity added at block N, swap at N+jitWindow
    ///         (still inside window): should score 40 when mature.
    ///         jitWindowBlocks = 10, maturityBlocks = 5 → add at 0, swap at 10 → age=10,
    ///         mature(>=5) and within window(<=10) → 40 pts.
    function test_JITSignal_CrossBlock_Inclusive() public {
        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(this), "");
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.jitWindowBlocks());
        vm.stopPrank();

        vm.prank(hook, address(0x123));
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0x123), "");
        assertEq(score, 40, "JIT on boundary block (mature + in-window) should add 40 pts");
    }

    /// @notice Past jitWindow: no JIT score regardless of maturity.
    function test_JITSignal_CrossBlock_Exclusive() public {
        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(this), "");
        uint256 startBlock = block.number;
        vm.roll(startBlock + detector.jitWindowBlocks() + 1);
        vm.stopPrank();

        vm.prank(hook, address(0x123));
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0x123), "");
        assertEq(score, 0, "Past jitWindow should add 0 JIT pts");
    }

    function test_JITSignal_DifferentPools_NoJIT() public {
        vm.startPrank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(this), "");

        PoolKey memory key2 = PoolKey({
            currency0:   Currency.wrap(address(0x300)),
            currency1:   Currency.wrap(address(0x400)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });
        assertEq(detector.scoreSwap(key2, swapParams, address(this), ""), 0,
            "JIT from different pool should not trigger score");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   SCORE AGGREGATION & CAP
    // ═══════════════════════════════════════════════════════════════════

    /// @notice All 4 signals: priority fee (+25) + reversal (+30) + price impact (+20)
    ///         + JIT (+40) = 115 → capped at 100.
    ///         For JIT to fire the LP must be MATURE, so we roll past maturityBlocks(5)
    ///         but stay within jitWindowBlocks(10).
    function test_ScoreAggregationAndCap() public {
        vm.prank(oracleRelayer);
        detector.setRollingPriorityFeeAvg(poolId, 10 gwei);

        // Seed reversal state (swap 1: zeroForOne = false)
        SwapParams memory params1 = SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(hook, address(0x123));
        detector.scoreSwap(testKey, params1, address(0x123), "");

        // Add LP at current block
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(this), "");

        // Advance past maturity (5 blocks) but within jitWindow (10)
        vm.roll(block.number + 7);

        // High gas for priority fee anomaly
        vm.txGasPrice(35 gwei);
        vm.fee(10 gwei); // priority fee = 25 gwei > 20 gwei → +25

        // Attack swap: opposite direction (+30), large amount (+20), JIT mature (+40)
        SwapParams memory attackParams = SwapParams({zeroForOne: true, amountSpecified: -15 ether, sqrtPriceLimitX96: 0});
        vm.prank(hook, address(0x123));
        uint256 finalScore = detector.scoreSwap(testKey, attackParams, address(0x123), "");
        assertEq(finalScore, 100, "Aggregated score 115 should be capped at 100");
    }

    // ═══════════════════════════════════════════════════════════════════
    //               JIT CONFIRMATION — onBeforeRemoveLiquidity()
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test 6 — Immature LP removes liquidity: no JIT confirmation.
    ///         Alice adds at block 100, removes at block 101 (immature).
    ///         No swap occurred at all. Expect no JITConfirmed.
    function test_ImmatureRemoval_NoFalseJITConfirm() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        vm.roll(101);
        // No JITConfirmed event should be emitted
        vm.recordLogs();
        vm.prank(hook);
        detector.onBeforeRemoveLiquidity(testKey, addParams, address(0xAA));

        // Check no JITConfirmed log was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 jitSig = keccak256("JITConfirmed(bytes32,address,bool)");
            assertFalse(logs[i].topics[0] == jitSig,
                "Immature removal must not emit JITConfirmed");
        }
    }

    /// @notice Cross-tx JIT with swap while LP was immature — no confirmation.
    ///         Alice adds at block 100. Bob swaps at block 101 (LP immature).
    ///         Alice removes at block 102. Expect NO JITConfirmed because the
    ///         swap occurred before maturity.
    function test_CrossTxJIT_SwapDuringImmature_NoConfirm() public {
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});

        vm.roll(100);
        vm.prank(hook, address(0xAA));
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");
        detector.clearTransientState();

        // Bob swaps at block 101 — Alice's LP is immature (age=1 < maturity=5)
        vm.roll(101);
        vm.prank(hook, address(0xBB));
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        detector.clearTransientState();

        // Alice removes at block 102
        vm.roll(102);
        vm.recordLogs();
        vm.prank(hook, address(0xAA));
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));

        // Must NOT emit JITConfirmed — swap was during immature period
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 jitSig = keccak256("JITConfirmed(bytes32,address,bool)");
            assertFalse(logs[i].topics[0] == jitSig,
                "Swap during immature period must not confirm JIT");
        }
    }

    /// @notice Test 7 — Mature JIT: add → mature → swap → remove → JITConfirmed.
    ///         Alice adds at block 100. Block 105 = maturity. Swap at 105.
    ///         Alice removes at 106. Expect JITConfirmed(false).
    function test_MatureJIT_AddSwapRemove_Confirmed() public {
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});

        // Alice adds at block 100
        vm.roll(100);
        vm.prank(hook, address(0xAA));
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");
        detector.clearTransientState();

        // Bob swaps at block 105 (maturity boundary — LP is now mature)
        vm.roll(105);
        vm.prank(hook, address(0xBB));
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        detector.clearTransientState();

        // Alice removes at block 106 (within jitWindowBlocks=10 of addedBlock=100)
        vm.roll(106);
        vm.expectEmit(true, true, false, true);
        emit JITConfirmed(poolId, address(0xAA), false);
        vm.prank(hook, address(0xAA));
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));
    }

    /// @notice Old cross-tx JIT test updated: swap must occur after maturity for
    ///         JITConfirmed to be emitted.
    function test_JITConfirmation_CrossTx() public {
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});

        // 1. Alice adds at block 0 (default)
        vm.prank(hook, address(0xAA));
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");
        detector.clearTransientState();

        // Roll past maturity (5 blocks) so the swap is against mature liquidity
        vm.roll(block.number + detector.liquidityMaturityBlocks());

        // 2. Bob swaps (Alice's position is now mature → JIT candidate)
        vm.prank(hook, address(0xBB));
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");
        detector.clearTransientState();

        // 3. Alice removes (within jitWindow) → JITConfirmed
        vm.expectEmit(true, true, false, true);
        emit JITConfirmed(poolId, address(0xAA), false);
        vm.prank(hook, address(0xAA));
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));
    }

    /// @notice Atomic JIT: add + swap + remove in same tx → JITConfirmed(isAtomic=true).
    ///         Atomic path bypasses the maturation check.
    function test_JITConfirmation_Atomic() public {
        ModifyLiquidityParams memory removeParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});

        vm.startPrank(hook, address(0xAA));

        // 1. ADD
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // 2. SWAP (by Bob in same tx)
        detector.scoreSwap(testKey, swapParams, address(0xBB), "");

        // 3. REMOVE (Alice removes in same tx) → atomic JIT
        vm.expectEmit(true, true, false, true);
        emit JITConfirmed(poolId, address(0xAA), true);
        detector.onBeforeRemoveLiquidity(testKey, removeParams, address(0xAA));

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //              TEST 5 & 8 — MULTIPLE LPs, INDEPENDENT MATURITY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Test 5 — existing mature LP + new immature LP.
    ///         Alice adds at block 50 (mature by block 55).
    ///         Bob adds at block 100 (matures at block 105).
    ///         Charlie swaps at block 103: Bob's LP (latest) is still immature.
    ///         hasImmatureLiquidity returns true (Bob's position blocks the gate).
    ///         JIT scoring: lastPoolLP = Bob; age=3 < maturity=5 → 0 JIT pts.
    function test_MultipleLP_IndependentMaturity() public {
        // Alice adds at block 50
        vm.roll(50);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // Bob adds at block 100 (overwrites lastPoolLP)
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xBB), "");

        // At block 103: Bob's LP age = 3 < maturityBlocks(5) → immature gate is ON
        vm.roll(103);
        assertTrue(detector.hasImmatureLiquidity(poolId),
            "Bob's LP is immature at block 103 (age=3 < maturity=5) -> gate should be true");

        // JIT score for Charlie's swap: Bob is immature → 0 pts
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xCC), "");
        assertEq(score, 0,
            "Bob's immature LP must not produce JIT score for Charlie's swap");

        // At block 105: Bob's LP matures → gate is OFF
        vm.roll(105);
        assertFalse(detector.hasImmatureLiquidity(poolId),
            "Bob's LP is mature at block 105 (age=5 >= maturity=5) -> gate should be false");
    }

    /// @notice Verify that JIT scoring uses lastPoolLP[poolId] — swapper is the LP,
    ///         so lp == trader and JIT score is 0.
    function test_JITSuspicion_LPIsSwapper_NoScore() public {
        vm.roll(100);
        vm.prank(hook);
        detector.onBeforeAddLiquidity(testKey, addParams, address(0xAA), "");

        // LP is also the swapper → lp == trader → no JIT score
        vm.roll(107); // past maturity
        vm.prank(hook);
        uint256 score = detector.scoreSwap(testKey, swapParams, address(0xAA), "");
        assertEq(score, 0, "LP swapping their own position must not self-score JIT");
    }
}
