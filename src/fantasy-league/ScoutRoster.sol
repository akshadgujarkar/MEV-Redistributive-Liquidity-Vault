// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ScoutRoster
/// @notice Manages per-LP, per-season rosters of staked addresses for the Fantasy MEV League.
contract ScoutRoster {
    using SafeERC20 for IERC20;

    error NotLeagueOrchestrator();
    error NotOracle();
    error RosterFull();
    error TraderAlreadyStaked();

    struct Pick {
        address trader;
        uint256 mrlvStaked;
        uint256 points;
        bool flagged; // true if flagged at least once this season
    }

    address public leagueOrchestrator;
    address public pointsOracle;
    
    // LP -> SeasonId -> Picks
    mapping(address => mapping(uint256 => Pick[])) public rosters;

    event PickStaked(address indexed lp, address indexed trader, uint256 amount, uint256 seasonId);
    event PickFlagged(address indexed lp, address indexed trader, uint256 pointsAwarded, uint256 seasonId);

    modifier onlyLeague() {
        if (msg.sender != leagueOrchestrator) revert NotLeagueOrchestrator();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != pointsOracle) revert NotOracle();
        _;
    }

    constructor(address _leagueOrchestrator) {
        leagueOrchestrator = _leagueOrchestrator;
    }

    function setPointsOracle(address _oracle) external onlyLeague {
        pointsOracle = _oracle;
    }

    /// @notice Stakes a pick for a user in a specific season. Called by the MEVScoutLeague orchestrator.
    function stakePick(address lp, address trader, uint256 seasonId, uint256 amount) external onlyLeague {
        Pick[] storage lpRoster = rosters[lp][seasonId];
        
        if (lpRoster.length >= 3) {
            revert RosterFull();
        }

        // Prevent drafting the same trader twice in the same season
        for (uint256 i = 0; i < lpRoster.length; i++) {
            if (lpRoster[i].trader == trader) {
                revert TraderAlreadyStaked();
            }
        }

        lpRoster.push(Pick({
            trader: trader,
            mrlvStaked: amount,
            points: 0,
            flagged: false
        }));

        emit PickStaked(lp, trader, amount, seasonId);
    }

    /// @notice Credits points to a pick. Called by the ScoutPointsOracle.
    function addPoints(address lp, address trader, uint256 seasonId, uint256 pointsAwarded) external onlyOracle {
        Pick[] storage lpRoster = rosters[lp][seasonId];
        for (uint256 i = 0; i < lpRoster.length; i++) {
            if (lpRoster[i].trader == trader) {
                lpRoster[i].points += pointsAwarded;
                lpRoster[i].flagged = true;
                
                emit PickFlagged(lp, trader, pointsAwarded, seasonId);
                break;
            }
        }
    }

    /// @notice Checks if a user has drafted a specific trader in a season.
    function hasDrafted(address lp, address trader, uint256 seasonId) external view returns (bool) {
        Pick[] memory lpRoster = rosters[lp][seasonId];
        for (uint256 i = 0; i < lpRoster.length; i++) {
            if (lpRoster[i].trader == trader) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the full roster for an LP in a specific season.
    function getRoster(address lp, uint256 seasonId) external view returns (Pick[] memory) {
        return rosters[lp][seasonId];
    }
}
