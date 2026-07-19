// contracts/core/ReputationRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "./BaseReputationRegistry.sol";
import "../erc8004-interfaces/IERC8004Reputation.sol";

/**
 * @title ReputationRegistry
 * @dev ERC-8004 Reputation Registry implementation
 */
contract ReputationRegistry is BaseReputationRegistry, IERC8004Reputation {
    
    constructor(address _identityRegistry) BaseReputationRegistry(_identityRegistry) {}
    
    function giveFeedback(
        uint256 agentId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string calldata fileuri,
        bytes32 filehash,
        bytes calldata feedbackAuth
    ) external override {
        if (!identityRegistry.agentExists(agentId)) {
            revert ERC8004__AgentNotRegistered();
        }
        if (score > 100) {
            revert ERC8004__ScoreOutOfRange();
        }
        
        bytes32 authHash = keccak256(feedbackAuth);
        if (usedSignatures[authHash]) {
            revert ERC8004__SignatureAlreadyUsed();
        }
        usedSignatures[authHash] = true;
        
        _processFeedbackAuthorization(feedbackAuth, agentId);
        
        uint64 index = _getLastFeedbackIndex(agentId, msg.sender) + 1;
        _setLastFeedbackIndex(agentId, msg.sender, index);
        
        Feedback memory newFeedback = Feedback({
            score: score,
            tag1: tag1,
            tag2: tag2,
            fileuri: fileuri,
            filehash: filehash,
            revoked: false,
            index: index,
            timestamp: block.timestamp
        });
        
        _setFeedback(agentId, msg.sender, index, newFeedback);
        _addClientToAgent(agentId, msg.sender);
        
        emit NewFeedback(agentId, msg.sender, score, tag1, tag2, fileuri, filehash);
    }
    
    function _processFeedbackAuthorization(bytes calldata feedbackAuth, uint256 agentId) internal {
        (uint256 authAgentId, address clientAddress, uint64 indexLimit, uint256 expiry) = _decodeAuthPart1(feedbackAuth);
        _validateAuthPart1(authAgentId, clientAddress, indexLimit, expiry, agentId);
        
        (uint256 chainId, address authIdentityRegistry, bytes memory signature) = _decodeAuthPart2(feedbackAuth);
        _validateAuthPart2(chainId, authIdentityRegistry, authAgentId, clientAddress, indexLimit, expiry);
        
        _verifySignature(authAgentId, clientAddress, indexLimit, expiry, chainId, authIdentityRegistry, signature, agentId);
    }
    
    function _decodeAuthPart1(bytes calldata feedbackAuth) 
        internal pure returns (uint256 authAgentId, address clientAddress, uint64 indexLimit, uint256 expiry) {
        (authAgentId, clientAddress, indexLimit, expiry, , , ) = abi.decode(
            feedbackAuth, 
            (uint256, address, uint64, uint256, uint256, address, bytes)
        );
    }
    
    function _decodeAuthPart2(bytes calldata feedbackAuth) 
        internal pure returns (uint256 chainId, address authIdentityRegistry, bytes memory signature) {
        (, , , , chainId, authIdentityRegistry, signature) = abi.decode(
            feedbackAuth, 
            (uint256, address, uint64, uint256, uint256, address, bytes)
        );
    }
    
    function _validateAuthPart1(
        uint256 authAgentId,
        address clientAddress,
        uint64 indexLimit,
        uint256 expiry,
        uint256 agentId
    ) internal view {
        if (authAgentId != agentId) {
            revert ERC8004__AuthorizationMismatch();
        }
        if (clientAddress != msg.sender) {
            revert ERC8004__AuthorizationMismatch();
        }
        if (block.timestamp > expiry) {
            revert ERC8004__AuthorizationExpired();
        }
        if (indexLimit <= _getLastFeedbackIndex(agentId, msg.sender)) {
            revert ERC8004__IndexLimitTooLow();
        }
    }
    
    function _validateAuthPart2(
        uint256 chainId,
        address authIdentityRegistry,
        uint256 authAgentId,
        address clientAddress,
        uint64 indexLimit,
        uint256 expiry
    ) internal {
        if (chainId != block.chainid) {
            revert ERC8004__AuthorizationMismatch();
        }
        if (authIdentityRegistry != address(identityRegistry)) {
            revert ERC8004__AuthorizationMismatch();
        }
        
        bytes32 authorizationKey = keccak256(abi.encode(
            authAgentId,
            clientAddress,
            indexLimit,
            expiry,
            chainId,
            authIdentityRegistry
        ));
        if (usedAuthorizationKeys[authorizationKey]) {
            revert ERC8004__AuthorizationMismatch();
        }
        usedAuthorizationKeys[authorizationKey] = true;
    }
    
    function _verifySignature(
        uint256 authAgentId,
        address clientAddress,
        uint64 indexLimit,
        uint256 expiry,
        uint256 chainId,
        address authIdentityRegistry,
        bytes memory signature,
        uint256 agentId
    ) internal view {
        bytes32 messageHash = keccak256(abi.encode(
            authAgentId,
            clientAddress,
            indexLimit,
            expiry,
            chainId,
            authIdentityRegistry
        ));
        
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        
        address signerAddress;
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);
        
        if (recoveredSigner.code.length > 0) {
            bytes4 result = IERC1271(recoveredSigner).isValidSignature(ethSignedMessageHash, signature);
            if (result != IERC1271.isValidSignature.selector) {
                revert ERC8004__InvalidSignature();
            }
            signerAddress = recoveredSigner;
        } else {
            if (recoveredSigner == address(0)) {
                revert ERC8004__InvalidSignature();
            }
            signerAddress = recoveredSigner;
        }
        
        if (identityRegistry.ownerOf(agentId) != signerAddress) {
            revert ERC8004__InvalidSignature();
        }
    }
    
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external override {
        Feedback storage feedback = feedbacks[agentId][msg.sender][feedbackIndex];
        if (feedback.index != feedbackIndex) {
            revert ERC8004__FeedbackNotFound();
        }
        if (feedback.revoked) {
            revert ERC8004__FeedbackAlreadyRevoked();
        }
        
        feedback.revoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }
    
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseUri,
        bytes32 responseHash
    ) external override {
        if (feedbacks[agentId][clientAddress][feedbackIndex].index != feedbackIndex) {
            revert ERC8004__FeedbackNotFound();
        }
        
        responses[agentId][clientAddress][feedbackIndex].push(Response({
            responseUri: responseUri,
            responseHash: responseHash,
            responder: msg.sender,
            timestamp: block.timestamp
        }));
        
        emit ResponseAppended(agentId, clientAddress, feedbackIndex, msg.sender, responseUri);
    }
    
    function getReputationSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view override returns (uint64 count, uint8 averageScore) {
        // Fix: Use if-else instead of ternary operator
        address[] memory clientsToCheck;
        if (clientAddresses.length > 0) {
            clientsToCheck = clientAddresses;
        } else {
            clientsToCheck = _getAgentClientsMemory(agentId);
        }
            
        (uint64 totalCount, uint256 totalScore) = _calculateDetailedSummary(agentId, clientsToCheck, tag1, tag2);
        
        count = totalCount;
        if (count > 0) {
            averageScore = uint8(totalScore / count);
        }
        
        return (count, averageScore);
    }
    
    function getReputationSummaryDetailed(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view override returns (uint64 count, uint256 totalScore, uint16 averageScorePrecise) {
        // Fix: Use if-else instead of ternary operator
        address[] memory clientsToCheck;
        if (clientAddresses.length > 0) {
            clientsToCheck = clientAddresses;
        } else {
            clientsToCheck = _getAgentClientsMemory(agentId);
        }
            
        (count, totalScore) = _calculateDetailedSummary(agentId, clientsToCheck, tag1, tag2);
        
        if (count > 0) {
            averageScorePrecise = uint16((totalScore * 10000) / count);
        }
        
        return (count, totalScore, averageScorePrecise);
    }
    
    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view override returns (uint8 score, bytes32 tag1, bytes32 tag2, bool isRevoked) {
        Feedback memory feedback = _getFeedback(agentId, clientAddress, index);
        if (feedback.index != index) {
            revert ERC8004__FeedbackNotFound();
        }
        
        return (feedback.score, feedback.tag1, feedback.tag2, feedback.revoked);
    }
    
    function readAllFeedbackPaginated(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2,
        bool includeRevoked,
        uint256 offset,
        uint256 limit
    ) external view override returns (
        address[] memory clientAddressesResult,
        uint8[] memory scores,
        bytes32[] memory tag1s,
        bytes32[] memory tag2s,
        bool[] memory revokedStatuses
    ) {
        if (limit > 100) limit = 100;
        if (limit == 0) revert ERC8004__LimitTooHigh();
        
        // Fix: Use if-else instead of ternary operator
        address[] memory clientsToCheck;
        if (clientAddresses.length > 0) {
            clientsToCheck = clientAddresses;
        } else {
            clientsToCheck = _getAgentClientsMemory(agentId);
        }
        
        uint256 totalCount = _calculateFeedbackCount(agentId, clientsToCheck, tag1, tag2, includeRevoked);
        
        if (offset >= totalCount) {
            revert ERC8004__OffsetOutOfBounds();
        }
        
        uint256 resultCount = (offset + limit) > totalCount ? (totalCount - offset) : limit;
        
        clientAddressesResult = new address[](resultCount);
        scores = new uint8[](resultCount);
        tag1s = new bytes32[](resultCount);
        tag2s = new bytes32[](resultCount);
        revokedStatuses = new bool[](resultCount);
        
        uint256 currentIndex = 0;
        uint256 collected = 0;
        
        for (uint256 i = 0; i < clientsToCheck.length && collected < resultCount; i++) {
            address client = clientsToCheck[i];
            uint64 lastIndex = _getLastFeedbackIndex(agentId, client);
            
            for (uint64 j = 1; j <= lastIndex && collected < resultCount; j++) {
                Feedback memory feedback = _getFeedback(agentId, client, j);
                
                if ((includeRevoked || !feedback.revoked) && 
                    (tag1 == bytes32(0) || feedback.tag1 == tag1) &&
                    (tag2 == bytes32(0) || feedback.tag2 == tag2)) {
                    
                    if (currentIndex >= offset) {
                        clientAddressesResult[collected] = client;
                        scores[collected] = feedback.score;
                        tag1s[collected] = feedback.tag1;
                        tag2s[collected] = feedback.tag2;
                        revokedStatuses[collected] = feedback.revoked;
                        collected++;
                    }
                    currentIndex++;
                }
            }
        }
        
        return (clientAddressesResult, scores, tag1s, tag2s, revokedStatuses);
    }
    
    function getResponseCount(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        address[] calldata responders
    ) external view override returns (uint64) {
        Response[] storage responseList = responses[agentId][clientAddress][feedbackIndex];
        
        if (responders.length == 0) {
            return uint64(responseList.length);
        }
        
        uint64 count = 0;
        for (uint256 i = 0; i < responseList.length; i++) {
            for (uint256 j = 0; j < responders.length; j++) {
                if (responseList[i].responder == responders[j]) {
                    count++;
                    break;
                }
            }
        }
        
        return count;
    }
    
    function getClients(uint256 agentId) external view override returns (address[] memory) {
        return getClientsPaginated(agentId, 0, 200);
    }
    
    function getClientsPaginated(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) public view override returns (address[] memory clients) {
        if (limit > 200) limit = 200;
        
        address[] storage allClients = _getAgentClients(agentId);
        uint256 totalCount = allClients.length;
        
        if (offset >= totalCount) {
            return new address[](0);
        }
        
        uint256 resultCount = (offset + limit) > totalCount ? (totalCount - offset) : limit;
        clients = new address[](resultCount);
        
        for (uint256 i = 0; i < resultCount; i++) {
            clients[i] = allClients[offset + i];
        }
        
        return clients;
    }
    
    function getLastIndex(uint256 agentId, address clientAddress) external view override returns (uint64) {
        return _getLastFeedbackIndex(agentId, clientAddress);
    }
    
    function getIdentityRegistry() external view override returns (address) {
        return address(identityRegistry);
    }
}
