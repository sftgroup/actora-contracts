// contracts/erc8004-extensions/PaymentReputationOracle.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice 结算记录（链上可表达形式），供逐字段交叉核对。
struct SettlementRecord {
    uint256 agentId;
    address payer;
    address asset;
    uint256 amount;
    string  rail;
    uint64  settledAt;
    bool    exists;
}

/**
 * @notice 结算核对 provider（契约 PC-4 的链上适配面）。
 *         实现路径（2026-10-04 决策）：
 *           - C 主：`rail='erc8183'` 时直读 BSC 官方 ERC-8183（APEX）内核（无信任）——见 `Erc8183Verifier`；
 *           - A 兜底：读 `SettlementRegistry`（链上结算承诺）——见 `SettlementRegistryVerifier`。
 */
interface ISettlementVerifier {
    function verifySettlement(
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        bytes32 settlementRef,
        uint64 settledAt
    ) external view returns (SettlementRecord memory);
}

/// @notice 官方 canonical ReputationRegistry 的写入面（无签名入参、禁自评）。
interface ICanonicalReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}

/**
 * @title PaymentReputationOracle
 * @notice WS9（B2 支付可信闭环）：把「链上真实结算记录」转成「不可伪造、可复算的信誉权重」，
 *         再以聚合值镜像写入官方 ERC-8004 ReputationRegistry（Oracle 作为唯一 client）。
 *
 * 设计要点（对齐 docs/actora-master-plan-2026-10-02.md §5 WS9）：
 *  1. 信任根 = 付款方对 SettlementProof 的 EIP-712 签名 + 中继（本合约验签）。
 *  2. 数据源 = WS2 统一后的 infraX settlement（经 ISettlementVerifier 注入式核对，PC-4）；
 *     核对规则 = ① 验签恢复 == payer；② 结算记录存在；③ 逐字段一致；④ settlementRef 幂等。
 *  3. 幂等锚点 = settlementRef（同一笔结算只计一次）。
 *  4. 权重 = 确定性纯函数（金额封顶 × 时间衰减 × 反女巫）；参数**版本化 append-only**，
 *     每笔结算固定其落库时的参数版本，调参不追溯历史，公式公开供第三方复算。
 */
