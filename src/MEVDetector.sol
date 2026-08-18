// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title MEVDetector
/// @notice Detects MEV swap patterns using EIP-1153 transient storage and risk scoring
contract MEVDetector {
    error NotGovernance();
    error NotHook();
    error NotOracleRelayer();

    address public governance;
    address public hook;
    address public oracleRelayer;

    // Signal point constants
    uint8 public constant PRIORITY_FEE_POINTS = 25;
    uint8 public constant REVERSAL_POINTS = 30;
    uint8 public constant PRICE_IMPACT_POINTS = 20;
    uint8 public constant JIT_POINTS = 40;

    // Default baseline fallback for priority fee anomaly when rolling average is 0
    // ASSUMPTION: Priority fee anomaly triggers if priorityFee > 2 * rollingPriorityFeeAvg[poolId] (or > 5 gwei if avg is 0)
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

    // Transient storage keys
    bytes32 private constant ATOMIC_ADD_LP_KEY = keccak256("MRLV_ATOMIC_ADD_LP");
    bytes32 private constant ATOMIC_SWAP_OCCURRED_KEY = keccak256("MRLV_ATOMIC_SWAP_OCCURRED");

    mapping(bytes32 => mapping(address => LiquidityRecord)) public lastAdditions;
    mapping(bytes32 => address) public lastPoolLP;
    mapping(bytes32 => uint32) public lastSwapBlock;
    mapping(bytes32 => uint32) public lastSwapSequence;

    event JITConfirmed(bytes32 indexed poolId, address indexed lp, bool isAtomic);

    mapping(bytes32 => mapping(address => uint256)) public lastAddLiquidityBlock;
    uint32 public jitWindowBlocks;

    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event OracleRelayerUpdated(address indexed newRelayer);
    event RollingPriorityFeeAvgUpdated(bytes32 indexed poolId, uint256 newAvg);
    event PriceImpactThresholdUpdated(bytes32 indexed poolId, uint256 newThreshold);

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

    constructor(address _governance, address _hook, address _oracleRelayer) {
        governance = _governance;
        hook = _hook;
        oracleRelayer = _oracleRelayer;
        reversalWindowBlocks = 10;
        jitWindowBlocks = 10;
    }

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

    event ReversalWindowBlocksUpdated(uint32 newWindow);
    event JitWindowBlocksUpdated(uint32 newWindow);

    function setReversalWindowBlocks(uint32 _reversalWindowBlocks) external onlyGovernance {
        reversalWindowBlocks = _reversalWindowBlocks;
        emit ReversalWindowBlocksUpdated(_reversalWindowBlocks);
    }

    function setJitWindowBlocks(uint32 _jitWindowBlocks) external onlyGovernance {
        jitWindowBlocks = _jitWindowBlocks;
        emit JitWindowBlocksUpdated(_jitWindowBlocks);
    }

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

    /// @notice Called by MRLVHook before add liquidity to record block number in persistent storage
    function onBeforeAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address sender,
        bytes calldata
    ) external onlyHook {
        bytes32 poolId = PoolId.unwrap(key.toId());
        // Use tx.origin to catch atomic EOA transactions across contract proxies
        address targetAddress = tx.origin != address(0) ? tx.origin : sender;

        lastAddLiquidityBlock[poolId][targetAddress] = block.number;

        // Set EIP-1153 transient storage flag for atomic JIT
        _tstore(ATOMIC_ADD_LP_KEY, uint256(uint160(targetAddress)));

        // Record in persistent storage for cross-transaction JIT
        lastAdditions[poolId][targetAddress] = LiquidityRecord({
            blockNumber: uint32(block.number),
            sequenceNumber: ++globalSequence,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.liquidityDelta > 0 ? uint128(uint256(params.liquidityDelta)) : 0
        });

        lastPoolLP[poolId] = targetAddress;
    }

    /// @notice Called by MRLVHook before remove liquidity to check and handle JIT confirmation
    function onBeforeRemoveLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        address sender
    ) external onlyHook {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address remover = tx.origin != address(0) ? tx.origin : sender;

        // 1. Check Atomic JIT
        address atomicLP = address(uint160(_tload(ATOMIC_ADD_LP_KEY)));
        uint256 atomicSwap = _tload(ATOMIC_SWAP_OCCURRED_KEY);
        if (remover == atomicLP && atomicSwap == 1) {
            emit JITConfirmed(poolId, remover, true);
            return;
        }

        // 2. Check Cross-Transaction JIT
        LiquidityRecord memory record = lastAdditions[poolId][remover];
        if (record.blockNumber != 0 && block.number - record.blockNumber <= jitWindowBlocks) {
            // Was there a swap after addition?
            if (lastSwapBlock[poolId] >= record.blockNumber && lastSwapSequence[poolId] > record.sequenceNumber) {
                // Verify tick range overlap
                if (params.tickLower == record.tickLower && params.tickUpper == record.tickUpper) {
                    emit JITConfirmed(poolId, remover, false);
                }
            }
        }
    }

    /// @notice Clears transient storage for testing or manual overrides
    function clearTransientState() external {
        _tstore(ATOMIC_ADD_LP_KEY, 0);
        _tstore(ATOMIC_SWAP_OCCURRED_KEY, 0);
    }

    /// @notice Scores a swap transaction for MEV signals
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
        address targetAddress = tx.origin != address(0) ? tx.origin : sender;

        // Record swap timing/order
        lastSwapBlock[poolId] = uint32(block.number);
        lastSwapSequence[poolId] = ++globalSequence;

        // Check EIP-1153 transient storage for atomic swap
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

        // 4. JIT liquidity pattern (+40)
        total += _checkJITPattern(poolId, targetAddress);

        // Cap score at 100
        return total > 100 ? 100 : total;
    }

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

        // Update history AFTER scoring this swap, so the check above reflects the trader's
        // PRIOR swap, not the current one.
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

    function _checkJITPattern(bytes32 poolId, address trader) internal view returns (uint8 points) {
        address lp = lastPoolLP[poolId];
        if (lp != address(0) && lp != trader) {
            LiquidityRecord memory record = lastAdditions[poolId][lp];
            if (record.blockNumber != 0 && block.number - record.blockNumber <= jitWindowBlocks) {
                points = JIT_POINTS;
            }
        }
    }
}
