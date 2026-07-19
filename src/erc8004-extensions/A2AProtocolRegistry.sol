// contracts/extensions/A2AProtocolRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @title A2AProtocolRegistry
 * @dev Full A2A protocol support for AI Agents with Agent Cards and skills management
 * @notice Implements A2A protocol features including Agent Cards, skills, and task orchestration
 */
contract A2AProtocolRegistry is Ownable {
    IERC8004Identity public immutable identityRegistry;
    IERC721 public immutable erc721Identity;
    
    // 修复：手动实现计数器
    uint256 private _agentCardCounter;
    uint256 private _skillCounter;
    uint256 private _taskCounter;
    
    // A2A Agent Card structure
    struct AgentCard {
        uint256 cardId;
        uint256 agentId;
        string name;
        string description;
        string version;
        string[] capabilities;
        string[] supportedTasks;
        string communicationProtocol;
        string authenticationMethod;
        string cardURI;
        bool isActive;
        uint256 createdAt;
        uint256 updatedAt;
        address createdBy;
    }
    
    // A2A Skill definition
    struct A2ASkill {
        uint256 skillId;
        string name;
        string description;
        string inputSchema;
        string outputSchema;
        string[] requiredCapabilities;
        uint256 complexity;
        bool isActive;
        uint256 createdAt;
    }
    
    // Agent Skill association
    struct AgentSkill {
        uint256 agentId;
        uint256 skillId;
        string skillEndpoint;
        string version;
        uint256 price;
        address priceToken;
        bool isActive;
        uint256 registeredAt;
    }
    
    // A2A Task definition
    struct A2ATask {
        uint256 taskId;
        uint256 agentId;
        string taskType;
        string inputData;
        string outputData;
        uint256 status;
        address clientAddress;
        uint256 createdAt;
        uint256 completedAt;
        bytes32 taskHash;
    }
    
    // Storage
    mapping(uint256 => AgentCard) private _agentCards;
    mapping(uint256 => A2ASkill) private _a2aSkills;
    mapping(uint256 => mapping(uint256 => AgentSkill)) private _agentSkills;
    mapping(uint256 => uint256[]) private _agentSkillIds;
    mapping(uint256 => A2ATask) private _a2aTasks;
    mapping(uint256 => uint256[]) private _agentTasks;
    mapping(address => uint256[]) private _userTasks;
    
    // Events
    event AgentCardCreated(
        uint256 indexed cardId,
        uint256 indexed agentId,
        string name,
        string version,
        string cardURI
    );
    
    event AgentCardUpdated(
        uint256 indexed cardId,
        uint256 indexed agentId,
        string name,
        string version
    );
    
    event SkillRegistered(
        uint256 indexed skillId,
        string name,
        string description,
        uint256 complexity
    );
    
    event AgentSkillAdded(
        uint256 indexed agentId,
        uint256 indexed skillId,
        string skillEndpoint,
        string version
    );
    
    event TaskCreated(
        uint256 indexed taskId,
        uint256 indexed agentId,
        address indexed clientAddress,
        string taskType,
        uint256 status
    );
    
    event TaskCompleted(
        uint256 indexed taskId,
        uint256 indexed agentId,
        uint256 status,
        uint256 completedAt
    );
    
    // Custom errors
    error A2AProtocol__AgentNotOwner();
    error A2AProtocol__AgentCardNotFound();
    error A2AProtocol__SkillNotFound();
    error A2AProtocol__TaskNotFound();
    error A2AProtocol__InvalidInput();
    error A2AProtocol__TaskNotActive();
    error A2AProtocol__Unauthorized();

    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert A2AProtocol__InvalidInput();
        }
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        
        // 修复：初始化计数器
        _agentCardCounter = 1;
        _skillCounter = 1;
        _taskCounter = 1;
        
        _initializeDefaultSkills();
    }
    
    /**
     * @dev Create or update A2A Agent Card
     */
    function createAgentCard(
        uint256 agentId,
        string memory name,
        string memory description,
        string memory version,
        string[] memory capabilities,
        string[] memory supportedTasks,
        string memory communicationProtocol,
        string memory authenticationMethod,
        string memory cardURI
    ) external returns (uint256 cardId) {
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert A2AProtocol__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert A2AProtocol__AgentNotOwner();
        }
        
        if (bytes(name).length == 0 || bytes(description).length == 0) {
            revert A2AProtocol__InvalidInput();
        }
        
        // 修复：使用手动计数器
        uint256 currentCounter = _agentCardCounter;
        for (uint256 i = 1; i < currentCounter; i++) {
            AgentCard storage card = _agentCards[i];
            if (card.agentId == agentId && card.isActive) {
                card.name = name;
                card.description = description;
                card.version = version;
                card.capabilities = capabilities;
                card.supportedTasks = supportedTasks;
                card.communicationProtocol = communicationProtocol;
                card.authenticationMethod = authenticationMethod;
                card.cardURI = cardURI;
                card.updatedAt = block.timestamp;
                
                emit AgentCardUpdated(i, agentId, name, version);
                return i;
            }
        }
        
        cardId = _agentCardCounter;
        _agentCardCounter++;
        
        AgentCard memory newCard = AgentCard({
            cardId: cardId,
            agentId: agentId,
            name: name,
            description: description,
            version: version,
            capabilities: capabilities,
            supportedTasks: supportedTasks,
            communicationProtocol: communicationProtocol,
            authenticationMethod: authenticationMethod,
            cardURI: cardURI,
            isActive: true,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            createdBy: msg.sender
        });
        
        _agentCards[cardId] = newCard;
        
        emit AgentCardCreated(cardId, agentId, name, version, cardURI);
        return cardId;
    }
    
    /**
     * @dev Register a new A2A skill
     */
    function registerSkill(
        string memory name,
        string memory description,
        string memory inputSchema,
        string memory outputSchema,
        string[] memory requiredCapabilities,
        uint256 complexity
    ) external onlyOwner returns (uint256 skillId) {
        if (bytes(name).length == 0 || complexity == 0 || complexity > 10) {
            revert A2AProtocol__InvalidInput();
        }
        
        skillId = _skillCounter;
        _skillCounter++;
        
        A2ASkill memory newSkill = A2ASkill({
            skillId: skillId,
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            requiredCapabilities: requiredCapabilities,
            complexity: complexity,
            isActive: true,
            createdAt: block.timestamp
        });
        
        _a2aSkills[skillId] = newSkill;
        
        emit SkillRegistered(skillId, name, description, complexity);
        return skillId;
    }
    
    /**
     * @dev Add skill to agent
     */
    function addAgentSkill(
        uint256 agentId,
        uint256 skillId,
        string memory skillEndpoint,
        string memory version,
        uint256 price,
        address priceToken
    ) external {
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert A2AProtocol__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert A2AProtocol__AgentNotOwner();
        }
        
        A2ASkill storage skill = _a2aSkills[skillId];
        if (!skill.isActive) {
            revert A2AProtocol__SkillNotFound();
        }
        
        if (bytes(skillEndpoint).length == 0) {
            revert A2AProtocol__InvalidInput();
        }
        
        AgentSkill memory agentSkill = AgentSkill({
            agentId: agentId,
            skillId: skillId,
            skillEndpoint: skillEndpoint,
            version: version,
            price: price,
            priceToken: priceToken,
            isActive: true,
            registeredAt: block.timestamp
        });
        
        _agentSkills[agentId][skillId] = agentSkill;
        _agentSkillIds[agentId].push(skillId);
        
        emit AgentSkillAdded(agentId, skillId, skillEndpoint, version);
    }
    
    /**
     * @dev Create A2A task
     */
    function createTask(
        uint256 agentId,
        string memory taskType,
        string memory inputData
    ) external returns (uint256 taskId) {
        if (!identityRegistry.agentExists(agentId)) {
            revert A2AProtocol__InvalidInput();
        }
        
        taskId = _taskCounter;
        _taskCounter++;
        
        bytes32 taskHash = keccak256(abi.encode(
            taskId,
            agentId,
            msg.sender,
            taskType,
            inputData,
            block.timestamp
        ));
        
        A2ATask memory newTask = A2ATask({
            taskId: taskId,
            agentId: agentId,
            taskType: taskType,
            inputData: inputData,
            outputData: "",
            status: 0,
            clientAddress: msg.sender,
            createdAt: block.timestamp,
            completedAt: 0,
            taskHash: taskHash
        });
        
        _a2aTasks[taskId] = newTask;
        _agentTasks[agentId].push(taskId);
        _userTasks[msg.sender].push(taskId);
        
        emit TaskCreated(taskId, agentId, msg.sender, taskType, 0);
        return taskId;
    }
    
    /**
     * @dev Complete A2A task (only agent owner can call)
     */
    function completeTask(
        uint256 taskId,
        string memory outputData,
        uint256 status
    ) external {
        A2ATask storage task = _a2aTasks[taskId];
        if (task.taskId == 0) {
            revert A2AProtocol__TaskNotFound();
        }
        
        address agentOwner;
        try erc721Identity.ownerOf(task.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert A2AProtocol__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert A2AProtocol__AgentNotOwner();
        }
        
        if (task.status != 0 && task.status != 1) {
            revert A2AProtocol__TaskNotActive();
        }
        
        task.outputData = outputData;
        task.status = status;
        task.completedAt = block.timestamp;
        
        emit TaskCompleted(taskId, task.agentId, status, block.timestamp);
    }
    
    /**
     * @dev Get agent card by agent ID
     */
    function getAgentCard(uint256 agentId) external view returns (AgentCard memory) {
        uint256 currentCounter = _agentCardCounter;
        for (uint256 i = 1; i < currentCounter; i++) {
            AgentCard storage card = _agentCards[i];
            if (card.agentId == agentId && card.isActive) {
                return card;
            }
        }
        revert A2AProtocol__AgentCardNotFound();
    }
    
    /**
     * @dev Get A2A skill by ID
     */
    function getSkill(uint256 skillId) external view returns (A2ASkill memory) {
        A2ASkill memory skill = _a2aSkills[skillId];
        if (!skill.isActive) {
            revert A2AProtocol__SkillNotFound();
        }
        return skill;
    }
    
    /**
     * @dev Get agent skills
     */
    function getAgentSkills(uint256 agentId) external view returns (AgentSkill[] memory) {
        uint256[] storage skillIds = _agentSkillIds[agentId];
        AgentSkill[] memory skills = new AgentSkill[](skillIds.length);
        
        for (uint256 i = 0; i < skillIds.length; i++) {
            skills[i] = _agentSkills[agentId][skillIds[i]];
        }
        
        return skills;
    }
    
    /**
     * @dev Get task by ID
     */
    function getTask(uint256 taskId) external view returns (A2ATask memory) {
        A2ATask memory task = _a2aTasks[taskId];
        if (task.taskId == 0) {
            revert A2AProtocol__TaskNotFound();
        }
        return task;
    }
    
    /**
     * @dev Get agent tasks
     */
    function getAgentTasks(uint256 agentId) external view returns (A2ATask[] memory) {
        uint256[] storage taskIds = _agentTasks[agentId];
        A2ATask[] memory tasks = new A2ATask[](taskIds.length);
        
        for (uint256 i = 0; i < taskIds.length; i++) {
            tasks[i] = _a2aTasks[taskIds[i]];
        }
        
        return tasks;
    }
    
    /**
     * @dev Get all task IDs created by a user
     */
    function getUserTasks(address user) external view returns (uint256[] memory) {
        return _userTasks[user];
    }

    /**
     * @dev Search agents by skill
     */
    function searchAgentsBySkill(uint256 skillId) external view returns (uint256[] memory agentIds) {
        uint256 totalAgents = identityRegistry.getCurrentAgentId();
        uint256 count = 0;
        
        for (uint256 i = 1; i <= totalAgents; i++) {
            AgentSkill storage agentSkill = _agentSkills[i][skillId];
            if (agentSkill.isActive) {
                count++;
            }
        }
        
        agentIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= totalAgents; i++) {
            AgentSkill storage agentSkill = _agentSkills[i][skillId];
            if (agentSkill.isActive) {
                agentIds[index] = i;
                index++;
            }
        }
        
        return agentIds;
    }
    
    /**
     * @dev Initialize default A2A skills
     */
    function _initializeDefaultSkills() internal {
        string[] memory textCapabilities = new string[](2);
        textCapabilities[0] = "text-generation";
        textCapabilities[1] = "natural-language-processing";
        
        // 修复：直接创建技能，不调用外部函数
        uint256 skillId1 = _skillCounter;
        _skillCounter++;
        _a2aSkills[skillId1] = A2ASkill({
            skillId: skillId1,
            name: "Text Generation",
            description: "Generate human-like text based on prompts",
            inputSchema: '{"type":"object","properties":{"prompt":{"type":"string"},"max_length":{"type":"integer"}}}',
            outputSchema: '{"type":"object","properties":{"generated_text":{"type":"string"}}}',
            requiredCapabilities: textCapabilities,
            complexity: 3,
            isActive: true,
            createdAt: block.timestamp
        });
        emit SkillRegistered(skillId1, "Text Generation", "Generate human-like text based on prompts", 3);
        
        string[] memory imageCapabilities = new string[](2);
        imageCapabilities[0] = "image-generation";
        imageCapabilities[1] = "computer-vision";
        
        uint256 skillId2 = _skillCounter;
        _skillCounter++;
        _a2aSkills[skillId2] = A2ASkill({
            skillId: skillId2,
            name: "Image Generation",
            description: "Generate images from text descriptions",
            inputSchema: '{"type":"object","properties":{"prompt":{"type":"string"},"size":{"type":"string"}}}',
            outputSchema: '{"type":"object","properties":{"image_url":{"type":"string"}}}',
            requiredCapabilities: imageCapabilities,
            complexity: 5,
            isActive: true,
            createdAt: block.timestamp
        });
        emit SkillRegistered(skillId2, "Image Generation", "Generate images from text descriptions", 5);
        
        string[] memory dataCapabilities = new string[](2);
        dataCapabilities[0] = "data-analysis";
        dataCapabilities[1] = "statistical-computing";
        
        uint256 skillId3 = _skillCounter;
        _skillCounter++;
        _a2aSkills[skillId3] = A2ASkill({
            skillId: skillId3,
            name: "Data Analysis",
            description: "Analyze and process structured data",
            inputSchema: '{"type":"object","properties":{"data":{"type":"array"},"analysis_type":{"type":"string"}}}',
            outputSchema: '{"type":"object","properties":{"result":{"type":"object"},"insights":{"type":"array"}}}',
            requiredCapabilities: dataCapabilities,
            complexity: 4,
            isActive: true,
            createdAt: block.timestamp
        });
        emit SkillRegistered(skillId3, "Data Analysis", "Analyze and process structured data", 4);
    }
    
    /**
     * @dev Get all available skills
     */
    function getAllSkills() external view returns (A2ASkill[] memory) {
        uint256 totalSkills = _skillCounter - 1;
        A2ASkill[] memory skills = new A2ASkill[](totalSkills);
        
        for (uint256 i = 1; i <= totalSkills; i++) {
            skills[i-1] = _a2aSkills[i];
        }
        
        return skills;
    }
    
    /**
     * @dev Get task statistics for agent
     */
    function getAgentTaskStats(uint256 agentId) external view returns (
        uint256 totalTasks,
        uint256 completedTasks,
        uint256 failedTasks,
        uint256 successRate
    ) {
        uint256[] storage taskIds = _agentTasks[agentId];
        totalTasks = taskIds.length;
        
        for (uint256 i = 0; i < taskIds.length; i++) {
            A2ATask memory task = _a2aTasks[taskIds[i]];
            if (task.status == 2) {
                completedTasks++;
            } else if (task.status == 3) {
                failedTasks++;
            }
        }
        
        if (totalTasks > 0) {
            successRate = (completedTasks * 100) / totalTasks;
        }
        
        return (totalTasks, completedTasks, failedTasks, successRate);
    }
}
