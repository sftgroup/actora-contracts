// contracts/interfaces/IERC8004Validation.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ERC-8004 Validation Registry Interface
 * @dev Interface for AI Agent validation and verification system
 */
interface IERC8004Validation {
    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string requestUri,
        bytes32 indexed requestHash
    );
    
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseUri,
        bytes32 tag
    );
    
    error ERC8004__ZeroAddress();
    error ERC8004__OnlyAgentOwner();
    error ERC8004__RequestAlreadyExists();
    error ERC8004__OnlyValidator();
    error ERC8004__ResponseOutOfRange();
    error ERC8004__RequestNotFound();
    
    /**
     * @dev Request validation for an AI Agent
     */
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestUri,
        bytes32 requestHash
    ) external;
    
    /**
     * @dev Submit validation response
     */
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseUri,
        bytes32 responseHash,
        bytes32 tag
    ) external;
    
    /**
     * @dev Get validation status for a request
     */
    function getValidationStatus(
        bytes32 requestHash
    ) external view returns (
        address validatorAddress,
        uint256 agentId,
        uint8 response,
        bytes32 tag,
        uint256 lastUpdate
    );
    
    /**
     * @dev Get validation summary for an agent
     */
    function getValidationSummary(
        uint256 agentId,
        address[] calldata validatorAddresses,
        bytes32 tag
    ) external view returns (uint64 count, uint8 avgResponse);
    
    /**
     * @dev Get all validations for an agent
     */
    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory);
    
    /**
     * @dev Get all validation requests for a validator
     */
    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory);
    
    /**
     * @dev Get the identity registry address
     */
    function getIdentityRegistry() external view returns (address);
}
