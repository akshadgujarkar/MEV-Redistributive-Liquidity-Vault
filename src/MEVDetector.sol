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

    /// @notice Called by MRLVHook before add liquidity to set JIT flag in transient storage
    function onBeforeAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        address sender,
        bytes calldata
    ) external onlyHook {
        bytes32 poolId = PoolId.unwrap(key.toId());
        // Use tx.origin to catch atomic EOA transactions across contract proxies
        address targetAddress = tx.origin != address(0) ? tx.origin : sender;

        // Namespace transient key by (poolId, address, block.number)
        bytes32 jitKey = keccak256(abi.encode("JIT_ADD", poolId, targetAddress, block.number));
        _tstore(jitKey, 1);
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

        uint256 total = 0;

        // 1. Priority fee anomaly (+25)
        if (_checkPriorityFeeAnomaly(poolId)) {
            total += PRIORITY_FEE_POINTS;
        }

        // 2. Same-block opposite-direction swap / reversal (+30)
        if (_checkSameBlockReversal(poolId, targetAddress, params.zeroForOne)) {
            total += REVERSAL_POINTS;
        }

        // 3. Large price impact (+20)
        if (_checkLargePriceImpact(poolId, params.amountSpecified)) {
            total += PRICE_IMPACT_POINTS;
        }

        // 4. JIT liquidity pattern (+40)
        if (_checkJITPattern(poolId, targetAddress)) {
            total += JIT_POINTS;
        }

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

    function _checkSameBlockReversal(bytes32 poolId, address targetAddress, bool zeroForOne) internal returns (bool) {
        bytes32 reversalKey = keccak256(abi.encode("SAME_BLOCK_REVERSAL", poolId, targetAddress, block.number));
        uint256 prevDir = _tload(reversalKey);
        uint256 currentDir = zeroForOne ? 1 : 2;

        bool isReversal = false;
        if (prevDir != 0 && prevDir != currentDir) {
            isReversal = true;
        }

        _tstore(reversalKey, currentDir);
        return isReversal;
    }

    function _checkLargePriceImpact(bytes32 poolId, int256 amountSpecified) internal view returns (bool) {
        uint256 threshold = priceImpactThreshold[poolId];
        if (threshold == 0) {
            threshold = DEFAULT_PRICE_IMPACT_THRESHOLD;
        }
        int256 absAmount = amountSpecified < 0 ? -amountSpecified : amountSpecified;
        return absAmount > int256(threshold);
    }

    function _checkJITPattern(bytes32 poolId, address targetAddress) internal view returns (bool) {
        bytes32 jitKey = keccak256(abi.encode("JIT_ADD", poolId, targetAddress, block.number));
        return _tload(jitKey) == 1;
    }
}
