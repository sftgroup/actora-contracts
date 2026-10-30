// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/erc8004-core/IdentityRegistry.sol";
import "../src/erc8004-extensions/AgentFactory.sol";
import "../../src/erc8004-extensions/MultiEndpointRegistry.sol";

/**
 * @dev 最小 canonical 模拟：`register(string)` **非 payable**、0-based；**无** `getCurrentAgentId`，
 *      用于触发 AgentFactory 的 canonical 模式探测。
 */
contract MockCanonicalIdentityRegistry {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => string) private _uris;
    uint256 private _next;

    function register(string memory agentURI) external returns (uint256 agentId) {
        agentId = _next++;
        _owners[agentId] = msg.sender;
        _uris[agentId] = agentURI;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        require(o != address(0), "nonexistent");
        return o;
    }

    function transferFrom(address from, address to, uint256 agentId) external {
        require(_owners[agentId] == from, "not owner");
        _owners[agentId] = to;
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        return _uris[agentId];
    }
}

/**
 * @title AgentFactory 写入路径（WS4：legacy / canonical 双模式）
 * @notice 验证：
 *         · legacy（自研 ERC8004IdentityRegistry，payable + 注册费 + 1-based）→ 转发调用方传值；
 *         · canonical（官方单例语义，非 payable + 无注册费 + 0-based）→ 不带值；
 *         模式在构造 / setIdentityRegistry 时自动探测，写入路径随之切换。
 */
contract AgentFactoryWriteTest is Test {
    ERC8004IdentityRegistry internal legacy; // 1-based、register 需 ≥0.001 ether
    MockCanonicalIdentityRegistry internal canonical; // 0-based、非 payable
    MultiEndpointRegistry internal multiLegacy;
    MultiEndpointRegistry internal multiCanonical;

    /// @dev 接收 AgentFactory 退回的多余注册费
    receive() external payable {}

    function setUp() public {
        legacy = new ERC8004IdentityRegistry();
        canonical = new MockCanonicalIdentityRegistry();
        multiLegacy = new MultiEndpointRegistry(address(legacy));
        multiCanonical = new MultiEndpointRegistry(address(canonical));
    }

    /// @dev 建一个无端点/无配置的模板，聚焦写入路径本身
    function _emptyTemplate(AgentFactory f) internal returns (uint256 templateId) {
        string[] memory empty = new string[](0);
        templateId = f.createTemplate("t", "d", "ipfs://base", empty, empty, empty, empty, empty, empty, empty);
    }

    // ── legacy 模式 ──────────────────────────────────────────────────────

    function test_LegacyMode_Detected() public {
        AgentFactory f = new AgentFactory(address(legacy), address(multiLegacy));
        assertFalse(f.canonicalMode());
    }

    function test_LegacyMode_ForwardsValue() public {
        AgentFactory f = new AgentFactory(address(legacy), address(multiLegacy));
        uint256 tid = _emptyTemplate(f);

        vm.deal(address(this), 5 ether);
        uint256 agentId = f.createAgentFromTemplate{value: 1 ether}(tid);

        assertEq(agentId, 1); // legacy 1-based
        // NFT 先铸给工厂、创建完成后转交调用方
        assertEq(legacy.ownerOf(agentId), address(this));
        // 只消耗注册费（0.001 ether），多付部分退回调用方，工厂零滞留
        assertEq(address(this).balance, 4.999 ether);
        assertEq(address(f).balance, 0);
    }

    // ── canonical 模式 ───────────────────────────────────────────────────

    function test_CanonicalMode_Detected() public {
        AgentFactory f = new AgentFactory(address(canonical), address(multiCanonical));
        assertTrue(f.canonicalMode());
    }

    function test_CanonicalMode_CreateAgent() public {
        AgentFactory f = new AgentFactory(address(canonical), address(multiCanonical));
        uint256 tid = _emptyTemplate(f);

        uint256 agentId = f.createAgentFromTemplate(tid); // 不带值
        assertEq(agentId, 0); // canonical 0-based
        assertEq(canonical.ownerOf(agentId), address(this)); // 已转交调用方
        assertEq(canonical.tokenURI(agentId), "ipfs://base");
    }

    function test_CanonicalMode_RejectsValue() public {
        AgentFactory f = new AgentFactory(address(canonical), address(multiCanonical));
        uint256 tid = _emptyTemplate(f);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(AgentFactory.AgentFactory__UnexpectedValue.selector);
        f.createAgentFromTemplate{value: 1 ether}(tid);
    }

    function test_CanonicalMode_Batch() public {
        AgentFactory f = new AgentFactory(address(canonical), address(multiCanonical));
        uint256 tid = _emptyTemplate(f);

        uint256[] memory ids = f.createAgentsFromTemplate(tid, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(ids[2], 2);
        // 每个 agent 均已转交调用方
        assertEq(canonical.ownerOf(0), address(this));
        assertEq(canonical.ownerOf(1), address(this));
        assertEq(canonical.ownerOf(2), address(this));
    }

    // ── 切换身份注册表：重新探测模式 ─────────────────────────────────────

    function test_SetIdentityRegistry_RedetectsMode() public {
        AgentFactory f = new AgentFactory(address(legacy), address(multiLegacy));
        assertFalse(f.canonicalMode());

        f.setIdentityRegistry(address(canonical));
        assertTrue(f.canonicalMode());
        assertEq(address(f.identityRegistry()), address(canonical));

        f.setIdentityRegistry(address(legacy));
        assertFalse(f.canonicalMode());
    }

    function test_SetIdentityRegistry_Guards() public {
        AgentFactory f = new AgentFactory(address(legacy), address(multiLegacy));

        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert();
        f.setIdentityRegistry(address(canonical));

        vm.expectRevert(AgentFactory.AgentFactory__InvalidInput.selector);
        f.setIdentityRegistry(address(0));
    }
}
