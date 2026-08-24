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

    mapping(address => mapping(bytes32 => uint256)) public firstDepositBlock;
    mapping(address => mapping(bytes32 => uint256)) public liquidityAmount;
    mapping(address => mapping(bytes32 => uint8)) public tier; // 0 = Bronze, 1 = Silver, 2 = Gold
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
 // 100 + 50
    /// @notice Handler for adding liquidity
    function onAddLiquidity(address lp, uint128 liquidity, bytes32 poolId) external onlyHook {
        if (firstDepositBlock[lp][poolId] == 0) {
            firstDepositBlock[lp][poolId] = block.number;
            _updateTierAndNFT(lp, poolId);
        } else {
            _updateTierAndNFT(lp, poolId); // silver 
            firstDepositBlock[lp][poolId] = block.number; // bronze 
        }
        // 100 + 50 = 150 
        liquidityAmount[lp][poolId] += liquidity;
        poolLiquidity[poolId] += liquidity;
    }

    /// @notice Handler for removing liquidity
    function onRemoveLiquidity(address lp, uint128 liquidity, bytes32 poolId) external onlyHook {
        uint256 currentAmount = liquidityAmount[lp][poolId];
        if (currentAmount < liquidity) {
            revert InsufficientLiquidity(lp, poolId, currentAmount, liquidity);
        }
        liquidityAmount[lp][poolId] = currentAmount - liquidity;
        poolLiquidity[poolId] = poolLiquidity[poolId] >= liquidity ? poolLiquidity[poolId] - liquidity : 0;

        uint256 startBlock = firstDepositBlock[lp][poolId];
        if (startBlock > 0 && block.number - startBlock < earlyWithdrawWindow) {
            if (rewardVault != address(0)) {
                IRewardVault(rewardVault).applyExitPenalty(lp, poolId);
            }
            emit ExitPenaltyApplied(lp, poolId, block.number);
        }

        if (liquidityAmount[lp][poolId] == 0) {
            firstDepositBlock[lp][poolId] = 0;
            tier[lp][poolId] = 0;
            if (loyaltyNFT != address(0)) {
                uint256 tokenId = uint256(keccak256(abi.encodePacked(lp, poolId)));
                if (ILoyaltyNFT(loyaltyNFT).exists(tokenId)) {
                    ILoyaltyNFT(loyaltyNFT).burn(tokenId);
                }
            }
        }
        // if the LP only partially withdraws, preserve the remaining pool position and its loyalty state
    }

    /// @notice Updates LP's tier and mints or upgrades their loyalty NFT.
    function _updateTierAndNFT(address lp, bytes32 poolId) internal {
        uint256 startBlock = firstDepositBlock[lp][poolId]; // 100  - 35 days 
        if (startBlock == 0) return;

        uint256 duration = block.number - startBlock;  // 35 days 
        uint8 newTier = 0;
        if (duration >= goldThresholdBlocks) {
            newTier = 2;
        } else if (duration >= silverThresholdBlocks) {
            newTier = 1; // silver 
        }

        uint8 oldTier = tier[lp][poolId]; // bronze 
        if (newTier != oldTier) {
            tier[lp][poolId] = newTier; // bronze to silver 
            emit TierUpgraded(lp, poolId, newTier);
        }

        if (loyaltyNFT != address(0)) {
            uint256 tokenId = uint256(keccak256(abi.encodePacked(lp, poolId)));
            if (!ILoyaltyNFT(loyaltyNFT).exists(tokenId)) {
                ILoyaltyNFT(loyaltyNFT).mint(lp, tokenId, newTier);
            } else {
                ILoyaltyNFT(loyaltyNFT).upgradeTier(tokenId, newTier);
            }
        }
    }

    /// @notice Helper to compute raw metrics and normalized LP scores for a set of LPs in a pool.
    function computeLPScores(address[] calldata lps, bytes32 poolId) external view returns (uint256[] memory scores) {
        uint256 len = lps.length;
        scores = new uint256[](len);
        if (len == 0) return scores;

        uint256[] memory amounts = new uint256[](len);
        uint256[] memory durations = new uint256[](len);
        uint256[] memory contributions = new uint256[](len);

        uint256 minAmt = type(uint256).max;
        uint256 maxAmt = 0;
        uint256 minDur = type(uint256).max;
        uint256 maxDur = 0;
        uint256 minContr = type(uint256).max;
        uint256 maxContr = 0;

        uint256 totalPoolLiq = poolLiquidity[poolId];

        // 1. Calculate raw values and find min/max
        for (uint256 i = 0; i < len; i++) {
            address lp = lps[i];
            if (firstDepositBlock[lp][poolId] == 0 || flaggedMalicious[lp]) {
                continue;
            }

            uint256 amt = liquidityAmount[lp][poolId];
            uint256 dur = block.number - firstDepositBlock[lp][poolId];
            uint256 contr = totalPoolLiq == 0 ? 0 : (amt * 10000) / totalPoolLiq;

            amounts[i] = amt;
            durations[i] = dur;
            contributions[i] = contr;

            if (amt < minAmt) minAmt = amt;
            if (amt > maxAmt) maxAmt = amt;

            if (dur < minDur) minDur = dur;
            if (dur > maxDur) maxDur = dur;

            if (contr < minContr) minContr = contr;
            if (contr > maxContr) maxContr = contr;
        }

        // 2. Compute normalized scores using weights: w1=35, w2=30, w3=15, w4=20
        for (uint256 i = 0; i < len; i++) {
            address lp = lps[i];
            if (firstDepositBlock[lp][poolId] == 0 || flaggedMalicious[lp]) {
                scores[i] = 0;
                continue;
            }

            uint256 normAmt = 1e18;
            if (maxAmt > minAmt) {
                normAmt = ((amounts[i] - minAmt) * 1e18) / (maxAmt - minAmt);
            }

            uint256 normDur = 1e18;
            if (maxDur > minDur) {
                normDur = ((durations[i] - minDur) * 1e18) / (maxDur - minDur);
            }

            uint256 normContr = 1e18;
            if (maxContr > minContr) {
                normContr = ((contributions[i] - minContr) * 1e18) / (maxContr - minContr);
            }

            uint256 consistency = consistencyIndex[lp];
            uint256 consistencyTerm = (1e18 * 1e18) / (1e18 + consistency);

            // Calculate base weighted score (scaled by 1e18)
            uint256 baseScore = (35 * normAmt + 30 * normDur + 15 * consistencyTerm + 20 * normContr) / 100;

            // Apply loyalty tier multiplier: Bronze = 1x, Silver = 2x, Gold = 3x
            uint8 lpTier = tier[lp][poolId];
            uint256 multiplier = lpTier == 2 ? 3 : (lpTier == 1 ? 2 : 1);
            scores[i] = baseScore * multiplier;
        }
    }
}
