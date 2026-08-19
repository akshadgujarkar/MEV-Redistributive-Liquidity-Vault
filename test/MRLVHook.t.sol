// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {MRLVHook} from "../src/MRLVHook.sol";
import {MEVDetector} from "../src/MEVDetector.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {AnalyticsEmitter} from "../src/AnalyticsEmitter.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

contract MRLVHookTest is Test {
    MRLVHook public hook;
    MEVDetector public detector;
    DynamicFeeManager public feeManager;
    AnalyticsEmitter public analytics;

    address public governance = address(0xBEEF);
    address public oracleRelayer = address(0xCEEF);
    address public poolManagerAddr = address(0x1234);
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        // Mine a valid hook address using HookMiner
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        // Deploy helper contracts with a temporary hook placeholder
        // (will be replaced with the mined address)
        detector = new MEVDetector(governance, address(this), oracleRelayer);
        feeManager = new DynamicFeeManager(governance, address(this));
        analytics = new AnalyticsEmitter(governance);

        // Mine CREATE2 salt for hook deployment
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            detector,
            feeManager,
            analytics,
            governance
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(MRLVHook).creationCode,
            constructorArgs
        );

        // Deploy hook at the mined address
        hook = new MRLVHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            detector,
            feeManager,
            analytics,
            governance
        );
        require(address(hook) == hookAddr, "Hook address mismatch");

        // Update detector and feeManager to point to the actual hook address
        vm.startPrank(governance);
        detector.setHook(address(hook));
        feeManager.setHook(address(hook));
        analytics.setHook(address(hook));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  onlyPoolManager ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_beforeInitialize_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(unauthorized, key, 0);
    }

    function test_afterInitialize_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(unauthorized, key, 0, 0);
    }

    function test_beforeSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(unauthorized, key, params, "");
    }

    function test_afterSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        BalanceDelta delta;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(unauthorized, key, params, delta, "");
    }

    function test_beforeAddLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(unauthorized, key, params, "");
    }

    function test_afterAddLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        BalanceDelta delta;
        BalanceDelta feesAccrued;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(unauthorized, key, params, delta, feesAccrued, "");
    }

    function test_beforeRemoveLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(unauthorized, key, params, "");
    }

    function test_afterRemoveLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        BalanceDelta delta;
        BalanceDelta feesAccrued;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(unauthorized, key, params, delta, feesAccrued, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    CIRCUIT BREAKER (PAUSE/UNPAUSE)
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_onlyGovernance() public {
        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(governance);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.unpause();
    }

    function test_pauseAndUnpause() public {
        vm.prank(governance);
        hook.pause();
        assertTrue(hook.paused());

        vm.prank(governance);
        hook.unpause();
        assertFalse(hook.paused());
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    INVALID HOOKDATA
    // ═══════════════════════════════════════════════════════════════════

    function test_beforeSwap_invalidHookData_reverts() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // hookData with length 1-31 (not empty, not valid ABI chunk)
        bytes memory badData = hex"DEADBEEF"; // 4 bytes

        vm.prank(poolManagerAddr);
        vm.expectRevert(MRLVHook.InvalidHookData.selector);
        hook.beforeSwap(address(this), key, params, badData);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    GOVERNANCE TRANSFER
    // ═══════════════════════════════════════════════════════════════════

    function test_transferGovernance() public {
        address newGov = address(0xCAFE);
        vm.prank(governance);
        hook.transferGovernance(newGov);
        assertEq(hook.governance(), newGov);
    }

    function test_transferGovernance_revertsForNonGovernance() public {
        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.transferGovernance(unauthorized);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              PAUSED beforeSwap PASSTHROUGH TEST
    // ═══════════════════════════════════════════════════════════════════

    function test_pausedBeforeSwap_returnsBaseFee() public {
        vm.prank(governance);
        hook.pause();

        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        (bytes4 selector_, , uint24 feeOverride) = hook.beforeSwap(address(this), key, params, "");

        assertEq(selector_, hook.beforeSwap.selector);
        // Fee should be BASE_FEE | OVERRIDE_FEE_FLAG
        uint24 expectedFee = LPFeeLibrary.OVERRIDE_FEE_FLAG | feeManager.BASE_FEE();
        assertEq(feeOverride, expectedFee, "Paused hook should return base fee");
    }

    function test_beforeSwapGasBenchmark() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        uint256 gasStart = gasleft();
        hook.beforeSwap(address(this), key, params, "");
        uint256 gasUsed = gasStart - gasleft();
        emit log_named_uint("Baseline Gas used by beforeSwap", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              LIQUIDITY MATURATION GATE (5-block rule)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice beforeSwap MUST succeed even when the most-recently-added LP position is immature (< 5 blocks old).
    function test_beforeSwap_succeedsWithImmatureLiquidity() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // LP adds liquidity via the hook (poolManager calls beforeAddLiquidity)
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(address(0xAA), key, lpParams, "");

        // Advance 2 blocks — LP is still immature (age=2 < maturityBlocks=5)
        vm.roll(block.number + 2);

        // Normal trader swap attempt MUST succeed
        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(address(0xBB), key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "beforeSwap with immature liquidity should succeed");
    }

    /// @notice beforeSwap must succeed once the LP position has matured (>= 5 blocks).
    function test_beforeSwap_succeedsWithMatureLiquidity() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // LP adds liquidity
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(address(0xAA), key, lpParams, "");

        // Advance exactly 5 blocks — LP is now mature (block.number >= addedBlock + 5)
        vm.roll(block.number + 5);

        // Swap must succeed (no revert)
        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(address(0xBB), key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "beforeSwap should return its selector");
    }

    /// @notice beforeSwap must succeed when no LP has ever added to the pool.
    ///         The maturation gate is a no-op when lastPoolLP is address(0).
    function test_beforeSwap_noLiquidity_succeeds() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        // No prior LP addition — gate is inactive
        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(address(0xCC), key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "beforeSwap with no LP should succeed");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     SPECIFIC SCENARIO TESTS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Scenario 1 — One immature LP: Alice adds at 100, Bob swaps at 102.
    ///         Bob's swap MUST succeed and JIT score from Alice must be 0.
    function test_Scenario1_OneImmatureLP() public {
        vm.roll(100);
        PoolKey memory key = _makePoolKey();
        bytes32 poolId = PoolId.unwrap(key.toId());
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        address alice = address(0xAA);
        address bob = address(0xBB);

        // Block 100: Alice adds liquidity
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(alice, key, lpParams, "");

        // Block 102: Bob swaps (maturity is 5 blocks)
        vm.roll(102);

        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(bob, key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "Bob's swap must succeed");

        // Verify risk score stored in swap context (JIT points = 0)
        bytes32 ctxKey = keccak256(abi.encode("SWAP_CTX", poolId, 102, bob));
        (,,, uint256 riskScore,) = hook._swapContext(ctxKey);
        assertEq(riskScore, 0, "Immature LP must produce 0 JIT points");
    }

    /// @notice Scenario 2 — Continuous LP additions:
    ///         Block 100 Alice, 101 Bob, 102 Charlie, 103 Dave swaps, 104 Eve, 105 Frank swaps.
    ///         Normal swaps MUST NOT be blocked.
    function test_Scenario2_ContinuousLPAdditions() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        address alice = address(0xAA);
        address bob = address(0xBB);
        address charlie = address(0xCC);
        address dave = address(0xDD);
        address eve = address(0xEE);
        address frank = address(0xFF);

        // Block 100: Alice adds liquidity
        vm.roll(100);
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(alice, key, lpParams, "");

        // Block 101: Bob adds liquidity
        vm.roll(101);
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(bob, key, lpParams, "");

        // Block 102: Charlie adds liquidity
        vm.roll(102);
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(charlie, key, lpParams, "");

        // Block 103: Dave swaps (must succeed)
        vm.roll(103);
        vm.prank(poolManagerAddr);
        (bytes4 sel1,,) = hook.beforeSwap(dave, key, params, "");
        assertEq(sel1, hook.beforeSwap.selector, "Dave swap must succeed");

        // Block 104: Eve adds liquidity
        vm.roll(104);
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(eve, key, lpParams, "");

        // Block 105: Frank swaps (must succeed)
        vm.roll(105);
        vm.prank(poolManagerAddr);
        (bytes4 sel2,,) = hook.beforeSwap(frank, key, params, "");
        assertEq(sel2, hook.beforeSwap.selector, "Frank swap must succeed");
    }

    /// @notice Scenario 3 — Mature LP:
    ///         Block 100 Alice adds, Block 105+ mature, Block 107 normal trader swaps.
    ///         Alice can now be considered by JIT suspicion logic.
    function test_Scenario3_MatureLP_EligibleForJIT() public {
        vm.roll(100);
        PoolKey memory key = _makePoolKey();
        bytes32 poolId = PoolId.unwrap(key.toId());
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        address alice = address(0xAA);
        address bob = address(0xBB);

        // Block 100: Alice adds liquidity
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(alice, key, lpParams, "");

        // Block 107: Bob swaps (Alice age = 7 >= maturity 5, <= jitWindow 10)
        vm.roll(107);
        vm.prank(poolManagerAddr);
        hook.beforeSwap(bob, key, params, "");

        bytes32 ctxKey = keccak256(abi.encode("SWAP_CTX", poolId, 107, bob));
        (,,, uint256 riskScore,) = hook._swapContext(ctxKey);
        assertEq(riskScore, 40, "Mature LP within JIT window must yield 40 JIT points");
    }

    /// @notice Scenario 4 — Immature add -> swap -> remove:
    ///         Block 100 Alice adds, Block 102 trader swaps, Block 103 Alice removes.
    ///         Must NOT emit JITConfirmed.
    function test_Scenario4_ImmatureAdd_Swap_Remove_NoJITConfirmed() public {
        vm.roll(100);
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory addP =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        ModifyLiquidityParams memory removeP =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        SwapParams memory swapP =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        address alice = address(0xAA);
        address trader = address(0xBB);

        // Block 100: Alice adds liquidity (tx 1)
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(alice, key, addP, "");
        detector.clearTransientState(); // End tx 1 (EIP-1153 transient storage cleared between txs)

        // Block 102: trader swaps (Alice is immature at swap time) (tx 2)
        vm.roll(102);
        vm.prank(poolManagerAddr);
        hook.beforeSwap(trader, key, swapP, "");
        detector.clearTransientState(); // End tx 2

        // Block 103: Alice removes liquidity (tx 3)
        vm.roll(103);
        // Expect NO JITConfirmed event emitted
        vm.recordLogs();
        vm.prank(poolManagerAddr);
        hook.beforeRemoveLiquidity(alice, key, removeP, "");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(
                entries[i].topics[0] != keccak256("JITConfirmed(bytes32,address,bool)"),
                "JITConfirmed must NOT be emitted for immature LP"
            );
        }
    }

    /// @notice Scenario 5 — Mature add -> swap -> remove:
    ///         Block 100 Alice adds, Block 105 mature, Block 107 trader swaps, Block 108 Alice removes.
    ///         Emits JITConfirmed(poolId, Alice, false).
    function test_Scenario5_MatureAdd_Swap_Remove_EmitsJITConfirmed() public {
        vm.roll(100);
        PoolKey memory key = _makePoolKey();
        bytes32 poolId = PoolId.unwrap(key.toId());
        ModifyLiquidityParams memory addP =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        ModifyLiquidityParams memory removeP =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        SwapParams memory swapP =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        address alice = address(0xAA);
        address trader = address(0xBB);

        // Block 100: Alice adds liquidity (tx 1)
        vm.prank(poolManagerAddr);
        hook.beforeAddLiquidity(alice, key, addP, "");
        detector.clearTransientState(); // End tx 1

        // Block 105: Alice matures (age 5)
        // Block 107: trader swaps (tx 2)
        vm.roll(107);
        vm.prank(poolManagerAddr);
        hook.beforeSwap(trader, key, swapP, "");
        detector.clearTransientState(); // End tx 2

        // Block 108: Alice removes liquidity (tx 3)
        vm.roll(108);

        vm.expectEmit(true, true, false, true);
        emit MEVDetector.JITConfirmed(poolId, alice, false);

        vm.prank(poolManagerAddr);
        hook.beforeRemoveLiquidity(alice, key, removeP, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _makePoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}
