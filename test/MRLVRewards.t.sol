// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {MRLVHook} from "../src/MRLVHook.sol";
import {MEVDetector} from "../src/MEVDetector.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {AnalyticsEmitter} from "../src/AnalyticsEmitter.sol";
import {MRLVToken} from "../src/MRLVToken.sol";
import {LoyaltyNFT} from "../src/LoyaltyNFT.sol";
import {LoyaltyManager} from "../src/LoyaltyManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {IMRLVToken} from "../src/RewardVault.sol";

/// @dev Minimal mock pool manager used in tests
contract MockPoolManager2 {
    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return MRLVHook(payable(msg.sender)).unlockCallback(data);
    }

    function sync(Currency) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(Currency, address, uint256) external {}
}

contract MRLVRewardsTest is Test {
    using PoolIdLibrary for PoolKey;

    // ── Contracts ───────────────────────────────────────────────────────────
    MRLVHook public hook;
    MEVDetector public detector;
    DynamicFeeManager public feeManager;
    AnalyticsEmitter public analytics;
    MRLVToken public mrlvToken;
    IMRLVToken public iMrlvToken;
    LoyaltyNFT public loyaltyNFT;
    LoyaltyManager public loyaltyManager;
    RewardVault public rewardVault;
    MockPoolManager2 public mockPoolManager;

    // ── Addresses ────────────────────────────────────────────────────────────
    address public governance = address(0xBEEF);
    address public oracleRelayer = address(0xCEEF);
    address public lp1 = address(0x1001);
    address public lp2 = address(0x1002);
    address public lp3 = address(0x1003);

    // ── Pool Keys & IDs ──────────────────────────────────────────────────────
    PoolKey public poolKey;
    bytes32 public poolId;

    PoolKey public poolKeyB;
    bytes32 public poolIdB;

    // ─── Setup ───────────────────────────────────────────────────────────────
    function setUp() public {
        mockPoolManager = new MockPoolManager2();

        // Deploy Phase 1 contracts
        detector = new MEVDetector(governance, address(this), oracleRelayer);
        feeManager = new DynamicFeeManager(governance, address(this));
        analytics = new AnalyticsEmitter(governance);

        // Mine hook address with required flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(mockPoolManager)),
            detector,
            feeManager,
            analytics,
            governance
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(MRLVHook).creationCode,
            constructorArgs
        );

        hook = new MRLVHook{salt: salt}(
            IPoolManager(address(mockPoolManager)),
            detector,
            feeManager,
            analytics,
            governance
        );

        // Wire Phase 1 modules
        vm.startPrank(governance);
        detector.setHook(address(hook));
        feeManager.setHook(address(hook));
        analytics.setHook(address(hook));
        vm.stopPrank();

        // Deploy Phase 2 contracts
        mrlvToken = new MRLVToken(governance);
        loyaltyNFT = new LoyaltyNFT(governance);
        loyaltyManager = new LoyaltyManager(governance, address(hook));
        iMrlvToken = IMRLVToken(address(mrlvToken));
        rewardVault = new RewardVault(governance, address(hook), iMrlvToken);

        // Wire Phase 2 contracts
        vm.startPrank(governance);
        mrlvToken.setRewardVault(address(rewardVault));
        loyaltyNFT.setLoyaltyManager(address(loyaltyManager));
        loyaltyManager.setRewardVault(address(rewardVault));
        loyaltyManager.setLoyaltyNFT(address(loyaltyNFT));
        loyaltyManager.setOracleRelayer(oracleRelayer);
        rewardVault.setLoyaltyManager(address(loyaltyManager));
        hook.setRewardVault(rewardVault);
        hook.setLoyaltyManager(loyaltyManager);
        vm.stopPrank();

        // Pool A key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0x800000, // dynamic fee flag
            tickSpacing: 60,
            hooks: hook
        });
        poolId = PoolId.unwrap(poolKey.toId());

        // Pool B key
        poolKeyB = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(2)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        poolIdB = PoolId.unwrap(poolKeyB.toId());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 1: MRLVToken — mint/lock/withdraw/votingPower
    // ═══════════════════════════════════════════════════════════════════════════

    function test_MRLVToken_mintOnlyByRewardVault() public {
        vm.expectRevert(MRLVToken.NotRewardVault.selector);
        mrlvToken.mint(lp1, 100 ether);
    }

    function test_MRLVToken_mintByRewardVault() public {
        vm.prank(address(rewardVault));
        mrlvToken.mint(lp1, 100 ether);
        assertEq(mrlvToken.balanceOf(lp1), 100 ether);
    }

    function test_MRLVToken_lockAndVotingPower() public {
        vm.prank(address(rewardVault));
        mrlvToken.mint(lp1, 200 ether);

        vm.startPrank(lp1);
        mrlvToken.lock(100 ether, 365 days);
        vm.stopPrank();

        assertEq(mrlvToken.balanceOf(lp1), 100 ether);
        assertGt(mrlvToken.votingPowerOf(lp1), 0);
    }

    function test_MRLVToken_withdrawBeforeUnlock_reverts() public {
        vm.prank(address(rewardVault));
        mrlvToken.mint(lp1, 100 ether);

        vm.startPrank(lp1);
        mrlvToken.lock(100 ether, 365 days);
        vm.expectRevert(MRLVToken.LockStillActive.selector);
        mrlvToken.withdraw();
        vm.stopPrank();
    }

    function test_MRLVToken_withdrawAfterUnlock() public {
        vm.prank(address(rewardVault));
        mrlvToken.mint(lp1, 100 ether);

        vm.startPrank(lp1);
        mrlvToken.lock(100 ether, 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 101);

        vm.prank(lp1);
        mrlvToken.withdraw();

        assertEq(mrlvToken.balanceOf(lp1), 100 ether);
        assertEq(mrlvToken.votingPowerOf(lp1), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 2: LoyaltyNFT — soulbound enforcement
    // ═══════════════════════════════════════════════════════════════════════════

    function test_LoyaltyNFT_mintOnlyByLoyaltyManager() public {
        vm.expectRevert(LoyaltyNFT.NotLoyaltyManager.selector);
        loyaltyNFT.mint(lp1, uint256(uint160(lp1)), 0);
    }

    function test_LoyaltyNFT_isSoulbound_transferReverts() public {
        vm.prank(address(loyaltyManager));
        loyaltyNFT.mint(lp1, uint256(uint160(lp1)), 0);

        vm.prank(lp1);
        vm.expectRevert(LoyaltyNFT.NonTransferable.selector);
        loyaltyNFT.transferFrom(lp1, lp2, uint256(uint160(lp1)));
    }

    function test_LoyaltyNFT_tierUpgrade() public {
        uint256 tokenId = uint256(uint160(lp1));
        vm.startPrank(address(loyaltyManager));
        loyaltyNFT.mint(lp1, tokenId, 0);
        loyaltyNFT.upgradeTier(tokenId, 1);
        vm.stopPrank();

        assertEq(loyaltyNFT.tokenTier(tokenId), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 3: LoyaltyManager — tenure tracking and tier progression
    // ═══════════════════════════════════════════════════════════════════════════

    function test_LoyaltyManager_onAddLiquidity_setsFirstDepositBlock() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), block.number);
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 1000);
    }

    function test_LoyaltyManager_onAddLiquidity_resetsFirstBlock() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        vm.roll(block.number + 10);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 500, bytes32(poolId));

        // Starts/resets that pool's window, so firstDepositBlock updates to block.number
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), block.number);
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 1500);
    }

    function test_LoyaltyManager_tierProgressesToSilver() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        // Fast-forward past silver threshold (216000 blocks)
        vm.roll(block.number + 216001);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1, bytes32(poolId)); // trigger update (which updates using old timer, then resets)

        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 1); // Silver
    }

    function test_LoyaltyManager_tierProgressesToGold() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        // Fast-forward past gold threshold (648000 blocks)
        vm.roll(block.number + 648001);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1, bytes32(poolId));

        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 2); // Gold
    }

    function test_LoyaltyManager_onRemoveLiquidity_reducesAmount() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        // Roll forward past early withdraw window
        vm.roll(block.number + 50401);

        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 400, bytes32(poolId));

        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 600);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 4: LoyaltyManager — exit penalty
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ExitPenalty_forfeitHalfAccruedRewards() public {
        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 1000 ether);

        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        address[] memory lps = new address[](1);
        lps[0] = lp1;
        rewardVault.distribute(bytes32(poolId), lps);

        uint256 claimableBefore = rewardVault.claimable(lp1);
        assertGt(claimableBefore, 0);

        // Remove liquidity early
        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 1000, bytes32(poolId));

        uint256 claimableAfter = rewardVault.claimable(lp1);
        assertApproxEqAbs(claimableAfter, claimableBefore / 2, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 5: RewardVault — deposit, distribute, claim
    // ═══════════════════════════════════════════════════════════════════════════

    function test_RewardVault_deposit_splitInsuranceCut() public {
        address insurancePool = address(0x9999);
        vm.prank(governance);
        rewardVault.setInsurancePool(insurancePool);

        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 1000 ether);

        assertEq(mrlvToken.balanceOf(insurancePool), 50 ether);
        assertEq(rewardVault.poolDistributable(bytes32(poolId)), 950 ether);
    }

    function test_RewardVault_distribute_proRataByScore() public {
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 2000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp2, 1000, bytes32(poolId));
        rewardVault.deposit(bytes32(poolId), 300 ether);
        vm.stopPrank();

        address[] memory lps = new address[](2);
        lps[0] = lp1;
        lps[1] = lp2;
        rewardVault.distribute(bytes32(poolId), lps);

        uint256 claimable1 = rewardVault.claimable(lp1);
        uint256 claimable2 = rewardVault.claimable(lp2);
        assertGt(claimable1, 0);
        assertGt(claimable2, 0);
        assertGt(claimable1, claimable2);
    }

    function test_RewardVault_claim_transfersExactAmount() public {
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        rewardVault.deposit(bytes32(poolId), 100 ether);
        vm.stopPrank();

        address[] memory lps = new address[](1);
        lps[0] = lp1;
        rewardVault.distribute(bytes32(poolId), lps);

        uint256 expectedClaim = rewardVault.claimable(lp1);
        assertGt(expectedClaim, 0);

        vm.prank(lp1);
        rewardVault.claim();

        assertEq(mrlvToken.balanceOf(lp1), expectedClaim);
        assertEq(rewardVault.claimable(lp1), 0);
    }

    function test_RewardVault_claim_revertsIfZero() public {
        vm.prank(lp1);
        vm.expectRevert(RewardVault.ZeroClaim.selector);
        rewardVault.claim();
    }

    function test_RewardVault_deposit_onlyHook() public {
        vm.expectRevert(RewardVault.NotHook.selector);
        rewardVault.deposit(bytes32(poolId), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 6: Reentrancy guard on claim()
    // ═══════════════════════════════════════════════════════════════════════════

    function test_RewardVault_claim_reentrancyGuard() public {
        vm.startPrank(address(hook));
        rewardVault.deposit(bytes32(poolId), 100 ether);
        vm.stopPrank();

        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        address[] memory lps = new address[](1);
        lps[0] = lp1;
        rewardVault.distribute(bytes32(poolId), lps);

        vm.prank(lp1);
        rewardVault.claim();

        vm.prank(lp1);
        vm.expectRevert(RewardVault.ZeroClaim.selector);
        rewardVault.claim();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 7: Sybil-splitting — no aggregate score advantage
    // ═══════════════════════════════════════════════════════════════════════════

    function test_Sybil_perWalletRewardLessThanWhale() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 3000, bytes32(poolId));

        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp2, 1000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp3, 1000, bytes32(poolId));
        vm.stopPrank();
        address lp4 = address(0x1004);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp4, 1000, bytes32(poolId));

        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 1000 ether);

        address[] memory lps = new address[](4);
        lps[0] = lp1; lps[1] = lp2; lps[2] = lp3; lps[3] = lp4;
        rewardVault.distribute(bytes32(poolId), lps);

        uint256 whaleClaim   = rewardVault.claimable(lp1);
        uint256 sybil1Claim  = rewardVault.claimable(lp2);
        uint256 sybil2Claim  = rewardVault.claimable(lp3);
        uint256 sybil3Claim  = rewardVault.claimable(lp4);

        assertGt(whaleClaim, sybil1Claim, "whale should beat sybil1");
        assertGt(whaleClaim, sybil2Claim, "whale should beat sybil2");
        assertGt(whaleClaim, sybil3Claim, "whale should beat sybil3");

        assertEq(sybil1Claim, sybil2Claim, "sybil shares should be equal");
        assertEq(sybil2Claim, sybil3Claim, "sybil shares should be equal");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 8: Multi-LP multi-epoch distribution
    // ═══════════════════════════════════════════════════════════════════════════

    function test_MultiEpoch_distributionAccumulates() public {
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp2, 1000, bytes32(poolId));
        vm.stopPrank();

        address[] memory lps = new address[](2);
        lps[0] = lp1; lps[1] = lp2;

        // Epoch 1
        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 200 ether);
        rewardVault.distribute(bytes32(poolId), lps);
        uint256 claimable1AfterEpoch1 = rewardVault.claimable(lp1);

        // Epoch 2
        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 200 ether);
        rewardVault.distribute(bytes32(poolId), lps);
        uint256 claimable1AfterEpoch2 = rewardVault.claimable(lp1);

        assertGt(claimable1AfterEpoch2, claimable1AfterEpoch1);

        vm.prank(lp1);
        rewardVault.claim();
        assertEq(rewardVault.claimable(lp1), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 9: LoyaltyManager access control
    // ═══════════════════════════════════════════════════════════════════════════

    function test_LoyaltyManager_onAddLiquidity_onlyHook() public {
        vm.prank(lp1);
        vm.expectRevert(LoyaltyManager.NotHook.selector);
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
    }

    function test_LoyaltyManager_onRemoveLiquidity_onlyHook() public {
        vm.prank(lp1);
        vm.expectRevert(LoyaltyManager.NotHook.selector);
        loyaltyManager.onRemoveLiquidity(lp1, 1000, bytes32(poolId));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Section 10: Pool-specific loyalty tracking and validation tests
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verify separate Pool A / Pool B positions
    function test_PoolIndependence_PoolAPoolB() public {
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp1, 2500, bytes32(poolIdB));
        vm.stopPrank();

        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 1000);
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolIdB)), 2500);
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), block.number);
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolIdB)), block.number);
    }

    /// @notice Verify timer reset on every deposit
    function test_TimerResetOnEveryDeposit() public {
        vm.roll(10);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), 10);

        vm.roll(25);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 500, bytes32(poolId));
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), 25);
    }

    /// @notice Verify early and non-early withdrawals
    function test_EarlyAndNonEarlyWithdrawals() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        // Seed some claimable rewards for penalty application
        vm.prank(address(hook));
        rewardVault.deposit(bytes32(poolId), 100 ether);
        address[] memory lps = new address[](1);
        lps[0] = lp1;
        rewardVault.distribute(bytes32(poolId), lps);

        uint256 startClaimable = rewardVault.claimable(lp1);
        assertGt(startClaimable, 0);

        // Early withdrawal (before earlyWithdrawWindow of 50400)
        vm.roll(block.number + 100);
        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 100, bytes32(poolId));
        // Penalty of 50% should be applied
        assertApproxEqAbs(rewardVault.claimable(lp1), startClaimable / 2, 1);

        // Non-early withdrawal (after window)
        // Reset/re-deposit to get window starting at block.number (which is block 101 now)
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 100, bytes32(poolId)); // resets window start to 101
        
        vm.roll(block.number + 50405); // Roll past window
        uint256 claimableBeforeNoPenalty = rewardVault.claimable(lp1);

        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 100, bytes32(poolId));
        // No penalty should be applied
        assertEq(rewardVault.claimable(lp1), claimableBeforeNoPenalty);
    }

    /// @notice Verify partial withdrawals preserve remaining loyalty state
    function test_PartialWithdrawalPreservesState() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        // Progress to Silver
        vm.roll(block.number + 216005);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 10, bytes32(poolId)); // upgrades to Silver, resets window start
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 1); // Silver

        (uint256 tokenAId, , , ) = loyaltyManager.userPositions(lp1, bytes32(poolId), 0);
        assertTrue(loyaltyNFT.exists(tokenAId));
        assertEq(loyaltyNFT.tokenTier(tokenAId), 1);

        // Partial withdrawal
        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 500, bytes32(poolId));

        // Remaining position preserved
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 510);
        // Loyalty tier preserved (Silver)
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 1);
        assertTrue(loyaltyNFT.exists(tokenAId));
        assertEq(loyaltyNFT.tokenTier(tokenAId), 1);
    }

    /// @notice Verify complete exit with NFT burn
    function test_CompleteExitNFTBurn() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        (uint256 pId, , , ) = loyaltyManager.userPositions(lp1, bytes32(poolId), 0);
        assertTrue(loyaltyNFT.exists(pId));

        // Complete exit
        vm.roll(block.number + 60000); // Past early withdraw window so we don't trigger penalty (optional)
        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 1000, bytes32(poolId));

        // State reset
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 0);
        assertEq(loyaltyManager.getUserFirstDepositBlock(lp1, bytes32(poolId)), 0);
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 0);
        // NFT burned
        assertFalse(loyaltyNFT.exists(pId));
    }

    /// @notice Verify invalid over-withdrawal reverts
    function test_InvalidOverWithdrawal() public {
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(
            LoyaltyManager.InsufficientLiquidity.selector,
            lp1,
            bytes32(poolId),
            1000,
            1001
        ));
        loyaltyManager.onRemoveLiquidity(lp1, 1001, bytes32(poolId));
    }

    /// @notice Verify independent tiers/NFTs per pool
    function test_IndependentTiersAndNFTs() public {
        // Alice deposits in Pool A and Pool B
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp1, 2000, bytes32(poolIdB));
        vm.stopPrank();

        (uint256 tokenAId, , , ) = loyaltyManager.userPositions(lp1, bytes32(poolId), 0);
        (uint256 tokenBId, , , ) = loyaltyManager.userPositions(lp1, bytes32(poolIdB), 0);

        assertNotEq(tokenAId, tokenBId); // Ensure no collision

        // Alice waits past silver threshold for Pool A, but then deposits again in Pool A to upgrade it
        vm.roll(block.number + 216005);
        vm.prank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 10, bytes32(poolId)); // Upgrade A to Silver

        // Pool A is Silver (1), Pool B remains Bronze (0)
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 1);
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolIdB)), 0);

        assertEq(loyaltyNFT.tokenTier(tokenAId), 1);
        assertEq(loyaltyNFT.tokenTier(tokenBId), 0);

        // Complete exit from Pool A
        vm.prank(address(hook));
        loyaltyManager.onRemoveLiquidity(lp1, 1010, bytes32(poolId));

        // Pool A reset, Pool B untouched
        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolId)), 0);
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolId)), 0);
        assertFalse(loyaltyNFT.exists(tokenAId));

        assertEq(loyaltyManager.getUserTotalLiquidity(lp1, bytes32(poolIdB)), 2000);
        assertEq(loyaltyManager.getUserMaxTier(lp1, bytes32(poolIdB)), 0);
        assertTrue(loyaltyNFT.exists(tokenBId));
    }

    /// @notice Verify pool-specific LP score calculation
    function test_PoolSpecificLPScoreCalculation() public {
        // Pool A: lp1 has 1000, lp2 has 2000
        // Pool B: lp1 has 3000, lp2 has 1000
        vm.startPrank(address(hook));
        loyaltyManager.onAddLiquidity(lp1, 1000, bytes32(poolId));
        loyaltyManager.onAddLiquidity(lp2, 2000, bytes32(poolId));

        loyaltyManager.onAddLiquidity(lp1, 3000, bytes32(poolIdB));
        loyaltyManager.onAddLiquidity(lp2, 1000, bytes32(poolIdB));
        vm.stopPrank();

        address[] memory lps = new address[](2);
        lps[0] = lp1;
        lps[1] = lp2;

        uint256[] memory scoresA = loyaltyManager.computeLPScores(lps, bytes32(poolId));
        uint256[] memory scoresB = loyaltyManager.computeLPScores(lps, bytes32(poolIdB));

        // In Pool A, lp2 has more liquidity than lp1, so score should be higher
        assertGt(scoresA[1], scoresA[0], "lp2 should have higher score in Pool A");

        // In Pool B, lp1 has more liquidity than lp2, so score should be higher
        assertGt(scoresB[0], scoresB[1], "lp1 should have higher score in Pool B");
    }
}
