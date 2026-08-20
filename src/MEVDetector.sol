// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title MEVDetector
/// @notice Detects MEV swap patterns using risk scoring.
///
/// ## Liquidity Maturation Setting
/// Defines `liquidityMaturityBlocks`, which is configured by governance and used
/// by the hook contract for pending liquidity escrow maturation.
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

    // ─── Configurable windows & maturation ───────────────────────────

    /// @notice Number of blocks after which a liquidity addition is considered MATURE in hook escrow.
    ///         Default: 5.
    uint32 public liquidityMaturityBlocks;

    // ─── Events ──────────────────────────────────────────────────────
    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event OracleRelayerUpdated(address indexed newRelayer);
    event RollingPriorityFeeAvgUpdated(bytes32 indexed poolId, uint256 newAvg);
    event PriceImpactThresholdUpdated(bytes32 indexed poolId, uint256 newThreshold);
    event ReversalWindowBlocksUpdated(uint32 newWindow);
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

    /// @notice Sets the number of blocks a liquidity position must age in escrow before maturity.
    /// @param _maturityBlocks Number of blocks required (default 5).
    function setLiquidityMaturityBlocks(uint32 _maturityBlocks) external onlyGovernance {
        liquidityMaturityBlocks = _maturityBlocks;
        emit LiquidityMaturityBlocksUpdated(_maturityBlocks);
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

        // Cap score at 100
        return total > 100 ? 100 : total;
    }

    // ─── Internal signal checkers ─────────────────────────────────────

    function _checkPriorityFeeAnomaly(bytes32 poolId) internal view returns (bool) {
        uint256 priorityFee = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
        uint256 avg = rollingPriorityFeeAvg[poolId];

        if (avg > 0) {
            return priorityFee > 2 * avg;
        } else {
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
}

