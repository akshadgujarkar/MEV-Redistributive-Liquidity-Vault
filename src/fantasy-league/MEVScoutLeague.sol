// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ScoutRoster} from "./ScoutRoster.sol";

/// @title MEVScoutLeague
/// @notice Orchestrator for the Fantasy MEV League. Manages seasons, staking, and payouts.
contract MEVScoutLeague {
    using SafeERC20 for IERC20;

    error NotOwner();
    error InvalidSeasonStatus();
    error ZeroStake();
    error NoPointsScored();
    error NothingToClaim();

    enum SeasonStatus { DRAFTING, ACTIVE, SETTLED }

    struct Season {
        uint256 id;
        SeasonStatus status;
        uint256 prizePool;
        uint256 totalPoints;
        address[] participants;
    }

    address public owner;
    IERC20 public mrlvToken;
    ScoutRoster public scoutRoster;
    
    uint256 public currentSeasonId;
    mapping(uint256 => Season) public seasons;
    
    // LP => Claimable MRLV
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable; // Tracks global claimable amount to preserve solvency
    
    // To check if LP is already in the participants list for a season
    mapping(address => mapping(uint256 => bool)) public hasJoined;

    event SeasonStarted(uint256 seasonId);
    event SeasonLocked(uint256 seasonId);
    event SeasonSettled(uint256 seasonId, uint256 totalPoints, uint256 totalPrizePool);
    event PrizePoolToppedUp(uint256 seasonId, uint256 amount);
    event Claimed(address indexed lp, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IERC20 _mrlvToken, ScoutRoster _scoutRoster) {
        owner = msg.sender;
        mrlvToken = _mrlvToken;
        scoutRoster = _scoutRoster;
    }

    /// @notice Opens a new season for drafting.
    function startSeason() external onlyOwner {
        if (currentSeasonId > 0 && seasons[currentSeasonId].status != SeasonStatus.SETTLED) {
            revert InvalidSeasonStatus();
        }
        
        currentSeasonId++;
        Season storage newSeason = seasons[currentSeasonId];
        newSeason.id = currentSeasonId;
        newSeason.status = SeasonStatus.DRAFTING;
        
        // If there was leftover prize pool from previous season (e.g., nobody scored), carry it over
        uint256 balance = mrlvToken.balanceOf(address(this));
        uint256 leftover = balance > totalClaimable ? balance - totalClaimable : 0;
        newSeason.prizePool = leftover;

        emit SeasonStarted(currentSeasonId);
    }

    /// @notice Locks the current season, ending drafting and beginning the active scoring phase.
    function lockSeason() external onlyOwner {
        Season storage season = seasons[currentSeasonId];
        if (season.status != SeasonStatus.DRAFTING) revert InvalidSeasonStatus();
        
        season.status = SeasonStatus.ACTIVE;
        emit SeasonLocked(currentSeasonId);
    }

    /// @notice Settles the current season, calculating and allocating proportional payouts.
    function settleSeason() external onlyOwner {
        Season storage season = seasons[currentSeasonId];
        if (season.status != SeasonStatus.ACTIVE) revert InvalidSeasonStatus();
        
        season.status = SeasonStatus.SETTLED;
        
        uint256 totalPoints = 0;
        
        // 1st Pass: Calculate total points scored in the season
        for (uint256 i = 0; i < season.participants.length; i++) {
            address lp = season.participants[i];
            ScoutRoster.Pick[] memory roster = scoutRoster.getRoster(lp, currentSeasonId);
            for (uint256 j = 0; j < roster.length; j++) {
                totalPoints += roster[j].points;
            }
        }
        
        season.totalPoints = totalPoints;

        // 2nd Pass: Allocate payouts based on points proportion
        if (totalPoints > 0) {
            uint256 pool = season.prizePool;
            for (uint256 i = 0; i < season.participants.length; i++) {
                address lp = season.participants[i];
                ScoutRoster.Pick[] memory roster = scoutRoster.getRoster(lp, currentSeasonId);
                uint256 lpPoints = 0;
                for (uint256 j = 0; j < roster.length; j++) {
                    lpPoints += roster[j].points;
                }
                
                if (lpPoints > 0) {
                    uint256 share = (pool * lpPoints) / totalPoints;
                    claimable[lp] += share;
                    totalClaimable += share;
                }
            }
        }
        // If totalPoints == 0, the prizePool remains in the contract and will be carried over to the next season.
        
        emit SeasonSettled(currentSeasonId, totalPoints, season.prizePool);
    }

    /// @notice LPs call this to stake MRLV and draft a trader for the current season.
    function stakePick(address trader, uint256 amount) external {
        Season storage season = seasons[currentSeasonId];
        if (season.status != SeasonStatus.DRAFTING) revert InvalidSeasonStatus();
        if (amount == 0) revert ZeroStake();

        // Collect the stake entry fee
        mrlvToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Add to prize pool
        season.prizePool += amount;

        // Add to participants list if not already
        if (!hasJoined[msg.sender][currentSeasonId]) {
            hasJoined[msg.sender][currentSeasonId] = true;
            season.participants.push(msg.sender);
        }

        // Delegate to ScoutRoster (which validates 1-3 picks and duplicates)
        scoutRoster.stakePick(msg.sender, trader, currentSeasonId, amount);
    }

    /// @notice Permissionless top-up of the current season's prize pool.
    function topUpPrizePool(uint256 amount) external {
        Season storage season = seasons[currentSeasonId];
        // Can only top-up during drafting or active phases.
        if (season.status == SeasonStatus.SETTLED) revert InvalidSeasonStatus();
        if (amount == 0) revert ZeroStake();

        mrlvToken.safeTransferFrom(msg.sender, address(this), amount);
        season.prizePool += amount;

        emit PrizePoolToppedUp(currentSeasonId, amount);
    }

    /// @notice Pull-based claim for winning LPs.
    function claimRewards() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        mrlvToken.safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    function getSeasonParticipants(uint256 seasonId) external view returns (address[] memory) {
        return seasons[seasonId].participants;
    }
}
