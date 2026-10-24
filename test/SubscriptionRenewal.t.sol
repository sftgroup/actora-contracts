// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../src/erc8004-extensions/SubscriptionManager.sol";
import "../src/erc8004-extensions/TokenPriceOracle.sol";

contract MockRenewIdentity is ERC721 {
    constructor() ERC721("Mock Agent", "MAGENT") {}

    function mint(address to, uint256 agentId) external {
        _mint(to, agentId);
    }
}

/**
 * @notice 手动续费（processPayment）与旧签名门禁查询（hasActiveSubscription）的回归测试。
 *         这两个入口是为了让网关 / SDK / 前端在切到 ERC8004SubscriptionManager 后
 *         不需要改调用方——续费必须延长原 subscriptionId，而不是新建订阅。
 */
contract SubscriptionRenewalTest is Test {
    ERC8004SubscriptionManager private manager;
    MockRenewIdentity private identity;

    address private agentOwner = makeAddr("agentOwner");
    address private subscriber = makeAddr("subscriber");
    address private other = makeAddr("other");
    address private feeCollector = makeAddr("feeCollector");

    uint256 private constant PRICE = 10 ether;
    uint256 private constant FEE_BPS = 250;
    uint256 private constant MONTH = 30 days;
    uint256 private planId;

    function setUp() public {
        identity = new MockRenewIdentity();
        identity.mint(agentOwner, 1);

        TokenPriceOracle oracle = new TokenPriceOracle();
        manager = new ERC8004SubscriptionManager(
            address(identity),
            address(oracle),
            feeCollector
        );
        manager.setDefaultPlatformFee(FEE_BPS);

        vm.prank(agentOwner);
        planId = manager.createPlan(
            1,
            "Pro",
            "monthly pro plan",
            ERC8004SubscriptionManager.PlanType.Subscription,
            address(0),
            PRICE,
            0,
            ERC8004SubscriptionManager.BillingPeriod.Monthly,
            0,
            0
        );

        vm.deal(subscriber, 100 ether);
    }

    function _subscribe() private returns (uint256 subscriptionId) {
        vm.prank(subscriber);
        subscriptionId = manager.subscribe{value: PRICE}(planId);
    }

    function test_HasActiveSubscription_TrueAfterSubscribe() public {
        uint256 id = _subscribe();
        assertTrue(manager.isSubscriptionActive(id));
        assertTrue(manager.hasActiveSubscription(subscriber, 1));
    }

    function test_HasActiveSubscription_FalseForOtherAgentOrUser() public {
        _subscribe();
        assertFalse(manager.hasActiveSubscription(subscriber, 2));
        assertFalse(manager.hasActiveSubscription(other, 1));
    }

    function test_HasActiveSubscription_FalseAfterGracePeriod() public {
        uint256 id = _subscribe();
        ERC8004SubscriptionManager.Subscription memory s = manager.getSubscription(id);

        // 宽限期（默认 3 天）内仍算有效
        vm.warp(s.nextBillingDate + 3 days);
        assertTrue(manager.hasActiveSubscription(subscriber, 1));

        vm.warp(s.nextBillingDate + 3 days + 1);
        assertFalse(manager.hasActiveSubscription(subscriber, 1));
    }

    function test_Renew_ExtendsFromOriginalDueDate() public {
        uint256 id = _subscribe();
        ERC8004SubscriptionManager.Subscription memory before = manager.getSubscription(id);

        vm.warp(block.timestamp + 5 days);
        vm.prank(subscriber);
        manager.processPayment{value: PRICE}(id);

        ERC8004SubscriptionManager.Subscription memory afterRenew = manager.getSubscription(id);
        assertEq(afterRenew.subscriptionId, id, "must renew the same subscription");
        assertEq(afterRenew.nextBillingDate, before.nextBillingDate + MONTH);
        assertEq(afterRenew.totalPaid, PRICE * 2);

        uint256 fee = (PRICE * FEE_BPS) / 10_000;
        assertEq(feeCollector.balance, fee * 2);
        assertEq(agentOwner.balance, (PRICE - fee) * 2);
    }

    function test_Renew_AfterExpiry_StartsFromNow() public {
        uint256 id = _subscribe();
        ERC8004SubscriptionManager.Subscription memory before = manager.getSubscription(id);

        vm.warp(before.nextBillingDate + 10 days);
        vm.prank(subscriber);
        manager.processPayment{value: PRICE}(id);

        ERC8004SubscriptionManager.Subscription memory afterRenew = manager.getSubscription(id);
        assertEq(afterRenew.nextBillingDate, block.timestamp + MONTH);
    }

    function test_RevertWhen_RenewByNonSubscriber() public {
        uint256 id = _subscribe();

        vm.deal(other, 100 ether);
        vm.prank(other);
        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__NotAuthorized.selector);
        manager.processPayment{value: PRICE}(id);
    }

    function test_RevertWhen_RenewWithWrongValue() public {
        uint256 id = _subscribe();

        vm.prank(subscriber);
        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__InvalidAmount.selector);
        manager.processPayment{value: PRICE - 1}(id);
    }

    function test_RevertWhen_RenewUnknownSubscription() public {
        vm.prank(subscriber);
        vm.expectRevert(ERC8004SubscriptionManager.SubscriptionManager__SubscriptionNotFound.selector);
        manager.processPayment{value: PRICE}(999);
    }
}
