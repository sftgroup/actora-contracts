// contracts/erc8004-extensions/AgentMigrator.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";

/**
 * @dev legacy 自有 IdentityRegistry 的元数据枚举视图（`getAgentMetadata`）。
 *      canonical 单例没有该函数 —— 迁移器用 try/catch 兼容两种 flavor。
 */
interface ILegacyIdentityMetadata {
    struct MetadataEntry {
        string key;
        bytes value;
    }

    function getAgentMetadata(uint256 agentId) external view returns (MetadataEntry[] memory);
}

/**
 * @dev canonical 标准注册表的最小写入面（`register(uri, MetadataEntry[])`，非 payable）。
 *      struct 与官方 `IdentityRegistryUpgradeable.MetadataEntry` 逐字段一致（ABI 相同）。
 */
interface ICanonicalIdentityRegistry {
    struct MetadataEntry {
        string key;
        bytes value;
    }

    function register(string memory agentURI, MetadataEntry[] memory metadata) external returns (uint256 agentId);
}

/**
 * @title AgentMigrator
 * @notice WS1 / M2：把 legacy IdentityRegistry 上的 agent **全量迁移**到官方 ERC-8004 canonical 单例。
 *
 * 流程（每链一个实例，构造参数固定 legacy / canonical 地址）：
 *   1. 读链上真相：`legacy.ownerOf(id)` / `tokenURI(id)` / `getAgentMetadata(id)`（不信任调用方入参）；
 *   2. `canonical.register(uri, metadata)` —— NFT 先铸给本合约；
 *   3. `transferFrom(this → legacyOwner)` —— 归属还原给原 owner；
 *   4. 记录 `legacyAgentId → canonicalAgentId`，同一 legacy id 只能迁移一次。
 *
 * 边界与信任模型：
 *   - **不迁移 legacy NFT 本身**（旧合约在 M5 冻结后只读存档）；
 *   - **不代签 `agentWallet`**：canonical 的 `setAgentWallet` 需 owner 签名。若 legacy 元数据里
 *     `agentWallet` ≠ owner，本合约发出 `WalletRebindRequired` 事件，由 owner 事后用
 *     EIP-712 / ERC-1271 重新绑定（M2 文档口径）；
 *   - 任何人可调用（结果确定、受益人是原 owner）；`owner` 可通过 `setFrozen(true)` 在 M5 停用。
 */
