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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MEVDetector} from "./MEVDetector.sol";
import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {AnalyticsEmitter} from "./AnalyticsEmitter.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

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
    /// @notice Legacy error retained for ABI compatibility.
    /// @dev Immature liquidity does not block ordinary swaps. It is excluded from JIT/MEV analysis until mature.
    error ImmatureLiquidityExists();
    error PositionNotMature();
    error PositionAlreadyActivated();
    error PositionAlreadyWithdrawn();
    error PositionNotFound();
    error NotPositionOwner();
    error ZeroLiquidity();

    // ─── Structs ─────────────────────────────────────────────────────
    struct PendingPosition {
        bytes32 posKey;
        address owner;
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint32 blockNumber;
        bool activated;
        bool withdrawn;
    }

    // ─── State variables (per Architecture.md §3.2) ──────────────────
    MEVDetector public detector;
    DynamicFeeManager public feeManager;
    AnalyticsEmitter public analytics;
    address public governance;
    bool public paused; // circuit breaker, governance-controlled

    mapping(bytes32 => PendingPosition) public pendingPositions;
    mapping(bytes32 => bytes32[]) public poolPendingPosKeys;
    mapping(bytes32 => PoolKey) public poolKeys;
    uint256 public pendingNonce;

    // ─── Per-swap context stored transiently for afterSwap ───────────
    struct SwapContext {
        address trader;
        bool zeroForOne;
        int256 amountSpecified;
        uint256 riskScore;
        uint24 appliedFee;
    }

    mapping(bytes32 => SwapContext) public _swapContext;

    // ─── Events ──────────────────────────────────────────────────────
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    event LiquidityPending(
        bytes32 indexed posKey,
        bytes32 indexed poolId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event LiquidityActivated(
        bytes32 indexed posKey,
        bytes32 indexed poolId,
        address indexed owner,
        uint128 liquidity
    );

    event LiquidityWithdrawnPending(
        bytes32 indexed posKey,
        bytes32 indexed poolId,
        address indexed owner,
        uint256 amount0,
        uint256 amount1
    );

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
        poolKeys[poolId] = key;

        _autoActivateMaturePositions(poolId);

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
        bytes32 poolId = PoolId.unwrap(key.toId());
        poolKeys[poolId] = key;

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

    // ═══════════════════════════════════════════════════════════════════
    //                   PENDING LIQUIDITY ESCROW & MATURITY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposits LP liquidity into hook escrow without crediting active pool liquidity yet.
    function depositPendingLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 amount0,
        uint256 amount1
    ) external returns (bytes32 posKey) {
        if (params.liquidityDelta <= 0) revert ZeroLiquidity();
        bytes32 poolId = PoolId.unwrap(key.toId());
        poolKeys[poolId] = key;
        uint128 liquidity = uint128(uint256(params.liquidityDelta));

        posKey = keccak256(
            abi.encode(poolId, msg.sender, params.tickLower, params.tickUpper, block.number, ++pendingNonce)
        );

        pendingPositions[posKey] = PendingPosition({
            posKey: posKey,
            owner: msg.sender,
            poolId: poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1,
            blockNumber: uint32(block.number),
            activated: false,
            withdrawn: false
        });

        poolPendingPosKeys[poolId].push(posKey);

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (amount0 > 0 && c0 != address(0)) {
            IERC20(c0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0 && c1 != address(0)) {
            IERC20(c1).transferFrom(msg.sender, address(this), amount1);
        }

        emit LiquidityPending(
            posKey, poolId, msg.sender, params.tickLower, params.tickUpper, liquidity, amount0, amount1
        );
    }

    /// @notice Activates a matured pending position, registering it with MEVDetector.
    function activateLiquidity(bytes32 posKey) public returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (pos.activated) revert PositionAlreadyActivated();
        if (pos.withdrawn) revert PositionAlreadyWithdrawn();

        uint32 maturityBlocks = detector.liquidityMaturityBlocks();
        if (block.number - pos.blockNumber < maturityBlocks) revert PositionNotMature();

        return _activatePosition(posKey);
    }

    /// @notice Internal helper for lazy auto-activating mature pending positions during swaps.
    function _autoActivateMaturePositions(bytes32 poolId) internal {
        bytes32[] storage keys = poolPendingPosKeys[poolId];
        uint32 maturityBlocks = detector.liquidityMaturityBlocks();
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 pKey = keys[i];
            PendingPosition storage pos = pendingPositions[pKey];
            if (!pos.activated && !pos.withdrawn && block.number - pos.blockNumber >= maturityBlocks) {
                _activatePosition(pKey);
            }
        }
    }

    /// @notice Internal activation helper.
    function _activatePosition(bytes32 posKey) internal returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        pos.activated = true;

        PoolKey memory key = poolKeys[pos.poolId];

        detector.onBeforeAddLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: int256(uint256(pos.liquidity)),
                salt: 0
            }),
            pos.owner,
            ""
        );

        emit LiquidityActivated(posKey, pos.poolId, pos.owner, pos.liquidity);
        return true;
    }

    /// @notice Withdraws a pending position that has not yet been activated, returning exact escrowed tokens.
    function withdrawPendingLiquidity(bytes32 posKey, PoolKey calldata key) external returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (msg.sender != pos.owner) revert NotPositionOwner();
        if (pos.activated) revert PositionAlreadyActivated();
        if (pos.withdrawn) revert PositionAlreadyWithdrawn();

        pos.withdrawn = true;

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (pos.amount0 > 0 && c0 != address(0)) {
            IERC20(c0).transfer(pos.owner, pos.amount0);
        }
        if (pos.amount1 > 0 && c1 != address(0)) {
            IERC20(c1).transfer(pos.owner, pos.amount1);
        }

        emit LiquidityWithdrawnPending(posKey, pos.poolId, pos.owner, pos.amount0, pos.amount1);
        return true;
    }

    /// @notice Views a position's maturity status and remaining blocks until maturity.
    function getPendingPositionStatus(bytes32 posKey)
        external
        view
        returns (
            bool isPending,
            bool isMature,
            uint256 remainingBlocks,
            uint128 liquidity,
            address owner
        )
    {
        PendingPosition memory pos = pendingPositions[posKey];
        if (pos.owner == address(0)) revert PositionNotFound();

        isPending = !pos.activated && !pos.withdrawn;
        uint32 maturityBlocks = detector.liquidityMaturityBlocks();
        uint256 age = block.number - pos.blockNumber;
        isMature = age >= maturityBlocks;
        remainingBlocks = isMature ? 0 : (maturityBlocks - age);
        liquidity = pos.liquidity;
        owner = pos.owner;
    }
}
