// contracts/test/PaymentReputationOracleV2.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    PaymentReputationOracleV2,
    ISettlementVerifierV2,
    ICanonicalReputationRegistryV2,
    ISubscriptionManagerV2,
    SettlementRecordV2
} from "../src/erc8004-extensions/PaymentReputationOracleV2.sol";

/// @dev 回显式结算核对桩。
contract MockVerifierV2 is ISettlementVerifierV2 {
    bool public exists = true;

    function setExists(bool v) external {
        exists = v;
    }

    function verifySettlement(
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        bytes32,
        uint64 settledAt
    ) external view returns (SettlementRecordV2 memory) {
        return SettlementRecordV2({
            agentId: agentId,
            payer: payer,
            asset: asset,
            amount: amount,
            rail: rail,
            settledAt: settledAt,
            exists: exists
        });
    }
}

/// @dev 可注入订阅状态的 SubscriptionManager 桩（对齐 ERC8004SubscriptionManager）。
contract MockSubscriptionManagerV2 is ISubscriptionManagerV2 {
    mapping(uint256 => ISubscriptionManagerV2.Subscription) internal _subs;

    function set(
        uint256 subscriptionId,
        address subscriber,
        uint256 agentId,
        uint8 status,
        uint256 startDate,
        address paymentToken,
        uint256 totalPaid
    ) external {
        _subs[subscriptionId] = ISubscriptionManagerV2.Subscription({
            subscriptionId: subscriptionId,
            planId: 1,
            agentId: agentId,
            subscriber: subscriber,
            status: status,
            planType: 0,
            startDate: startDate,
            nextBillingDate: startDate + 30 days,
            endDate: 0,
            currentPeriodUsage: 0,
            totalUsage: 0,
            remainingUsage: 0,
            totalPaid: totalPaid,
            createdAt: startDate,
            lastPaymentDate: startDate,
            paymentToken: paymentToken
        });
    }

    function getSubscription(uint256 subscriptionId)
        external
        view
        returns (ISubscriptionManagerV2.Subscription memory)
    {
        return _subs[subscriptionId];
    }
}

/// @dev 最小 ERC-1271 合约钱包：owner 的 ECDSA 签名视为有效。
contract MockSmartWallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return 0x1626ba7e;
        return 0xffffffff;
    }
}

contract MockCanonicalReputationV2 is ICanonicalReputationRegistryV2 {
    uint256 public callCount;
    uint256 public lastAgentId;
    int128 public lastValue;
    string public lastTag1;

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8,
        string calldata tag1,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external {
        callCount += 1;
        lastAgentId = agentId;
        lastValue = value;
        lastTag1 = tag1;
    }
}

