// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MRLVToken} from "../src/MRLVToken.sol";
import {ScoutRoster} from "../src/fantasy-league/ScoutRoster.sol";
import {ScoutPointsOracle} from "../src/fantasy-league/ScoutPointsOracle.sol";
import {MEVScoutLeague} from "../src/fantasy-league/MEVScoutLeague.sol";

contract MockRewardVault {
    MRLVToken public mrlv;
    constructor(MRLVToken _mrlv) {
        mrlv = _mrlv;
    }
    function mintTo(address to, uint256 amount) external {
        mrlv.mint(to, amount);
    }
}

contract FantasyLeagueTest is Test {
    MRLVToken public mrlv;
    MockRewardVault public mockVault;
    
    ScoutRoster public roster;
    ScoutPointsOracle public oracle;
    MEVScoutLeague public league;

    address public owner = address(this);
    address public relayer = address(0x1111);
    
    address public lp1 = address(0x1001);
    address public lp2 = address(0x1002);
    address public lp3 = address(0x1003);

    address public traderA = address(0xA001);
    address public traderB = address(0xB002);
    address public traderC = address(0xC003);

    function setUp() public {
        mrlv = new MRLVToken(owner);
        mockVault = new MockRewardVault(mrlv);
        mrlv.setRewardVault(address(mockVault));

        league = new MEVScoutLeague(mrlv, ScoutRoster(address(0))); // Temporary
        roster = new ScoutRoster(address(league));
        
        // Re-deploy league with actual roster
        league = new MEVScoutLeague(mrlv, roster);
        
        oracle = new ScoutPointsOracle(relayer, roster);
        
        // Wire them up
        roster = new ScoutRoster(address(league));
        league = new MEVScoutLeague(mrlv, roster);
        oracle = new ScoutPointsOracle(relayer, roster);
        roster.setPointsOracle(address(oracle));

        // Fund LPs
        mockVault.mintTo(lp1, 1000 ether);
        mockVault.mintTo(lp2, 1000 ether);
        mockVault.mintTo(lp3, 1000 ether);

        vm.startPrank(lp1);
        mrlv.approve(address(league), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp2);
        mrlv.approve(address(league), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp3);
        mrlv.approve(address(league), type(uint256).max);
        vm.stopPrank();
    }

    function test_SeasonLifecycle_And_Drafting() public {
        // Start season
        league.startSeason();
        assertEq(league.currentSeasonId(), 1);
        (uint256 id, uint8 status, uint256 prizePool, uint256 totalPoints) = league.seasons(1);
        assertEq(uint8(status), 0); // DRAFTING

        // LP1 stakes for TraderA
        vm.prank(lp1);
        league.stakePick(traderA, 100 ether);
        
        (, , prizePool, ) = league.seasons(1);
        assertEq(prizePool, 100 ether);
        
        // LP2 stakes for TraderB
        vm.prank(lp2);
        league.stakePick(traderB, 200 ether);

        // Lock Season
        league.lockSeason();
        (, status, , ) = league.seasons(1);
        assertEq(uint8(status), 1); // ACTIVE

        // Try to draft after lock (should fail)
        vm.expectRevert();
        vm.prank(lp3);
        league.stakePick(traderC, 100 ether);

        // Oracle reports a detection for TraderA (Reversal)
        address[] memory lpsForA = new address[](1);
        lpsForA[0] = lp1;

        vm.prank(relayer);
        oracle.reportDetection(traderA, 1, keccak256("REVERSAL"), lpsForA);

        // Settle Season
        league.settleSeason();
        (, status, prizePool, totalPoints) = league.seasons(1);
        assertEq(uint8(status), 2); // SETTLED
        assertEq(totalPoints, 30); // 30 points from REVERSAL

        // LP1 should have 100% of the claimable pool (300 ether)
        assertEq(league.claimable(lp1), 300 ether);
        assertEq(league.claimable(lp2), 0); // Scored 0

        // Claim
        vm.prank(lp1);
        league.claimRewards();
        
        assertEq(mrlv.balanceOf(lp1), 1200 ether); // 1000 - 100 (stake) + 300 (win) = 1200
    }
    
    function test_TopUpPrizePool() public {
        league.startSeason();
        
        vm.prank(lp1);
        league.stakePick(traderA, 100 ether);
        
        // Random LP tops up pool
        vm.prank(lp3);
        league.topUpPrizePool(500 ether);
        
        (,, uint256 prizePool, ) = league.seasons(1);
        assertEq(prizePool, 600 ether); // 100 stake + 500 topUp
    }
    
    function test_LeftoverCarryOver_OnZeroPoints() public {
        league.startSeason();
        
        vm.prank(lp1);
        league.stakePick(traderA, 100 ether);
        
        league.lockSeason();
        league.settleSeason(); // No points scored
        
        // Claimable should be 0
        assertEq(league.claimable(lp1), 0);
        
        // Start next season
        league.startSeason();
        
        // Leftover prize pool should carry over
        (,, uint256 prizePool2, ) = league.seasons(2);
        assertEq(prizePool2, 100 ether);
    }
    
    function test_ProportionalPayouts() public {
        league.startSeason();
        
        vm.prank(lp1);
        league.stakePick(traderA, 100 ether); // Pool = 100
        
        vm.prank(lp2);
        league.stakePick(traderB, 100 ether); // Pool = 200
        
        vm.prank(lp3);
        league.stakePick(traderC, 100 ether); // Pool = 300
        
        league.lockSeason();
        
        // TraderA flagged for PriorityFee (25)
        address[] memory lpsA = new address[](1); lpsA[0] = lp1;
        vm.prank(relayer);
        oracle.reportDetection(traderA, 1, keccak256("PRIORITY_FEE"), lpsA);
        
        // TraderB flagged for Reversal (30)
        address[] memory lpsB = new address[](1); lpsB[0] = lp2;
        vm.prank(relayer);
        oracle.reportDetection(traderB, 1, keccak256("REVERSAL"), lpsB);
        
        // TraderB flagged for PriceImpact (20)
        vm.prank(relayer);
        oracle.reportDetection(traderB, 1, keccak256("PRICE_IMPACT"), lpsB);
        
        // total points: LP1=25, LP2=50, LP3=0. Total = 75
        
        league.settleSeason();
        
        // Pool is 300 ether
        // LP1 share: (300 * 25) / 75 = 100 ether
        // LP2 share: (300 * 50) / 75 = 200 ether
        // LP3 share: 0
        
        assertEq(league.claimable(lp1), 100 ether);
        assertEq(league.claimable(lp2), 200 ether);
        assertEq(league.claimable(lp3), 0 ether);
        
        // All time scores
        assertEq(oracle.allTimeScoutScore(lp1), 25);
        assertEq(oracle.allTimeScoutScore(lp2), 50);
        assertEq(oracle.allTimeScoutScore(lp3), 0);
    }
}
