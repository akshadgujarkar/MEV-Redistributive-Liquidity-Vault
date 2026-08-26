// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoutRoster} from "./ScoutRoster.sol";

/// @title ScoutPointsOracle
/// @notice Receives detection reports from an off-chain relayer (Pattern A) and assigns points.
contract ScoutPointsOracle {

    error NotOwner();
    error NotRelayer();

    address public owner;
    address public relayer;
    
    ScoutRoster public scoutRoster;
    
    // Mapping of signal types to point values.
    // E.g. keccak256("PRIORITY_FEE") => 25, keccak256("REVERSAL") => 30, keccak256("PRICE_IMPACT") => 20
    mapping(bytes32 => uint256) public signalWeights;

    // LP Address => All Time Score
    mapping(address => uint256) public allTimeScoutScore;
    
    // Array of LPs to iterate through when assigning points (since the relayer just passes the trader)
    // To make this efficient on-chain, the orchestrator should register LPs who drafted in a season, 
    // or the relayer passes the list of LPs who drafted the trader.
    // Passing the LPs who drafted the trader is much more gas efficient, but requires the relayer to query the Roster.
    // Let's have the relayer pass the LPs that drafted the trader for scalability, 
    // OR we can just register LPs per season in the orchestrator and iterate.
    // Actually, passing the list of LPs from the relayer is safest, but we can verify it on-chain against ScoutRoster.

    event SignalWeightUpdated(bytes32 indexed signalType, uint256 weight);
    event AllTimeScoreUpdated(address indexed lp, uint256 newScore);
    event RelayerUpdated(address indexed newRelayer);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer && msg.sender != owner) revert NotRelayer();
        _;
    }

    constructor(address _relayer, ScoutRoster _scoutRoster) {
        owner = msg.sender;
        relayer = _relayer;
        scoutRoster = _scoutRoster;

        // Default weights based on existing MEVDetector
        signalWeights[keccak256("PRIORITY_FEE")] = 25;
        signalWeights[keccak256("REVERSAL")] = 30;
        signalWeights[keccak256("PRICE_IMPACT")] = 20;
    }

    function setRelayer(address _relayer) external onlyOwner {
        relayer = _relayer;
        emit RelayerUpdated(_relayer);
    }

    function setSignalWeight(bytes32 signalType, uint256 weight) external onlyOwner {
        signalWeights[signalType] = weight;
        emit SignalWeightUpdated(signalType, weight);
    }

    /// @notice Reports a detection for a specific trader.
    /// @param trader The address that was flagged by the MEVDetector.
    /// @param seasonId The current active season.
    /// @param signalType The type of signal detected (e.g., keccak256("REVERSAL")).
    /// @param lps The list of LPs who drafted this trader (provided by relayer for gas efficiency).
    function reportDetection(
        address trader, 
        uint256 seasonId, 
        bytes32 signalType,
        address[] calldata lps
    ) external onlyRelayer {
        uint256 pointsToAward = signalWeights[signalType];
        if (pointsToAward == 0) return;

        for (uint256 i = 0; i < lps.length; i++) {
            address lp = lps[i];
            
            // Verify on-chain that the LP actually drafted the trader this season
            if (scoutRoster.hasDrafted(lp, trader, seasonId)) {
                // Add points to the season roster
                scoutRoster.addPoints(lp, trader, seasonId, pointsToAward);
                
                // Add points to all-time score
                allTimeScoutScore[lp] += pointsToAward;
                emit AllTimeScoreUpdated(lp, allTimeScoutScore[lp]);
            }
        }
    }
}
