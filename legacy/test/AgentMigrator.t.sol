// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "../src/IdentityRegistry.sol";
import "../src/erc8004-extensions/AgentMigrator.sol";

/**
 * @dev canonical 最小实现：`register(uri, MetadataEntry[])` **非 payable**、**0-based**、无
 *      `getCurrentAgentId` / `getAgentMetadata`（与官方单例 flavor 对齐）。
 */
contract MockCanonicalRegistry is ERC721URIStorage {
    struct MetadataEntry {
        string key;
        bytes value;
    }

    uint256 private _next; // 0-based
    mapping(uint256 => mapping(bytes32 => bytes)) public metadata;

    constructor() ERC721("Canonical Agent", "C8004") {}

    function register(string memory agentURI, MetadataEntry[] memory entries) external returns (uint256 agentId) {
        agentId = _next++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        for (uint256 i = 0; i < entries.length; i++) {
            metadata[agentId][keccak256(bytes(entries[i].key))] = entries[i].value;
        }
    }
}

/// @dev 只有 ownerOf / tokenURI 的 legacy（无 `getAgentMetadata`）→ 覆盖迁移器的 try/catch 分支。
contract MockLegacyMinimal {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => string) private _uris;
    uint256 private _next;

    function mint(address to, string memory uri) external returns (uint256 agentId) {
        agentId = ++_next;
        _owners[agentId] = to;
        _uris[agentId] = uri;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        require(o != address(0), "nonexistent");
        return o;
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        return _uris[agentId];
    }
}

contract AgentMigratorTest is Test {
    IdentityRegistry internal legacy;
    MockCanonicalRegistry internal canonical;
    AgentMigrator internal migrator;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    event AgentMigrated(
        uint256 indexed legacyAgentId,
        uint256 indexed canonicalAgentId,
        address indexed owner,
        string tokenURI
    );
    event WalletRebindRequired(
        uint256 indexed legacyAgentId,
        uint256 indexed canonicalAgentId,
        address indexed owner,
        address legacyAgentWallet
    );
    event FrozenSet(bool frozen);

    function setUp() public {
        legacy = new IdentityRegistry();
        canonical = new MockCanonicalRegistry();
        migrator = new AgentMigrator(address(legacy), address(canonical));
    }

    function _registerLegacy(address owner, string memory uri) internal returns (uint256 id) {
        vm.prank(owner);
        id = legacy.register(uri);
    }

    function _registerLegacyWithWallet(
        address owner,
        string memory uri,
        address wallet
    ) internal returns (uint256 id) {
        IdentityRegistry.MetadataEntry[] memory entries = new IdentityRegistry.MetadataEntry[](2);
        entries[0] = IdentityRegistry.MetadataEntry({key: "name", value: bytes("demo-agent")});
        entries[1] = IdentityRegistry.MetadataEntry({key: "agentWallet", value: abi.encode(wallet)});
        vm.prank(owner);
        id = legacy.registerWithMetadata(uri, entries);
    }

    function test_Migrate_TransfersOwnershipAndKeepsTokenURI() public {
        uint256 legacyId = _registerLegacy(alice, "ipfs://legacy/alice");

        vm.expectEmit(true, true, true, true);
        emit AgentMigrated(legacyId, 0, alice, "ipfs://legacy/alice");
        uint256 canonicalId = migrator.migrate(legacyId);

        assertEq(canonicalId, 0, "canonical is 0-based: first id must be 0");
        assertEq(canonical.ownerOf(canonicalId), alice);
        assertEq(canonical.tokenURI(canonicalId), "ipfs://legacy/alice");
        assertTrue(migrator.isMigrated(legacyId));
        assertEq(migrator.canonicalAgentIdOf(legacyId), canonicalId);
    }

    function test_Migrate_ReplaysMetadata() public {
        uint256 legacyId = _registerLegacyWithWallet(alice, "ipfs://legacy/meta", alice);
        uint256 canonicalId = migrator.migrate(legacyId);

        assertEq(canonical.metadata(canonicalId, keccak256("name")), bytes("demo-agent"));
        assertEq(abi.decode(canonical.metadata(canonicalId, keccak256("agentWallet")), (address)), alice);
    }

    function test_Migrate_EmitsWalletRebindWhenLegacyWalletDiffers() public {
        uint256 legacyId = _registerLegacyWithWallet(alice, "ipfs://legacy/wallet", bob);

        vm.expectEmit(true, true, true, true);
        emit WalletRebindRequired(legacyId, 0, alice, bob);
        migrator.migrate(legacyId);

        // 不代签：canonical 侧不做 agentWallet 绑定，归属仍为 owner
        assertEq(canonical.ownerOf(0), alice);
    }

    function test_Migrate_CoreFlavorWithoutMetadataView() public {
        MockLegacyMinimal minimal = new MockLegacyMinimal();
        AgentMigrator m = new AgentMigrator(address(minimal), address(canonical));
        uint256 id = minimal.mint(alice, "ipfs://minimal/1");

        uint256 canonicalId = m.migrate(id);
        assertEq(canonicalId, 0);
        assertEq(canonical.ownerOf(0), alice);
    }

    function test_Migrate_RevertsOnDoubleMigration() public {
        uint256 legacyId = _registerLegacy(alice, "ipfs://legacy/dup");
        migrator.migrate(legacyId);

        vm.expectRevert(abi.encodeWithSelector(AgentMigrator.AgentMigrator__AlreadyMigrated.selector, legacyId));
        migrator.migrate(legacyId);
    }

    function test_Migrate_RevertsOnUnknownAgent() public {
        vm.expectRevert(abi.encodeWithSelector(AgentMigrator.AgentMigrator__InvalidAgent.selector, uint256(1)));
        migrator.migrate(1);
    }

    function test_SetFrozen_OnlyOwnerAndBlocksMigration() public {
        uint256 legacyId = _registerLegacy(alice, "ipfs://legacy/frozen");

        vm.prank(alice);
        vm.expectRevert();
        migrator.setFrozen(true);

        vm.expectEmit(false, false, false, true);
        emit FrozenSet(true);
        migrator.setFrozen(true);

        vm.expectRevert(AgentMigrator.AgentMigrator__Frozen.selector);
        migrator.migrate(legacyId);
    }

    function test_CanonicalAgentIdOf_RevertsBeforeMigration() public {
        vm.expectRevert(abi.encodeWithSelector(AgentMigrator.AgentMigrator__InvalidAgent.selector, uint256(7)));
        migrator.canonicalAgentIdOf(7);
    }

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(AgentMigrator.AgentMigrator__ZeroAddress.selector);
        new AgentMigrator(address(0), address(canonical));
        vm.expectRevert(AgentMigrator.AgentMigrator__ZeroAddress.selector);
        new AgentMigrator(address(legacy), address(0));
    }
}
