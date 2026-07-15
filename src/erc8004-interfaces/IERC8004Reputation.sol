// contracts/interfaces/IERC8004Reputation.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ERC-8004 Reputation Registry Interface
 * @dev Interface for AI Agent reputation and feedback system
 */
interface IERC8004Reputation {
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint8 score,
        bytes32 indexed tag1,
        bytes32 tag2,
        string fileuri,
        bytes32 filehash
    );
    
    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 indexed feedbackIndex
    );
    
    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 indexed feedbackIndex,
        address responder,
        string responseUri
    );
    
    error ERC8004__AgentNotRegistered();
    error ERC8004__ScoreOutOfRange();
    error ERC8004__InvalidSignature();
    error ERC8004__SignatureAlreadyUsed();
    error ERC8004__AuthorizationExpired();
    error ERC8004__IndexLimitTooLow();
    error ERC8004__AuthorizationMismatch();
    error ERC8004__FeedbackNotFound();
    error ERC8004__FeedbackAlreadyRevoked();
    error ERC8004__LimitTooHigh();
    error ERC8004__OffsetOutOfBounds();
    
    /**
     * @dev Give feedback for an AI Agent with EIP-191 signature verification
     */
    function giveFeedback(
        uint256 agentId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string calldata fileuri,
        bytes32 filehash,
        bytes calldata feedbackAuth
    ) external;
    
    /**
     * @dev Revoke previously given feedback
     */
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;
    
    /**
     * @dev Append response to feedback
     */
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseUri,
        bytes32 responseHash
    ) external;
    
    /**
     * @dev Get reputation summary for an agent
     */
    function getReputationSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 averageScore);
    
    /**
     * @dev Get detailed reputation summary with precise scoring
     */
    function getReputationSummaryDetailed(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint256 totalScore, uint16 averageScorePrecise);
    
    /**
     * @dev Read specific feedback entry
     */
    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (uint8 score, bytes32 tag1, bytes32 tag2, bool isRevoked);
    
    /**
     * @dev Read all feedback with pagination
     */
    function readAllFeedbackPaginated(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2,
        bool includeRevoked,
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory clientAddressesResult,
        uint8[] memory scores,
        bytes32[] memory tag1s,
        bytes32[] memory tag2s,
        bool[] memory revokedStatuses
    );
    
    /**
     * @dev Get response count for feedback
     */
    function getResponseCount(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        address[] calldata responders
    ) external view returns (uint64);
    
    /**
     * @dev Get all clients who gave feedback to an agent
     */
    function getClients(uint256 agentId) external view returns (address[] memory);
    
    /**
     * @dev Get paginated client list
     */
    function getClientsPaginated(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory);
    
    /**
     * @dev Get last feedback index for a client
     */
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
    
    /**
     * @dev Get the identity registry address
     */
    function getIdentityRegistry() external view returns (address);
}
