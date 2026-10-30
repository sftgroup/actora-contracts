// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title 旧版 ReputationRegistry 的只读子集（自研 erc8004-core：uint8 score / bytes32 标签）
 */
interface ILegacyERC8004Reputation {
    function giveFeedback(
        uint256 agentId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string calldata fileuri,
        bytes32 filehash,
        bytes calldata feedbackAuth
    ) external;

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseUri,
        bytes32 responseHash
    ) external;

    function getReputationSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 averageScore);

    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (uint8 score, bytes32 tag1, bytes32 tag2, bool isRevoked);

    function getClients(uint256 agentId) external view returns (address[] memory);

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);

    function getIdentityRegistry() external view returns (address);
}

/**
 * @title 官方 canonical ERC-8004 ReputationRegistry 的只读子集
 *        （int128 value / uint8 valueDecimals / string 标签）
 * @dev 与 `erc8004-canonical/ReputationRegistryUpgradeable.sol`（官方参考实现镜像）ABI 对齐；
 *      `getSummary` 在 clientAddresses 为空时 revert（须显式传入客户地址列表）。
 */
interface ICanonicalERC8004Reputation {
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

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external;

    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex
    ) external view returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);

    function getClients(uint256 agentId) external view returns (address[] memory);

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);

    function getIdentityRegistry() external view returns (address);
}

/**
 * @title ERC8004ReputationAdapter
 * @notice WS9（B2）A 类前置：让信誉读取在**不迁移链上数据**的前提下兼容两种实现——
 *
 *           · legacy    —— 自研 erc8004-core ReputationRegistry（uint8 score / bytes32 标签）
 *           · canonical —— 官方 ERC-8004 canonical ReputationRegistry（int128 value / uint8 decimals / string 标签）
 *
 *         背景：两版的读取 ABI 不兼容（score 类型、标签类型、聚合语义都不同）。适配器对外
 *         同时暴露 **legacy 兼容面**（现有网管/SDK 直接调用，零改动）与 **标准面**
 *         （WS9 支付信誉闭环按 `getSummary([oracle], "payment-settlement")` 读取）。
 *
 *         模式探测：构造时试调 legacy 专有的 `getReputationSummary()`——成功即 legacy，
 *         revert 即 canonical。因此**同一字节码**在「旧版地址 / 官方单例地址」下均可工作。
 *
 *         用法：把消费者（网关 `reputationRegistry` 配置、SDK）指向适配器地址即可，
 *         底层写操作仍直接在**真实注册表**上进行。
 *
 *         安全说明：适配器为**只读桥**。写方法（giveFeedback/revokeFeedback/appendResponse）
 *         一律 revert —— 底层合约以 `msg.sender` / 授权签名判定反馈主体，经适配器转发会把
 *         反馈错记到适配器名下。写操作请直接调用底层注册表。
 */
