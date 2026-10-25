// contracts/erc8004-extensions/PaymentReputationOracleV2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice 结算记录（链上可表达形式），供逐字段交叉核对。
struct SettlementRecordV2 {
    uint256 agentId;
    address payer;
    address asset;
    uint256 amount;
    string  rail;
    uint64  settledAt;
    bool    exists;
}

/// @notice 结算核对 provider（与 V1 ABI 完全一致，可复用已部署的核验器）。
interface ISettlementVerifierV2 {
    function verifySettlement(
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        bytes32 settlementRef,
        uint64 settledAt
    ) external view returns (SettlementRecordV2 memory);
}

/// @notice 官方 canonical ReputationRegistry 的写入面（无签名入参、禁自评）。
interface ICanonicalReputationRegistryV2 {
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

/// @notice SubscriptionManager（erc8004-extensions/SubscriptionManager.sol）的只读面。
///         注意：线上三链部署的是 ERC8004SubscriptionManager（`getSubscription(uint256)`），
///         不是 `SubscriptionManager.sol`（后者为 `getSubscriptionDetail` 的另一套实现）。
interface ISubscriptionManagerV2 {
    struct Subscription {
        uint256 subscriptionId;
        uint256 planId;
        uint256 agentId;
        address subscriber;
        uint8   status;          // 0=Active 1=Cancelled 2=Expired 3=PaymentFailed 4=Suspended
        uint8   planType;
        uint256 startDate;
        uint256 nextBillingDate;
        uint256 endDate;
        uint256 currentPeriodUsage;
        uint256 totalUsage;
        uint256 remainingUsage;
        uint256 totalPaid;       // 该订阅累计实付（原子单位）
        uint256 createdAt;
        uint256 lastPaymentDate;
        address paymentToken;    // address(0)=原生币
    }

    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory);
}

/**
 * @title PaymentReputationOracleV2
 * @notice WS9 支付可信闭环 V2：在 V1 基础上增加两种准入方式。
 *
 *  V1 的问题：
 *   ① 只接受 `ecrecover == payer`，智能账户（ERC-4337）的付款无法计入；
 *   ② 链上订阅/自动续订没有「付款方 EIP-712 签名」，V1 完全无法覆盖。
 *
 *  V2 的两处变更：
 *   ① 验签改用 OpenZeppelin `SignatureChecker`：EOA 走 ECDSA，合约账户走 ERC-1271
 *      （Keel/Kernel 已支持 `0x01 ‖ validator ‖ sessionId ‖ policyData ‖ sig` 形态）；
 *   ② 新增 `submitSubscriptionSettlement`：直读 `SubscriptionManager` 的订阅状态，
 *      无需任何签名，任何人都可提交。信任根是链上真实付款状态，第三方可独立复核。
 *
 *  防重放：链上订阅路径以 `(subscriber, agentId)` 的 `subscriptionId` 严格递增为锚点；
 *          每次 `subscribe()` 都会新建一条订阅且 id 全局自增，因此递增天然成立。
 */
