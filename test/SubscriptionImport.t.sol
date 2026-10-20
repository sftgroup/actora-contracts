// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../src/erc8004-extensions/SubscriptionManager.sol";
import "../src/erc8004-extensions/AgentWallet.sol";
import "../src/erc8004-extensions/TokenPriceOracle.sol";

contract MockSubscriptionIdentity is ERC721 {
    constructor() ERC721("Mock Agent", "MAGENT") {}

    function mint(address to, uint256 agentId) external {
        _mint(to, agentId);
    }
}

contract SubscriptionImportTest is Test {
    ERC8004SubscriptionManager private manager;
    MockSubscriptionIdentity private identity;

    address private agentOwner = makeAddr("agentOwner");
    address private subscriber = makeAddr("subscriber");
    address private feeCollector = makeAddr("feeCollector");

    uint256 private constant PLAN_ID = 1;
    uint256 private constant START = 1_700_000_000;
    uint256 private constant NEXT_BILLING = START + 30 days;
    uint256 private constant END = START + 180 days;

    function setUp() public {
        identity = new MockSubscriptionIdentity();
        identity.mint(agentOwner, 1);

        AgentWallet wallet = new AgentWallet(address(identity));
        TokenPriceOracle oracle = new TokenPriceOracle();
        manager = new ERC8004SubscriptionManager(
            address(identity),
            address(wallet),
            address(oracle),
            feeCollector
        );

        vm.prank(agentOwner);
        manager.createPlan(
            1,
            "Pro",
            "monthly pro plan",
            ERC8004SubscriptionManager.PlanType.Subscription,
            address(0),
            10 ether,
            0,
            ERC8004SubscriptionManager.BillingPeriod.Monthly,
            0,
            0
        );
    }

    function _item(
        address who,
        ERC8004SubscriptionManager.SubscriptionStatus status,
        uint256 autoRenewal
    ) private pure returns (ERC8004SubscriptionManager.ImportedSubscription memory) {
        return ERC8004SubscriptionManager.ImportedSubscription({
            planId: PLAN_ID,
            subscriber: who,
            status: status,
            startDate: START,
            nextBillingDate: NEXT_BILLING,
            endDate: END,
            totalPaid: 30 ether,
            autoRenewal: autoRenewal
        });
    }

    function test_Import_PreservesFields() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 2);

        uint256 imported = manager.importSubscriptions(items);

        assertEq(imported, 1);
        assertTrue(manager.subscriptionsImported());
        assertEq(manager.getTotalSubscriptionCount(), 1);

        ERC8004SubscriptionManager.Subscription memory s = manager.getSubscription(1);
        assertEq(s.subscriptionId, 1);
        assertEq(s.planId, PLAN_ID);
        assertEq(s.agentId, 1);
        assertEq(s.subscriber, subscriber);
        assertEq(uint256(s.status), uint256(ERC8004SubscriptionManager.SubscriptionStatus.Active));
        assertEq(uint256(s.planType), uint256(ERC8004SubscriptionManager.PlanType.Subscription));
        assertEq(s.startDate, START);
        assertEq(s.nextBillingDate, NEXT_BILLING);
        assertEq(s.endDate, END);
        assertEq(s.totalPaid, 30 ether);
        assertEq(s.autoRenewal, 2);
        assertEq(s.createdAt, START);
        assertEq(s.lastPaymentDate, START);
        assertEq(s.paymentToken, address(0));
        assertEq(s.remainingUsage, 0);
    }

    function test_Import_DerivesPlanTypeAndUsage() public {
        vm.prank(agentOwner);
        uint256 usagePlanId = manager.createPlan(
            1,
            "Metered",
            "usage based",
            ERC8004SubscriptionManager.PlanType.UsageBased,
            address(0),
            0,
            1 ether,
            ERC8004SubscriptionManager.BillingPeriod.Monthly,
            0,
            500
        );

        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);
        items[0].planId = usagePlanId;

        manager.importSubscriptions(items);

        ERC8004SubscriptionManager.Subscription memory s = manager.getSubscription(1);
        assertEq(uint256(s.planType), uint256(ERC8004SubscriptionManager.PlanType.UsageBased));
        assertEq(s.remainingUsage, 500);
    }

    function test_Import_Indexes() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](2);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);
        items[1] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Cancelled, 1);

        manager.importSubscriptions(items);

        assertEq(manager.getUserSubscriptions(subscriber).length, 2);
        assertEq(manager.getAgentSubscriptionCount(1), 2);
        assertEq(manager.getAgentActiveSubscriptionCount(1), 1);
        assertEq(manager.getTotalSubscriptionCount(), 2);
    }

    function test_Import_OnlyActiveEntersActiveSet() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](3);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);
        items[1] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Cancelled, 0);
        items[2] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Expired, 0);

        manager.importSubscriptions(items);

        assertTrue(manager.isSubscriptionActive(1));
        assertFalse(manager.isSubscriptionActive(2));
        assertFalse(manager.isSubscriptionActive(3));
    }

    function test_Import_EmitsEvents() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 1);

        vm.expectEmit(true, true, true, true, address(manager));
        emit ERC8004SubscriptionManager.SubscriptionCreated(
            1,
            PLAN_ID,
            1,
            subscriber,
            ERC8004SubscriptionManager.PlanType.Subscription,
            START,
            NEXT_BILLING,
            1
        );
        vm.expectEmit(true, true, true, true, address(manager));
        emit ERC8004SubscriptionManager.SubscriptionsImported(1);

        manager.importSubscriptions(items);
    }

    function test_RevertWhen_CalledTwice() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);

        manager.importSubscriptions(items);

        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__AlreadyImported.selector);
        manager.importSubscriptions(items);
    }

    function test_RevertWhen_NotOwner() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);

        vm.prank(subscriber);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                subscriber
            )
        );
        manager.importSubscriptions(items);
    }

    function test_RevertWhen_UnknownPlan() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(subscriber, ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);
        items[0].planId = 999;

        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__InvalidPlan.selector);
        manager.importSubscriptions(items);
    }

    function test_RevertWhen_ZeroSubscriber() public {
        ERC8004SubscriptionManager.ImportedSubscription[]
            memory items = new ERC8004SubscriptionManager.ImportedSubscription[](1);
        items[0] = _item(address(0), ERC8004SubscriptionManager.SubscriptionStatus.Active, 0);

        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__InvalidSubscriber.selector);
        manager.importSubscriptions(items);
    }
}
