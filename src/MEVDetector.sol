// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title MEVDetector
/// @notice Detects MEV swap patterns using EIP-1153 transient storage and risk scoring.
///
/// ## Liquidity Maturation
/// Every liquidity addition is recorded with its block number. A position is considered
/// IMMATURE for `liquidityMaturityBlocks` blocks after it was added:
///
///   addedBlock + liquidityMaturityBlocks <= currentBlock  →  MATURE
///
/// Immature liquidity does NOT block or delay ordinary swaps. An LP that has recently
/// added liquidity and is still within `liquidityMaturityBlocks` is simply ignored for JIT/MEV
/// participation analysis until it becomes mature.
///
/// ## JIT Detection vs Maturation
/// These are two separate concerns:
///  • Maturation  – filter determining if an LP position is mature enough for JIT analysis.
///  • JIT scoring – risk/MEV signal in scoreSwap (soft score, 0-100).
///
/// JIT_POINTS (+40) are only awarded when the LP addition is MATURE at the time of the swap
/// AND the swap falls within jitWindowBlocks. Immature liquidity produces 0 JIT points and does
/// not cause a swap to revert.
///
/// ## Architecture Note — lastPoolLP tracking
/// The contract tracks the most-recently-added LP per pool (`lastPoolLP`) as a convenience
/// pointer for JIT analysis. It is NOT used as a global pool maturation gate to reject swaps.
contract MEVDetector {
    error NotGovernance();
    error NotHook();
    error NotOracleRelayer();

    address public governance;
    address public hook;
    address public oracleRelayer;

    // ─── Signal point constants ───────────────────────────────────────
    uint8 public constant PRIORITY_FEE_POINTS = 25;
    uint8 public constant REVERSAL_POINTS = 30;
    uint8 public constant PRICE_IMPACT_POINTS = 20;
    uint8 public constant JIT_POINTS = 40;

    // ASSUMPTION: Priority fee anomaly triggers if priorityFee > 2 * rollingPriorityFeeAvg[poolId]
    //             (or > 5 gwei if avg is 0)
    uint256 public constant DEFAULT_PRIORITY_FEE_BASELINE = 5 gwei;

    // ASSUMPTION: Default price impact threshold is 10 ether specified amount unless configured per pool
    uint256 public constant DEFAULT_PRICE_IMPACT_THRESHOLD = 10 ether;

    mapping(bytes32 => uint256) public rollingPriorityFeeAvg;
    mapping(bytes32 => uint256) public priceImpactThreshold;

    struct TradeRecord {
        bool lastZeroForOne;
        uint32 lastSwapBlock;
        bool hasTraded;
    }

    mapping(bytes32 => mapping(address => TradeRecord)) public tradeHistory;
    uint32 public reversalWindowBlocks;

    struct LiquidityRecord {
        uint32 blockNumber;
        uint32 sequenceNumber;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    uint32 public globalSequence;

    // ─── Transient storage keys (EIP-1153) ───────────────────────────
    bytes32 private constant ATOMIC_ADD_LP_KEY = keccak256("MRLV_ATOMIC_ADD_LP");
    bytes32 private constant ATOMIC_SWAP_OCCURRED_KEY = keccak256("MRLV_ATOMIC_SWAP_OCCURRED");

    // ─── Persistent liquidity tracking ───────────────────────────────
    /// @dev Maps poolId → LP address → their most recent liquidity addition record.
    mapping(bytes32 => mapping(address => LiquidityRecord)) public lastAdditions;

    /// @dev Most recently added LP address per pool. Used as the maturation sentinel:
    ///      if this LP's addition is immature the pool is gated for swaps.
    ///      Limitation: single-LP tracking only — the most recent addition overwrites
    ///      the previous one.  Multi-LP position-level tracking is a Phase 2 concern.
    mapping(bytes32 => address) public lastPoolLP;

    mapping(bytes32 => uint32) public lastSwapBlock;
    mapping(bytes32 => uint32) public lastSwapSequence;

    /// @dev Legacy per-(pool, address) block tracker kept for backward compatibility.
    mapping(bytes32 => mapping(address => uint256)) public lastAddLiquidityBlock;

    // ─── Configurable windows ─────────────────────────────────────────

    /// @notice Number of blocks after which a liquidity addition is considered MATURE.
    ///         Boundary: addedBlock + liquidityMaturityBlocks <= currentBlock → MATURE.
    ///         Default: 5.
    uint32 public liquidityMaturityBlocks;

    /// @notice Number of blocks within which add→swap→remove is flagged as potential JIT.
    ///         JIT scoring only fires when the LP position is ALREADY MATURE at swap time.
    uint32 public jitWindowBlocks;

    // ─── Events ──────────────────────────────────────────────────────
    event JITConfirmed(bytes32 indexed poolId, address indexed lp, bool isAtomic);
    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event OracleRelayerUpdated(address indexed newRelayer);
    event RollingPriorityFeeAvgUpdated(bytes32 indexed poolId, uint256 newAvg);
    event PriceImpactThresholdUpdated(bytes32 indexed poolId, uint256 newThreshold);
    event ReversalWindowBlocksUpdated(uint32 newWindow);
    event JitWindowBlocksUpdated(uint32 newWindow);
    event LiquidityMaturityBlocksUpdated(uint32 newMaturity);

    // ─── Modifiers ───────────────────────────────────────────────────
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyOracleRelayerOrGovernance() {
        if (msg.sender != oracleRelayer && msg.sender != governance) revert NotOracleRelayer();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────
    constructor(address _governance, address _hook, address _oracleRelayer) {
        governance = _governance;
        hook = _hook;
        oracleRelayer = _oracleRelayer;
        reversalWindowBlocks = 10;
        jitWindowBlocks = 10;
        // Liquidity must be held for 5 blocks before it is eligible for swap participation.
        liquidityMaturityBlocks = 5;
    }

    // ─── Governance setters ───────────────────────────────────────────
    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setHook(address _hook) external onlyGovernance {
        hook = _hook;
        emit HookUpdated(_hook);
    }

    function setOracleRelayer(address _relayer) external onlyGovernance {
        oracleRelayer = _relayer;
        emit OracleRelayerUpdated(_relayer);
    }

    function setRollingPriorityFeeAvg(bytes32 poolId, uint256 newAvg) external onlyOracleRelayerOrGovernance {
        rollingPriorityFeeAvg[poolId] = newAvg;
        emit RollingPriorityFeeAvgUpdated(poolId, newAvg);
    }

    function setPriceImpactThreshold(bytes32 poolId, uint256 newThreshold) external onlyGovernance {
        priceImpactThreshold[poolId] = newThreshold;
        emit PriceImpactThresholdUpdated(poolId, newThreshold);
    }

    function setReversalWindowBlocks(uint32 _reversalWindowBlocks) external onlyGovernance {
        reversalWindowBlocks = _reversalWindowBlocks;
        emit ReversalWindowBlocksUpdated(_reversalWindowBlocks);
    }

    function setJitWindowBlocks(uint32 _jitWindowBlocks) external onlyGovernance {
        jitWindowBlocks = _jitWindowBlocks;
        emit JitWindowBlocksUpdated(_jitWindowBlocks);
    }

    /// @notice Sets the number of blocks a liquidity position must age before it is
    ///         considered mature and eligible for swap participation.
    /// @param _maturityBlocks Number of blocks required (default 5).
    function setLiquidityMaturityBlocks(uint32 _maturityBlocks) external onlyGovernance {
        liquidityMaturityBlocks = _maturityBlocks;
        emit LiquidityMaturityBlocksUpdated(_maturityBlocks);
    }

    // ─── Transient storage helpers (EIP-1153) ────────────────────────
    /// @notice Helper for transient storage write
    function _tstore(bytes32 key, uint256 val) internal {
        assembly {
            tstore(key, val)
        }
    }

    /// @notice Helper for transient storage read
    function _tload(bytes32 key) internal view returns (uint256 val) {
        assembly {
            val := tload(key)
        }
    }

    // ─── Maturation gate ─────────────────────────────────────────────

    /// @notice Returns true if the most-recently-added LP in `poolId` has a position
    ///         that has NOT yet reached `liquidityMaturityBlocks` of age.
    ///
    ///         Maturity boundary (inclusive):
    ///             block.number >= record.blockNumber + liquidityMaturityBlocks  →  MATURE
    ///
    ///         Example with liquidityMaturityBlocks = 5:
    ///             addedBlock = 100
    ///             blocks 100-104  →  immature  (returns true)
    ///             block  105      →  mature    (returns false)
    ///
    /// @dev Returns maturation state for the most-recently-added LP position.
    ///      Immature liquidity is ignored for JIT scoring and does NOT block ordinary swaps.
    function hasImmatureLiquidity(bytes32 poolId) external view returns (bool) {
        address lp = lastPoolLP[poolId];
        if (lp == address(0)) return false; // no LP has ever added to this pool

        LiquidityRecord memory record = lastAdditions[poolId][lp];
        if (record.blockNumber == 0) return false; // no record found (defensive)

        // MATURE when: block.number >= record.blockNumber + liquidityMaturityBlocks
        return block.number < uint256(record.blockNumber) + uint256(liquidityMaturityBlocks);
    }

    // ─── Liquidity lifecycle callbacks ────────────────────────────────

    /// @notice Called by MRLVHook before add liquidity to record block number in
    ///         persistent storage and set the atomic JIT transient flag.
    function onBeforeAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address sender,
        bytes calldata
    ) external onlyHook {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address targetAddress = sender;

        lastAddLiquidityBlock[poolId][targetAddress] = block.number;

        // Set EIP-1153 transient storage flag for atomic JIT detection
        _tstore(ATOMIC_ADD_LP_KEY, uint256(uint160(targetAddress)));

        // Record in persistent storage for cross-transaction JIT detection
        lastAdditions[poolId][targetAddress] = LiquidityRecord({
            blockNumber: uint32(block.number),
            sequenceNumber: ++globalSequence,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.liquidityDelta > 0 ? uint128(uint256(params.liquidityDelta)) : 0
        });

        // Update the pool's most-recent-LP pointer
        lastPoolLP[poolId] = targetAddress;
    }

    /// @notice Called by MRLVHook before remove liquidity to check and handle JIT
    ///         confirmation.
    ///
    ///         Cross-tx JIT requires ALL of:
    ///           1. LP has a recorded addition in this pool.
    ///           2. Removal is within jitWindowBlocks of the addition.
    ///           3. A swap occurred AFTER the addition (by sequence number).
    ///           4. The swap occurred AFTER the LP's position was mature — i.e.,
    ///              lastSwapBlock >= addedBlock + liquidityMaturityBlocks.
    ///              (Immature liquidity cannot have legitimately participated in
    ///               the swap, so the classic JIT pattern cannot be confirmed.)
    ///           5. Tick range of removal matches the recorded addition.
    function onBeforeRemoveLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address sender
    ) external onlyHook {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address remover = sender;

        // ── 1. Check Atomic JIT ─────────────────────────────────────
        // Atomic JIT: add + swap + remove all in the same tx.
        // Transient storage is set by onBeforeAddLiquidity and cleared between txs.
        address atomicLP = address(uint160(_tload(ATOMIC_ADD_LP_KEY)));
        uint256 atomicSwap = _tload(ATOMIC_SWAP_OCCURRED_KEY);
        if (remover == atomicLP && atomicSwap == 1) {
            emit JITConfirmed(poolId, remover, true);
            return;
        }

        // ── 2. Check Cross-Transaction JIT ──────────────────────────
        LiquidityRecord memory record = lastAdditions[poolId][remover];
        if (record.blockNumber == 0) return; // no prior addition recorded

        // Removal must be within the JIT observation window
        if (block.number - record.blockNumber > jitWindowBlocks) return;

        // A swap must have occurred after the addition (sequence-number check)
        if (lastSwapBlock[poolId] < record.blockNumber) return;
        if (lastSwapSequence[poolId] <= record.sequenceNumber) return;

        // The swap must have occurred AFTER this LP's position was mature.
        // If the swap happened while the position was immature, the position
        // could not have legitimately participated — no JIT confirmation.
        uint256 maturityBlock = uint256(record.blockNumber) + uint256(liquidityMaturityBlocks);
        if (uint256(lastSwapBlock[poolId]) < maturityBlock) return;

        // Tick range of the removal must match the recorded addition
        if (params.tickLower != record.tickLower || params.tickUpper != record.tickUpper) return;

        emit JITConfirmed(poolId, remover, false);
    }

    /// @notice Clears transient storage for testing or manual overrides
    function clearTransientState() external {
        _tstore(ATOMIC_ADD_LP_KEY, 0);
        _tstore(ATOMIC_SWAP_OCCURRED_KEY, 0);
    }

    // ─── Swap scoring ────────────────────────────────────────────────

    /// @notice Scores a swap transaction for MEV signals.
    /// @param key Pool key
    /// @param params Swap params
    /// @param sender Calling address
    /// @return riskScore Total aggregated score (0 to 100)
    function scoreSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        address sender,
        bytes calldata
    ) external onlyHook returns (uint256 riskScore) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address targetAddress = sender;

        // Record swap timing / sequence for cross-tx JIT confirmation
        lastSwapBlock[poolId] = uint32(block.number);
        lastSwapSequence[poolId] = ++globalSequence;

        // Set atomic swap flag if there is an active atomic LP in this tx
        address atomicLP = address(uint160(_tload(ATOMIC_ADD_LP_KEY)));
        if (atomicLP != address(0) && atomicLP != sender) {
            _tstore(ATOMIC_SWAP_OCCURRED_KEY, 1);
        }

        uint256 total = 0;

        // 1. Priority fee anomaly (+25)
        if (_checkPriorityFeeAnomaly(poolId)) {
            total += PRIORITY_FEE_POINTS;
        }

        // 2. Same-block opposite-direction swap / reversal (+30)
        total += _checkReversalPattern(poolId, targetAddress, params.zeroForOne);

        // 3. Large price impact (+20)
        if (_checkLargePriceImpact(poolId, params.amountSpecified)) {
            total += PRICE_IMPACT_POINTS;
        }

        // 4. JIT liquidity suspicion signal (+40)
        //    NOTE: JIT_POINTS are only awarded when the most-recent LP position is
        //    MATURE at the time of the swap.  If the position is immature the hook
        //    would have already reverted the swap; awarding points for mere temporal
        //    proximity is a false positive and is explicitly avoided here.
        total += _checkJITSuspicion(poolId, targetAddress);

        // Cap score at 100
        return total > 100 ? 100 : total;
    }

    // ─── Internal signal checkers ─────────────────────────────────────

    function _checkPriorityFeeAnomaly(bytes32 poolId) internal view returns (bool) {
        uint256 priorityFee = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
        uint256 avg = rollingPriorityFeeAvg[poolId];

        if (avg > 0) {
            // ASSUMPTION: Anomaly if priority fee is > 2 * rolling average
            return priorityFee > 2 * avg;
        } else {
            // ASSUMPTION: Default threshold if no rolling average set
            return priorityFee > DEFAULT_PRIORITY_FEE_BASELINE;
        }
    }

    function _checkReversalPattern(bytes32 poolId, address trader, bool zeroForOne) internal returns (uint8 points) {
        TradeRecord storage record = tradeHistory[poolId][trader];

        if (record.hasTraded
            && record.lastZeroForOne != zeroForOne
            && block.number - record.lastSwapBlock <= reversalWindowBlocks) {
            points = REVERSAL_POINTS;
        }

        // Update history AFTER scoring this swap, so the check above reflects the
        // trader's PRIOR swap direction, not the current one.
        record.lastZeroForOne = zeroForOne;
        record.lastSwapBlock = uint32(block.number);
        record.hasTraded = true;
    }

    function _checkLargePriceImpact(bytes32 poolId, int256 amountSpecified) internal view returns (bool) {
        uint256 threshold = priceImpactThreshold[poolId];
        if (threshold == 0) {
            threshold = DEFAULT_PRICE_IMPACT_THRESHOLD;
        }
        int256 absAmount = amountSpecified < 0 ? -amountSpecified : amountSpecified;
        return absAmount > int256(threshold);
    }

    /// @notice JIT suspicion scoring signal.
    ///
    ///         Returns JIT_POINTS (+40) only when ALL of the following hold:
    ///           • A different address from the swapper recently added liquidity.
    ///           • That LP's position is NOW MATURE (>= liquidityMaturityBlocks old).
    ///           • The swap falls within jitWindowBlocks of the addition.
    ///
    ///         This deliberately avoids flagging ordinary swaps that happen after a
    ///         fresh (immature) liquidity addition — that pattern cannot represent
    ///         JIT liquidity because the hook would have reverted the swap.
    ///
    ///         The function is renamed from _checkJITPattern to _checkJITSuspicion
    ///         to reinforce that this is an early-warning signal, not a confirmation.
    function _checkJITSuspicion(bytes32 poolId, address trader) internal view returns (uint8 points) {
        address lp = lastPoolLP[poolId];
        if (lp == address(0) || lp == trader) return 0;

        LiquidityRecord memory record = lastAdditions[poolId][lp];
        if (record.blockNumber == 0) return 0;

        uint256 age = block.number - uint256(record.blockNumber);

        // Liquidity must be MATURE (>= liquidityMaturityBlocks blocks old)
        if (age < uint256(liquidityMaturityBlocks)) return 0;

        // Swap must be within the JIT observation window
        if (age > uint256(jitWindowBlocks)) return 0;

        return JIT_POINTS;
    }
}
