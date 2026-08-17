// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
