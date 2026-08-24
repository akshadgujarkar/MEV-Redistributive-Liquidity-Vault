// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILoyaltyNFT {
    function mint(address to, uint256 tokenId, uint8 tier) external;
    function upgradeTier(uint256 tokenId, uint8 newTier) external;
    function burn(uint256 tokenId) external;
    function exists(uint256 tokenId) external view returns (bool);
}

interface IRewardVault {
    function applyExitPenalty(address lp, bytes32 poolId) external;
}

/// @title LoyaltyManager
/// @notice Manages LP tenure, loyalty tiers, NFT badges, and LPScore calculations per pool
contract LoyaltyManager {
    error NotGovernance();
    error NotHook();
    error InvalidThresholds();
    error InsufficientLiquidity(address lp, bytes32 poolId, uint256 available, uint256 requested);

    address public governance;
    address public hook;
    address public rewardVault;
    address public loyaltyNFT;
    address public oracleRelayer;

   //  
    uint256 public earlyWithdrawWindow = 50400; // default 7 days in blocks (assuming 12s blocks)
    uint256 public silverThresholdBlocks = 216000; // default 30 days
    uint256 public goldThresholdBlocks = 648000; // default 90 days

    struct Position {
        uint256 id;
        uint256 amount;
        uint256 startBlock;
        uint8 tier; // 0 = Bronze, 1 = Silver, 2 = Gold
    }

    uint256 public nextPositionId = 1;
    mapping(address => mapping(bytes32 => Position[])) public userPositions;

    mapping(address => uint256) public consistencyIndex;
    mapping(address => bool) public flaggedMalicious;
    mapping(bytes32 => uint256) public poolLiquidity;

    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event RewardVaultUpdated(address indexed newRewardVault);
    event LoyaltyNFTUpdated(address indexed newLoyaltyNFT);
    event OracleRelayerUpdated(address indexed newOracleRelayer);
    event TierUpgraded(address indexed lp, bytes32 indexed poolId, uint8 newTier);
    event ExitPenaltyApplied(address indexed lp, bytes32 indexed poolId, uint256 blockNumber);
    event ConsistencyIndexUpdated(address indexed lp, uint256 newIndex);
    event MaliciousStatusUpdated(address indexed lp, bool flagged);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyOracleRelayerOrGovernance() {
        if (msg.sender != oracleRelayer && msg.sender != governance) revert NotGovernance();
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

    function setRewardVault(address _rewardVault) external onlyGovernance {
        rewardVault = _rewardVault;
        emit RewardVaultUpdated(_rewardVault);
    }

    function setLoyaltyNFT(address _loyaltyNFT) external onlyGovernance {
        loyaltyNFT = _loyaltyNFT;
        emit LoyaltyNFTUpdated(_loyaltyNFT);
    }

    function setOracleRelayer(address _oracleRelayer) external onlyGovernance {
        oracleRelayer = _oracleRelayer;
        emit OracleRelayerUpdated(_oracleRelayer);
    }

    function setThresholds(uint256 _silver, uint256 _gold) external onlyGovernance {
        if (_silver >= _gold) revert InvalidThresholds();
        silverThresholdBlocks = _silver;
        goldThresholdBlocks = _gold;
    }

    function setEarlyWithdrawWindow(uint256 _window) external onlyGovernance {
        earlyWithdrawWindow = _window;
    }

    function setConsistencyIndex(address lp, uint256 index) external onlyOracleRelayerOrGovernance {
        consistencyIndex[lp] = index;
        emit ConsistencyIndexUpdated(lp, index);
    }

    function setFlaggedMalicious(address lp, bool flagged) external onlyOracleRelayerOrGovernance {
        flaggedMalicious[lp] = flagged;
        emit MaliciousStatusUpdated(lp, flagged);
    }

    /// @notice Handler for adding liquidity
    function onAddLiquidity(address lp, uint128 liquidity, bytes32 poolId) external onlyHook {
        uint256 posId = nextPositionId++;
        userPositions[lp][poolId].push(Position({
            id: posId,
            amount: liquidity,
            startBlock: block.number,
            tier: 0
        }));

        if (loyaltyNFT != address(0)) {
            ILoyaltyNFT(loyaltyNFT).mint(lp, posId, 0); // Mint position-specific Bronze NFT
        }

        poolLiquidity[poolId] += liquidity;
    }

    /// @notice Handler for removing liquidity
    function onRemoveLiquidity(address lp, uint128 liquidity, bytes32 poolId) external onlyHook {
        Position[] storage positions = userPositions[lp][poolId];
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            totalAmount += positions[i].amount;
        }
        if (totalAmount < liquidity) {
            revert InsufficientLiquidity(lp, poolId, totalAmount, liquidity);
        }

        uint256 remainingToRemove = liquidity;
        bool appliedPenalty = false;

        // LIFO: start from the newest position (end of the array)
        for (uint256 i = positions.length; i > 0; i--) {
            if (remainingToRemove == 0) break;
            uint256 idx = i - 1;
            Position storage pos = positions[idx];

            if (!appliedPenalty && (block.number - pos.startBlock < earlyWithdrawWindow)) {
                if (rewardVault != address(0)) {
                    IRewardVault(rewardVault).applyExitPenalty(lp, poolId);
                }
                emit ExitPenaltyApplied(lp, poolId, block.number);
                appliedPenalty = true; // Only apply penalty once per tx
            }

            if (pos.amount <= remainingToRemove) {
                remainingToRemove -= pos.amount;
                
                // Burn specific NFT
                if (loyaltyNFT != address(0)) {
                    if (ILoyaltyNFT(loyaltyNFT).exists(pos.id)) {
                        ILoyaltyNFT(loyaltyNFT).burn(pos.id);
                    }
                }

                // Remove from array 
                positions.pop();
            } else {
                pos.amount -= remainingToRemove;
                remainingToRemove = 0;
            }
        }

        poolLiquidity[poolId] = poolLiquidity[poolId] >= liquidity ? poolLiquidity[poolId] - liquidity : 0;
    }

    /// @notice Upgrades LP's tiers and their loyalty NFTs for all their positions in a pool.
    function refreshTiers(address lp, bytes32 poolId) public {
        Position[] storage positions = userPositions[lp][poolId];
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 startBlock = positions[i].startBlock;
            if (startBlock == 0) continue;

            uint256 duration = block.number - startBlock;
            uint8 newTier = 0;
            if (duration >= goldThresholdBlocks) {
                newTier = 2;
            } else if (duration >= silverThresholdBlocks) {
                newTier = 1;
            }

            uint8 oldTier = positions[i].tier;
            if (newTier != oldTier) {
                positions[i].tier = newTier;
                emit TierUpgraded(lp, poolId, newTier);

                if (loyaltyNFT != address(0)) {
                    uint256 tokenId = positions[i].id;
                    if (ILoyaltyNFT(loyaltyNFT).exists(tokenId)) {
                        ILoyaltyNFT(loyaltyNFT).upgradeTier(tokenId, newTier);
                    }
                }
            }
        }
    }

    /// @notice Helper to compute raw metrics and normalized LP scores for a set of LPs in a pool.
    function computeLPScores(address[] calldata lps, bytes32 poolId) external view returns (uint256[] memory scores) {
        uint256 len = lps.length;
        scores = new uint256[](len);
        if (len == 0) return scores;

        uint256 minAmt = type(uint256).max;
        uint256 maxAmt = 0;
        uint256 minDur = type(uint256).max;
        uint256 maxDur = 0;
        uint256 minContr = type(uint256).max;
        uint256 maxContr = 0;

        uint256 totalPoolLiq = poolLiquidity[poolId];

        // 1. Calculate raw values and find min/max across all positions
        for (uint256 i = 0; i < len; i++) {
            address lp = lps[i];
            if (flaggedMalicious[lp]) continue;

            Position[] storage positions = userPositions[lp][poolId];
            for (uint256 j = 0; j < positions.length; j++) {
                uint256 amt = positions[j].amount;
                uint256 dur = block.number - positions[j].startBlock;
                uint256 contr = totalPoolLiq == 0 ? 0 : (amt * 10000) / totalPoolLiq;

                if (amt < minAmt) minAmt = amt;
                if (amt > maxAmt) maxAmt = amt;
                if (dur < minDur) minDur = dur;
                if (dur > maxDur) maxDur = dur;
                if (contr < minContr) minContr = contr;
                if (contr > maxContr) maxContr = contr;
            }
        }

        // 2. Compute normalized scores per position and sum them up
        for (uint256 i = 0; i < len; i++) {
            address lp = lps[i];
            if (flaggedMalicious[lp]) {
                scores[i] = 0;
                continue;
            }

            uint256 consistency = consistencyIndex[lp];
            uint256 consistencyTerm = (1e18 * 1e18) / (1e18 + consistency);

            uint256 totalLPScore = 0;
            Position[] storage positions = userPositions[lp][poolId];
            
            for (uint256 j = 0; j < positions.length; j++) {
                uint256 amt = positions[j].amount;
                uint256 dur = block.number - positions[j].startBlock;
                uint256 contr = totalPoolLiq == 0 ? 0 : (amt * 10000) / totalPoolLiq;

                uint256 normAmt = 1e18;
                if (maxAmt > minAmt) {
                    normAmt = ((amt - minAmt) * 1e18) / (maxAmt - minAmt);
                }

                uint256 normDur = 1e18;
                if (maxDur > minDur) {
                    normDur = ((dur - minDur) * 1e18) / (maxDur - minDur);
                }

                uint256 normContr = 1e18;
                if (maxContr > minContr) {
                    normContr = ((contr - minContr) * 1e18) / (maxContr - minContr);
                }

                // Calculate base weighted score for this position (scaled by 1e18)
                uint256 posBaseScore = (35 * normAmt + 30 * normDur + 15 * consistencyTerm + 20 * normContr) / 100;

                uint8 posTier = 0;
                if (dur >= goldThresholdBlocks) {
                    posTier = 2;
                } else if (dur >= silverThresholdBlocks) {
                    posTier = 1;
                }
                uint256 multiplier = posTier == 2 ? 3 : (posTier == 1 ? 2 : 1);
                
                totalLPScore += posBaseScore * multiplier;
            }
            
            scores[i] = totalLPScore;
        }
    }

    function getUserPositionsLength(address lp, bytes32 poolId) external view returns (uint256) {
        return userPositions[lp][poolId].length;
    }

    function getUserTotalLiquidity(address lp, bytes32 poolId) external view returns (uint256 total) {
        Position[] storage positions = userPositions[lp][poolId];
        for (uint256 i = 0; i < positions.length; i++) {
            total += positions[i].amount;
        }
    }
    
    function getUserFirstDepositBlock(address lp, bytes32 poolId) external view returns (uint256) {
        Position[] storage positions = userPositions[lp][poolId];
        if (positions.length == 0) return 0;
        return positions[0].startBlock;
    }

    function getUserMaxTier(address lp, bytes32 poolId) external view returns (uint8 maxTier) {
        Position[] storage positions = userPositions[lp][poolId];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tier > maxTier) {
                maxTier = positions[i].tier;
            }
        }
    }

}