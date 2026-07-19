// contracts/extensions/ConfigurationRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @title ConfigurationRegistry
 * @dev Configuration management for AI Agents with gas optimization
 * @notice Production-ready configuration registry with efficient storage
 */
contract ConfigurationRegistry is Ownable {
    IERC8004Identity public immutable identityRegistry;
    IERC721 public immutable erc721Identity;
    uint256 private _configCounter; // 修复：使用原生计数器替代Counters
    
    struct ConfigEntry {
        uint256 configId;
        uint256 agentId;
        string configKey;
        string configValue;
        string dataType;
        string description;
        bool isActive;
        uint256 createdAt;
        uint256 updatedAt;
        address createdBy;
    }
    
    // 修复：使用映射优化存储访问
    mapping(uint256 => ConfigEntry) private _configEntries;
    mapping(uint256 => string[]) private _agentConfigKeys;
    mapping(uint256 => mapping(bytes32 => bool)) private _agentConfigKeyExists;
    mapping(bytes32 => uint256) private _configKeyIndexes;
    
    // 修复：添加事件
    event ConfigSet(
        uint256 indexed configId,
        uint256 indexed agentId,
        string indexed configKey,
        string configValue,
        string dataType,
        address createdBy
    );
    
    event ConfigUpdated(
        uint256 indexed configId,
        uint256 indexed agentId,
        string configKey,
        string configValue,
        uint256 updatedAt
    );
    
    event ConfigRemoved(
        uint256 indexed configId,
        uint256 indexed agentId,
        string configKey
    );
    
    // Custom errors
    error Configuration__AgentNotOwner();
    error Configuration__ConfigNotFound();
    error Configuration__InvalidInput();
    error Configuration__ConfigKeyExists();
    error Configuration__InvalidDataType();

    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert Configuration__InvalidInput();
        }
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        _configCounter = 0; // 初始化计数器
    }
    
    /**
     * @dev Set configuration for an agent
     */
    function setConfig(
        uint256 agentId,
        string memory configKey,
        string memory configValue,
        string memory dataType,
        string memory description
    ) external returns (uint256 configId) {
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert Configuration__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert Configuration__AgentNotOwner();
        }
        
        if (bytes(configKey).length == 0 || bytes(configValue).length == 0) {
            revert Configuration__InvalidInput();
        }
        
        // 修复：验证数据类型
        if (!_isValidDataType(dataType)) {
            revert Configuration__InvalidDataType();
        }
        
        bytes32 keyHash = keccak256(bytes(configKey));
        
        // 检查是否已存在相同配置键
        if (_agentConfigKeyExists[agentId][keyHash]) {
            // 更新现有配置
            uint256 existingConfigId = _configKeyIndexes[keyHash];
            ConfigEntry storage existingConfig = _configEntries[existingConfigId];
            
            existingConfig.configValue = configValue;
            existingConfig.dataType = dataType;
            existingConfig.description = description;
            existingConfig.updatedAt = block.timestamp;
            
            emit ConfigUpdated(existingConfigId, agentId, configKey, configValue, block.timestamp);
            return existingConfigId;
        }
        
        // 创建新配置
        _configCounter++; // 修复：使用原生计数器递增
        configId = _configCounter;
        
        ConfigEntry memory newConfig = ConfigEntry({
            configId: configId,
            agentId: agentId,
            configKey: configKey,
            configValue: configValue,
            dataType: dataType,
            description: description,
            isActive: true,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            createdBy: msg.sender
        });
        
        _configEntries[configId] = newConfig;
        _agentConfigKeys[agentId].push(configKey);
        _agentConfigKeyExists[agentId][keyHash] = true;
        _configKeyIndexes[keyHash] = configId;
        
        emit ConfigSet(configId, agentId, configKey, configValue, dataType, msg.sender);
        return configId;
    }
    
    /**
     * @dev Bulk set configurations
     */
    function setConfigsBulk(
        uint256 agentId,
        string[] memory configKeys,
        string[] memory configValues,
        string[] memory dataTypes,
        string[] memory descriptions
    ) external returns (uint256[] memory) {
        if (configKeys.length != configValues.length || 
            configKeys.length != dataTypes.length || 
            configKeys.length != descriptions.length) {
            revert Configuration__InvalidInput();
        }
        
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert Configuration__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert Configuration__AgentNotOwner();
        }
        
        uint256[] memory configIds = new uint256[](configKeys.length);
        
        for (uint256 i = 0; i < configKeys.length; i++) {
            configIds[i] = this.setConfig(
                agentId,
                configKeys[i],
                configValues[i],
                dataTypes[i],
                descriptions[i]
            );
        }
        
        return configIds;
    }
    
    /**
     * @dev Get configuration value by key
     */
    function getConfig(uint256 agentId, string memory configKey) external view returns (ConfigEntry memory) {
        bytes32 keyHash = keccak256(bytes(configKey));
        
        if (!_agentConfigKeyExists[agentId][keyHash]) {
            revert Configuration__ConfigNotFound();
        }
        
        uint256 configId = _configKeyIndexes[keyHash];
        ConfigEntry memory config = _configEntries[configId];
        
        if (!config.isActive) {
            revert Configuration__ConfigNotFound();
        }
        
        return config;
    }
    
    /**
     * @dev Get all configuration keys for an agent
     */
    function getConfigKeys(uint256 agentId) external view returns (string[] memory) {
        return _agentConfigKeys[agentId];
    }
    
    /**
     * @dev Get all configurations for an agent
     */
    function getAgentConfigs(uint256 agentId) external view returns (ConfigEntry[] memory) {
        string[] storage keys = _agentConfigKeys[agentId];
        ConfigEntry[] memory configs = new ConfigEntry[](keys.length);
        
        for (uint256 i = 0; i < keys.length; i++) {
            bytes32 keyHash = keccak256(bytes(keys[i]));
            uint256 configId = _configKeyIndexes[keyHash];
            configs[i] = _configEntries[configId];
        }
        
        return configs;
    }
    
    /**
     * @dev Remove configuration
     */
    function removeConfig(uint256 agentId, string memory configKey) external {
        // 修复：使用 erc721Identity.ownerOf 而不是 identityRegistry.ownerOf
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert Configuration__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert Configuration__AgentNotOwner();
        }
        
        bytes32 keyHash = keccak256(bytes(configKey));
        
        if (!_agentConfigKeyExists[agentId][keyHash]) {
            revert Configuration__ConfigNotFound();
        }
        
        uint256 configId = _configKeyIndexes[keyHash];
        ConfigEntry storage config = _configEntries[configId];
        
        config.isActive = false;
        config.updatedAt = block.timestamp;
        
        // 修复：从数组中移除配置键
        _removeConfigKeyFromArray(agentId, configKey);
        
        delete _agentConfigKeyExists[agentId][keyHash];
        delete _configKeyIndexes[keyHash];
        
        emit ConfigRemoved(configId, agentId, configKey);
    }
    
    /**
     * @dev Internal function to remove config key from array
     */
    function _removeConfigKeyFromArray(uint256 agentId, string memory configKey) internal {
        string[] storage keys = _agentConfigKeys[agentId];
        
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(configKey))) {
                if (i < keys.length - 1) {
                    keys[i] = keys[keys.length - 1];
                }
                keys.pop();
                break;
            }
        }
    }
    
    /**
     * @dev Validate data type
     */
    function _isValidDataType(string memory dataType) internal pure returns (bool) {
        bytes32 typeHash = keccak256(bytes(dataType));
        
        if (typeHash == keccak256(bytes("string"))) return true;
        if (typeHash == keccak256(bytes("number"))) return true;
        if (typeHash == keccak256(bytes("boolean"))) return true;
        if (typeHash == keccak256(bytes("array"))) return true;
        if (typeHash == keccak256(bytes("object"))) return true;
        
        return false;
    }
    
    /**
     * @dev Get configuration count for an agent
     */
    function getConfigCount(uint256 agentId) external view returns (uint256) {
        return _agentConfigKeys[agentId].length;
    }
    
    /**
     * @dev Check if configuration exists
     */
    function configExists(uint256 agentId, string memory configKey) external view returns (bool) {
        bytes32 keyHash = keccak256(bytes(configKey));
        return _agentConfigKeyExists[agentId][keyHash];
    }
    
    /**
     * @dev Get current config counter
     */
    function getConfigCounter() external view returns (uint256) {
        return _configCounter;
    }
}