contract PaymentReputationOracleV2Test is Test {
    uint256 internal constant AMOUNT_CAP = 100e18;
    uint256 internal constant MAX_AGE = 180 days;
    uint256 internal constant PAYER_CAP = 3;

    uint256 internal constant PAYER_PK = 0xA11CE;
    address internal payer;

    PaymentReputationOracleV2 internal oracle;
    MockVerifierV2 internal verifier;
    MockSubscriptionManagerV2 internal manager;
    MockCanonicalReputationV2 internal registry;

    function setUp() public {
        payer = vm.addr(PAYER_PK);
        manager = new MockSubscriptionManagerV2();
        verifier = new MockVerifierV2();
        registry = new MockCanonicalReputationV2();
        oracle = new PaymentReputationOracleV2(AMOUNT_CAP, MAX_AGE, PAYER_CAP, address(manager));
        oracle.setSettlementVerifier(address(verifier));
        oracle.setReputationRegistry(address(registry));
    }

    // ── helpers ──

    function _proof(address who, uint256 agentId, uint256 amount, uint64 settledAt, bytes32 ref)
        internal
        pure
        returns (PaymentReputationOracleV2.SettlementProof memory)
    {
        return PaymentReputationOracleV2.SettlementProof({
            agentId: agentId,
            payer: who,
            asset: address(0),
            amount: amount,
            rail: "x402",
            taskRef: keccak256("task"),
            settlementRef: ref,
            settledAt: settledAt
        });
    }

    function _sign(uint256 pk, PaymentReputationOracleV2.SettlementProof memory p)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.hashSettlementProof(p));
        return abi.encodePacked(r, s, v);
    }

    function _subRef(uint256 subscriptionId) internal view returns (bytes32) {
        return keccak256(abi.encode(keccak256("subscription"), block.chainid, address(manager), subscriptionId));
    }

    // ── 签名路径 ──

    function test_Submit_EOA_Records() public {
        uint64 t = uint64(block.timestamp);
        bytes32 ref = keccak256("eoa-1");
        PaymentReputationOracleV2.SettlementProof memory p = _proof(payer, 1, 10e18, t, ref);
        oracle.submitSettlement(p, _sign(PAYER_PK, p));

        (uint256 weight, uint256 count) = oracle.getPaymentReputation(1);
        assertEq(count, 1);
        assertGt(weight, 0);
        assertEq(oracle.getSettlement(ref).payer, payer);
    }

    function test_Submit_ERC1271_Records() public {
        MockSmartWallet wallet = new MockSmartWallet(payer);
        uint64 t = uint64(block.timestamp);
        PaymentReputationOracleV2.SettlementProof memory p =
            _proof(address(wallet), 2, 10e18, t, keccak256("1271-1"));

        // 合约钱包的 owner 对摘要签名，由钱包合约通过 ERC-1271 验证
        oracle.submitSettlement(p, _sign(PAYER_PK, p));

        (, uint256 count) = oracle.getPaymentReputation(2);
        assertEq(count, 1);
        assertEq(oracle.getSettlement(keccak256("1271-1")).payer, address(wallet));
    }

    function test_Submit_WrongSigner_Reverts() public {
        PaymentReputationOracleV2.SettlementProof memory p =
            _proof(payer, 1, 1e18, uint64(block.timestamp), keccak256("wrong"));
        bytes memory sig = _sign(0xBEEF, p);
        vm.expectRevert(PaymentReputationOracleV2.Oracle__InvalidSignature.selector);
        oracle.submitSettlement(p, sig);
    }

    // ── 链上订阅路径 ──

    function test_Subscription_Records() public {
        uint256 t = block.timestamp;
        manager.set(11, payer, 7, 0, t, address(0), 5e18);

        oracle.submitSubscriptionSettlement(7, payer, 11);

        (uint256 weight, uint256 count) = oracle.getPaymentReputation(7);
        assertEq(count, 1);
        assertGt(weight, 0);

        PaymentReputationOracleV2.SettlementProof memory stored = oracle.getSettlement(_subRef(11));
        assertEq(stored.agentId, 7);
        assertEq(stored.payer, payer);
        assertEq(stored.amount, 5e18);
        assertEq(stored.settledAt, uint64(t));
        assertEq(stored.rail, "subscription");
        assertEq(oracle.lastSubscriptionIdOf(payer, 7), 11);
        assertEq(oracle.payerCount(7, payer), 1);
    }

    function test_Subscription_Duplicate_Reverts() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), 5e18);
        oracle.submitSubscriptionSettlement(7, payer, 11);

        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementAlreadyUsed.selector);
        oracle.submitSubscriptionSettlement(7, payer, 11);
    }

    function test_Subscription_LowerId_Reverts() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), 5e18);
        manager.set(10, payer, 7, 0, block.timestamp, address(0), 5e18);
        oracle.submitSubscriptionSettlement(7, payer, 11);

        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementAlreadyUsed.selector);
        oracle.submitSubscriptionSettlement(7, payer, 10);
    }

    function test_Subscription_NewerId_Accumulates() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), 5e18);
        manager.set(12, payer, 7, 0, block.timestamp + 30 days, address(0), 5e18);

        oracle.submitSubscriptionSettlement(7, payer, 11);
        oracle.submitSubscriptionSettlement(7, payer, 12);

        (, uint256 count) = oracle.getPaymentReputation(7);
        assertEq(count, 2);
        assertEq(oracle.lastSubscriptionIdOf(payer, 7), 12);
    }

    function test_Subscription_Cancelled_Reverts() public {
        manager.set(11, payer, 7, 1, block.timestamp, address(0), 5e18);
        vm.expectRevert(PaymentReputationOracleV2.Oracle__SubscriptionCancelled.selector);
        oracle.submitSubscriptionSettlement(7, payer, 11);
    }

    function test_Subscription_Expired_Accepted() public {
        manager.set(11, payer, 7, 2, block.timestamp, address(0), 5e18);
        oracle.submitSubscriptionSettlement(7, payer, 11);
        (, uint256 count) = oracle.getPaymentReputation(7);
        assertEq(count, 1);
    }

    function test_Subscription_Mismatch_Reverts() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), 5e18);

        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementMismatch.selector);
        oracle.submitSubscriptionSettlement(8, payer, 11);

        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementMismatch.selector);
        oracle.submitSubscriptionSettlement(7, address(0xB0B), 11);
    }

    function test_Subscription_Unknown_Reverts() public {
        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementUnverified.selector);
        oracle.submitSubscriptionSettlement(7, payer, 999);
    }

    function test_Subscription_ZeroAmount_Reverts() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), 0);
        vm.expectRevert(PaymentReputationOracleV2.Oracle__SettlementUnverified.selector);
        oracle.submitSubscriptionSettlement(7, payer, 11);
    }

    // ── 镜像 ──

    function test_Mirror_AfterSubscription() public {
        manager.set(11, payer, 7, 0, block.timestamp, address(0), AMOUNT_CAP);
        oracle.submitSubscriptionSettlement(7, payer, 11);
        oracle.mirrorToRegistry(7);

        assertEq(registry.callCount(), 1);
        assertEq(registry.lastAgentId(), 7);
        assertEq(registry.lastValue(), 1);
        assertEq(registry.lastTag1(), "payment-settlement");
    }

    // ── 管理 ──

    function test_SetSubscriptionManager_OnlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B))
        );
        oracle.setSubscriptionManager(address(manager));
    }
}
