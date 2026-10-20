// contracts/test/PaymentReputationOracle.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PaymentReputationOracle,
    ISettlementVerifier,
    ICanonicalReputationRegistry,
    SettlementRecord
} from "../src/erc8004-extensions/PaymentReputationOracle.sol";
import {SettlementRegistry, SettlementRegistryVerifier} from "../src/erc8004-extensions/SettlementRegistry.sol";

/// @dev 注入式结算核对桩：字段默认回显查询参数（即「一致」），可注入「不存在 / 金额不符」。
contract MockSettlementVerifier is ISettlementVerifier {
    bool public exists = true;
    bool public useAmountOverride;
    uint256 public amountOverride;

    function setExists(bool v) external {
        exists = v;
    }

    function setAmountOverride(uint256 a) external {
        amountOverride = a;
        useAmountOverride = true;
    }

    function verifySettlement(
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        bytes32,
        uint64 settledAt
    ) external view returns (SettlementRecord memory) {
        return SettlementRecord({
            agentId: agentId,
            payer: payer,
            asset: asset,
            amount: useAmountOverride ? amountOverride : amount,
            rail: rail,
            settledAt: settledAt,
            exists: exists
        });
    }
}

/// @dev 记录镜像写入的伪 canonical ReputationRegistry。
contract MockCanonicalReputation is ICanonicalReputationRegistry {
    uint256 public callCount;
    uint256 public lastAgentId;
    int128 public lastValue;
    uint8 public lastDecimals;
    string public lastTag1;

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external {
        callCount += 1;
        lastAgentId = agentId;
        lastValue = value;
        lastDecimals = valueDecimals;
        lastTag1 = tag1;
    }
}