contract ERC8004ReputationAdapter {
    /// @notice 旧版 ReputationRegistry 只读接口
    ILegacyERC8004Reputation public immutable legacy;
    /// @notice 官方 canonical 单例只读接口
    ICanonicalERC8004Reputation public immutable canonical;
    /**
     * @notice 底层注册表是否为 canonical 标准实现。
     *         legacy 暴露 `getReputationSummary()`；canonical 无此函数（调用 revert）→ 据此探测。
     */
    bool public immutable canonicalMode;

    error ReputationAdapter__ZeroAddress();
    error ReputationAdapter__NotAContract();
    error ReputationAdapter__ReadOnly();
    /// @notice 标签超过 32 字节，无法编码为 legacy 的 bytes32
    error ReputationAdapter__TagTooLong();

    constructor(address reputationRegistry) {
        if (reputationRegistry == address(0)) {
            revert ReputationAdapter__ZeroAddress();
        }
        if (reputationRegistry.code.length == 0) {
            revert ReputationAdapter__NotAContract();
        }

        legacy = ILegacyERC8004Reputation(reputationRegistry);
        canonical = ICanonicalERC8004Reputation(reputationRegistry);

        // 探测：legacy 有 getReputationSummary()，canonical 只有 getSummary() → 调用 revert。
        address[] memory emptyClients = new address[](0);
        try
            ILegacyERC8004Reputation(reputationRegistry).getReputationSummary(
                0,
                emptyClients,
                bytes32(0),
                bytes32(0)
            )
        returns (uint64, uint8) {
            canonicalMode = false;
        } catch {
            canonicalMode = true;
        }
    }

    // ── 共有读路径（两版同签名的入口）────────────────────────────────────

    function getIdentityRegistry() external view returns (address) {
        return canonicalMode ? canonical.getIdentityRegistry() : legacy.getIdentityRegistry();
    }

    function getClients(uint256 agentId) external view returns (address[] memory) {
        return canonicalMode ? canonical.getClients(agentId) : legacy.getClients(agentId);
    }

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        return canonicalMode ? canonical.getLastIndex(agentId, clientAddress) : legacy.getLastIndex(agentId, clientAddress);
    }

    // ── 标准面：string 标签 + int128 value/valueDecimals（WS9 消费口径）──

    /**
     * @notice 标准聚合读取。
     * @dev legacy：转调 `getReputationSummary`（uint8 均分）→ 归一化为 `(count, avg, 0)`；
     *      canonical：直接转调标准 `getSummary`。
     *      注意：canonical 下 `clients` 为空会 revert（标准要求显式传入客户地址）；
     *      legacy 下 `clients` 为空表示「全部客户」。
     */
    function getSummary(
        uint256 agentId,
        address[] calldata clients,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 value, uint8 valueDecimals) {
        if (canonicalMode) {
            return canonical.getSummary(agentId, clients, tag1, tag2);
        }
        (uint64 c, uint8 averageScore) = legacy.getReputationSummary(
            agentId,
            clients,
            _toBytes32(tag1),
            _toBytes32(tag2)
        );
        return (c, int128(uint128(averageScore)), 0);
    }

    /**
     * @notice 标准明细读取（单条反馈）。
     * @dev legacy：转调 `readFeedback`（uint8/bytes32）→ 归一化为标准形参；
     *      canonical：直接转调标准 `readFeedback`。
     */
    function getFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked) {
        if (canonicalMode) {
            return canonical.readFeedback(agentId, clientAddress, index);
        }
        (uint8 score, bytes32 legacyTag1, bytes32 legacyTag2, bool revoked) = legacy.readFeedback(
            agentId,
            clientAddress,
            index
        );
        return (int128(uint128(score)), 0, _fromBytes32(legacyTag1), _fromBytes32(legacyTag2), revoked);
    }

    // ── legacy 兼容面：bytes32 标签 + uint8 score（现有网管/SDK 口径）──

    /**
     * @notice legacy 兼容聚合读取（现有网关 `REP_ABI` 口径）。
     * @dev legacy：直接转调；canonical：由标准 `getSummary` 归一到 0-100 的 uint8 均分。
     */
    function getReputationSummary(
        uint256 agentId,
        address[] calldata clients,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 averageScore) {
        if (!canonicalMode) {
            return legacy.getReputationSummary(agentId, clients, tag1, tag2);
        }
        (uint64 c, int128 value, uint8 valueDecimals) = canonical.getSummary(
            agentId,
            clients,
            _fromBytes32(tag1),
            _fromBytes32(tag2)
        );
        return (c, _toScore(value, valueDecimals));
    }

    /**
     * @notice legacy 兼容明细读取（现有网关 `REP_ABI` 口径）。
     * @dev legacy：直接转调；canonical：由标准 `readFeedback` 归一。
     */
    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (uint8 score, bytes32 tag1, bytes32 tag2, bool isRevoked) {
        if (!canonicalMode) {
            return legacy.readFeedback(agentId, clientAddress, index);
        }
        (int128 value, uint8 valueDecimals, string memory s1, string memory s2, bool revoked) = canonical.readFeedback(
            agentId,
            clientAddress,
            index
        );
        return (_toScore(value, valueDecimals), _toBytes32(s1), _toBytes32(s2), revoked);
    }

    // ── 写路径：不支持（只读桥）──────────────────────────────────────────

    function giveFeedback(uint256, uint8, bytes32, bytes32, string calldata, bytes32, bytes calldata) external pure {
        revert ReputationAdapter__ReadOnly();
    }

    function revokeFeedback(uint256, uint64) external pure {
        revert ReputationAdapter__ReadOnly();
    }

    function appendResponse(uint256, address, uint64, string calldata, bytes32) external pure {
        revert ReputationAdapter__ReadOnly();
    }

    // ── 编码辅助 ────────────────────────────────────────────────────────

    /// @dev 短字符串 → bytes32（右补零）；超过 32 字节 revert。
    function _toBytes32(string memory s) private pure returns (bytes32 r) {
        bytes memory b = bytes(s);
        if (b.length > 32) revert ReputationAdapter__TagTooLong();
        assembly {
            r := mload(add(b, 32))
        }
    }

    /// @dev bytes32 → 字符串（去掉右侧零填充）。
    function _fromBytes32(bytes32 x) private pure returns (string memory) {
        uint256 len;
        while (len < 32 && x[len] != bytes1(0)) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; i++) {
            b[i] = x[i];
        }
        return string(b);
    }

    /// @dev int128 value + decimals → 0-100 的 uint8 均分（用于 legacy 兼容面）。
    function _toScore(int128 value, uint8 decimals) private pure returns (uint8) {
        int256 v = int256(value);
        if (decimals > 0) {
            v = v / int256(10 ** uint256(decimals));
        }
        if (v <= 0) return 0;
        if (v >= 100) return 100;
        return uint8(uint256(v));
    }
}
