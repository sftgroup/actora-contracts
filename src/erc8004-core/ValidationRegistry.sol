// contracts/core/ValidationRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./IdentityRegistry.sol";
import "../erc8004-interfaces/IERC8004Validation.sol";

/**
 * @title ValidationRegistry
 * @dev ERC-8004 Validation Registry implementation
 */
contract ValidationRegistry is Ownable, IERC8004Validation {
    IdentityRegistry public immutable identityRegistry;
    
    struct ValidationRequestData {
        address validatorAddress;
        uint256 agentId;
        string requestUri;
        bytes32 requestHash;
        uint256 timestamp;
    }
    
    struct ValidationResponseData {
        uint8 response;
        string responseUri;
        bytes32 responseHash;
        bytes32 tag;
        uint256 timestamp;
    }
    
    mapping(bytes32 => ValidationRequestData) public validationRequests;
    mapping(bytes32 => ValidationResponseData[]) public validationResponses;
    mapping(uint256 => bytes32[]) public agentValidations;
    mapping(address => bytes32[]) public validatorRequests;
    
    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert ERC8004__ZeroAddress();
        }
        identityRegistry = IdentityRegistry(_identityRegistry);
    }
    
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestUri,
        bytes32 requestHash
    ) external override {
        if (identityRegistry.ownerOf(agentId) != msg.sender) {
            revert ERC8004__OnlyAgentOwner();
        }
        if (validatorAddress == address(0)) {
            revert ERC8004__ZeroAddress();
        }
        
        // Fix: Use requestHash directly as key, no longer calculate requestKey
        if (validationRequests[requestHash].validatorAddress != address(0)) {
            revert ERC8004__RequestAlreadyExists();
        }
        
        validationRequests[requestHash] = ValidationRequestData({
            validatorAddress: validatorAddress,
            agentId: agentId,
            requestUri: requestUri,
            requestHash: requestHash,
            timestamp: block.timestamp
        });
        
        agentValidations[agentId].push(requestHash);
        validatorRequests[validatorAddress].push(requestHash);
        
        emit ValidationRequest(validatorAddress, agentId, requestUri, requestHash);
    }
    
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseUri,
        bytes32 responseHash,
        bytes32 tag
    ) external override {
        // Fix: Use requestHash directly for lookup
        ValidationRequestData storage request = validationRequests[requestHash];
        if (request.validatorAddress != msg.sender) {
            revert ERC8004__OnlyValidator();
        }
        if (response > 100) {
            revert ERC8004__ResponseOutOfRange();
        }
        
        validationResponses[requestHash].push(ValidationResponseData({
            response: response,
            responseUri: responseUri,
            responseHash: responseHash,
            tag: tag,
            timestamp: block.timestamp
        }));
        
        emit ValidationResponse(
            request.validatorAddress,
            request.agentId,
            requestHash,
            response,
            responseUri,
            tag
        );
    }
    
    function getValidationStatus(
        bytes32 requestHash
    ) external view override returns (
        address validatorAddress,
        uint256 agentId,
        uint8 response,
        bytes32 tag,
        uint256 lastUpdate
    ) {
        // Fix: Use requestHash directly for lookup
        ValidationRequestData storage request = validationRequests[requestHash];
        if (request.validatorAddress == address(0)) {
            revert ERC8004__RequestNotFound();
        }
        
        ValidationResponseData[] storage responses = validationResponses[requestHash];
        if (responses.length > 0) {
            ValidationResponseData storage latestResponse = responses[responses.length - 1];
            response = latestResponse.response;
            tag = latestResponse.tag;
            lastUpdate = latestResponse.timestamp;
        } else {
            response = 0;
            tag = bytes32(0);
            lastUpdate = request.timestamp;
        }
        
        return (request.validatorAddress, request.agentId, response, tag, lastUpdate);
    }
    
    function getValidationSummary(
        uint256 agentId,
        address[] calldata validatorAddresses,
        bytes32 tag
    ) external view override returns (uint64 count, uint8 avgResponse) {
        bytes32[] storage validations = agentValidations[agentId];
        uint256 totalResponse = 0;
        count = 0;
        
        for (uint256 i = 0; i < validations.length; i++) {
            bytes32 requestHash = validations[i];
            ValidationRequestData storage request = validationRequests[requestHash];
            
            if (validatorAddresses.length > 0) {
                bool validatorMatch = false;
                for (uint256 j = 0; j < validatorAddresses.length; j++) {
                    if (request.validatorAddress == validatorAddresses[j]) {
                        validatorMatch = true;
                        break;
                    }
                }
                if (!validatorMatch) continue;
            }
            
            ValidationResponseData[] storage responses = validationResponses[requestHash];
            if (responses.length > 0) {
                ValidationResponseData storage latestResponse = responses[responses.length - 1];
                
                if (tag != bytes32(0) && latestResponse.tag != tag) {
                    continue;
                }
                
                totalResponse += latestResponse.response;
                count++;
            }
        }
        
        if (count > 0) {
            avgResponse = uint8(totalResponse / count);
        }
        
        return (count, avgResponse);
    }
    
    function getAgentValidations(uint256 agentId) external view override returns (bytes32[] memory) {
        return agentValidations[agentId];
    }
    
    function getValidatorRequests(address validatorAddress) external view override returns (bytes32[] memory) {
        return validatorRequests[validatorAddress];
    }
    
    function getIdentityRegistry() external view override returns (address) {
        return address(identityRegistry);
    }
}
