// contracts/test/Erc8183Verifier.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PaymentReputationOracle,
    SettlementRecord
} from "../src/erc8004-extensions/PaymentReputationOracle.sol";
import {
    Erc8183Verifier,
    IAgenticCommerce,
    IERC8004IdentityOwner
} from "../src/erc8004-extensions/Erc8183Verifier.sol";

/// @dev 官方 ERC-8183 内核桩：可注入 job / 代币 / getJob 是否 revert。
contract MockACPCore is IAgenticCommerce {
    mapping(uint256 => Job) internal _jobs;
    mapping(uint256 => address) internal _jobTokens;
    address internal _defaultToken;
    bool public revertGetJob;

    function setJob(
        uint256 jobId,
        address client,
        address provider,
        uint256 budget,
        JobStatus status,
        uint256 submittedAt
    ) external {
        _jobs[jobId] = Job({
            id: jobId,
            client: client,
            provider: provider,
            evaluator: client,
            description: "",
            budget: budget,
            expiredAt: block.timestamp + 1 days,
            status: status,
            hook: address(0),
            submittedAt: submittedAt,
            deliverable: bytes32(0)
        });
    }

    function setJobToken(uint256 jobId, address token) external {
        _jobTokens[jobId] = token;
    }

    function setDefaultToken(address token) external {
        _defaultToken = token;
    }

    function setRevertGetJob(bool v) external {
        revertGetJob = v;
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        if (revertGetJob) revert("InvalidJob");
        return _jobs[jobId];
    }

    function paymentToken() external view returns (address) {
        return _defaultToken;
    }

    function jobPaymentToken(uint256 jobId) external view returns (address) {
        return _jobTokens[jobId];
    }
}

/// @dev ERC-8004 身份注册表桩：agentId → owner。
contract MockIdentity is IERC8004IdentityOwner {
    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        require(o != address(0), "unknown agent");
        return o;
    }
}