contract AgentMigrator is Ownable, IERC721Receiver, ReentrancyGuard {
    /// @notice 旧身份注册表（生产为自有 1-based `IdentityRegistry`）
    IERC8004Identity public immutable legacyRegistry;
    /// @notice 官方 ERC-8004 canonical 单例
    IERC8004Identity public immutable canonicalRegistry;

    /// @notice M5 后停止新迁移（旧合约冻结同批执行）
    bool public frozen;

    mapping(uint256 => uint256) private _canonicalOf;
    mapping(uint256 => bool) private _migrated;

    event AgentMigrated(
        uint256 indexed legacyAgentId,
        uint256 indexed canonicalAgentId,
        address indexed owner,
        string tokenURI
    );
    /// @notice legacy `agentWallet` ≠ owner：owner 须自行用 EIP-712 / ERC-1271 重新 `setAgentWallet`
    event WalletRebindRequired(
        uint256 indexed legacyAgentId,
        uint256 indexed canonicalAgentId,
        address indexed owner,
        address legacyAgentWallet
    );
    event FrozenSet(bool frozen);

    error AgentMigrator__Frozen();
    error AgentMigrator__AlreadyMigrated(uint256 legacyAgentId);
    error AgentMigrator__InvalidAgent(uint256 legacyAgentId);
    error AgentMigrator__ZeroAddress();

    constructor(address legacy, address canonical) Ownable(msg.sender) {
        if (legacy == address(0) || canonical == address(0)) revert AgentMigrator__ZeroAddress();
        legacyRegistry = IERC8004Identity(legacy);
        canonicalRegistry = IERC8004Identity(canonical);
    }

    /// @notice M5：冻结迁移入口（不触碰已迁移记录）
    function setFrozen(bool value) external onlyOwner {
        frozen = value;
        emit FrozenSet(value);
    }

    /// @notice 迁移单个 legacy agent；返回 canonical agentId
    function migrate(uint256 legacyAgentId) external nonReentrant returns (uint256 canonicalAgentId) {
        if (frozen) revert AgentMigrator__Frozen();
        if (_migrated[legacyAgentId]) revert AgentMigrator__AlreadyMigrated(legacyAgentId);

        address owner;
        string memory uri;
        try legacyRegistry.ownerOf(legacyAgentId) returns (address o) {
            owner = o;
        } catch {
            revert AgentMigrator__InvalidAgent(legacyAgentId);
        }
        if (owner == address(0)) revert AgentMigrator__InvalidAgent(legacyAgentId);
        uri = IERC721Metadata(address(legacyRegistry)).tokenURI(legacyAgentId);

        (ICanonicalIdentityRegistry.MetadataEntry[] memory entries, address legacyWallet) = _readMetadata(legacyAgentId);

        canonicalAgentId = ICanonicalIdentityRegistry(address(canonicalRegistry)).register(uri, entries);

        // 归属还原：NFT 由本合约接住（safeMint），转交给 legacy owner
        IERC721(address(canonicalRegistry)).transferFrom(address(this), owner, canonicalAgentId);

        _canonicalOf[legacyAgentId] = canonicalAgentId;
        _migrated[legacyAgentId] = true;

        emit AgentMigrated(legacyAgentId, canonicalAgentId, owner, uri);
        if (legacyWallet != address(0) && legacyWallet != owner) {
            emit WalletRebindRequired(legacyAgentId, canonicalAgentId, owner, legacyWallet);
        }
    }

    /// @notice legacy id → canonical id（未迁移则 revert，避免把 0 当作有效 id）
    function canonicalAgentIdOf(uint256 legacyAgentId) external view returns (uint256) {
        if (!_migrated[legacyAgentId]) revert AgentMigrator__InvalidAgent(legacyAgentId);
        return _canonicalOf[legacyAgentId];
    }

    function isMigrated(uint256 legacyAgentId) external view returns (bool) {
        return _migrated[legacyAgentId];
    }

    /// @dev 读 legacy 元数据并翻译为 canonical struct；同时解析 `agentWallet`（若有）。
    function _readMetadata(
        uint256 legacyAgentId
    ) private view returns (ICanonicalIdentityRegistry.MetadataEntry[] memory entries, address legacyWallet) {
        ILegacyIdentityMetadata.MetadataEntry[] memory legacyEntries;
        try ILegacyIdentityMetadata(address(legacyRegistry)).getAgentMetadata(legacyAgentId) returns (
            ILegacyIdentityMetadata.MetadataEntry[] memory found
        ) {
            legacyEntries = found;
        } catch {
            return (new ICanonicalIdentityRegistry.MetadataEntry[](0), address(0));
        }

        entries = new ICanonicalIdentityRegistry.MetadataEntry[](legacyEntries.length);
        for (uint256 i = 0; i < legacyEntries.length; i++) {
            entries[i] = ICanonicalIdentityRegistry.MetadataEntry({
                key: legacyEntries[i].key,
                value: legacyEntries[i].value
            });
            if (keccak256(bytes(legacyEntries[i].key)) == keccak256(bytes("agentWallet"))) {
                legacyWallet = _decodeAddress(legacyEntries[i].value);
            }
        }
    }

    /// @dev legacy 的 agentWallet 可能以 32 字节（abi.encode）或 20 字节（address(bytes20)）存储
    function _decodeAddress(bytes memory value) private pure returns (address) {
        if (value.length == 32) return abi.decode(value, (address));
        if (value.length == 20) return address(bytes20(value));
        return address(0);
    }

    /// @dev canonical `register` 经 `_safeMint` 铸给本合约，必须实现接收钩子
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
