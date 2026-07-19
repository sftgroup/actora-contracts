// contracts/core/IdentityRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @title IdentityRegistry
 * @dev ERC-8004 Identity Registry implementation based on ERC-721
 */
contract IdentityRegistry is ERC721, ERC721URIStorage, Ownable, IERC8004Identity {
    using EnumerableSet for EnumerableSet.UintSet;
    
    uint256 private _agentIdCounter;
    
    mapping(uint256 => mapping(string => bytes)) private _agentMetadata;
    mapping(address => EnumerableSet.UintSet) private _ownedAgentsSet;
    
    // Use EnumerableSet to store all agent IDs for easy pagination queries
    EnumerableSet.UintSet private _allAgentIds;
    
    uint256 public registrationFee = 0.001 ether;
    
    constructor() ERC721("AI Agent Identity", "AGENT") Ownable(msg.sender) {
        _agentIdCounter = 1; // Start counting from 1
    }
    
    function register() external payable override returns (uint256) {
        if (msg.value < registrationFee) {
            revert ERC8004__InsufficientFee();
        }
        
        uint256 agentId = _agentIdCounter;
        _agentIdCounter++;
        
        _safeMint(msg.sender, agentId);
        _allAgentIds.add(agentId);
        
        // Ensure added to the owner's set
        _ownedAgentsSet[msg.sender].add(agentId);
        
        if (msg.value > registrationFee) {
            payable(msg.sender).transfer(msg.value - registrationFee);
        }
        
        emit Registered(agentId, "", msg.sender);
        return agentId;
    }
    
    function register(string memory agentTokenURI) external payable override returns (uint256) {
        ERC8004Types.MetadataEntry[] memory emptyMetadata;
        return _registerWithMetadata(agentTokenURI, emptyMetadata);
    }
    
    function _registerWithMetadata(
        string memory agentTokenURI, 
        ERC8004Types.MetadataEntry[] memory metadata
    ) internal returns (uint256 agentId) {
        if (msg.value < registrationFee) {
            revert ERC8004__InsufficientFee();
        }
        
        agentId = _agentIdCounter;
        _agentIdCounter++;
        
        _safeMint(msg.sender, agentId);
        _allAgentIds.add(agentId);
        
        // Ensure added to the owner's set
        _ownedAgentsSet[msg.sender].add(agentId);
        
        if (bytes(agentTokenURI).length > 0) {
            _setTokenURI(agentId, agentTokenURI);
        }
        
        for (uint256 i = 0; i < metadata.length; i++) {
            _setMetadata(agentId, metadata[i].key, metadata[i].value);
        }
        
        if (msg.value > registrationFee) {
            payable(msg.sender).transfer(msg.value - registrationFee);
        }
        
        emit Registered(agentId, agentTokenURI, msg.sender);
        return agentId;
    }
    
    function registerWithMetadata(
        string memory agentTokenURI, 
        ERC8004Types.MetadataEntry[] calldata metadata
    ) external payable override returns (uint256) {
        ERC8004Types.MetadataEntry[] memory metadataMemory = metadata;
        return _registerWithMetadata(agentTokenURI, metadataMemory);
    }
    
    function setMetadata(uint256 agentId, string memory key, bytes memory value) external override {
        if (ownerOf(agentId) != msg.sender) {
            revert ERC8004__OnlyAgentOwner();
        }
        _setMetadata(agentId, key, value);
    }
    
    function _setMetadata(uint256 agentId, string memory key, bytes memory value) internal {
        _agentMetadata[agentId][key] = value;
        emit MetadataSet(agentId, keccak256(bytes(key)), key, value);
    }
    
    function getMetadata(uint256 agentId, string memory key) external view override returns (bytes memory value) {
        if (_ownerOf(agentId) == address(0)) {
            revert ERC8004__AgentNotExists();
        }
        return _agentMetadata[agentId][key];
    }
    
    function agentExists(uint256 agentId) external view override returns (bool) {
        return _ownerOf(agentId) != address(0);
    }
    
    function getAgentsByOwner(address owner) external view override returns (uint256[] memory) {
        return _ownedAgentsSet[owner].values();
    }
    
    function getCurrentAgentId() external view override returns (uint256) {
        return _agentIdCounter - 1;
    }
    
    function getIdentityRegistry() external view override returns (address) {
        return address(this);
    }
    
    /**
     * @dev Get paginated list of all registered agents
     * @param page The page number (starting from 1)
     * @param limit The number of agents per page
     * @return agentIds Array of agent IDs for the requested page
     * @return totalAgents Total number of registered agents
     */
    function getAllAgentsPaginated(
        uint256 page, 
        uint256 limit
    ) external view override returns (uint256[] memory agentIds, uint256 totalAgents) {
        if (page == 0 || limit == 0) {
            revert ERC8004__InvalidPagination();
        }
        
        totalAgents = _allAgentIds.length();
        uint256 start = (page - 1) * limit;
        uint256 end = start + limit;
        
        // If the start position is out of range, return an empty array
        if (start >= totalAgents) {
            return (new uint256[](0), totalAgents);
        }
        
        // If the end position is out of range, adjust to the last element
        if (end > totalAgents) {
            end = totalAgents;
        }
        
        uint256 resultSize = end - start;
        agentIds = new uint256[](resultSize);
        
        // Get agent IDs within the specified range
        for (uint256 i = 0; i < resultSize; i++) {
            agentIds[i] = _allAgentIds.at(start + i);
        }
        
        return (agentIds, totalAgents);
    }
    
    /**
     * @dev Update token URI for an existing agent
     * @param agentId The ID of the agent to update
     * @param newTokenURI The new token URI
     */
    function updateTokenURI(uint256 agentId, string memory newTokenURI) external override {
        if (ownerOf(agentId) != msg.sender) {
            revert ERC8004__OnlyAgentOwner();
        }
        
        // Check if the agent exists
        if (_ownerOf(agentId) == address(0)) {
            revert ERC8004__AgentNotExists();
        }
        
        // Update the token URI
        _setTokenURI(agentId, newTokenURI);
        
        emit TokenURIUpdated(agentId, newTokenURI);
    }
    
    function setRegistrationFee(uint256 fee) external onlyOwner {
        registrationFee = fee;
    }
    
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance <= 0) {
            revert ERC8004__NoFeesToWithdraw();
        }
        payable(owner()).transfer(balance);
    }
    
    // Override required functions from ERC721 and ERC721URIStorage
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return 
            interfaceId == type(IERC8004Identity).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721)
        returns (address)
    {
        // Get the owner before the transfer
        address from = _ownerOf(tokenId);
        
        // Call the parent's _update
        address previousOwner = super._update(to, tokenId, auth);
        
        // Update the owner set
        if (from != address(0)) {
            _ownedAgentsSet[from].remove(tokenId);
        }
        
        if (to != address(0)) {
            _ownedAgentsSet[to].add(tokenId);
        } else {
            // Token is being burned
            _allAgentIds.remove(tokenId);
        }
        
        return previousOwner;
    }
    
    /**
     * @dev Add a burn function to allow owners to burn their Agent
     */
    function burn(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "ERC8004: caller is not owner");
        _burn(tokenId);
    }
}
