// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IdentityRegistry.sol";
import "../src/erc8004-extensions/ERC8004IdentityAdapter.sol";
import "../src/erc8004-extensions/ConfigurationRegistry.sol";

/**
 * @dev 最小 canonical 模拟：ERC-721 `ownerOf` + 标准 `getMetadata`；**无** `getCurrentAgentId`，
 *      用于触发适配器的 canonical 模式探测。canonical 的 agentId 为 0-based。
 */
contract MockCanonicalIdentity {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => mapping(string => bytes)) private _meta;

    function mint(address to, uint256 agentId) external {
        _owners[agentId] = to;
    }

    function setMeta(uint256 agentId, string calldata key, bytes calldata value) external {
        _meta[agentId][key] = value;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        require(o != address(0), "nonexistent");
        return o;
    }

    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory) {
        return _meta[agentId][key];
    }
}

/**
 * @title ERC8004IdentityAdapter 测试
 * @notice 验证 WS1/WS4 只读桥：适配器读路径与底层注册表一致、写路径拒绝，且
 *         **同一字节码**在 legacy（旧版 IdentityRegistry）与 canonical（官方单例）两种
 *         模式下均可读；扩展（ConfigurationRegistry）可经适配器读到身份。
 */
contract ERC8004IdentityAdapterTest is Test {
    IdentityRegistry internal legacy;
    ERC8004IdentityAdapter internal adapter;

    address internal creator = makeAddr("creator");
    address internal other = makeAddr("other");

    function setUp() public {
        legacy = new IdentityRegistry();
        adapter = new ERC8004IdentityAdapter(address(legacy));
    }

    function test_BackingIsLegacyRegistry() public view {
        assertEq(adapter.getIdentityRegistry(), address(legacy));
        assertEq(address(adapter.legacy()), address(legacy));
        assertEq(address(adapter.erc721Identity()), address(legacy));
        assertFalse(adapter.canonicalMode());
    }

    function test_ReadsMirrorLegacy() public {
        vm.prank(creator);
        uint256 agentId = legacy.register("ipfs://agent-1");
        assertEq(agentId, 1);

        assertEq(adapter.getCurrentAgentId(), legacy.getCurrentAgentId());
        assertTrue(adapter.agentExists(agentId));
        assertEq(adapter.ownerOf(agentId), creator);

        uint256[] memory owned = adapter.getAgentsByOwner(creator);
        assertEq(owned.length, 1);
        assertEq(owned[0], agentId);
    }

    function test_MetadataRoundTrip() public {
        // 旧合约的 MetadataEntry 为其自身类型（ABI 与 ERC8004Types.MetadataEntry 一致）
        IdentityRegistry.MetadataEntry[] memory meta = new IdentityRegistry.MetadataEntry[](2);
        meta[0] = IdentityRegistry.MetadataEntry("name", bytes("Actora"));
        meta[1] = IdentityRegistry.MetadataEntry("version", bytes("1.0.0"));

        vm.prank(creator);
        uint256 agentId = legacy.registerWithMetadata("ipfs://agent", meta);

        assertEq(adapter.getMetadata(agentId, "name"), bytes("Actora"));
        assertEq(adapter.getMetadata(agentId, "version"), bytes("1.0.0"));
        assertEq(adapter.getMetadata(agentId, "missing"), bytes(""));
    }

    function test_OwnerOf_RevertsForUnknownAgent() public {
        // 与 ERC-721 语义一致：未知 agentId 直接 revert（扩展用 try/catch 捕获）
        vm.expectRevert();
        adapter.ownerOf(999);
    }

    function test_Pagination() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(creator);
            legacy.register(string.concat("ipfs://", vm.toString(i)));
        }

        (uint256[] memory page1, uint256 total) = adapter.getAllAgentsPaginated(1, 2);
        assertEq(total, 5);
        assertEq(page1.length, 2);
        assertEq(page1[0], 1);
        assertEq(page1[1], 2);

        (uint256[] memory page3, ) = adapter.getAllAgentsPaginated(3, 2);
        assertEq(page3.length, 1);
        assertEq(page3[0], 5);

        (uint256[] memory empty, uint256 total2) = adapter.getAllAgentsPaginated(99, 2);
        assertEq(empty.length, 0);
        assertEq(total2, 5);
    }

    function test_Pagination_InvalidArgs() public {
        vm.expectRevert();
        adapter.getAllAgentsPaginated(0, 10);
        vm.expectRevert();
        adapter.getAllAgentsPaginated(1, 0);
    }

    function test_WritesRevert() public {
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__ReadOnly.selector);
        adapter.register();
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__ReadOnly.selector);
        adapter.register("ipfs://x");
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__ReadOnly.selector);
        adapter.updateTokenURI(1, "ipfs://y");
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__ReadOnly.selector);
        adapter.setMetadata(1, "k", bytes("v"));
    }

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__ZeroAddress.selector);
        new ERC8004IdentityAdapter(address(0));
    }

    // ── 集成：扩展经适配器读取存量身份 ──────────────────────────────────

    function test_ExtensionReadsLegacyIdentityThroughAdapter() public {
        vm.prank(creator);
        uint256 agentId = legacy.register("ipfs://agent");

        // 扩展的 identity 参数指向 adapter（而非旧合约）
        ConfigurationRegistry config = new ConfigurationRegistry(address(adapter));

        // creator 是旧合约中的 agent 所有者 → 经 adapter.ownerOf 通过鉴权
        vm.prank(creator);
        uint256 configId = config.setConfig(agentId, "model", "gpt-x", "string", "demo");

        assertGt(configId, 0);
        assertEq(config.getConfigCount(agentId), 1);

        // 非所有者应被拒绝（鉴权确实来自旧合约的 ownerOf）
        vm.prank(other);
        vm.expectRevert();
        config.setConfig(agentId, "model2", "y", "string", "demo2");
    }

    function test_Constructor_RejectsNonContract() public {
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__NotAContract.selector);
        new ERC8004IdentityAdapter(other);
    }

    // ── canonical（官方单例）模式：同一字节码自动探测 ────────────────────

    function test_CanonicalMode_DetectedAndReads() public {
        MockCanonicalIdentity canon = new MockCanonicalIdentity();
        canon.mint(creator, 0); // canonical 0-based
        canon.setMeta(0, "name", bytes("Actora"));

        ERC8004IdentityAdapter a = new ERC8004IdentityAdapter(address(canon));
        assertTrue(a.canonicalMode());
        assertEq(a.getIdentityRegistry(), address(canon));

        assertEq(a.ownerOf(0), creator);
        assertTrue(a.agentExists(0));
        assertFalse(a.agentExists(999)); // 派生存在性：未知 id 返回 false（不 revert）
        assertEq(a.getMetadata(0, "name"), bytes("Actora"));
        assertEq(a.getMetadata(0, "missing"), bytes(""));
    }

    function test_CanonicalMode_OwnerOfRevertsForUnknown() public {
        MockCanonicalIdentity canon = new MockCanonicalIdentity();
        ERC8004IdentityAdapter a = new ERC8004IdentityAdapter(address(canon));
        vm.expectRevert();
        a.ownerOf(1);
    }

    function test_CanonicalMode_EnumerationUnsupported() public {
        MockCanonicalIdentity canon = new MockCanonicalIdentity();
        ERC8004IdentityAdapter a = new ERC8004IdentityAdapter(address(canon));

        vm.expectRevert(ERC8004IdentityAdapter.Adapter__UnsupportedOnCanonical.selector);
        a.getCurrentAgentId();
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__UnsupportedOnCanonical.selector);
        a.getAgentsByOwner(creator);
        vm.expectRevert(ERC8004IdentityAdapter.Adapter__UnsupportedOnCanonical.selector);
        a.getAllAgentsPaginated(1, 10);
    }

    function test_CanonicalMode_ExtensionReadsThroughAdapter() public {
        MockCanonicalIdentity canon = new MockCanonicalIdentity();
        canon.mint(creator, 0);

        ERC8004IdentityAdapter a = new ERC8004IdentityAdapter(address(canon));
        ConfigurationRegistry config = new ConfigurationRegistry(address(a));

        // creator 是 canonical 中 agentId 0 的所有者 → 经 adapter.ownerOf 通过鉴权
        vm.prank(creator);
        uint256 configId = config.setConfig(0, "model", "gpt-x", "string", "demo");
        assertGt(configId, 0);
        assertEq(config.getConfigCount(0), 1);

        vm.prank(other);
        vm.expectRevert();
        config.setConfig(0, "model2", "y", "string", "demo2");
    }
}
