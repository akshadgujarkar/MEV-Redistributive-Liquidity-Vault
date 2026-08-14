// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AnalyticsEmitter
/// @notice Centralized event emitter for off-chain indexing of MRLV protocol events
contract AnalyticsEmitter {
    error NotHook();
    error NotGovernance();

    address public hook;
    address public governance;

    event HookUpdated(address indexed newHook);
    event SwapProcessed(bytes32 indexed poolId, address indexed trader, uint24 appliedFee, uint256 riskScore);
    event MEVDetected(bytes32 indexed poolId, address indexed trader, uint256 riskScore, uint24 feeSurcharge);
    event FeeCaptured(bytes32 indexed poolId, uint256 amount);

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    constructor(address _governance) {
        governance = _governance;
    }

    function setHook(address _hook) external onlyGovernance {
        hook = _hook;
        emit HookUpdated(_hook);
    }

    function emitSwapProcessed(bytes32 poolId, address trader, uint24 appliedFee, uint256 riskScore) external onlyHook {
        emit SwapProcessed(poolId, trader, appliedFee, riskScore);
    }

    function emitMEVDetected(bytes32 poolId, address trader, uint256 riskScore, uint24 feeSurcharge) external onlyHook {
        emit MEVDetected(poolId, trader, riskScore, feeSurcharge);
    }

    function emitFeeCaptured(bytes32 poolId, uint256 amount) external onlyHook {
        emit FeeCaptured(poolId, amount);
    }
}
