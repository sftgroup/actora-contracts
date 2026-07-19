// contracts/extensions/MultiEndpointRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @title MultiEndpointRegistry
 * @dev Registry for managing multiple endpoints for AI Agents
 * @notice Supports different communication protocols and endpoint types
 */
contract MultiEndpointRegistry is Ownable {
    IERC8004Identity public immutable identityRegistry;
    IERC721 public immutable erc721Identity;
    
    // 修复：手动实现计数器
    uint256 private _endpointCounter;
    
    // Endpoint structure
    struct Endpoint {
        uint256 endpointId;
        uint256 agentId;
        string name;
        string endpointType;
        string protocol;
        string url;
        string description;
        bool isActive;
        uint256 createdAt;
        uint256 updatedAt;
        address createdBy;
    }
    
    // Protocol configuration
    struct ProtocolConfig {
        string protocol;
        bool isSupported;
        uint256 maxEndpointsPerAgent;
        string[] requiredParams;
    }
    
    // Storage
    mapping(uint256 => Endpoint) private _endpoints;
    mapping(uint256 => uint256[]) private _agentEndpoints;
    mapping(string => ProtocolConfig) private _protocolConfigs;
    string[] private _supportedProtocols;
    
    // Events
    event EndpointCreated(
        uint256 indexed endpointId,
        uint256 indexed agentId,
        string endpointType,
        string protocol,
        string url
    );
    
    event EndpointUpdated(
        uint256 indexed endpointId,
        uint256 indexed agentId,
        string endpointType,
        string protocol,
        string url
    );
    
    event EndpointDeactivated(
        uint256 indexed endpointId,
        uint256 indexed agentId
    );
    
    event ProtocolSupported(
        string protocol,
        uint256 maxEndpointsPerAgent
    );
    
    // Custom errors
    error MultiEndpoint__AgentNotOwner();
    error MultiEndpoint__EndpointNotFound();
    error MultiEndpoint__ProtocolNotSupported();
    error MultiEndpoint__MaxEndpointsReached();
    error MultiEndpoint__InvalidInput();
    error MultiEndpoint__Unauthorized();

    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert MultiEndpoint__InvalidInput();
        }
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        
        // 修复：初始化计数器
        _endpointCounter = 1;
        
        _initializeDefaultProtocols();
    }
    
    /**
     * @dev Create a new endpoint for an agent
     */
    function createEndpoint(
        uint256 agentId,
        string memory name,
        string memory endpointType,
        string memory protocol,
        string memory url,
        string memory description
    ) external returns (uint256 endpointId) {
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert MultiEndpoint__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert MultiEndpoint__AgentNotOwner();
        }
        
        ProtocolConfig storage config = _protocolConfigs[protocol];
        if (!config.isSupported) {
            revert MultiEndpoint__ProtocolNotSupported();
        }
        
        uint256[] storage agentEndpoints = _agentEndpoints[agentId];
        if (agentEndpoints.length >= config.maxEndpointsPerAgent) {
            revert MultiEndpoint__MaxEndpointsReached();
        }
        
        if (bytes(name).length == 0 || bytes(url).length == 0) {
            revert MultiEndpoint__InvalidInput();
        }
        
        endpointId = _endpointCounter;
        _endpointCounter++;
        
        Endpoint memory newEndpoint = Endpoint({
            endpointId: endpointId,
            agentId: agentId,
            name: name,
            endpointType: endpointType,
            protocol: protocol,
            url: url,
            description: description,
            isActive: true,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            createdBy: msg.sender
        });
        
        _endpoints[endpointId] = newEndpoint;
        _agentEndpoints[agentId].push(endpointId);
        
        emit EndpointCreated(endpointId, agentId, endpointType, protocol, url);
        return endpointId;
    }
    
    /**
     * @dev Update an existing endpoint
     */
    function updateEndpoint(
        uint256 endpointId,
        string memory name,
        string memory endpointType,
        string memory protocol,
        string memory url,
        string memory description
    ) external {
        Endpoint storage endpoint = _endpoints[endpointId];
        if (endpoint.endpointId == 0) {
            revert MultiEndpoint__EndpointNotFound();
        }
        
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(endpoint.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert MultiEndpoint__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert MultiEndpoint__AgentNotOwner();
        }
        
        ProtocolConfig storage config = _protocolConfigs[protocol];
        if (!config.isSupported) {
            revert MultiEndpoint__ProtocolNotSupported();
        }
        
        if (bytes(name).length == 0 || bytes(url).length == 0) {
            revert MultiEndpoint__InvalidInput();
        }
        
        endpoint.name = name;
        endpoint.endpointType = endpointType;
        endpoint.protocol = protocol;
        endpoint.url = url;
        endpoint.description = description;
        endpoint.updatedAt = block.timestamp;
        
        emit EndpointUpdated(endpointId, endpoint.agentId, endpointType, protocol, url);
    }
    
    /**
     * @dev Deactivate an endpoint
     */
    function deactivateEndpoint(uint256 endpointId) external {
        Endpoint storage endpoint = _endpoints[endpointId];
        if (endpoint.endpointId == 0) {
            revert MultiEndpoint__EndpointNotFound();
        }
        
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(endpoint.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert MultiEndpoint__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender && msg.sender != owner()) {
            revert MultiEndpoint__Unauthorized();
        }
        
        endpoint.isActive = false;
        endpoint.updatedAt = block.timestamp;
        
        emit EndpointDeactivated(endpointId, endpoint.agentId);
    }
    
    /**
     * @dev Add support for a new protocol (only owner)
     */
    function addProtocolSupport(
        string memory protocol,
        uint256 maxEndpointsPerAgent,
        string[] memory requiredParams
    ) external onlyOwner {
        if (bytes(protocol).length == 0 || maxEndpointsPerAgent == 0) {
            revert MultiEndpoint__InvalidInput();
        }
        
        ProtocolConfig memory config = ProtocolConfig({
            protocol: protocol,
            isSupported: true,
            maxEndpointsPerAgent: maxEndpointsPerAgent,
            requiredParams: requiredParams
        });
        
        _protocolConfigs[protocol] = config;
        _supportedProtocols.push(protocol);
        
        emit ProtocolSupported(protocol, maxEndpointsPerAgent);
    }
    
    /**
     * @dev Get endpoint by ID
     */
    function getEndpoint(uint256 endpointId) external view returns (Endpoint memory) {
        Endpoint memory endpoint = _endpoints[endpointId];
        if (endpoint.endpointId == 0) {
            revert MultiEndpoint__EndpointNotFound();
        }
        return endpoint;
    }
    
    /**
     * @dev Get all endpoints for an agent
     */
    function getAgentEndpoints(uint256 agentId) external view returns (Endpoint[] memory) {
        uint256[] storage endpointIds = _agentEndpoints[agentId];
        Endpoint[] memory endpoints = new Endpoint[](endpointIds.length);
        
        for (uint256 i = 0; i < endpointIds.length; i++) {
            endpoints[i] = _endpoints[endpointIds[i]];
        }
        
        return endpoints;
    }
    
    /**
     * @dev Get active endpoints for an agent
     */
    function getActiveAgentEndpoints(uint256 agentId) external view returns (Endpoint[] memory) {
        uint256[] storage endpointIds = _agentEndpoints[agentId];
        
        // Count active endpoints
        uint256 activeCount = 0;
        for (uint256 i = 0; i < endpointIds.length; i++) {
            if (_endpoints[endpointIds[i]].isActive) {
                activeCount++;
            }
        }
        
        Endpoint[] memory activeEndpoints = new Endpoint[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < endpointIds.length; i++) {
            Endpoint memory endpoint = _endpoints[endpointIds[i]];
            if (endpoint.isActive) {
                activeEndpoints[index] = endpoint;
                index++;
            }
        }
        
        return activeEndpoints;
    }
    
    /**
     * @dev Get endpoints by protocol
     */
    function getEndpointsByProtocol(string memory protocol) external view returns (Endpoint[] memory) {
        uint256 totalEndpoints = _endpointCounter - 1;
        
        // Count endpoints with this protocol
        uint256 count = 0;
        for (uint256 i = 1; i <= totalEndpoints; i++) {
            Endpoint memory endpoint = _endpoints[i];
            if (keccak256(bytes(endpoint.protocol)) == keccak256(bytes(protocol)) && endpoint.isActive) {
                count++;
            }
        }
        
        Endpoint[] memory endpoints = new Endpoint[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= totalEndpoints; i++) {
            Endpoint memory endpoint = _endpoints[i];
            if (keccak256(bytes(endpoint.protocol)) == keccak256(bytes(protocol)) && endpoint.isActive) {
                endpoints[index] = endpoint;
                index++;
            }
        }
        
        return endpoints;
    }
    
    /**
     * @dev Get supported protocols
     */
    function getSupportedProtocols() external view returns (string[] memory) {
        return _supportedProtocols;
    }
    
    /**
     * @dev Get protocol configuration
     */
    function getProtocolConfig(string memory protocol) external view returns (ProtocolConfig memory) {
        ProtocolConfig memory config = _protocolConfigs[protocol];
        if (!config.isSupported) {
            revert MultiEndpoint__ProtocolNotSupported();
        }
        return config;
    }
    
    /**
     * @dev Check if protocol is supported
     */
    function isProtocolSupported(string memory protocol) external view returns (bool) {
        return _protocolConfigs[protocol].isSupported;
    }
    
    /**
     * @dev Initialize default supported protocols
     */
    function _initializeDefaultProtocols() internal {
        string[] memory httpParams = new string[](2);
        httpParams[0] = "url";
        httpParams[1] = "method";
        
        // 修复：直接创建协议配置，不调用外部函数
        _protocolConfigs["HTTP"] = ProtocolConfig({
            protocol: "HTTP",
            isSupported: true,
            maxEndpointsPerAgent: 5,
            requiredParams: httpParams
        });
        _supportedProtocols.push("HTTP");
        emit ProtocolSupported("HTTP", 5);
        
        string[] memory websocketParams = new string[](2);
        websocketParams[0] = "url";
        websocketParams[1] = "protocol";
        
        _protocolConfigs["WebSocket"] = ProtocolConfig({
            protocol: "WebSocket",
            isSupported: true,
            maxEndpointsPerAgent: 3,
            requiredParams: websocketParams
        });
        _supportedProtocols.push("WebSocket");
        emit ProtocolSupported("WebSocket", 3);
        
        string[] memory grpcParams = new string[](2);
        grpcParams[0] = "url";
        grpcParams[1] = "service";
        
        _protocolConfigs["gRPC"] = ProtocolConfig({
            protocol: "gRPC",
            isSupported: true,
            maxEndpointsPerAgent: 3,
            requiredParams: grpcParams
        });
        _supportedProtocols.push("gRPC");
        emit ProtocolSupported("gRPC", 3);
        
        string[] memory ipfsParams = new string[](1);
        ipfsParams[0] = "cid";
        
        _protocolConfigs["IPFS"] = ProtocolConfig({
            protocol: "IPFS",
            isSupported: true,
            maxEndpointsPerAgent: 10,
            requiredParams: ipfsParams
        });
        _supportedProtocols.push("IPFS");
        emit ProtocolSupported("IPFS", 10);
    }
    
    /**
     * @dev Get endpoint statistics for agent
     */
    function getAgentEndpointStats(uint256 agentId) external view returns (
        uint256 totalEndpoints,
        uint256 activeEndpoints,
        uint256 httpEndpoints,
        uint256 websocketEndpoints,
        uint256 grpcEndpoints
    ) {
        uint256[] storage endpointIds = _agentEndpoints[agentId];
        totalEndpoints = endpointIds.length;
        
        for (uint256 i = 0; i < endpointIds.length; i++) {
            Endpoint memory endpoint = _endpoints[endpointIds[i]];
            if (endpoint.isActive) {
                activeEndpoints++;
            }
            
            if (keccak256(bytes(endpoint.protocol)) == keccak256(bytes("HTTP"))) {
                httpEndpoints++;
            } else if (keccak256(bytes(endpoint.protocol)) == keccak256(bytes("WebSocket"))) {
                websocketEndpoints++;
            } else if (keccak256(bytes(endpoint.protocol)) == keccak256(bytes("gRPC"))) {
                grpcEndpoints++;
            }
        }
        
        return (totalEndpoints, activeEndpoints, httpEndpoints, websocketEndpoints, grpcEndpoints);
    }
    
    /**
     * @dev Search endpoints by type and protocol
     */
    function searchEndpoints(
        string memory endpointType,
        string memory protocol
    ) external view returns (Endpoint[] memory) {
        uint256 totalEndpoints = _endpointCounter - 1;
        
        // Count matching endpoints
        uint256 count = 0;
        for (uint256 i = 1; i <= totalEndpoints; i++) {
            Endpoint memory endpoint = _endpoints[i];
            if (endpoint.isActive &&
                (bytes(endpointType).length == 0 || keccak256(bytes(endpoint.endpointType)) == keccak256(bytes(endpointType))) &&
                (bytes(protocol).length == 0 || keccak256(bytes(endpoint.protocol)) == keccak256(bytes(protocol)))) {
                count++;
            }
        }
        
        Endpoint[] memory endpoints = new Endpoint[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= totalEndpoints; i++) {
            Endpoint memory endpoint = _endpoints[i];
            if (endpoint.isActive &&
                (bytes(endpointType).length == 0 || keccak256(bytes(endpoint.endpointType)) == keccak256(bytes(endpointType))) &&
                (bytes(protocol).length == 0 || keccak256(bytes(endpoint.protocol)) == keccak256(bytes(protocol)))) {
                endpoints[index] = endpoint;
                index++;
            }
        }
        
        return endpoints;
    }
}
