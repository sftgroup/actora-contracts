// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../src/erc8004-extensions/SubscriptionManager.sol";
import "../src/erc8004-extensions/AgentWallet.sol";
import "../src/erc8004-extensions/TokenPriceOracle.sol";
import "../src/erc8004-extensions/MultiEndpointRegistry.sol";
import "../src/erc8004-extensions/A2AProtocolRegistry.sol";

contract MockIdentity is ERC721 {
    constructor() ERC721("Mock Agent", "MAGENT") {}

    function mint(address to, uint256 agentId) external {
        _mint(to, agentId);
    }
}

/// @notice P1.7：importPlans / importEndpoints / importSkills 的一次性重放入口
contract ImportReplayTest is Test {
    ERC8004SubscriptionManager private manager;
    MultiEndpointRegistry private endpoints;
    A2AProtocolRegistry private a2a;
    MockIdentity private identity;

    address private agentOwner = makeAddr("agentOwner");
    address private feeCollector = makeAddr("feeCollector");
    address private stranger = makeAddr("stranger");

    uint256 private constant AGENT_ID = 1;
    uint256 private constant CREATED_AT = 1_700_000_000;

    function setUp() public {
        identity = new MockIdentity();
        identity.mint(agentOwner, AGENT_ID);

        AgentWallet wallet = new AgentWallet(address(identity));
        TokenPriceOracle oracle = new TokenPriceOracle();
        manager = new ERC8004SubscriptionManager(
            address(identity),
            address(wallet),
            address(oracle),
            feeCollector
        );
        endpoints = new MultiEndpointRegistry(address(identity));
        a2a = new A2AProtocolRegistry(address(identity));
    }

    // ---------------------------------------------------------------------
    // importPlans
    // ---------------------------------------------------------------------

    function _plan(
        string memory name,
        ERC8004SubscriptionManager.PlanType planType,
        uint256 subscriptionPrice,
        uint256 usagePrice
    ) private pure returns (ERC8004SubscriptionManager.ImportedPlan memory) {
        return ERC8004SubscriptionManager.ImportedPlan({
            agentId: AGENT_ID,
            name: name,
            description: "imported plan",
            planType: planType,
            token: address(0),
            subscriptionPrice: subscriptionPrice,
            usagePrice: usagePrice,
            billingPeriod: ERC8004SubscriptionManager.BillingPeriod.Monthly,
            maxUsage: 0,
            totalUsageLimit: 500,
            isActive: true,
            createdAt: CREATED_AT,
            platformFeePercentage: 250
        });
    }

    function test_ImportPlans_PreservesFields() public {
        ERC8004SubscriptionManager.ImportedPlan[]
            memory items = new ERC8004SubscriptionManager.ImportedPlan[](2);
        items[0] = _plan(
            "Pro",
            ERC8004SubscriptionManager.PlanType.Subscription,
            10 ether,
            0
        );
        items[1] = _plan(
            "Metered",
            ERC8004SubscriptionManager.PlanType.Hybrid,
            5 ether,
            1 ether
        );

        uint256 imported = manager.importPlans(items);

        assertEq(imported, 2);
        assertTrue(manager.plansImported());
        assertEq(manager.getTotalPlanCount(), 2);

        ERC8004SubscriptionManager.SubscriptionPlan memory plan = manager.getPlan(1);
        assertEq(plan.planId, 1);
        assertEq(plan.agentId, AGENT_ID);
        assertEq(plan.name, "Pro");
        assertEq(plan.description, "imported plan");
        assertEq(
            uint256(plan.planType),
            uint256(ERC8004SubscriptionManager.PlanType.Subscription)
        );
        assertEq(plan.subscriptionPrice, 10 ether);
        assertEq(plan.usagePrice, 0);
        assertEq(
            uint256(plan.billingPeriod),
            uint256(ERC8004SubscriptionManager.BillingPeriod.Monthly)
        );
        assertEq(plan.totalUsageLimit, 500);
        assertTrue(plan.isActive);
        assertEq(plan.createdAt, CREATED_AT);
        assertEq(plan.platformFeePercentage, 250);

        ERC8004SubscriptionManager.SubscriptionPlan[] memory agentPlans =
            manager.getAgentPlans(AGENT_ID);
        assertEq(agentPlans.length, 2);
        assertEq(agentPlans[1].planId, 2);
        assertEq(agentPlans[1].usagePrice, 1 ether);
    }

    function test_ImportPlans_CalledTwiceReverts() public {
        ERC8004SubscriptionManager.ImportedPlan[]
            memory items = new ERC8004SubscriptionManager.ImportedPlan[](1);
        items[0] = _plan(
            "Pro",
            ERC8004SubscriptionManager.PlanType.Subscription,
            10 ether,
            0
        );

        manager.importPlans(items);

        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__AlreadyImported.selector);
        manager.importPlans(items);
    }

    function test_ImportPlans_NotOwnerReverts() public {
        ERC8004SubscriptionManager.ImportedPlan[]
            memory items = new ERC8004SubscriptionManager.ImportedPlan[](1);
        items[0] = _plan(
            "Pro",
            ERC8004SubscriptionManager.PlanType.Subscription,
            10 ether,
            0
        );

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        manager.importPlans(items);
    }

    function test_ImportPlans_UnknownAgentReverts() public {
        ERC8004SubscriptionManager.ImportedPlan[]
            memory items = new ERC8004SubscriptionManager.ImportedPlan[](1);
        items[0] = _plan(
            "Pro",
            ERC8004SubscriptionManager.PlanType.Subscription,
            10 ether,
            0
        );
        items[0].agentId = 999;

        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__InvalidAgent.selector);
        manager.importPlans(items);
    }

    // ---------------------------------------------------------------------
    // importEndpoints
    // ---------------------------------------------------------------------

    function _endpoint(
        string memory name,
        string memory protocol,
        string memory url
    ) private pure returns (MultiEndpointRegistry.ImportedEndpoint memory) {
        return MultiEndpointRegistry.ImportedEndpoint({
            agentId: AGENT_ID,
            name: name,
            endpointType: "a2a",
            protocol: protocol,
            url: url,
            description: "imported endpoint",
            isActive: true,
            createdAt: CREATED_AT,
            createdBy: address(0)
        });
    }

    function test_ImportEndpoints_PreservesFieldsAndIndex() public {
        MultiEndpointRegistry.ImportedEndpoint[]
            memory items = new MultiEndpointRegistry.ImportedEndpoint[](2);
        items[0] = _endpoint("primary", "HTTP", "https://agent.example/a2a");
        items[1] = _endpoint("stream", "WebSocket", "wss://agent.example/ws");

        uint256 imported = endpoints.importEndpoints(items);

        assertEq(imported, 2);
        assertTrue(endpoints.endpointsImported());

        MultiEndpointRegistry.Endpoint memory first = endpoints.getEndpoint(1);
        assertEq(first.endpointId, 1);
        assertEq(first.agentId, AGENT_ID);
        assertEq(first.name, "primary");
        assertEq(first.protocol, "HTTP");
        assertEq(first.url, "https://agent.example/a2a");
        assertEq(first.createdAt, CREATED_AT);
        assertEq(first.createdBy, address(this));

        MultiEndpointRegistry.Endpoint[] memory list = endpoints.getAgentEndpoints(AGENT_ID);
        assertEq(list.length, 2);
        assertEq(list[1].endpointId, 2);
        assertEq(list[1].protocol, "WebSocket");
    }

    function test_ImportEndpoints_CalledTwiceReverts() public {
        MultiEndpointRegistry.ImportedEndpoint[]
            memory items = new MultiEndpointRegistry.ImportedEndpoint[](1);
        items[0] = _endpoint("primary", "HTTP", "https://agent.example/a2a");

        endpoints.importEndpoints(items);

        vm.expectRevert(MultiEndpointRegistry.MultiEndpoint__AlreadyImported.selector);
        endpoints.importEndpoints(items);
    }

    function test_ImportEndpoints_NotOwnerReverts() public {
        MultiEndpointRegistry.ImportedEndpoint[]
            memory items = new MultiEndpointRegistry.ImportedEndpoint[](1);
        items[0] = _endpoint("primary", "HTTP", "https://agent.example/a2a");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        endpoints.importEndpoints(items);
    }

    function test_ImportEndpoints_UnsupportedProtocolReverts() public {
        MultiEndpointRegistry.ImportedEndpoint[]
            memory items = new MultiEndpointRegistry.ImportedEndpoint[](1);
        items[0] = _endpoint("primary", "CARRIER-PIGEON", "https://agent.example/a2a");

        vm.expectRevert(MultiEndpointRegistry.MultiEndpoint__ProtocolNotSupported.selector);
        endpoints.importEndpoints(items);
    }

    // ---------------------------------------------------------------------
    // importSkills
    // ---------------------------------------------------------------------

    function _skill(
        uint256 skillId,
        string memory url
    ) private pure returns (A2AProtocolRegistry.ImportedAgentSkill memory) {
        return A2AProtocolRegistry.ImportedAgentSkill({
            agentId: AGENT_ID,
            skillId: skillId,
            skillEndpoint: url,
            version: "1.0.0",
            price: 1 ether,
            priceToken: address(0),
            isActive: true,
            registeredAt: CREATED_AT
        });
    }

    function test_ImportSkills_PreservesFieldsAndIndex() public {
        A2AProtocolRegistry.ImportedAgentSkill[]
            memory items = new A2AProtocolRegistry.ImportedAgentSkill[](2);
        items[0] = _skill(1, "https://agent.example/skills/text");
        items[1] = _skill(3, "https://agent.example/skills/data");

        uint256 imported = a2a.importSkills(items);

        assertEq(imported, 2);
        assertTrue(a2a.agentSkillsImported());

        A2AProtocolRegistry.AgentSkill[] memory skills = a2a.getAgentSkills(AGENT_ID);
        assertEq(skills.length, 2);
        assertEq(skills[0].skillId, 1);
        assertEq(skills[0].skillEndpoint, "https://agent.example/skills/text");
        assertEq(skills[0].version, "1.0.0");
        assertEq(skills[0].price, 1 ether);
        assertEq(skills[0].registeredAt, CREATED_AT);
        assertEq(skills[1].skillId, 3);
    }

    function test_ImportSkills_DuplicatePairIndexedOnce() public {
        A2AProtocolRegistry.ImportedAgentSkill[]
            memory items = new A2AProtocolRegistry.ImportedAgentSkill[](2);
        items[0] = _skill(1, "https://agent.example/skills/text");
        items[1] = _skill(1, "https://agent.example/skills/text-v2");

        a2a.importSkills(items);

        A2AProtocolRegistry.AgentSkill[] memory skills = a2a.getAgentSkills(AGENT_ID);
        assertEq(skills.length, 1);
        assertEq(skills[0].skillEndpoint, "https://agent.example/skills/text-v2");
    }

    function test_ImportSkills_CalledTwiceReverts() public {
        A2AProtocolRegistry.ImportedAgentSkill[]
            memory items = new A2AProtocolRegistry.ImportedAgentSkill[](1);
        items[0] = _skill(1, "https://agent.example/skills/text");

        a2a.importSkills(items);

        vm.expectRevert(A2AProtocolRegistry.A2AProtocol__AlreadyImported.selector);
        a2a.importSkills(items);
    }

    function test_ImportSkills_NotOwnerReverts() public {
        A2AProtocolRegistry.ImportedAgentSkill[]
            memory items = new A2AProtocolRegistry.ImportedAgentSkill[](1);
        items[0] = _skill(1, "https://agent.example/skills/text");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        a2a.importSkills(items);
    }

    function test_ImportSkills_UnknownSkillReverts() public {
        A2AProtocolRegistry.ImportedAgentSkill[]
            memory items = new A2AProtocolRegistry.ImportedAgentSkill[](1);
        items[0] = _skill(999, "https://agent.example/skills/unknown");

        vm.expectRevert(A2AProtocolRegistry.A2AProtocol__SkillNotFound.selector);
        a2a.importSkills(items);
    }
}
