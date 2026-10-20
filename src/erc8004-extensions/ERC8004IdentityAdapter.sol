// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @title 旧版 IdentityRegistry 的只读子集（仅声明适配器用到的入口）
 * @dev 与 src/IdentityRegistry.sol 的 ABI 对齐；结构体按字段顺序/类型匹配即可，
 *      与结构体声明位置无关。
 */
interface ILegacyAgentXIdentityRegistry {
    struct MetadataEntry {
        string key;
        bytes value;
    }

    function getCurrentAgentId() external view returns (uint256);
    function agentExists(uint256 agentId) external view returns (bool);
    function getAgentsByOwner(address owner) external view returns (uint256[] memory);
    function getAgentMetadata(uint256 agentId) external view returns (MetadataEntry[] memory);
}

/**
 * @title 官方 canonical ERC-8004 IdentityRegistry 的只读子集
 * @dev 官方单例（CREATE2 确定性部署，BSC/ETH/Base 同址）暴露的标准读入口；
 *      它**没有** `getCurrentAgentId` / `getAgentsByOwner` / `getAllAgentsPaginated`
 *      等历史视图 —— 枚举须由 `Registered` / `Transfer` 日志在链下派生。
 */
interface ICanonicalERC8004Identity {
    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory);
}

/**
 * @title ERC8004IdentityAdapter
 * @notice WS1/WS4 兼容适配器：让 ERC-8004 扩展（Reputation/Config/MultiEndpoint/A2A …）
 *         在**不迁移链上数据**的前提下，读取底层 Agent 身份——**自动兼容两种实现**：
 *
 *           · legacy  —— 自建旧版 IdentityRegistry（`totalAgents`/`getAgentMetadata` 等历史视图，1-based）
 *           · canonical —— 官方 ERC-8004 canonical 单例（标准 `getMetadata`/ERC-721，0-based）
 *
 *         背景：扩展的鉴权面依赖 `ownerOf` / `agentExists` / `getCurrentAgentId`；旧版与
 *         官方单例都不（完全）直接实现 `IERC8004Identity`。本适配器实现完整
 *         `IERC8004Identity`，只把**读**路径转调底层注册表。
 *
 *         模式探测：构造时试调 legacy 专有的 `getCurrentAgentId()`——成功即 legacy，
 *         revert 即 canonical。因此**同一字节码**在「旧版地址 / 官方单例地址」下均可工作。
 *
 *         用法：
 *           1. adapter = new ERC8004IdentityAdapter(identityRegistry)   // 旧版或官方单例地址
 *           2. 扩展部署时把 identityRegistry 参数指向 adapter 地址
 *              （扩展内部用 ownerOf / agentExists / getCurrentAgentId 做鉴权）
 *           3. 注册新 Agent 仍在**底层注册表**上进行；扩展经 adapter 读到同一主体
 *
 *         安全说明：适配器为**只读桥**。写方法（register/setMetadata/updateTokenURI）
 *         一律 revert —— 因为底层合约以 `msg.sender` 判定所有者，经适配器转发会把
 *         所有权错记到适配器名下。写操作请直接调用底层注册表。
 */