contract PaymentReputationOracle is Ownable, EIP712 {
    using ECDSA for bytes32;

    /// @dev EIP-712 结构体类型哈希（域含 chainId + verifyingContract，故结构体内不重复）。
    bytes32 public constant SETTLEMENT_PROOF_TYPEHASH = keccak256(
        "SettlementProof(uint256 agentId,address payer,address asset,uint256 amount,string rail,bytes32 taskRef,bytes32 settlementRef,uint64 settledAt)"
    );

    /// @dev 固定 18 位定点。
    uint256 private constant WAD = 1e18;

    /// @dev 镜像到 canonical 时使用的 tag1，用于与人类反馈区分。
    string public constant TAG1 = "payment-settlement";

    struct SettlementProof {
        uint256 agentId;       // 信誉记名对象（ERC-8004 agentId）
        address payer;         // 付款方，必须 == EIP-712 恢复地址
        address asset;         // address(0)=原生币，否则 ERC-20
        uint256 amount;        // 原子单位（不参与计价）
        string  rail;          // 'x402' | 'mpc' | 'sessionKey' | 'a2a' | 'fiat' | 'erc8183'
        bytes32 taskRef;       // keccak256(utf8(refId))
        bytes32 settlementRef; // keccak256(utf8(reference))，WS2 结算幂等键
        uint64  settledAt;     // 结算时间戳（秒）
    }

    // ── 配置 ──
    ISettlementVerifier public settlementVerifier;
    ICanonicalReputationRegistry public reputationRegistry;

    // ── 权重参数（版本化：地址与公式不变，参数 append-only）──
    /// @notice 一个参数版本；effectiveAt 仅作审计标记，新版本立即生效。
    struct ParamSet {
        uint256 amountCap;  // 单笔计入上限（防刷单）
        uint256 maxAge;     // 时间衰减窗口：超过则权重为 0
        uint256 payerCap;   // 同一 payer 对该 agent 的免罚笔数（超出降权）
        uint64 effectiveAt;
    }
    
    mapping(uint256 => ParamSet) public paramSets;
    uint256 public currentParamVersion;
    
    // ── 存储 ──
    mapping(bytes32 => SettlementProof) private _proofs;
    mapping(bytes32 => bool) private _used;
    mapping(bytes32 => uint256) private _proofParamVersion; // settlementRef → 落库时的参数版本
    mapping(uint256 => bytes32[]) private _agentSettlementRefs;
    mapping(uint256 => mapping(address => uint256)) private _payerCounts;

    // ── 事件 ──
    event SettlementRecorded(
        uint256 indexed agentId,
        address indexed payer,
        address asset,
        uint256 amount,
        string rail,
        bytes32 taskRef,
        bytes32 settlementRef,
        uint64 settledAt
    );
    event ReputationMirrored(uint256 indexed agentId, int128 value, uint8 valueDecimals, uint256 weight, uint256 settledCount);
    event SettlementVerifierUpdated(address indexed previous, address indexed current);
    event ReputationRegistryUpdated(address indexed previous, address indexed current);
    event ParamVersionAdded(
        uint256 indexed version,
        uint256 amountCap,
        uint256 maxAge,
        uint256 payerCap,
        uint64 effectiveAt
    );

    // ── 错误 ──
    error Oracle__ZeroAddress();
    error Oracle__InvalidSignature();
    error Oracle__SettlementAlreadyUsed();
    error Oracle__SettlementUnverified();
    error Oracle__SettlementMismatch();
    error Oracle__UnknownProof();
    error Oracle__NothingToMirror();
    error Oracle__VerifierNotConfigured();
    error Oracle__RegistryNotConfigured();
    error Oracle__ValueOverflow();
    error Oracle__InvalidParams();

    constructor(uint256 initialAmountCap, uint256 initialMaxAge, uint256 initialPayerCap)
        Ownable(msg.sender)
        EIP712("ActoraPaymentSettlement", "1")
    {
        if (initialAmountCap == 0 || initialMaxAge == 0 || initialPayerCap == 0) {
            revert Oracle__InvalidParams();
        }
        currentParamVersion = 1;
        paramSets[1] = ParamSet({
            amountCap: initialAmountCap,
            maxAge: initialMaxAge,
            payerCap: initialPayerCap,
            effectiveAt: uint64(block.timestamp)
        });
        emit ParamVersionAdded(1, initialAmountCap, initialMaxAge, initialPayerCap, uint64(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────
    //  写入
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice 提交一笔结算证明：验签 → 交叉核对 → 幂等落库。
     * @param proof 付款方签署的结算证明
     * @param signature 付款方对 hashSettlementProof(proof) 的 EIP-712 签名
     */
    function submitSettlement(SettlementProof calldata proof, bytes calldata signature) external {
        if (proof.payer == address(0)) revert Oracle__ZeroAddress();
        if (_used[proof.settlementRef]) revert Oracle__SettlementAlreadyUsed();

        // ① EIP-712 验签：恢复地址必须 == payer
        bytes32 digest = hashSettlementProof(proof);
        if (digest.recover(signature) != proof.payer) revert Oracle__InvalidSignature();

        // ② 与 WS2 结算记录交叉核对（PC-4）
        ISettlementVerifier verifier = settlementVerifier;
        if (address(verifier) == address(0)) revert Oracle__VerifierNotConfigured();
        SettlementRecord memory rec = verifier.verifySettlement(
            proof.agentId, proof.payer, proof.asset, proof.amount, proof.rail, proof.settlementRef, proof.settledAt
        );
        if (!rec.exists) revert Oracle__SettlementUnverified();
        if (
            rec.agentId != proof.agentId
                || rec.payer != proof.payer
                || rec.asset != proof.asset
                || rec.amount != proof.amount
                || rec.settledAt != proof.settledAt
                || keccak256(bytes(rec.rail)) != keccak256(bytes(proof.rail))
        ) revert Oracle__SettlementMismatch();

        // ③ 幂等落库（同时固定该笔使用的参数版本，后续调参不影响历史）
        _used[proof.settlementRef] = true;
        _proofs[proof.settlementRef] = proof;
        _proofParamVersion[proof.settlementRef] = currentParamVersion;
        _agentSettlementRefs[proof.agentId].push(proof.settlementRef);
        _payerCounts[proof.agentId][proof.payer] += 1;

        emit SettlementRecorded(
            proof.agentId, proof.payer, proof.asset, proof.amount,
            proof.rail, proof.taskRef, proof.settlementRef, proof.settledAt
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  读
    // ─────────────────────────────────────────────────────────────

    /// @notice EIP-712 摘要（付款方签名对象；供链下/第三方复算）。
    function hashSettlementProof(SettlementProof calldata proof) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            SETTLEMENT_PROOF_TYPEHASH,
            proof.agentId,
            proof.payer,
            proof.asset,
            proof.amount,
            keccak256(bytes(proof.rail)),
            proof.taskRef,
            proof.settlementRef,
            proof.settledAt
        ));
        return _hashTypedDataV4(structHash);
    }

    /// @notice 聚合信誉：(权重[WAD], 已计入结算笔数)。
    function getPaymentReputation(uint256 agentId) public view returns (uint256 weight, uint256 settledCount) {
        bytes32[] storage refs = _agentSettlementRefs[agentId];
        settledCount = refs.length;
        for (uint256 i = 0; i < refs.length; i++) {
            weight += contributionOf(refs[i]);
        }
    }

    /// @notice 单笔贡献（确定性纯函数，公开可复算）：
    ///         c = f(amount) · decay(Δt) · s(payer)，各因子归一化到 WAD。
    ///         参数取该笔落库时固定的版本，调参不追溯历史。
    function contributionOf(bytes32 settlementRef) public view returns (uint256) {
        SettlementProof storage p = _proofs[settlementRef];
        if (!_used[settlementRef]) return 0;
        
        ParamSet storage params = paramSets[_proofParamVersion[settlementRef]];
        uint256 cap = params.amountCap;
        uint256 window = params.maxAge;
        uint256 freeCount = params.payerCap;

        // f：单笔金额封顶后归一化（防刷单）
        uint256 amt = p.amount > cap ? cap : p.amount;
        uint256 amountFactor = (amt * WAD) / cap;

        // decay：线性衰减至 maxAge 归零
        uint256 age = block.timestamp > p.settledAt ? block.timestamp - p.settledAt : 0;
        uint256 timeFactor = age >= window ? 0 : (WAD * (window - age)) / window;

        // s：同一 payer 超出 payerCap 后按 1/(1+excess) 降权
        uint256 count = _payerCounts[p.agentId][p.payer];
        uint256 excess = count > freeCount ? count - freeCount : 0;
        uint256 sybilFactor = (WAD * freeCount) / (freeCount + excess);

        uint256 c = (amountFactor * timeFactor) / WAD;
        c = (c * sybilFactor) / WAD;
        return c;
    }
    
    /// @notice 当前生效参数（便于前端/复算脚本读取，避免两次调用之间版本切换）。
    function currentParams() external view returns (ParamSet memory) {
        return paramSets[currentParamVersion];
    }
    
    /// @notice 任意历史版本的参数（旧版本永久可查，供第三方复算）。
    function paramSetOf(uint256 version) external view returns (ParamSet memory) {
        return paramSets[version];
    }
    
    /// @notice 兼容旧读取面：返回当前版本的三个参数。
    function amountCap() external view returns (uint256) {
        return paramSets[currentParamVersion].amountCap;
    }
    
    function maxAge() external view returns (uint256) {
        return paramSets[currentParamVersion].maxAge;
    }
    
    function payerCap() external view returns (uint256) {
        return paramSets[currentParamVersion].payerCap;
    }

    function getSettlement(bytes32 settlementRef) external view returns (SettlementProof memory) {
        if (!_used[settlementRef]) revert Oracle__UnknownProof();
        return _proofs[settlementRef];
    }

    function getAgentSettlementRefs(uint256 agentId) external view returns (bytes32[] memory) {
        return _agentSettlementRefs[agentId];
    }

    function payerCount(uint256 agentId, address payer) external view returns (uint256) {
        return _payerCounts[agentId][payer];
    }

    // ─────────────────────────────────────────────────────────────
    //  镜像到官方 canonical ReputationRegistry
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice 将聚合权重镜像写入 canonical（valueDecimals=0，tag1="payment-settlement"）。
     *         第三方可凭链上证明 + 该笔的参数版本 + 公开公式复算出同一权重。
     */
    function mirrorToRegistry(uint256 agentId) external {
        ICanonicalReputationRegistry registry = reputationRegistry;
        if (address(registry) == address(0)) revert Oracle__RegistryNotConfigured();

        (uint256 weight, uint256 settledCount) = getPaymentReputation(agentId);
        if (weight == 0) revert Oracle__NothingToMirror();

        uint256 scaled = weight / WAD;
        if (scaled > uint256(uint128(type(int128).max))) revert Oracle__ValueOverflow();

        registry.giveFeedback(agentId, int128(int256(scaled)), 0, TAG1, "", "", "", bytes32(0));

        emit ReputationMirrored(agentId, int128(int256(scaled)), 0, weight, settledCount);
    }

    // ─────────────────────────────────────────────────────────────
    //  管理（参数版本化：只追加、不覆盖；数据源可换）
    // ─────────────────────────────────────────────────────────────
    
    /**
     * @notice 追加一个新参数版本；此前已落库的结算继续使用其原版本参数。
     * @dev 仅 owner；三个参数均须 > 0（避免除零）。新版本立即生效。
     */
    function newParamVersion(uint256 newAmountCap, uint256 newMaxAge, uint256 newPayerCap)
        external
        onlyOwner
        returns (uint256 version)
    {
        if (newAmountCap == 0 || newMaxAge == 0 || newPayerCap == 0) {
            revert Oracle__InvalidParams();
        }
        
        version = ++currentParamVersion;
        paramSets[version] = ParamSet({
            amountCap: newAmountCap,
            maxAge: newMaxAge,
            payerCap: newPayerCap,
            effectiveAt: uint64(block.timestamp)
        });
        
        emit ParamVersionAdded(version, newAmountCap, newMaxAge, newPayerCap, uint64(block.timestamp));
    }
    
    function setSettlementVerifier(address newVerifier) external onlyOwner {
        address previous = address(settlementVerifier);
        settlementVerifier = ISettlementVerifier(newVerifier);
        emit SettlementVerifierUpdated(previous, newVerifier);
    }

    function setReputationRegistry(address newRegistry) external onlyOwner {
        address previous = address(reputationRegistry);
        reputationRegistry = ICanonicalReputationRegistry(newRegistry);
        emit ReputationRegistryUpdated(previous, newRegistry);
    }
}
