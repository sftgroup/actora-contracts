// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IdentityRegistry (AgentX v1 — minimal)
 * @custom:deprecated 这个简化版 IdentityRegistry 将被弃用。
 *                   新功能应迁移到 erc8004-core/IdentityRegistry.sol，
 *                   该版本实现了完整的 IERC8004Identity 接口并支持
 *                   注册费、分页查询、burn 等能力。
 * @notice ERC-721 Agent NFT registry for AgentX platform.
 *         每个 Agent 作为 NFT 铸造，支持可扩展键值元数据。
 *         兼容 agentx-sdk AgentRegistry 的 ABI。
 *
 *         迁移路径:
 *         1. 新部署 → 直接使用 erc8004-core/IdentityRegistry.sol
 *         2. 已有部署 → 保持此合约不变，ERC8004 扩展可使用适配器
 *         3. ERC8004 扩展当前依赖 IERC8004Identity，若接入此合约需实现该接口
 */
contract IdentityRegistry is ERC721URIStorage, Ownable {
    // State
    uint256 private _currentAgentId;

    mapping(uint256 => string[]) private _agentMetadataKeys;
    mapping(uint256 => mapping(bytes32 => bytes)) private _agentMetadata;
    mapping(address => uint256[]) private _ownerAgents;
    mapping(uint256 => uint256) private _ownerIndex;
    mapping(uint256 => address) private _agentOwner;

    // Events
    event AgentRegistered(
        uint256 indexed agentId,
        address indexed creator,
        string tokenURI
    );

    event MetadataUpdated(
        uint256 indexed agentId,
        string key,
        bytes value
    );

    // Constructor
    constructor() ERC721("AgentX Agent", "AGENTX") Ownable(msg.sender) {}

    // Register with tokenURI only
    function register(string calldata tokenURI)
        external
        payable
        returns (uint256 agentId)
    {
        agentId = ++_currentAgentId;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, tokenURI);
        _agentOwner[agentId] = msg.sender;

        uint256 idx = _ownerAgents[msg.sender].length;
        _ownerIndex[agentId] = idx;
        _ownerAgents[msg.sender].push(agentId);

        emit AgentRegistered(agentId, msg.sender, tokenURI);
    }

    // Register with tokenURI + metadata
    function registerWithMetadata(
        string calldata tokenURI,
        MetadataEntry[] calldata metadata
    )
        external
        payable
        returns (uint256 agentId)
    {
        agentId = ++_currentAgentId;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, tokenURI);
        _agentOwner[agentId] = msg.sender;

        uint256 idx = _ownerAgents[msg.sender].length;
        _ownerIndex[agentId] = idx;
        _ownerAgents[msg.sender].push(agentId);

        for (uint256 i = 0; i < metadata.length; i++) {
            _agentMetadataKeys[agentId].push(metadata[i].key);
            _agentMetadata[agentId][keccak256(bytes(metadata[i].key))] = metadata[i].value;
        }

        emit AgentRegistered(agentId, msg.sender, tokenURI);
    }

    // Update metadata
    function updateMetadata(
        uint256 agentId,
        MetadataEntry[] calldata metadata
    )
        external
    {
        require(_agentOwner[agentId] == msg.sender, "Not agent owner");
        delete _agentMetadataKeys[agentId];

        for (uint256 i = 0; i < metadata.length; i++) {
            _agentMetadataKeys[agentId].push(metadata[i].key);
            _agentMetadata[agentId][keccak256(bytes(metadata[i].key))] = metadata[i].value;
            emit MetadataUpdated(agentId, metadata[i].key, metadata[i].value);
        }
    }

    // Queries
    function getCurrentAgentId() external view returns (uint256) {
        return _currentAgentId;
    }

    function agentExists(uint256 agentId) external view returns (bool) {
        return _agentOwner[agentId] != address(0);
    }

    function getAgentOwner(uint256 agentId) external view returns (address) {
        return _agentOwner[agentId];
    }

    function getAgentsByOwner(address owner)
        external
        view
        returns (uint256[] memory)
    {
        return _ownerAgents[owner];
    }

    function getAgentMetadata(uint256 agentId)
        external
        view
        returns (MetadataEntry[] memory)
    {
        string[] storage keys = _agentMetadataKeys[agentId];
        MetadataEntry[] memory entries = new MetadataEntry[](keys.length);

        for (uint256 i = 0; i < keys.length; i++) {
            entries[i] = MetadataEntry({
                key: keys[i],
                value: _agentMetadata[agentId][keccak256(bytes(keys[i]))]
            });
        }

        return entries;
    }

    function totalAgents() external view returns (uint256) {
        return _currentAgentId;
    }

    // Structs
    struct MetadataEntry {
        string key;
        bytes value;
    }
}
