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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MEVDetector} from "./MEVDetector.sol";
import {DynamicFeeManager} from "./DynamicFeeManager.sol";
import {AnalyticsEmitter} from "./AnalyticsEmitter.sol";
import {IERC20} from "lib/v4-hooks-public/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/v4-hooks-public/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {RewardVault} from "./RewardVault.sol";
import {LoyaltyManager} from "./LoyaltyManager.sol";

/// @title MRLVHook
/// @notice MEV-Redistributive Liquidity Vault — thin dispatcher hook for Uniswap v4.
///         Delegates MEV detection to MEVDetector, fee calculation to DynamicFeeManager,
///         and analytics emission to AnalyticsEmitter.
///         Phase 2 modules (RewardVault, LoyaltyManager) are referenced via TODO stubs.
contract MRLVHook is BaseHook, IUnlockCallback, ReentrancyGuard {
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

    using SafeERC20 for IERC20;
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
    bool private _isActivating; // transient lock for internal position activation

    RewardVault public rewardVault;
    LoyaltyManager public loyaltyManager;

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

    receive() external payable {}

    // ─── Hook permissions ────────────────────────────────────────────
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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

    function setRewardVault(RewardVault _rewardVault) external onlyGovernance {
        rewardVault = _rewardVault;
    }

    function setLoyaltyManager(LoyaltyManager _loyaltyManager) external onlyGovernance {
        loyaltyManager = _loyaltyManager;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════

    // ─── beforeInitialize ────────────────────────────────────────────
    function _beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) internal override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    // ─── afterInitialize ─────────────────────────────────────────────
    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) internal override returns (bytes4) {
        return this.afterInitialize.selector;
    }

    // ─── beforeSwap ──────────────────────────────────────────────────
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (hookData.length > 0 && hookData.length < 32) {
            revert InvalidHookData();
        }

        if (paused) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                LPFeeLibrary.OVERRIDE_FEE_FLAG |
                    DynamicFeeManager(feeManager).BASE_FEE()
            );
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        poolKeys[poolId] = key;

        _autoActivateMaturePositions(poolId);

        uint256 riskScore = detector.scoreSwap(key, params, sender, hookData);
        uint24 appliedFee = feeManager.computeFee(poolId, riskScore);

        bytes32 ctxKey = keccak256(
            abi.encode("SWAP_CTX", poolId, block.number, sender)
        );
        _swapContext[ctxKey] = SwapContext({
            trader: sender,
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified,
            riskScore: riskScore,
            appliedFee: appliedFee
        });

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
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (paused) {
            return (this.afterSwap.selector, 0);
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 ctxKey = keccak256(
            abi.encode("SWAP_CTX", poolId, block.number, sender)
        );
        SwapContext memory ctx = _swapContext[ctxKey];

        analytics.emitSwapProcessed(
            poolId,
            ctx.trader,
            ctx.appliedFee,
            ctx.riskScore
        );

        if (ctx.riskScore >= 30) {
            uint24 surcharge = ctx.appliedFee >
                DynamicFeeManager(feeManager).BASE_FEE()
                ? ctx.appliedFee - DynamicFeeManager(feeManager).BASE_FEE()
                : 0;
            analytics.emitMEVDetected(
                poolId,
                ctx.trader,
                ctx.riskScore,
                surcharge
            );

            if (surcharge > 0 && address(rewardVault) != address(0)) {
                uint256 notional = params.amountSpecified < 0
                    ? uint256(-params.amountSpecified)
                    : uint256(params.amountSpecified);
                uint256 surchargeAmount = (notional * surcharge) / 1000000;
                if (surchargeAmount > 0) {
                    rewardVault.deposit(poolId, surchargeAmount);
                }
            }
        }

        delete _swapContext[ctxKey];

        return (this.afterSwap.selector, 0);
    }

    // ─── beforeAddLiquidity ──────────────────────────────────────────
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        poolKeys[poolId] = key;

        // Enforce Liquidity Escrow: Direct liquidity additions that bypass pending escrow are rejected.
        if (!_isActivating) {
            revert PositionNotMature();
        }

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
        return (this.afterAddLiquidity.selector, delta);
    }

    // ─── beforeRemoveLiquidity ───────────────────────────────────────
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        if (address(loyaltyManager) != address(0)) {
            bytes32 poolId = PoolId.unwrap(key.toId());
            uint128 liquidity = uint128(uint256(-params.liquidityDelta));
            loyaltyManager.onRemoveLiquidity(sender, liquidity, poolId);
        }
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
        return (this.afterRemoveLiquidity.selector, delta);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                   PENDING LIQUIDITY ESCROW & MATURITY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposits LP liquidity into hook escrow without crediting active pool liquidity yet.
    /// @dev Protected against reentrancy via nonReentrant and strict CEI pattern.
    function depositPendingLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 amount0,
        uint256 amount1
    ) external nonReentrant returns (bytes32 posKey) {
        if (params.liquidityDelta <= 0) revert ZeroLiquidity();
        bytes32 poolId = PoolId.unwrap(key.toId());
        poolKeys[poolId] = key;
        uint128 liquidity = uint128(uint256(params.liquidityDelta));

        posKey = keccak256(
            abi.encode(
                poolId,
                msg.sender,
                params.tickLower,
                params.tickUpper,
                block.number,
                ++pendingNonce
            )
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

        emit LiquidityPending(
            posKey,
            poolId,
            msg.sender,
            params.tickLower,
            params.tickUpper,
            liquidity,
            amount0,
            amount1
        );

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (amount0 > 0 && c0 != address(0)) {
            IERC20(c0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0 && c1 != address(0)) {
            IERC20(c1).safeTransferFrom(msg.sender, address(this), amount1);
        }
    }

    /// @notice Activates a matured pending position.
    ///         Can only be invoked when liquidity has reached the maturity block level.
    function activateLiquidity(
        bytes32 posKey
    ) public nonReentrant returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (pos.activated) revert PositionAlreadyActivated();
        if (pos.withdrawn) revert PositionAlreadyWithdrawn();

        uint32 maturityBlocks = detector.liquidityMaturityBlocks();
        if (block.number - pos.blockNumber < maturityBlocks)
            revert PositionNotMature();

        poolManager.unlock(abi.encode(posKey));
        return true;
    }

    /// @notice Callback for PoolManager unlock to execute position activation.
    function unlockCallback(
        bytes calldata data
    ) external override onlyPoolManager returns (bytes memory) {
        bytes32 posKey = abi.decode(data, (bytes32));
        _activatePosition(posKey);
        return "";
    }

    /// @notice Internal helper for lazy auto-activating mature pending positions during swaps.
    function _autoActivateMaturePositions(bytes32 poolId) internal {
        bytes32[] storage keys = poolPendingPosKeys[poolId];
        uint32 maturityBlocks = detector.liquidityMaturityBlocks();
        uint256 len = keys.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 pKey = keys[i];
            PendingPosition storage pos = pendingPositions[pKey];
            if (
                !pos.activated &&
                !pos.withdrawn &&
                block.number - pos.blockNumber >= maturityBlocks
            ) {
                _activatePosition(pKey);
            }
        }
    }

    /// @notice Internal activation helper.
    function _activatePosition(bytes32 posKey) internal returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        if (pos.activated) return false;
        pos.activated = true;

        PoolKey memory key = poolKeys[pos.poolId];

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            liquidityDelta: int256(uint256(pos.liquidity)),
            salt: 0
        });

        _isActivating = true;
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        _isActivating = false;

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            uint256 amount0Owed = uint256(uint128(-delta0));
            address c0 = Currency.unwrap(key.currency0);
            if (c0 != address(0)) {
                poolManager.sync(key.currency0);
                IERC20(c0).safeTransfer(address(poolManager), amount0Owed);
                poolManager.settle();
            } else {
                poolManager.settle{value: amount0Owed}();
            }
            if (pos.amount0 > amount0Owed) {
                uint256 refund0 = pos.amount0 - amount0Owed;
                if (c0 != address(0)) {
                    IERC20(c0).safeTransfer(pos.owner, refund0);
                }
            }
        } else if (delta0 > 0) {
            poolManager.take(
                key.currency0,
                pos.owner,
                uint256(uint128(delta0))
            );
            if (pos.amount0 > 0) {
                address c0 = Currency.unwrap(key.currency0);
                if (c0 != address(0)) {
                    IERC20(c0).safeTransfer(pos.owner, pos.amount0);
                }
            }
        }

        if (delta1 < 0) {
            uint256 amount1Owed = uint256(uint128(-delta1));
            address c1 = Currency.unwrap(key.currency1);
            if (c1 != address(0)) {
                poolManager.sync(key.currency1);
                IERC20(c1).safeTransfer(address(poolManager), amount1Owed);
                poolManager.settle();
            } else {
                poolManager.settle{value: amount1Owed}();
            }
            if (pos.amount1 > amount1Owed) {
                uint256 refund1 = pos.amount1 - amount1Owed;
                if (c1 != address(0)) {
                    IERC20(c1).safeTransfer(pos.owner, refund1);
                }
            }
        } else if (delta1 > 0) {
            poolManager.take(
                key.currency1,
                pos.owner,
                uint256(uint128(delta1))
            );
            if (pos.amount1 > 0) {
                address c1 = Currency.unwrap(key.currency1);
                if (c1 != address(0)) {
                    IERC20(c1).safeTransfer(pos.owner, pos.amount1);
                }
            }
        }

        if (address(loyaltyManager) != address(0)) {
            loyaltyManager.onAddLiquidity(pos.owner, pos.liquidity, pos.poolId);
        }

        emit LiquidityActivated(posKey, pos.poolId, pos.owner, pos.liquidity);
        return true;
    }

    /// @notice Withdraws a pending position that has not yet been activated, returning exact escrowed tokens.
    function withdrawPendingLiquidity(
        bytes32 posKey,
        PoolKey calldata key
    ) external nonReentrant returns (bool) {
        PendingPosition storage pos = pendingPositions[posKey];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (msg.sender != pos.owner) revert NotPositionOwner();
        if (pos.activated) revert PositionAlreadyActivated();
        if (pos.withdrawn) revert PositionAlreadyWithdrawn();

        pos.withdrawn = true;

        emit LiquidityWithdrawnPending(
            posKey,
            pos.poolId,
            pos.owner,
            pos.amount0,
            pos.amount1
        );

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (pos.amount0 > 0 && c0 != address(0)) {
            IERC20(c0).safeTransfer(pos.owner, pos.amount0);
        }
        if (pos.amount1 > 0 && c1 != address(0)) {
            IERC20(c1).safeTransfer(pos.owner, pos.amount1);
        }

        return true;
    }

    /// @notice Views a position's maturity status and remaining blocks until maturity.
    function getPendingPositionStatus(
        bytes32 posKey
    )
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
