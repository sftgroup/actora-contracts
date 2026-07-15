// contracts/core/BaseReputationRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./IdentityRegistry.sol";

/**
 * @title BaseReputationRegistry
 * @dev ERC-8004 Reputation Registry base implementation with core storage only
 */
abstract contract BaseReputationRegistry is Ownable {
    using ECDSA for bytes32;
    
    IdentityRegistry public immutable identityRegistry;
    
    struct Feedback {
        uint8 score;
        bytes32 tag1;
        bytes32 tag2;
        string fileuri;
        bytes32 filehash;
        bool revoked;
        uint64 index;
        uint256 timestamp;
    }
    
    struct Response {
        string responseUri;
        bytes32 responseHash;
        address responder;
        uint256 timestamp;
    }
    
    // Fix: Change storage mappings to internal
    mapping(uint256 => mapping(address => uint64)) internal lastFeedbackIndex;
    mapping(uint256 => mapping(address => mapping(uint64 => Feedback))) internal feedbacks;
    mapping(uint256 => mapping(address => mapping(uint64 => Response[]))) internal responses;
    mapping(uint256 => address[]) internal agentClients;
    
    mapping(bytes32 => bool) public usedSignatures;
    mapping(bytes32 => bool) public usedAuthorizationKeys;

    // Fix: Use custom error to avoid duplicate declaration
    error BaseReputation__InvalidIdentityRegistry();

    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert BaseReputation__InvalidIdentityRegistry();
        }
        identityRegistry = IdentityRegistry(_identityRegistry);
    }
    
    // Internal functions for storage access
    function _getLastFeedbackIndex(uint256 agentId, address client) internal view returns (uint64) {
        return lastFeedbackIndex[agentId][client];
    }
    
    function _setLastFeedbackIndex(uint256 agentId, address client, uint64 index) internal {
        lastFeedbackIndex[agentId][client] = index;
    }
    
    function _getFeedback(uint256 agentId, address client, uint64 index) internal view returns (Feedback memory) {
        return feedbacks[agentId][client][index];
    }
    
    function _setFeedback(uint256 agentId, address client, uint64 index, Feedback memory feedback) internal {
        feedbacks[agentId][client][index] = feedback;
    }
    
    function _getAgentClients(uint256 agentId) internal view returns (address[] storage) {
        return agentClients[agentId];
    }
    
    // Fix: Add memory version function
    function _getAgentClientsMemory(uint256 agentId) internal view returns (address[] memory) {
        return agentClients[agentId];
    }
    
    function _addClientToAgent(uint256 agentId, address client) internal {
        address[] storage clients = agentClients[agentId];
        for (uint256 i = 0; i < clients.length; i++) {
            if (clients[i] == client) {
                return;
            }
        }
        clients.push(client);
    }
    
    function _calculateDetailedSummary(
        uint256 agentId,
        address[] memory clientsToCheck,
        bytes32 tag1,
        bytes32 tag2
    ) internal view returns (uint64 count, uint256 totalScore) {
        for (uint256 i = 0; i < clientsToCheck.length; i++) {
            address client = clientsToCheck[i];
            uint64 lastIndex = _getLastFeedbackIndex(agentId, client);
            
            for (uint64 j = 1; j <= lastIndex; j++) {
                Feedback memory feedback = _getFeedback(agentId, client, j);
                
                if (!feedback.revoked && 
                    (tag1 == bytes32(0) || feedback.tag1 == tag1) &&
                    (tag2 == bytes32(0) || feedback.tag2 == tag2)) {
                    
                    totalScore += feedback.score;
                    count++;
                }
            }
        }
    }
    
    function _calculateFeedbackCount(
        uint256 agentId,
        address[] memory clientsToCheck,
        bytes32 tag1,
        bytes32 tag2,
        bool includeRevoked
    ) internal view returns (uint256 count) {
        for (uint256 i = 0; i < clientsToCheck.length; i++) {
            address client = clientsToCheck[i];
            uint64 lastIndex = _getLastFeedbackIndex(agentId, client);
            
            for (uint64 j = 1; j <= lastIndex; j++) {
                Feedback memory feedback = _getFeedback(agentId, client, j);
                
                if (!includeRevoked && feedback.revoked) continue;
                if (tag1 != bytes32(0) && feedback.tag1 != tag1) continue;
                if (tag2 != bytes32(0) && feedback.tag2 != tag2) continue;
                
                count++;
            }
        }
    }
}
