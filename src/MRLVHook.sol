// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MEVDetector} from "./MEVDetector.sol";
import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {AnalyticsEmitter} from "./AnalyticsEmitter.sol";

/// @title MRLVHook
/// @notice MEV-Redistributive Liquidity Vault — thin dispatcher hook for Uniswap v4.
///         Delegates MEV detection to MEVDetector, fee calculation to DynamicFeeManager,
///         and analytics emission to AnalyticsEmitter.
///         Phase 2 modules (RewardVault, LoyaltyManager) are referenced via TODO stubs.
contract MRLVHook is BaseHook {
    // ─── Custom errors ───────────────────────────────────────────────
    error NotGovernance();
    error HookIsPaused();
    error InvalidHookData();
    /// @notice Emitted when a swap is attempted against a pool whose most-recently-added
    ///         LP position has not yet reached the `liquidityMaturityBlocks` maturation
    ///         period.  The swap must be retried once the immature position has matured.
    error ImmatureLiquidityExists();

    // ─── State variables (per Architecture.md §3.2) ──────────────────
    MEVDetector public detector;
    DynamicFeeManager public feeManager;
    AnalyticsEmitter public analytics;
    address public governance;
    bool public paused; // circuit breaker, governance-controlled

    // ─── Per-swap context stored transiently for afterSwap ───────────
    struct SwapContext {
        address trader;
        bool zeroForOne;
        int256 amountSpecified;
        uint256 riskScore;
        uint24 appliedFee;
    }

    // Using transient storage for swap context to avoid persistent writes on every swap.
    // Key: keccak256(abi.encode("SWAP_CTX", poolId, block.number, msg.sender))
    // But since afterSwap is called in the same tx, we use a simple storage variable
    // that gets overwritten each swap (never read across txs). This is cheaper than
    // re-encoding to transient storage for a struct.
    mapping(bytes32 => SwapContext) internal _swapContext;

    // ─── Events ──────────────────────────────────────────────────────
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    // ─── Modifiers ───────────────────────────────────────────────────
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────
    constructor(
        IPoolManager _poolManager,
        MEVDetector _detector,
        DynamicFeeManager _feeManager,
        AnalyticsEmitter _analytics,
        address _governance
    ) BaseHook(_poolManager) {
        detector = _detector;
        feeManager = _feeManager;
        analytics = _analytics;
        governance = _governance;
    }

    // ─── Hook permissions ────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Governance controls ─────────────────────────────────────────
    function pause() external onlyGovernance {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════

    // ─── beforeInitialize ────────────────────────────────────────────
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        override
        returns (bytes4)
    {
        // Pool validation — v4 ensures PoolKey.hooks == address(this) via address convention.
        // No additional validation needed for Phase 1.
        return this.beforeInitialize.selector;
    }

    // ─── afterInitialize ─────────────────────────────────────────────
    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        // TODO(Phase 2): Initialize LoyaltyManager state for this pool if needed.
        return this.afterInitialize.selector;
    }

    // ─── beforeSwap ──────────────────────────────────────────────────
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Validate hookData: if provided, must be valid ABI-encoded bytes.
        // Empty hookData is acceptable for Phase 1 (no hookData needed).
        if (hookData.length > 0 && hookData.length < 32) {
            revert InvalidHookData();
        }

        // If paused, pass through with base fee — no detection
        if (paused) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                LPFeeLibrary.OVERRIDE_FEE_FLAG | DynamicFeeManager(feeManager).BASE_FEE()
            );
        }

        bytes32 poolId = PoolId.unwrap(key.toId());

        // ── Liquidity Maturation Gate ────────────────────────────────
        // Protocol constraint: swaps are blocked while the most-recently-added LP
        // position has not yet matured (< liquidityMaturityBlocks blocks old).
        //
        // Architecture note: Uniswap v4 hooks cannot selectively exclude individual
        // positions from swap execution.  The only hook-level enforcement is to revert
        // the entire swap.  When only mature liquidity exists this gate is a no-op.
        if (detector.hasImmatureLiquidity(poolId)) {
            revert ImmatureLiquidityExists();
        }

        // 1. Score swap via MEVDetector
        uint256 riskScore = detector.scoreSwap(key, params, sender, hookData);

        // 2. Compute rate-limited fee via DynamicFeeManager
        uint24 appliedFee = feeManager.computeFee(poolId, riskScore);

        // 3. Store swap context for afterSwap
        bytes32 ctxKey = keccak256(abi.encode("SWAP_CTX", poolId, block.number, sender));
        _swapContext[ctxKey] = SwapContext({
            trader: sender,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            riskScore: riskScore,
            appliedFee: appliedFee
        });

        // Return fee override with the OVERRIDE_FEE_FLAG
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            LPFeeLibrary.OVERRIDE_FEE_FLAG | appliedFee
        );
    }

    // ─── afterSwap ───────────────────────────────────────────────────
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (paused) {
            return (this.afterSwap.selector, 0);
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 ctxKey = keccak256(abi.encode("SWAP_CTX", poolId, block.number, sender));
        SwapContext memory ctx = _swapContext[ctxKey];

        // Emit analytics events
        analytics.emitSwapProcessed(poolId, ctx.trader, ctx.appliedFee, ctx.riskScore);

        if (ctx.riskScore >= 30) {
            uint24 surcharge = ctx.appliedFee > DynamicFeeManager(feeManager).BASE_FEE()
                ? ctx.appliedFee - DynamicFeeManager(feeManager).BASE_FEE()
                : 0;
            analytics.emitMEVDetected(poolId, ctx.trader, ctx.riskScore, surcharge);
        }
    
        // TODO(Phase 2): Compute surcharge amount from (appliedFee - BASE_FEE) * notional
        //                 and call RewardVault.deposit(poolId, surchargeAmount)
        // TODO(Phase 2): Call LoyaltyManager to update per-swap stats

        // Clean up swap context (gas refund on SSTORE to zero)
        delete _swapContext[ctxKey];

        return (this.afterSwap.selector, 0);
    }

    // ─── beforeAddLiquidity ──────────────────────────────────────────
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        // Set JIT flag in MEVDetector's transient storage
        detector.onBeforeAddLiquidity(key, params, sender, hookData);

        // TODO(Phase 2): Call LoyaltyManager.onAddLiquidity() to start/continue tenure
        return this.beforeAddLiquidity.selector;
    }

    // ─── afterAddLiquidity ───────────────────────────────────────────
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // TODO(Phase 2): Recompute LPScore and update tier (may trigger NFT mint)
        return (this.afterAddLiquidity.selector, delta);
    }

    // ─── beforeRemoveLiquidity ───────────────────────────────────────
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        detector.onBeforeRemoveLiquidity(key, params, sender);
        return this.beforeRemoveLiquidity.selector;
    }

    // ─── afterRemoveLiquidity ────────────────────────────────────────
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // TODO(Phase 2): Settle pending claimable delta, update LoyaltyManager state
        return (this.afterRemoveLiquidity.selector, delta);
    }
}
