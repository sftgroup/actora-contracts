// contracts/interfaces/IERC8004Identity.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC8004Types.sol";

/**
 * @title ERC-8004 Identity Registry Interface
 * @dev Interface for AI Agent identity registration and management
 */
interface IERC8004Identity {
    event Registered(uint256 indexed agentId, string tokenURI, address indexed owner);
    event MetadataSet(uint256 indexed agentId, bytes32 indexed indexedKey, string key, bytes value);
    event TokenURIUpdated(uint256 indexed agentId, string newTokenURI);
    
    error ERC8004__InsufficientFee();
    error ERC8004__AgentNotExists();
    error ERC8004__OnlyAgentOwner();
    error ERC8004__NoFeesToWithdraw();
    error ERC8004__InvalidPagination();
    
    /**
     * @dev Register a new AI Agent with metadata
     */
    function registerWithMetadata(
        string memory tokenURI, 
        ERC8004Types.MetadataEntry[] calldata metadata
    ) external payable returns (uint256 agentId);
    
    /**
     * @dev Register a new AI Agent with token URI only
     */
    function register(string memory tokenURI) external payable returns (uint256);
    
    /**
     * @dev Register a new AI Agent without token URI
     */
    function register() external payable returns (uint256);
    
    /**
     * @dev Set metadata for an agent
     */
    function setMetadata(uint256 agentId, string memory key, bytes memory value) external;
    
    /**
     * @dev Get metadata for an agent
     */
    function getMetadata(uint256 agentId, string memory key) external view returns (bytes memory value);
    
    /**
     * @dev Check if agent exists
     */
    function agentExists(uint256 agentId) external view returns (bool);
    
    /**
     * @dev Get the identity registry address
     */
    function getIdentityRegistry() external view returns (address);
    
    /**
     * @dev Get all agents owned by an address
     */
    function getAgentsByOwner(address owner) external view returns (uint256[] memory);
    
    /**
     * @dev Get current agent ID counter
     */
    function getCurrentAgentId() external view returns (uint256);
    
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
    ) external view returns (uint256[] memory agentIds, uint256 totalAgents);
    
    /**
     * @dev Update token URI for an existing agent
     * @param agentId The ID of the agent to update
     * @param newTokenURI The new token URI
     */
    function updateTokenURI(uint256 agentId, string memory newTokenURI) external;
}

