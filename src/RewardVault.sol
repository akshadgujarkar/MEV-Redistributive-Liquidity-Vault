// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMRLVToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface ILoyaltyManager {
    function computeLPScores(address[] calldata lps, bytes32 poolId) external view returns (uint256[] memory);
}

/// @title RewardVault
/// @notice Escrows captured MEV fee surcharges and handles epoch-based distributions
contract RewardVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotGovernance();
    error NotHook();
    error NotLoyaltyManager();
    error ZeroClaim();
    error InvalidInsuranceBps();

    address public governance;
    address public hook;
    address public loyaltyManager;
    address public insurancePool;
    uint16 public insuranceBps = 500; // default 5% (500 bps)

    IMRLVToken public mrlvToken;

    mapping(address => uint256) public claimable;
    uint256 public totalCaptured;
    uint256 public totalDistributed;
    uint256 public penaltyReserves;

    mapping(bytes32 => uint256) public poolCapturedTotal;
    mapping(bytes32 => uint256) public poolDistributable;

    event GovernanceUpdated(address indexed newGovernance);
    event HookUpdated(address indexed newHook);
    event LoyaltyManagerUpdated(address indexed newLoyaltyManager);
    event InsurancePoolUpdated(address indexed newInsurancePool);
    event InsuranceBpsUpdated(uint16 newBps);
    event Deposited(bytes32 indexed poolId, uint256 amount, uint256 blockNumber);
    event Distributed(bytes32 indexed poolId, uint256 amount);
    event Claimed(address indexed lp, uint256 amount);
    event ExitPenaltyApplied(address indexed lp, uint256 penaltyAmount);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier onlyLoyaltyManager() {
        if (msg.sender != loyaltyManager) revert NotLoyaltyManager();
        _;
    }

    constructor(address _governance, address _hook, IMRLVToken _mrlvToken) {
        governance = _governance;
        hook = _hook;
        mrlvToken = _mrlvToken;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setHook(address _hook) external onlyGovernance {
        hook = _hook;
        emit HookUpdated(_hook);
    }

    function setLoyaltyManager(address _loyaltyManager) external onlyGovernance {
        loyaltyManager = _loyaltyManager;
        emit LoyaltyManagerUpdated(_loyaltyManager);
    }

    function setInsurancePool(address _insurancePool) external onlyGovernance {
        insurancePool = _insurancePool;
        emit InsurancePoolUpdated(_insurancePool);
    }

    function setInsuranceBps(uint16 _bps) external onlyGovernance {
        if (_bps > 10000) revert InvalidInsuranceBps();
        insuranceBps = _bps;
        emit InsuranceBpsUpdated(_bps);
    }

    /// @notice Records a surcharge deposit from a swap.
    function deposit(bytes32 poolId, uint256 amount) external onlyHook {
        totalCaptured += amount;
        poolCapturedTotal[poolId] += amount;

        uint256 insuranceCut = 0;
        if (insurancePool != address(0) && insuranceBps > 0) {
            insuranceCut = (amount * insuranceBps) / 10000;
            if (insuranceCut > 0) {
                mrlvToken.mint(insurancePool, insuranceCut);
            }
        }

        uint256 distributable = amount - insuranceCut;
        poolDistributable[poolId] += distributable;

        emit Deposited(poolId, amount, block.number);
    }

    /// @notice Distributes the pool's collected surcharges to the active LPs pro-rata.
    function distribute(bytes32 poolId, address[] calldata lps) external {
        uint256 amountToDistribute = poolDistributable[poolId];
        if (amountToDistribute == 0) return;

        // Reset the distributable amount to keep it idempotent-safe
        poolDistributable[poolId] = 0;

        uint256[] memory scores = ILoyaltyManager(loyaltyManager).computeLPScores(lps, poolId);
        uint256 totalScore = 0;
        uint256 len = lps.length;
        for (uint256 i = 0; i < len; i++) {
            totalScore += scores[i];
        }

        uint256 totalDistributedThisEpoch = 0;
        if (totalScore > 0) {
            uint256[] memory shares = new uint256[](len);
            for (uint256 i = 0; i < len; i++) {
                shares[i] = (amountToDistribute * scores[i]) / totalScore;
                totalDistributedThisEpoch += shares[i];
            }

            if (totalDistributedThisEpoch > 0) {
                // Use penalty reserves if any, to avoid over-minting
                uint256 amountToMint = 0;
                uint256 reservesUsed = 0;
                if (totalDistributedThisEpoch > penaltyReserves) {
                    amountToMint = totalDistributedThisEpoch - penaltyReserves;
                    reservesUsed = penaltyReserves;
                } else {
                    reservesUsed = totalDistributedThisEpoch;
                }

                penaltyReserves -= reservesUsed;
                if (amountToMint > 0) {
                    mrlvToken.mint(address(this), amountToMint);
                }

                for (uint256 i = 0; i < len; i++) {
                    if (shares[i] > 0) {
                        claimable[lps[i]] += shares[i];
                    }
                }
                totalDistributed += totalDistributedThisEpoch;
            }
        }

        // Return the undistributed dust back to the poolDistributable pool
        poolDistributable[poolId] += (amountToDistribute - totalDistributedThisEpoch);

        emit Distributed(poolId, totalDistributedThisEpoch);
    }

    /// @notice Withdraws claimable MRLV rewards for the caller.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert ZeroClaim();

        claimable[msg.sender] = 0;
        IERC20(address(mrlvToken)).safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    /// @notice Applies an exit penalty (50% reduction) to an LP's accrued rewards.
    function applyExitPenalty(address lp, bytes32 poolId) external onlyLoyaltyManager {
        uint256 accrued = claimable[lp];
        if (accrued > 0) {
            uint256 penalty = accrued / 2;
            claimable[lp] -= penalty;
            penaltyReserves += penalty;
            poolDistributable[poolId] += penalty;

            emit ExitPenaltyApplied(lp, penalty);
        }
    }
}
