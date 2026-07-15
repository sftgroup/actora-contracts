// contracts/interfaces/ERC8004Types.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ERC8004 Types
 * @dev Common types and structures for ERC-8004 interfaces
 */
library ERC8004Types {
    struct MetadataEntry {
        string key;
        bytes value;
    }
    
    enum EndpointType {
        A2A,
        MCP,
        OASF,
        HTTP,
        WebSocket,
        GRPC,
        ENS,
        DID,
        AGENT_WALLET
    }
    
    struct Endpoint {
        EndpointType endpointType;
        string name;
        string endpoint;
        string version;
        string capabilities;
        uint256 chainId;
        uint256 createdAt;
        bool isActive;
    }
}