contract PaymentReputationOracleV2 is Ownable, EIP712 {
    /// @dev EIP-712 结构体类型哈希（域含 chainId + verifyingContract，故结构体内不重复）。
    bytes32 public constant SETTLEMENT_PROOF_TYPEHASH = keccak256(
        "SettlementProof(uint256 agentId,address payer,address asset,uint256 amount,string rail,bytes32 taskRef,bytes32 settlementRef,uint64 settledAt)"
    );

    /// @dev 固定 18 位定点。
    uint256 private constant WAD = 1e18;

    /// @dev 镜像到 canonical 时使用的 tag1，用于与人类反馈区分。
    string public constant TAG1 = "payment-settlement";

    /// @dev 链上订阅路径使用的 rail 标识。
    string public constant SUBSCRIPTION_RAIL = "subscription";
    bytes32 private constant SUBSCRIPTION_RAIL_KEY = keccak256("subscription");

    uint8 private constant STATUS_CANCELLED = 1;

    struct SettlementProof {
        uint256 agentId;       // 信誉记名对象（ERC-8004 agentId）
        address payer;         // 付款方（EOA 或智能账户）
        address asset;         // address(0)=原生币，否则 ERC-20
        uint256 amount;        // 原子单位（不参与计价）
        string  rail;          // 'x402' | 'subscription' | ...
        bytes32 taskRef;       // keccak256(utf8(refId))，订阅路径为 subscriptionId
        bytes32 settlementRef; // 幂等键
        uint64  settledAt;     // 结算时间戳（秒）
    }

    // ── 配置 ──
    ISettlementVerifierV2 public settlementVerifier;
    ICanonicalReputationRegistryV2 public reputationRegistry;
    ISubscriptionManagerV2 public subscriptionManager;

    // ── 权重参数（版本化：参数 append-only）──
    struct ParamSet {
        uint256 amountCap;
        uint256 maxAge;
        uint256 payerCap;
        uint64 effectiveAt;
    }

    mapping(uint256 => ParamSet) public paramSets;
    uint256 public currentParamVersion;

    // ── 存储 ──
    mapping(bytes32 => SettlementProof) private _proofs;
    mapping(bytes32 => bool) private _used;
    mapping(bytes32 => uint256) private _proofParamVersion;
    mapping(uint256 => bytes32[]) private _agentSettlementRefs;
    mapping(uint256 => mapping(address => uint256)) private _payerCounts;
    /// @dev 链上订阅防重放锚点：同一 (subscriber, agentId) 只接受严格递增的 subscriptionId。
    mapping(address => mapping(uint256 => uint256)) private _lastSubscriptionId;

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
    event SubscriptionSettlementRecorded(
        uint256 indexed agentId,
        address indexed subscriber,
        uint256 indexed subscriptionId,
        bytes32 settlementRef
    );
    event ReputationMirrored(uint256 indexed agentId, int128 value, uint8 valueDecimals, uint256 weight, uint256 settledCount);
    event SettlementVerifierUpdated(address indexed previous, address indexed current);
    event ReputationRegistryUpdated(address indexed previous, address indexed current);
    event SubscriptionManagerUpdated(address indexed previous, address indexed current);
    event ParamVersionAdded(uint256 indexed version, uint256 amountCap, uint256 maxAge, uint256 payerCap, uint64 effectiveAt);

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
    error Oracle__ManagerNotConfigured();
    error Oracle__SubscriptionCancelled();
    error Oracle__ValueOverflow();
    error Oracle__InvalidParams();

    constructor(
        uint256 initialAmountCap,
        uint256 initialMaxAge,
        uint256 initialPayerCap,
        address initialSubscriptionManager
    )
        Ownable(msg.sender)
        EIP712("ActoraPaymentSettlement", "1")
    {
        if (initialAmountCap == 0 || initialMaxAge == 0 || initialPayerCap == 0) {
            revert Oracle__InvalidParams();
        }
        if (initialSubscriptionManager == address(0)) revert Oracle__ZeroAddress();

        subscriptionManager = ISubscriptionManagerV2(initialSubscriptionManager);
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
    //  写入：签名路径（EOA + ERC-1271）
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice 提交一笔带付款方签名的结算证明。
     * @dev 验签使用 SignatureChecker：EOA 走 ECDSA，合约账户（智能账户）走 ERC-1271。
     */
    function submitSettlement(SettlementProof calldata proof, bytes calldata signature) external {
        if (proof.payer == address(0)) revert Oracle__ZeroAddress();
        if (_used[proof.settlementRef]) revert Oracle__SettlementAlreadyUsed();

        bytes32 digest = hashSettlementProof(proof);
        if (!SignatureChecker.isValidSignatureNow(proof.payer, digest, signature)) {
            revert Oracle__InvalidSignature();
        }

        ISettlementVerifierV2 verifier = settlementVerifier;
        if (address(verifier) == address(0)) revert Oracle__VerifierNotConfigured();
        SettlementRecordV2 memory rec = verifier.verifySettlement(
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

        _record(proof);
    }

    // ─────────────────────────────────────────────────────────────
    //  写入：链上订阅路径（免签名，任何人可提交）
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice 以 `SubscriptionManager` 的订阅状态为证据，记录一笔订阅付款。
     * @dev 无签名、无访问控制：链上状态即证据，谁提交结果都一样。
     *      防重放由 `(subscriber, agentId)` 的 subscriptionId 严格递增保证。
     */
    function submitSubscriptionSettlement(
        uint256 agentId,
        address subscriber,
        uint256 subscriptionId
    ) external {
        if (subscriber == address(0)) revert Oracle__ZeroAddress();

        ISubscriptionManagerV2 mgr = subscriptionManager;
        if (address(mgr) == address(0)) revert Oracle__ManagerNotConfigured();

        ISubscriptionManagerV2.Subscription memory s = mgr.getSubscription(subscriptionId);
        if (s.subscriptionId != subscriptionId || s.startDate == 0) revert Oracle__SettlementUnverified();
        if (s.subscriber != subscriber || s.agentId != agentId) revert Oracle__SettlementMismatch();
        if (s.status == STATUS_CANCELLED) revert Oracle__SubscriptionCancelled();
        if (s.totalPaid == 0) revert Oracle__SettlementUnverified();

        if (subscriptionId <= _lastSubscriptionId[subscriber][agentId]) revert Oracle__SettlementAlreadyUsed();

        bytes32 settlementRef = keccak256(
            abi.encode(SUBSCRIPTION_RAIL_KEY, block.chainid, address(mgr), subscriptionId)
        );
        if (_used[settlementRef]) revert Oracle__SettlementAlreadyUsed();
        if (s.startDate > type(uint64).max) revert Oracle__ValueOverflow();

        SettlementProof memory proof = SettlementProof({
            agentId: agentId,
            payer: subscriber,
            asset: s.paymentToken,
            amount: s.totalPaid,
            rail: SUBSCRIPTION_RAIL,
            taskRef: bytes32(subscriptionId),
            settlementRef: settlementRef,
            settledAt: uint64(s.startDate)
        });

        _record(proof);
        _lastSubscriptionId[subscriber][agentId] = subscriptionId;

        emit SubscriptionSettlementRecorded(agentId, subscriber, subscriptionId, settlementRef);
    }

    /// @dev 统一落库：幂等 + 固定参数版本 + 计数。
    function _record(SettlementProof memory proof) private {
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

    /// @notice 单笔贡献（确定性纯函数，公开可复算）。
    function contributionOf(bytes32 settlementRef) public view returns (uint256) {
        SettlementProof storage p = _proofs[settlementRef];
        if (!_used[settlementRef]) return 0;

        ParamSet storage params = paramSets[_proofParamVersion[settlementRef]];
        uint256 cap = params.amountCap;
        uint256 window = params.maxAge;
        uint256 freeCount = params.payerCap;

        uint256 amt = p.amount > cap ? cap : p.amount;
        uint256 amountFactor = (amt * WAD) / cap;

        uint256 age = block.timestamp > p.settledAt ? block.timestamp - p.settledAt : 0;
        uint256 timeFactor = age >= window ? 0 : (WAD * (window - age)) / window;

        uint256 count = _payerCounts[p.agentId][p.payer];
        uint256 excess = count > freeCount ? count - freeCount : 0;
        uint256 sybilFactor = (WAD * freeCount) / (freeCount + excess);

        uint256 c = (amountFactor * timeFactor) / WAD;
        c = (c * sybilFactor) / WAD;
        return c;
    }

    function currentParams() external view returns (ParamSet memory) {
        return paramSets[currentParamVersion];
    }

    function paramSetOf(uint256 version) external view returns (ParamSet memory) {
        return paramSets[version];
    }

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

    /// @notice 某 (subscriber, agentId) 已计入的最大 subscriptionId（供第三方复核防重放）。
    function lastSubscriptionIdOf(address subscriber, uint256 agentId) external view returns (uint256) {
        return _lastSubscriptionId[subscriber][agentId];
    }

    // ─────────────────────────────────────────────────────────────
    //  镜像到官方 canonical ReputationRegistry
    // ─────────────────────────────────────────────────────────────

    function mirrorToRegistry(uint256 agentId) external {
        ICanonicalReputationRegistryV2 registry = reputationRegistry;
        if (address(registry) == address(0)) revert Oracle__RegistryNotConfigured();

        (uint256 weight, uint256 settledCount) = getPaymentReputation(agentId);
        if (weight == 0) revert Oracle__NothingToMirror();

        uint256 scaled = weight / WAD;
        if (scaled > uint256(uint128(type(int128).max))) revert Oracle__ValueOverflow();

        registry.giveFeedback(agentId, int128(int256(scaled)), 0, TAG1, "", "", "", bytes32(0));

        emit ReputationMirrored(agentId, int128(int256(scaled)), 0, weight, settledCount);
    }

    // ─────────────────────────────────────────────────────────────
    //  管理
    // ─────────────────────────────────────────────────────────────

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
        settlementVerifier = ISettlementVerifierV2(newVerifier);
        emit SettlementVerifierUpdated(previous, newVerifier);
    }

    function setReputationRegistry(address newRegistry) external onlyOwner {
        address previous = address(reputationRegistry);
        reputationRegistry = ICanonicalReputationRegistryV2(newRegistry);
        emit ReputationRegistryUpdated(previous, newRegistry);
    }

    function setSubscriptionManager(address newManager) external onlyOwner {
        address previous = address(subscriptionManager);
        subscriptionManager = ISubscriptionManagerV2(newManager);
        emit SubscriptionManagerUpdated(previous, newManager);
    }
}
