// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DynamicFeeManager
/// @notice Computes dynamic fees based on MEV risk scores, enforcing caps and rate limits
contract DynamicFeeManager {
    error NotGovernance();
    error NotHook();
    error InvalidFeeMultiplier();

    uint24 public constant BASE_FEE = 3000; // 0.30% in hundredths of a bip
    uint24 public constant HARD_CAP = 30000; // 3.00% absolute ceiling

    address public governance;
    address public hook;
    uint24 public maxFeeMultiplier = 3; // Fee jump rate limit multiplier (≤3x per design)

    mapping(bytes32 => uint24) public lastAppliedFee;

    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event MaxFeeMultiplierUpdated(uint24 newMultiplier);
    event FeeAdjusted(bytes32 indexed poolId, uint24 oldFee, uint24 newFee, uint256 riskScore);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address _governance, address _hook) {
        governance = _governance;
        hook = _hook;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setHook(address _hook) external onlyGovernance {
        hook = _hook;
        emit HookUpdated(_hook);
    }

    function setMaxFeeMultiplier(uint24 _multiplier) external onlyGovernance {
        if (_multiplier == 0 || _multiplier > 3) revert InvalidFeeMultiplier();
        maxFeeMultiplier = _multiplier;
        emit MaxFeeMultiplierUpdated(_multiplier);
    }

    /// @notice Calculates the un-rate-limited raw fee for a risk score
    /// @param riskScore Score between 0 and 100 (or capped at 100)
    /// @return Raw fee in hundredths of a bip
    function calculateRawFee(uint256 riskScore) public pure returns (uint24) {
        if (riskScore < 30) {
            return BASE_FEE; // 3000 (0.30%)
        } else if (riskScore < 70) {
            return BASE_FEE * 2; // 6000 (0.60%)
        } else {
            if (riskScore >= 100) {
                return HARD_CAP; // 30000 (3.00%)
            }
            // Linear scale from 10000 (1.00%) at score 70 to 30000 (3.00%) at score 100
            uint256 scaled = 10000 + ((riskScore - 70) * (30000 - 10000)) / 30;
            uint24 fee = uint24(scaled);
            return fee > HARD_CAP ? HARD_CAP : fee;
        }
    }

    /// @notice Applies the per-block rate limit against a previous applied fee
    /// @param rawFee Proposed raw fee
    /// @param prevFee Previous applied fee for the pool (0 if none)
    /// @return Fee clamped to at most maxFeeMultiplier * previous fee and HARD_CAP
    function applyRateLimit(uint24 rawFee, uint24 prevFee) public view returns (uint24) {
        uint24 baseline = prevFee == 0 ? BASE_FEE : prevFee;
        uint256 maxAllowed256 = uint256(baseline) * uint256(maxFeeMultiplier);
        uint24 maxAllowed = maxAllowed256 > HARD_CAP ? HARD_CAP : uint24(maxAllowed256);

        uint24 fee = rawFee > maxAllowed ? maxAllowed : rawFee;
        return fee > HARD_CAP ? HARD_CAP : fee;
    }

    /// @notice Preview fee calculation without modifying state
    function previewFee(bytes32 poolId, uint256 riskScore) public view returns (uint24) {
        uint24 rawFee = calculateRawFee(riskScore);
        uint24 prevFee = lastAppliedFee[poolId];
        return applyRateLimit(rawFee, prevFee);
    }

    /// @notice Computes and updates the rate-limited fee for a pool
    /// @param poolId Uniswap v4 pool identifier
    /// @param riskScore MEV risk score
    /// @return Applied fee override
    function computeFee(bytes32 poolId, uint256 riskScore) external onlyHook returns (uint24) {
        uint24 prevFee = lastAppliedFee[poolId];
        uint24 rawFee = calculateRawFee(riskScore);
        uint24 finalFee = applyRateLimit(rawFee, prevFee);

        lastAppliedFee[poolId] = finalFee;
        emit FeeAdjusted(poolId, prevFee, finalFee, riskScore);

        return finalFee;
    }
}
