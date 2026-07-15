// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/IdentityRegistry.sol";
import "../src/SubscriptionManager.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "mUSDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AgentXTest is Test {
    IdentityRegistry public registry;
    SubscriptionManager public subscriptions;
    MockUSDT public usdt;

    address creator = makeAddr("creator");
    address subscriber = makeAddr("subscriber");
    address other = makeAddr("other");
    address platform = makeAddr("platform");

    uint256 constant INITIAL_FEE_BPS = 250; // 2.5%

    function setUp() public {
        registry = new IdentityRegistry();
        subscriptions = new SubscriptionManager(INITIAL_FEE_BPS);
        usdt = new MockUSDT();
        subscriptions.setTokenWhitelist(address(usdt), true);
    }

    // ── IdentityRegistry ─────────────────────────────────────────────────

    function test_RegisterAgent() public {
        vm.prank(creator);
        uint256 agentId = registry.register("ipfs://QmTest");
        assertEq(agentId, 1);
        assertTrue(registry.agentExists(1));
        assertEq(registry.getAgentOwner(1), creator);
    }

    function test_RegisterWithMetadata() public {
        IdentityRegistry.MetadataEntry[] memory meta = new IdentityRegistry.MetadataEntry[](2);
        meta[0] = IdentityRegistry.MetadataEntry("encryptedPayloadCid", bytes("QmEncrypted"));
        meta[1] = IdentityRegistry.MetadataEntry("eciesEncryptedKey", bytes("0x1234"));
        vm.prank(creator);
        uint256 id = registry.registerWithMetadata("ipfs://QmMeta", meta);
        IdentityRegistry.MetadataEntry[] memory attrs = registry.getAgentMetadata(id);
        assertEq(attrs.length, 2);
    }

    function test_GetAgentsByOwner() public {
        vm.startPrank(creator);
        registry.register("A"); registry.register("B"); registry.register("C");
        vm.stopPrank();
        assertEq(registry.getAgentsByOwner(creator).length, 3);
    }

    function test_OnlyOwnerCanUpdateMetadata() public {
        vm.prank(creator); registry.register("ipfs://QmTest");
        IdentityRegistry.MetadataEntry[] memory meta = new IdentityRegistry.MetadataEntry[](1);
        meta[0] = IdentityRegistry.MetadataEntry("version", bytes("2.0.0"));
        vm.prank(other);
        vm.expectRevert("Not agent owner");
        registry.updateMetadata(1, meta);
    }

    // ── Platform Fee ─────────────────────────────────────────────────────

    function test_PlatformFeeConfig() public {
        assertEq(subscriptions.platformFeeBps(), 250);
        subscriptions.setPlatformFee(500);
        assertEq(subscriptions.platformFeeBps(), 500);
        vm.expectRevert("Max 20%");
        subscriptions.setPlatformFee(3000);
    }

    function test_OnlyOwnerCanSetFee() public {
        vm.prank(other);
        vm.expectRevert();
        subscriptions.setPlatformFee(100);
    }

    // ── Create Plan ──────────────────────────────────────────────────────

    function test_CreatePlan_ETH() public {
        vm.prank(creator);
        uint256 id = subscriptions.createPlan(1, 0.01 ether, "month", address(0), 0);
        SubscriptionManager.SubscriptionPlan memory p = subscriptions.getPlan(id);
        assertEq(p.price, 0.01 ether);
        assertEq(p.payToken, address(0));
        assertEq(p.trialDays, 0);
    }

    function test_CreatePlan_WithTrial() public {
        vm.prank(creator);
        uint256 id = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 7);
        assertEq(subscriptions.getPlan(id).trialDays, 7);
    }

    function test_CreatePlan_ERC20() public {
        vm.prank(creator);
        uint256 id = subscriptions.createPlan(1, 100e18, "month", address(usdt), 0);
        assertEq(subscriptions.getPlan(id).payToken, address(usdt));
    }

    function test_CreatePlan_UnwhitelistedToken() public {
        vm.prank(creator);
        vm.expectRevert("Token not whitelisted");
        subscriptions.createPlan(1, 100, "month", makeAddr("fake"), 0);
    }

    // ── Subscribe: ETH (no trial) ────────────────────────────────────────

    function test_Subscribe_ETH() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 0);

        vm.deal(subscriber, 1 ether);
        uint256 creatorBefore = creator.balance;

        vm.prank(subscriber);
        subscriptions.subscribe{value: 0.1 ether}(planId);

        assertTrue(subscriptions.hasActiveSubscription(subscriber, 1));

        // No trial → funds released immediately
        uint256 expectedCreator = 0.1 ether - (0.1 ether * 250 / 10000);
        assertEq(creator.balance - creatorBefore, expectedCreator);
        assertEq(subscriptions.platformFeesCollected(address(0)), 0.1 ether * 250 / 10000);
    }

    // ── Subscribe: ERC20 ─────────────────────────────────────────────────

    function test_Subscribe_ERC20() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 100e18, "month", address(usdt), 0);

        usdt.mint(subscriber, 1000e18);
        vm.startPrank(subscriber);
        usdt.approve(address(subscriptions), 100e18);
        subscriptions.subscribe(planId);

        assertTrue(subscriptions.hasActiveSubscription(subscriber, 1));
        assertEq(usdt.balanceOf(creator), 100e18 - (100e18 * 250 / 10000));
    }

    // ── Trial + Refund ───────────────────────────────────────────────────

    function test_TrialRefund_WithinWindow() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 7);

        vm.deal(subscriber, 1 ether);
        uint256 balBefore = subscriber.balance;

        vm.prank(subscriber);
        uint256 subId = subscriptions.subscribe{value: 0.1 ether}(planId);

        assertTrue(subscriptions.hasActiveSubscription(subscriber, 1));

        // Cancel within trial window — full refund
        vm.prank(subscriber);
        subscriptions.cancelSubscription(subId);

        assertFalse(subscriptions.hasActiveSubscription(subscriber, 1));
        assertEq(subscriber.balance, balBefore); // 100% refund
    }

    function test_TrialNoRefund_AfterWindow() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 7);

        vm.deal(subscriber, 1 ether);
        vm.prank(subscriber);
        uint256 subId = subscriptions.subscribe{value: 0.1 ether}(planId);

        // Warp past 7-day trial window
        vm.warp(block.timestamp + 8 days);

        // Cancel after trial — no refund
        vm.prank(subscriber);
        subscriptions.cancelSubscription(subId);

        assertFalse(subscriptions.hasActiveSubscription(subscriber, 1));
        // ETH not returned
        assertLt(subscriber.balance, 1 ether);
    }

    // ── Release Funds ─────────────────────────────────────────────────────

    function test_ReleaseFunds_AfterTrial() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 7);

        vm.deal(subscriber, 1 ether);
        uint256 creatorBefore = creator.balance;

        vm.prank(subscriber);
        uint256 subId = subscriptions.subscribe{value: 0.1 ether}(planId);

        // Creator hasn't been paid yet (funds in escrow)
        assertEq(creator.balance, creatorBefore);

        // Warp past trial
        vm.warp(block.timestamp + 8 days);

        // Release funds
        subscriptions.releaseFunds(subId);

        uint256 expectedCreator = 0.1 ether - (0.1 ether * 250 / 10000);
        assertEq(creator.balance - creatorBefore, expectedCreator);
        assertGt(subscriptions.platformFeesCollected(address(0)), 0);
    }

    // ── No Trial → No Refund ─────────────────────────────────────────────

    function test_NoTrialNoRefund() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 0);

        vm.deal(subscriber, 1 ether);
        uint256 balBefore = subscriber.balance;

        vm.prank(subscriber);
        uint256 subId = subscriptions.subscribe{value: 0.1 ether}(planId);

        vm.prank(subscriber);
        subscriptions.cancelSubscription(subId);

        assertLt(subscriber.balance, balBefore); // money not returned
    }

    // ── Admin: Withdraw ──────────────────────────────────────────────────

    function test_WithdrawPlatformFees() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 0);

        vm.deal(subscriber, 1 ether);
        vm.prank(subscriber);
        subscriptions.subscribe{value: 0.1 ether}(planId);

        // After 10 subscriptions, withdraw
        uint256 fees = subscriptions.platformFeesCollected(address(0));
        assertGt(fees, 0);

        subscriptions.withdrawPlatformFees(address(0), platform);
        assertEq(subscriptions.platformFeesCollected(address(0)), 0);
        assertEq(platform.balance, fees);
    }

    // ── Edge Cases ───────────────────────────────────────────────────────

    function test_SubscribeInsufficientETH() public {
        vm.prank(creator);
        uint256 planId = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 0);
        vm.deal(subscriber, 0.05 ether);
        vm.prank(subscriber);
        vm.expectRevert("Insufficient ETH");
        subscriptions.subscribe{value: 0.05 ether}(planId);
    }

    function test_NoActiveSubscriptionForNonSubscriber() public {
        assertFalse(subscriptions.hasActiveSubscription(subscriber, 1));
    }

    function test_GetUserSubscriptions() public {
        vm.prank(creator);
        uint256 p1 = subscriptions.createPlan(1, 0.1 ether, "month", address(0), 0);
        vm.prank(other);
        uint256 p2 = subscriptions.createPlan(2, 0.05 ether, "day", address(0), 0);

        vm.deal(subscriber, 1 ether);
        vm.startPrank(subscriber);
        subscriptions.subscribe{value: 0.1 ether}(p1);
        subscriptions.subscribe{value: 0.05 ether}(p2);
        vm.stopPrank();

        assertEq(subscriptions.getUserSubscriptions(subscriber).length, 2);
    }
}
