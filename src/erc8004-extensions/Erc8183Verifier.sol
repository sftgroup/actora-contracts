// contracts/src/erc8004-extensions/Erc8183Verifier.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SettlementRecord, ISettlementVerifier} from "./PaymentReputationOracle.sol";

/**
 * @notice BSC 官方 ERC-8183（APEX）内核的最小读取面。
 *         与 `bnb-chain/apex-contracts/contracts/IACP.sol` 的 `Job`/`getJob` 布局逐字段一致。
 */
interface IAgenticCommerce {
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
        uint256 submittedAt; // 提交时间；未提交为 0
        bytes32 deliverable; // 交付物哈希；未提交为 0
    }

    /// @notice 返回 `jobId` 的完整 Job（jobId 非法时 revert）。
    function getJob(uint256 jobId) external view returns (Job memory);

    /// @notice 默认托管/结算代币（多代币升级前的兼容回退）。
    function paymentToken() external view returns (address);

    /// @notice 某 job 绑定的结算代币。
    function jobPaymentToken(uint256 jobId) external view returns (address);
}

/// @notice ERC-8004 身份注册表最小读取面（agentId 即 ERC-721 tokenId）。
interface IERC8004IdentityOwner {
    function ownerOf(uint256 agentId) external view returns (address);
}

/**
 * @title Erc8183Verifier
 * @notice `ISettlementVerifier` 的 **Option C** 实现：无信任地直读 BSC 官方 ERC-8183（APEX）内核，
 *         把一个「已完成的 job」核验成一笔结算记录，供 `PaymentReputationOracle` 交叉核对。
 *
 * 约定（`rail = "erc8183"`）：
 *  - `settlementRef := bytes32(uint256(jobId))`（jobId 唯一映射到 settlementRef）；
 *  - `agentId` 绑定到 job 的 provider：要求 `identityRegistry.ownerOf(agentId) == job.provider`；
 *  - `settledAt` 需满足 `job.submittedAt <= settledAt <= block.timestamp`（提交后、且不在未来）。
 *
 * 逐字段核验（任一不符 → `exists = false`，由 Oracle 侧统一转为 revert）：
 *  - `job.status == Completed`；`job.client == payer`；`job.budget == amount`；
 *  - `jobPaymentToken(jobId)`（缺省回退 `paymentToken()`）== `asset`。
 *
 * 说明：ERC-8183 结构化数据以「地址」标识参与方，不含 ERC-8004 `agentId`；
 *       agent 归属经 ERC-8004 身份注册表的 `ownerOf` 绑定到 provider 地址。
 */
contract Erc8183Verifier is ISettlementVerifier {
    /// @dev 本 verifier 仅服务 ERC-8183 rail。
    string private constant RAIL = "erc8183";

    IAgenticCommerce public immutable commerce;
    IERC8004IdentityOwner public immutable identityRegistry;

    error Verifier__ZeroAddress();

    constructor(address commerce_, address identityRegistry_) {
        if (commerce_ == address(0) || identityRegistry_ == address(0)) revert Verifier__ZeroAddress();
        commerce = IAgenticCommerce(commerce_);
        identityRegistry = IERC8004IdentityOwner(identityRegistry_);
    }

    function verifySettlement(
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        bytes32 settlementRef,
        uint64 settledAt
    ) external view returns (SettlementRecord memory) {
        SettlementRecord memory rec;

        // 仅处理 erc8183 rail
        if (keccak256(bytes(rail)) != keccak256(bytes(RAIL))) return rec;

        // 读取 job（jobId 非法会 revert → 视为未核验）
        IAgenticCommerce.Job memory job;
        try commerce.getJob(uint256(settlementRef)) returns (IAgenticCommerce.Job memory j) {
            job = j;
        } catch {
            return rec;
        }

        // 已完成的 job 才算结算
        if (job.client == address(0)) return rec;
        if (job.status != IAgenticCommerce.JobStatus.Completed) return rec;

        // 逐字段核验
        if (job.client != payer) return rec;
        if (job.budget != amount) return rec;

        address token = commerce.jobPaymentToken(uint256(settlementRef));
        if (token == address(0)) token = commerce.paymentToken();
        if (token != asset) return rec;

        // agent 绑定：provider 必须是该 agentId 的持有者（ownerOf 未知 agent 会 revert → 未核验）
        address owner;
        try identityRegistry.ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            return rec;
        }
        if (owner != job.provider) return rec;

        // 时间窗：提交后、不在未来
        if (settledAt < job.submittedAt || uint256(settledAt) > block.timestamp) return rec;

        rec.agentId = agentId;
        rec.payer = payer;
        rec.asset = asset;
        rec.amount = amount;
        rec.rail = RAIL;
        rec.settledAt = settledAt;
        rec.exists = true;
        return rec;
    }
}