contract ERC8004IdentityAdapter is IERC8004Identity {
    /// @notice 底层注册表地址（ERC-721）
    IERC721 public immutable erc721Identity;
    /// @notice 旧版 IdentityRegistry 只读接口
    ILegacyAgentXIdentityRegistry public immutable legacy;
    /// @notice 官方 canonical 单例只读接口
    ICanonicalERC8004Identity public immutable canonical;
    /**
     * @notice 底层注册表是否为 canonical 标准实现。
     *         legacy 暴露 `getCurrentAgentId()`；canonical 无此函数（调用 revert）→ 据此探测。
     */
    bool public immutable canonicalMode;

    error Adapter__ZeroAddress();
    error Adapter__NotAContract();
    error Adapter__ReadOnly();
    /// @notice canonical 无链上枚举视图（共享单例、日志派生）——相关方法不支持
    error Adapter__UnsupportedOnCanonical();

    constructor(address identityRegistry) {
        if (identityRegistry == address(0)) {
            revert Adapter__ZeroAddress();
        }
        if (identityRegistry.code.length == 0) {
            revert Adapter__NotAContract();
        }

        erc721Identity = IERC721(identityRegistry);
        legacy = ILegacyAgentXIdentityRegistry(identityRegistry);
        canonical = ICanonicalERC8004Identity(identityRegistry);

        // 探测：legacy 有 getCurrentAgentId()，canonical 没有 → 调用 revert。
        try ILegacyAgentXIdentityRegistry(identityRegistry).getCurrentAgentId() returns (uint256) {
            canonicalMode = false;
        } catch {
            canonicalMode = true;
        }
    }

    // ── 读路径：按模式转调底层注册表 ──────────────────────────────────────

    /// @inheritdoc IERC8004Identity
    function ownerOf(uint256 agentId) external view returns (address) {
        // 两种实现的 ownerOf 都是 ERC-721 语义：不存在的 agentId 直接 revert（扩展用 try/catch 捕获）
        return erc721Identity.ownerOf(agentId);
    }

    /// @inheritdoc IERC8004Identity
    function agentExists(uint256 agentId) external view returns (bool) {
        if (!canonicalMode) {
            return legacy.agentExists(agentId);
        }
        // canonical：无 agentExists → 以 ERC-721 ownerOf 派生存在性
        try erc721Identity.ownerOf(agentId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IERC8004Identity
    function getCurrentAgentId() external view returns (uint256) {
        if (canonicalMode) revert Adapter__UnsupportedOnCanonical();
        return legacy.getCurrentAgentId();
    }

    /// @inheritdoc IERC8004Identity
    function getAgentsByOwner(address owner) external view returns (uint256[] memory) {
        if (canonicalMode) revert Adapter__UnsupportedOnCanonical();
        return legacy.getAgentsByOwner(owner);
    }

    /// @inheritdoc IERC8004Identity
    /// @dev legacy：整表查询后按 key 过滤（未命中返回空 bytes）；canonical：直接转调标准 getMetadata
    function getMetadata(uint256 agentId, string memory key) external view returns (bytes memory) {
        if (canonicalMode) {
            return canonical.getMetadata(agentId, key);
        }
        ILegacyAgentXIdentityRegistry.MetadataEntry[] memory entries = legacy.getAgentMetadata(agentId);
        bytes32 want = keccak256(bytes(key));
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].key)) == want) {
                return entries[i].value;
            }
        }
        return "";
    }

    /// @inheritdoc IERC8004Identity
    /// @dev legacy：agentId 从 1 起严格递增且不 burn，故按 1..total 顺序分页；
    ///      canonical：共享单例无链上计数/枚举视图 → 不支持（须链下按日志派生）。
    function getAllAgentsPaginated(
        uint256 page,
        uint256 limit
    ) external view returns (uint256[] memory agentIds, uint256 totalAgents) {
        if (canonicalMode) revert Adapter__UnsupportedOnCanonical();
        if (page == 0 || limit == 0) {
            revert ERC8004__InvalidPagination();
        }

        totalAgents = legacy.getCurrentAgentId();
        uint256 start = (page - 1) * limit + 1;
        if (start > totalAgents) {
            return (new uint256[](0), totalAgents);
        }

        uint256 end = start + limit - 1;
        if (end > totalAgents) {
            end = totalAgents;
        }

        uint256 n = end - start + 1;
        agentIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            agentIds[i] = start + i;
        }
    }

    /// @inheritdoc IERC8004Identity
    function getIdentityRegistry() external view returns (address) {
        return address(erc721Identity);
    }

    // ── 写路径：不支持（只读桥） ──────────────────────────────────────────

    /// @inheritdoc IERC8004Identity
    function register() external payable returns (uint256) {
        revert Adapter__ReadOnly();
    }

    /// @inheritdoc IERC8004Identity
    function register(string memory) external payable returns (uint256) {
        revert Adapter__ReadOnly();
    }

    /// @inheritdoc IERC8004Identity
    function registerWithMetadata(
        string memory,
        ERC8004Types.MetadataEntry[] calldata
    ) external payable returns (uint256) {
        revert Adapter__ReadOnly();
    }

    /// @inheritdoc IERC8004Identity
    function setMetadata(uint256, string memory, bytes memory) external {
        revert Adapter__ReadOnly();
    }

    /// @inheritdoc IERC8004Identity
    function updateTokenURI(uint256, string memory) external {
        revert Adapter__ReadOnly();
    }
}