contract Erc8183VerifierTest is Test {
    uint256 internal constant AGENT_ID = 7;
    uint256 internal constant JOB_ID = 42;
    uint256 internal constant BUDGET = 5e18;

    MockACPCore internal core;
    MockIdentity internal identity;
    Erc8183Verifier internal verifier;

    address internal payer = address(0xA11CE);
    address internal provider = address(0xB0B);
    address internal token = address(0x1234);
    address internal other = address(0xDEAD);

    function setUp() public {
        vm.warp(1_000_000_000); // 非零时间戳，避免 timestamp 减法下溢
        core = new MockACPCore();
        identity = new MockIdentity();
        verifier = new Erc8183Verifier(address(core), address(identity));

        // 默认一笔「已完成的 job」
        core.setJob(JOB_ID, payer, provider, BUDGET, IAgenticCommerce.JobStatus.Completed, block.timestamp - 100);
        core.setJobToken(JOB_ID, token);
        identity.setOwner(AGENT_ID, provider);
    }

    function _verify(string memory rail, uint64 settledAt) internal view returns (SettlementRecord memory) {
        return verifier.verifySettlement(
            AGENT_ID, payer, token, BUDGET, rail, bytes32(JOB_ID), settledAt
        );
    }

    // ── 正常路径 ──

    function test_Verify_Valid_CompletedJob() public {
        uint64 t = uint64(block.timestamp);
        SettlementRecord memory r = _verify("erc8183", t);

        assertTrue(r.exists);
        assertEq(r.agentId, AGENT_ID);
        assertEq(r.payer, payer);
        assertEq(r.asset, token);
        assertEq(r.amount, BUDGET);
        assertEq(r.rail, "erc8183");
        assertEq(r.settledAt, t);
    }

    function test_Verify_FallsBackToDefaultToken() public {
        core.setJobToken(JOB_ID, address(0)); // 无 per-job token
        core.setDefaultToken(token);          // 回退默认代币

        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp));
        assertTrue(r.exists);
        assertEq(r.asset, token);
    }

    // ── rail 过滤 ──

    function test_Verify_WrongRail_ReturnsNotExists() public {
        SettlementRecord memory r = _verify("x402", uint64(block.timestamp));
        assertFalse(r.exists);
    }

    // ── job 不存在 ──

    function test_Verify_GetJobReverts_ReturnsNotExists() public {
        core.setRevertGetJob(true);
        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp));
        assertFalse(r.exists);
    }

    function test_Verify_UnknownJob_ReturnsNotExists() public {
        // 未注册的 jobId：getJob 返回零结构体（client == 0）
        SettlementRecord memory r = verifier.verifySettlement(
            AGENT_ID, payer, token, BUDGET, "erc8183", bytes32(uint256(999)), uint64(block.timestamp)
        );
        assertFalse(r.exists);
    }

    // ── 状态 / 字段核验 ──

    function test_Verify_NotCompleted_ReturnsNotExists() public {
        core.setJob(JOB_ID, payer, provider, BUDGET, IAgenticCommerce.JobStatus.Submitted, block.timestamp - 100);
        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp));
        assertFalse(r.exists);
    }

    function test_Verify_PayerMismatch_ReturnsNotExists() public {
        SettlementRecord memory r = verifier.verifySettlement(
            AGENT_ID, other, token, BUDGET, "erc8183", bytes32(JOB_ID), uint64(block.timestamp)
        );
        assertFalse(r.exists);
    }

    function test_Verify_AmountMismatch_ReturnsNotExists() public {
        SettlementRecord memory r = verifier.verifySettlement(
            AGENT_ID, payer, token, BUDGET + 1, "erc8183", bytes32(JOB_ID), uint64(block.timestamp)
        );
        assertFalse(r.exists);
    }

    function test_Verify_AssetMismatch_ReturnsNotExists() public {
        SettlementRecord memory r = verifier.verifySettlement(
            AGENT_ID, payer, other, BUDGET, "erc8183", bytes32(JOB_ID), uint64(block.timestamp)
        );
        assertFalse(r.exists);
    }

    // ── agent ↔ provider 绑定 ──

    function test_Verify_ProviderNotAgentOwner_ReturnsNotExists() public {
        identity.setOwner(AGENT_ID, other); // agent 归属并非 provider
        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp));
        assertFalse(r.exists);
    }

    function test_Verify_UnknownAgent_ReturnsNotExists() public {
        SettlementRecord memory r = verifier.verifySettlement(
            999, payer, token, BUDGET, "erc8183", bytes32(JOB_ID), uint64(block.timestamp)
        );
        assertFalse(r.exists);
    }

    // ── 时间窗 ──

    function test_Verify_SettledBeforeSubmit_ReturnsNotExists() public {
        core.setJob(JOB_ID, payer, provider, BUDGET, IAgenticCommerce.JobStatus.Completed, block.timestamp);
        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp - 1));
        assertFalse(r.exists);
    }

    function test_Verify_SettledInFuture_ReturnsNotExists() public {
        SettlementRecord memory r = _verify("erc8183", uint64(block.timestamp + 1 days));
        assertFalse(r.exists);
    }

    // ── 构造 ──

    function test_Constructor_ZeroAddress_Reverts() public {
        vm.expectRevert(Erc8183Verifier.Verifier__ZeroAddress.selector);
        new Erc8183Verifier(address(0), address(identity));
        vm.expectRevert(Erc8183Verifier.Verifier__ZeroAddress.selector);
        new Erc8183Verifier(address(core), address(0));
    }

    // ── 端到端：Erc8183Verifier → PaymentReputationOracle ──

    function test_EndToEnd_OracleAcceptsErc8183Settlement() public {
        uint256 pk = 0xC11E17;
        address client = vm.addr(pk);

        // 重建一笔以 client 为付款方的已完成 job
        core.setJob(JOB_ID, client, provider, BUDGET, IAgenticCommerce.JobStatus.Completed, block.timestamp - 100);

        PaymentReputationOracle oracle = new PaymentReputationOracle(100e18, 180 days, 3);
        oracle.setSettlementVerifier(address(verifier));

        uint64 t = uint64(block.timestamp);
        PaymentReputationOracle.SettlementProof memory p = PaymentReputationOracle.SettlementProof({
            agentId: AGENT_ID,
            payer: client,
            asset: token,
            amount: BUDGET,
            rail: "erc8183",
            taskRef: keccak256("task"),
            settlementRef: bytes32(JOB_ID),
            settledAt: t
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.hashSettlementProof(p));
        oracle.submitSettlement(p, abi.encodePacked(r, s, v));

        (uint256 weight, uint256 count) = oracle.getPaymentReputation(AGENT_ID);
        assertEq(count, 1);
        assertGt(weight, 0);
    }
}
