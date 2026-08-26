// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IExistingEvents
/// @notice This interface mirrors the events emitted by the AnalyticsEmitter contract.
///         It is purely used by the off-chain relayer to decode logs.
///         This file does not touch or modify any existing contracts.
interface IExistingEvents {
    event SwapProcessed(
        bytes32 indexed poolId,
        address indexed trader,
        uint24 appliedFee,
        uint256 riskScore
    );

    event MEVDetected(
        bytes32 indexed poolId,
        address indexed trader,
        uint256 riskScore,
        uint24 feeSurcharge
    );
}
