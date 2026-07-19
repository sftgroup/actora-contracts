// contracts/extensions/AgentFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";
import "./MultiEndpointRegistry.sol";

/**
 * @title AgentFactory
 * @dev Factory for creating AI Agents with predefined templates
 * @notice Production-ready agent factory with template management
 */
contract AgentFactory is Ownable {
    IERC8004Identity public immutable identityRegistry;
    MultiEndpointRegistry public immutable endpointRegistry;
    
    uint256 private _templateCounter; // 修复：使用原生计数器替代Counters
    
    struct AgentTemplate {
        uint256 templateId;
        string name;
        string description;
        string baseURI;
        string[] endpointTypes;
        string[] endpointURIs;
        string[] protocols; // 新增：存储协议类型
        string[] endpointNames; // 新增：存储端点名称
        string[] configKeys;
        string[] configValues;
        string[] dataTypes;
        bool isActive;
        uint256 createdAt;
        address createdBy;
    }
    
    // Storage
    mapping(uint256 => AgentTemplate) private _templates;
    mapping(uint256 => uint256[]) private _agentTemplates;
    
    // Events
    event TemplateCreated(
        uint256 indexed templateId,
        string name,
        string description,
        address indexed createdBy
    );
    
    event AgentCreated(
        uint256 indexed agentId,
        uint256 indexed templateId,
        address indexed owner,
        string agentURI
    );
    
    // Custom errors
    error AgentFactory__InvalidTemplate();
    error AgentFactory__TemplateNotActive();
    error AgentFactory__InvalidInput();
    error AgentFactory__CreationFailed();

    constructor(address _identityRegistry, address _endpointRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0) || _endpointRegistry == address(0)) {
            revert AgentFactory__InvalidInput();
        }
        identityRegistry = IERC8004Identity(_identityRegistry);
        endpointRegistry = MultiEndpointRegistry(_endpointRegistry);
        _templateCounter = 0; // 初始化计数器
    }
    
    /**
     * @dev Create a new agent template
     */
    function createTemplate(
        string memory name,
        string memory description,
        string memory baseURI,
        string[] memory endpointTypes,
        string[] memory endpointURIs,
        string[] memory protocols, // 新增：协议数组
        string[] memory endpointNames, // 新增：端点名称数组
        string[] memory configKeys,
        string[] memory configValues,
        string[] memory dataTypes
    ) external onlyOwner returns (uint256 templateId) {
        if (bytes(name).length == 0) {
            revert AgentFactory__InvalidInput();
        }
        
        if (endpointTypes.length != endpointURIs.length || 
            endpointTypes.length != protocols.length ||
            endpointTypes.length != endpointNames.length) {
            revert AgentFactory__InvalidInput();
        }
        
        if (configKeys.length != configValues.length || configKeys.length != dataTypes.length) {
            revert AgentFactory__InvalidInput();
        }
        
        _templateCounter++; // 修复：使用原生计数器递增
        templateId = _templateCounter;
        
        AgentTemplate memory newTemplate = AgentTemplate({
            templateId: templateId,
            name: name,
            description: description,
            baseURI: baseURI,
            endpointTypes: endpointTypes,
            endpointURIs: endpointURIs,
            protocols: protocols, // 新增：存储协议
            endpointNames: endpointNames, // 新增：存储端点名称
            configKeys: configKeys,
            configValues: configValues,
            dataTypes: dataTypes,
            isActive: true,
            createdAt: block.timestamp,
            createdBy: msg.sender
        });
        
        _templates[templateId] = newTemplate;
        
        emit TemplateCreated(templateId, name, description, msg.sender);
        return templateId;
    }
    
    /**
     * @dev Create agent from template
     */
    function createAgentFromTemplate(uint256 templateId) external payable returns (uint256 agentId) {
        AgentTemplate memory template = _templates[templateId];
        
        if (template.templateId == 0) {
            revert AgentFactory__InvalidTemplate();
        }
        
        if (!template.isActive) {
            revert AgentFactory__TemplateNotActive();
        }
        
        // 创建agent
        agentId = identityRegistry.register{value: msg.value}(template.baseURI);
        
        // 修复：使用正确的 createEndpoint 方法创建端点
        for (uint256 i = 0; i < template.endpointTypes.length; i++) {
            endpointRegistry.createEndpoint(
                agentId,
                template.endpointNames[i], // 使用模板中的端点名称
                template.endpointTypes[i], // 端点类型
                template.protocols[i],     // 协议类型
                template.endpointURIs[i],  // 端点URI
                ""                         // 描述可以为空
            );
        }
        
        // 记录使用的模板
        _agentTemplates[agentId].push(templateId);
        
        emit AgentCreated(agentId, templateId, msg.sender, template.baseURI);
        return agentId;
    }
    
    /**
     * @dev Create multiple agents from template
     */
    function createAgentsFromTemplate(
        uint256 templateId,
        uint256 count
    ) external payable returns (uint256[] memory agentIds) {
        if (count == 0) {
            revert AgentFactory__InvalidInput();
        }
        
        AgentTemplate memory template = _templates[templateId];
        
        if (template.templateId == 0) {
            revert AgentFactory__InvalidTemplate();
        }
        
        if (!template.isActive) {
            revert AgentFactory__TemplateNotActive();
        }
        
        agentIds = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            agentIds[i] = identityRegistry.register{value: msg.value / count}(template.baseURI);
            
            // 修复：使用正确的 createEndpoint 方法创建端点
            for (uint256 j = 0; j < template.endpointTypes.length; j++) {
                endpointRegistry.createEndpoint(
                    agentIds[i],
                    template.endpointNames[j], // 使用模板中的端点名称
                    template.endpointTypes[j], // 端点类型
                    template.protocols[j],     // 协议类型
                    template.endpointURIs[j],  // 端点URI
                    ""                         // 描述可以为空
                );
            }
            
            // 记录使用的模板
            _agentTemplates[agentIds[i]].push(templateId);
            
            emit AgentCreated(agentIds[i], templateId, msg.sender, template.baseURI);
        }
        
        return agentIds;
    }
    
    /**
     * @dev Update template
     */
    function updateTemplate(
        uint256 templateId,
        string memory name,
        string memory description,
        string memory baseURI,
        string[] memory endpointTypes,
        string[] memory endpointURIs,
        string[] memory protocols, // 新增：协议数组
        string[] memory endpointNames, // 新增：端点名称数组
        string[] memory configKeys,
        string[] memory configValues,
        string[] memory dataTypes
    ) external onlyOwner {
        AgentTemplate storage template = _templates[templateId];
        
        if (template.templateId == 0) {
            revert AgentFactory__InvalidTemplate();
        }
        
        template.name = name;
        template.description = description;
        template.baseURI = baseURI;
        template.endpointTypes = endpointTypes;
        template.endpointURIs = endpointURIs;
        template.protocols = protocols; // 新增：更新协议
        template.endpointNames = endpointNames; // 新增：更新端点名称
        template.configKeys = configKeys;
        template.configValues = configValues;
        template.dataTypes = dataTypes;
    }
    
    /**
     * @dev Set template active status
     */
    function setTemplateActive(uint256 templateId, bool isActive) external onlyOwner {
        AgentTemplate storage template = _templates[templateId];
        
        if (template.templateId == 0) {
            revert AgentFactory__InvalidTemplate();
        }
        
        template.isActive = isActive;
    }
    
    /**
     * @dev Get template details
     */
    function getTemplate(uint256 templateId) external view returns (AgentTemplate memory) {
        AgentTemplate memory template = _templates[templateId];
        
        if (template.templateId == 0) {
            revert AgentFactory__InvalidTemplate();
        }
        
        return template;
    }
    
    /**
     * @dev Get all templates
     */
    function getAllTemplates() external view returns (AgentTemplate[] memory) {
        AgentTemplate[] memory templates = new AgentTemplate[](_templateCounter);
        
        for (uint256 i = 1; i <= _templateCounter; i++) {
            templates[i - 1] = _templates[i];
        }
        
        return templates;
    }
    
    /**
     * @dev Get templates used by an agent
     */
    function getAgentTemplates(uint256 agentId) external view returns (uint256[] memory) {
        return _agentTemplates[agentId];
    }
    
    /**
     * @dev Get total template count
     */
    function getTotalTemplates() external view returns (uint256) {
        return _templateCounter;
    }

    /**
     * @dev Get current template counter
     */
    function getTemplateCounter() external view returns (uint256) {
        return _templateCounter;
    }
    
    /**
     * @dev Check if template exists
     */
    function templateExists(uint256 templateId) external view returns (bool) {
        return _templates[templateId].templateId != 0;
    }
}