contract PaymentReputationOracleTest is Test {
    uint256 internal constant AMOUNT_CAP = 100e18;
    uint256 internal constant MAX_AGE = 180 days;
    uint256 internal constant PAYER_CAP = 3;

    PaymentReputationOracle internal oracle;
    MockSettlementVerifier internal verifier;
    MockCanonicalReputation internal registry;

    uint256 internal constant PAYER_PK = 0xA11CE;
    address internal payer;
    address internal stranger = address(0xB0B);

    function setUp() public {
        payer = vm.addr(PAYER_PK);
        oracle = new PaymentReputationOracle(AMOUNT_CAP, MAX_AGE, PAYER_CAP);
        verifier = new MockSettlementVerifier();
        registry = new MockCanonicalReputation();
        oracle.setSettlementVerifier(address(verifier));
        oracle.setReputationRegistry(address(registry));
    }

    // ── helpers ──

    function _proof(uint256 agentId, uint256 amount, uint64 settledAt, bytes32 settlementRef)
        internal
        view
        returns (PaymentReputationOracle.SettlementProof memory)
    {
        return _proof(agentId, amount, settledAt, settlementRef, "x402");
    }

    function _proof(uint256 agentId, uint256 amount, uint64 settledAt, bytes32 settlementRef, string memory rail)
        internal
        view
        returns (PaymentReputationOracle.SettlementProof memory)
    {
        return PaymentReputationOracle.SettlementProof({
            agentId: agentId,
            payer: payer,
            asset: address(0),
            amount: amount,
            rail: rail,
            taskRef: keccak256("task"),
            settlementRef: settlementRef,
            settledAt: settledAt
        });
    }

    function _sign(PaymentReputationOracle.SettlementProof memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, oracle.hashSettlementProof(p));
        return abi.encodePacked(r, s, v);
    }

    function _submit(uint256 agentId, uint256 amount, uint64 settledAt, bytes32 ref) internal {
        PaymentReputationOracle.SettlementProof memory p = _proof(agentId, amount, settledAt, ref);
        oracle.submitSettlement(p, _sign(p));
    }

    // ── 配置：immutable 参数 ──

    function test_Constructor_SetsImmutableParams() public {
        assertEq(oracle.amountCap(), AMOUNT_CAP);
        assertEq(oracle.maxAge(), MAX_AGE);
        assertEq(oracle.payerCap(), PAYER_CAP);
    }

    // ── 写入：正常路径 ──

    function test_Submit_ValidSignature_Records() public {
        uint64 t = uint64(block.timestamp);
        bytes32 ref = keccak256("ref-1");
        _submit(1, 10e18, t, ref);

        (uint256 weight, uint256 count) = oracle.getPaymentReputation(1);
        assertEq(count, 1);
        assertGt(weight, 0);
        assertEq(oracle.payerCount(1, payer), 1);
        assertEq(oracle.getAgentSettlementRefs(1).length, 1);

        PaymentReputationOracle.SettlementProof memory stored = oracle.getSettlement(ref);
        assertEq(stored.agentId, 1);
        assertEq(stored.payer, payer);
    }

    function test_Submit_ZeroPayer_Reverts() public {
        PaymentReputationOracle.SettlementProof memory p =
            PaymentReputationOracle.SettlementProof(1, address(0), address(0), 1e18, "x402", bytes32(0), keccak256("z"), uint64(block.timestamp));
        vm.expectRevert(PaymentReputationOracle.Oracle__ZeroAddress.selector);
        oracle.submitSettlement(p, "");
    }

    // ── 写入：验签 ──

    function test_Submit_WrongSigner_Reverts() public {
        PaymentReputationOracle.SettlementProof memory p = _proof(1, 1e18, uint64(block.timestamp), keccak256("w"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, oracle.hashSettlementProof(p));
        vm.expectRevert(PaymentReputationOracle.Oracle__InvalidSignature.selector);
        oracle.submitSettlement(p, abi.encodePacked(r, s, v));
    }

    // ── 写入：幂等 ──

    function test_Submit_DuplicateSettlementRef_Reverts() public {
        uint64 t = uint64(block.timestamp);
        bytes32 ref = keccak256("dup");
        _submit(1, 1e18, t, ref);

        PaymentReputationOracle.SettlementProof memory p = _proof(1, 1e18, t, ref);
        bytes memory sig = _sign(p);
        vm.expectRevert(PaymentReputationOracle.Oracle__SettlementAlreadyUsed.selector);
        oracle.submitSettlement(p, sig);
    }

    // ── 写入：WS2 交叉核对 ──

    function test_Submit_Unverified_Reverts() public {
        verifier.setExists(false);
        PaymentReputationOracle.SettlementProof memory p = _proof(1, 1e18, uint64(block.timestamp), keccak256("u"));
        bytes memory sig = _sign(p);
        vm.expectRevert(PaymentReputationOracle.Oracle__SettlementUnverified.selector);
        oracle.submitSettlement(p, sig);
    }

    function test_Submit_Mismatch_Reverts() public {
        verifier.setAmountOverride(1); // 结算记录金额 ≠ 证明金额
        PaymentReputationOracle.SettlementProof memory p = _proof(1, 1e18, uint64(block.timestamp), keccak256("mm"));
        bytes memory sig = _sign(p);
        vm.expectRevert(PaymentReputationOracle.Oracle__SettlementMismatch.selector);
        oracle.submitSettlement(p, sig);
    }

    function test_Submit_VerifierNotConfigured_Reverts() public {
        PaymentReputationOracle fresh = new PaymentReputationOracle(AMOUNT_CAP, MAX_AGE, PAYER_CAP);
        PaymentReputationOracle.SettlementProof memory p = _proof(1, 1e18, uint64(block.timestamp), keccak256("n"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, fresh.hashSettlementProof(p));
        vm.expectRevert(PaymentReputationOracle.Oracle__VerifierNotConfigured.selector);
        fresh.submitSettlement(p, abi.encodePacked(r, s, v));
    }

    // ── 权重：时间衰减 ──

    function test_Weight_TimeDecay() public {
        uint64 t0 = uint64(block.timestamp);
        _submit(1, oracle.amountCap(), t0, keccak256("d1"));

        (uint256 w0,) = oracle.getPaymentReputation(1);
        assertGt(w0, 0);

        vm.warp(t0 + oracle.maxAge() / 2);
        (uint256 w1,) = oracle.getPaymentReputation(1);
        assertLt(w1, w0);

        vm.warp(t0 + oracle.maxAge());
        (uint256 w2,) = oracle.getPaymentReputation(1);
        assertEq(w2, 0);
    }

    // ── 权重：金额封顶（防刷单）──

    function test_Weight_AmountCap() public {
        uint64 t = uint64(block.timestamp);
        bytes32 r1 = keccak256("cap-1");
        bytes32 r2 = keccak256("cap-2");
        _submit(2, oracle.amountCap(), t, r1);
        _submit(2, oracle.amountCap() * 10, t, r2);

        assertEq(oracle.contributionOf(r1), oracle.contributionOf(r2));
    }

    // ── 镜像到 canonical ──

    function test_Mirror_WritesCanonicalWithTag() public {
        uint64 t = uint64(block.timestamp);
        _submit(3, oracle.amountCap(), t, keccak256("m1"));

        oracle.mirrorToRegistry(3);

        assertEq(registry.callCount(), 1);
        assertEq(registry.lastAgentId(), 3);
        assertEq(registry.lastTag1(), "payment-settlement");
        assertEq(registry.lastDecimals(), 0);
        assertEq(registry.lastValue(), 1); // weight == WAD → scaled = 1
    }

    function test_Mirror_NothingToMirror_Reverts() public {
        vm.expectRevert(PaymentReputationOracle.Oracle__NothingToMirror.selector);
        oracle.mirrorToRegistry(999);
    }

    function test_Mirror_RegistryNotConfigured_Reverts() public {
        PaymentReputationOracle fresh = new PaymentReputationOracle(AMOUNT_CAP, MAX_AGE, PAYER_CAP);
        vm.expectRevert(PaymentReputationOracle.Oracle__RegistryNotConfigured.selector);
        fresh.mirrorToRegistry(1);
    }

    // ── Option A：SettlementRegistry + Verifier 端到端 ──

    function test_RegistryVerifier_EndToEnd() public {
        SettlementRegistry reg = new SettlementRegistry();
        reg.setWriter(address(this), true);
        SettlementRegistryVerifier rv = new SettlementRegistryVerifier(address(reg));
        oracle.setSettlementVerifier(address(rv));

        uint64 t = uint64(block.timestamp);
        bytes32 ref = keccak256("reg-1");
        reg.writeSettlement(ref, 7, payer, address(0), 5e18, "erc8183", t);

        PaymentReputationOracle.SettlementProof memory p = _proof(7, 5e18, t, ref, "erc8183");
        oracle.submitSettlement(p, _sign(p));

        (uint256 w, uint256 c) = oracle.getPaymentReputation(7);
        assertEq(c, 1);
        assertGt(w, 0);
    }

    function test_Registry_WriteTwice_Reverts() public {
        SettlementRegistry reg = new SettlementRegistry();
        reg.setWriter(address(this), true);
        uint64 t = uint64(block.timestamp);
        bytes32 ref = keccak256("reg-2");
        reg.writeSettlement(ref, 1, payer, address(0), 1e18, "x402", t);
        vm.expectRevert(SettlementRegistry.Registry__AlreadyWritten.selector);
        reg.writeSettlement(ref, 1, payer, address(0), 1e18, "x402", t);
    }

    function test_Registry_NotWriter_Reverts() public {
        SettlementRegistry reg = new SettlementRegistry();
        vm.expectRevert(SettlementRegistry.Registry__NotWriter.selector);
        reg.writeSettlement(keccak256("reg-3"), 1, payer, address(0), 1e18, "x402", uint64(block.timestamp));
    }

    function test_RegistryVerifier_ZeroAddress_Reverts() public {
        vm.expectRevert(SettlementRegistryVerifier.Verifier__ZeroAddress.selector);
        new SettlementRegistryVerifier(address(0));
    }

    // ── 权限 ──

    function test_SetSettlementVerifier_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setSettlementVerifier(address(verifier));
    }

    function test_SetReputationRegistry_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setReputationRegistry(address(registry));
    }
}
