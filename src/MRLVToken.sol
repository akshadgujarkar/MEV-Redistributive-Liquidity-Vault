// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MRLVToken
/// @notice ERC-20 reward and governance token (veMRLV style lockable)
contract MRLVToken is ERC20 {
    error NotGovernance();
    error NotRewardVault();
    error LockDurationZero();
    error LockAmountZero();
    error LockStillActive();
    error NoActiveLock();

    struct LockInfo {
        uint256 amount;
        uint256 unlockTime;
        uint256 votingPower;
    }

    address public governance;
    address public rewardVault;

    mapping(address => LockInfo) public locks;

    event GovernanceUpdated(address indexed newGovernance);
    event RewardVaultUpdated(address indexed newRewardVault);
    event Locked(address indexed user, uint256 amount, uint256 unlockTime, uint256 votingPower);
    event Unlocked(address indexed user, uint256 amount);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyRewardVault() {
        if (msg.sender != rewardVault) revert NotRewardVault();
        _;
    }

    constructor(address _governance) ERC20("MEV-Redistributive Liquidity Vault", "MRLV") {
        governance = _governance;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setRewardVault(address _rewardVault) external onlyGovernance {
        rewardVault = _rewardVault;
        emit RewardVaultUpdated(_rewardVault);
    }

    /// @notice Mints tokens to a recipient. Only callable by the RewardVault.
    function mint(address to, uint256 amount) external onlyRewardVault {
        _mint(to, amount);
    }

    /// @notice Locks MRLV tokens to receive governance voting power.
    /// @param amount Amount of MRLV to lock
    /// @param duration Duration in seconds to lock
    function lock(uint256 amount, uint256 duration) external {
        if (amount == 0) revert LockAmountZero();
        if (duration == 0) revert LockDurationZero();

        LockInfo storage userLock = locks[msg.sender];

        // Transfer tokens from user to this contract
        _transfer(msg.sender, address(this), amount);

        uint256 newAmount = userLock.amount + amount;
        uint256 newUnlockTime = block.timestamp + duration;
        if (newUnlockTime < userLock.unlockTime) {
            newUnlockTime = userLock.unlockTime;
        }

        uint256 power = newAmount * duration;

        userLock.amount = newAmount;
        userLock.unlockTime = newUnlockTime;
        userLock.votingPower = power;

        emit Locked(msg.sender, amount, newUnlockTime, power);
    }

    /// @notice Withdraws locked MRLV tokens after the lock period has expired.
    function withdraw() external {
        LockInfo memory userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NoActiveLock();
        if (block.timestamp < userLock.unlockTime) revert LockStillActive();

        delete locks[msg.sender];

        _transfer(address(this), msg.sender, userLock.amount);

        emit Unlocked(msg.sender, userLock.amount);
    }

    /// @notice Returns the current voting power of a user.
    ///         Voting power is active until the unlock time is reached.
    function votingPowerOf(address user) external view returns (uint256) {
        LockInfo memory userLock = locks[user];
        if (block.timestamp >= userLock.unlockTime) {
            return 0;
        }
        return userLock.votingPower;
    }
}
