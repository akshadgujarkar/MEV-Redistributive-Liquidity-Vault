// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title LoyaltyNFT
/// @notice Non-transferable (soulbound) ERC-721 representing LP loyalty tier
contract LoyaltyNFT is ERC721 {
    error NonTransferable();
    error NotGovernance();
    error NotLoyaltyManager();
    error TokenDoesNotExist();

    address public governance;
    address public loyaltyManager;

    mapping(uint256 => uint8) public tokenTier; // 0 = Bronze, 1 = Silver, 2 = Gold

    event GovernanceUpdated(address indexed newGovernance);
    event LoyaltyManagerUpdated(address indexed newLoyaltyManager);
    event TierUpdated(uint256 indexed tokenId, uint8 newTier);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyLoyaltyManager() {
        if (msg.sender != loyaltyManager) revert NotLoyaltyManager();
        _;
    }

    constructor(address _governance) ERC721("MRLV Loyalty Badge", "MRLV-LOYALTY") {
        governance = _governance;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setLoyaltyManager(address _loyaltyManager) external onlyGovernance {
        loyaltyManager = _loyaltyManager;
        emit LoyaltyManagerUpdated(_loyaltyManager);
    }

    /// @notice Mints a new soulbound badge. Only callable by the LoyaltyManager.
    function mint(address to, uint256 tokenId, uint8 tier) external onlyLoyaltyManager {
        _safeMint(to, tokenId);
        tokenTier[tokenId] = tier;
        emit TierUpdated(tokenId, tier);
    }

    /// @notice Upgrades the tier of a badge. Only callable by the LoyaltyManager.
    function upgradeTier(uint256 tokenId, uint8 newTier) external onlyLoyaltyManager {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        tokenTier[tokenId] = newTier;  // bronze to silver 
        emit TierUpdated(tokenId, newTier);
    }

    /// @notice Checks if a token exists.
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Burns a badge when LP completely exits. Only callable by the LoyaltyManager.
    function burn(uint256 tokenId) external onlyLoyaltyManager {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        _burn(tokenId);
        delete tokenTier[tokenId];
    }

    /// @notice Token metadata URI mapping to visual tiers on-chain/IPFS.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        uint8 t = tokenTier[tokenId];
        if (t == 0) return "ipfs://bronze-badge";
        if (t == 1) return "ipfs://silver-badge";
        return "ipfs://gold-badge";
    }

    // ─── Overrides to enforce soulbound (non-transferable) behaviour ───

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        return super._update(to, tokenId, auth);
    }
}
