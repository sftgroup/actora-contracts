// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/erc8004-extensions/A2AProtocolRegistry.sol";

/**
 * @dev canonical 模拟：只有 ERC-721 `ownerOf`（供 A2A 鉴权），**无** `getCurrentAgentId`，
 *      agentId 0-based —— 用于证明 `searchAgentsBySkill` 已不再依赖链上枚举。
 */
contract MockCanonicalIdentity {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 agentId) external {
        _owners[agentId] = to;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        require(o != address(0), "nonexistent");
        return o;
    }
}

/**
 * @title A2A 技能检索去 `getCurrentAgentId` 依赖
 * @notice `searchAgentsBySkill` 原先靠 `identityRegistry.getCurrentAgentId()` 遍历
 *         1..N，而官方 canonical 单例无链上枚举视图（调用 revert）。现改为读取
 *         `addAgentSkill` 维护的 per-skill agentId 集合，legacy / canonical 通用。
 *         本测试用**无 `getCurrentAgentId`** 的 canonical 模拟证明依赖已去除。
 */
contract A2ASkillSearchTest is Test {
    MockCanonicalIdentity internal canonical; // 0-based、无 getCurrentAgentId

    address internal creator = makeAddr("creator");
    address internal second = makeAddr("second");

    uint256 internal constant SKILL_TEXT = 1;
    uint256 internal constant SKILL_IMAGE = 2;

    function setUp() public {
        canonical = new MockCanonicalIdentity();
        vm.deal(creator, 10 ether);
    }

    // ── canonical：证明不依赖 getCurrentAgentId ──────────────────────────

    /// @dev canonical 模拟无 `getCurrentAgentId`；若检索仍调用它，此用例会 revert
    function test_Canonical_SkillSearch_DoesNotNeedGetCurrentAgentId() public {
        canonical.mint(creator, 0);
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.prank(creator);
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "1.0.0", 0, address(0));

        uint256[] memory found = a2a.searchAgentsBySkill(SKILL_TEXT);
        assertEq(found.length, 1);
        assertEq(found[0], 0); // 0-based
    }

    /// @dev createTask 的存在性校验改为 ownerOf：canonical 模拟（无 agentExists）可正常建任务
    function test_Canonical_CreateTask_UsesOwnerOf() public {
        canonical.mint(creator, 0);
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.prank(second);
        uint256 taskId = a2a.createTask(0, "text", "hello");
        assertEq(taskId, 1); // 计数器从 1 开始（0 视为「无任务」哨兵）
    }

    /// @dev 不存在的 agentId：ownerOf revert → InvalidInput（不再依赖 agentExists）
    function test_Canonical_CreateTask_RevertsForUnknownAgent() public {
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.prank(second);
        vm.expectRevert(A2AProtocolRegistry.A2AProtocol__InvalidInput.selector);
        a2a.createTask(999, "text", "hello");
    }

    function test_Canonical_SkillSearch_MultipleAgents() public {
        canonical.mint(creator, 0);
        canonical.mint(second, 1);
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.prank(creator);
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "1.0.0", 0, address(0));
        vm.prank(second);
        a2a.addAgentSkill(1, SKILL_TEXT, "https://agent1.example", "1.0.0", 0, address(0));

        uint256[] memory found = a2a.searchAgentsBySkill(SKILL_TEXT);
        assertEq(found.length, 2);
        assertEq(found[0], 0);
        assertEq(found[1], 1);
    }

    function test_Canonical_SkillSearch_SeparatesSkills() public {
        canonical.mint(creator, 0);
        canonical.mint(second, 1);
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.prank(creator);
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "1.0.0", 0, address(0));
        vm.prank(second);
        a2a.addAgentSkill(1, SKILL_IMAGE, "https://agent1.example", "1.0.0", 0, address(0));

        uint256[] memory text = a2a.searchAgentsBySkill(SKILL_TEXT);
        assertEq(text.length, 1);
        assertEq(text[0], 0);

        uint256[] memory image = a2a.searchAgentsBySkill(SKILL_IMAGE);
        assertEq(image.length, 1);
        assertEq(image[0], 1);
    }

    function test_Canonical_SkillSearch_UnknownSkillEmpty() public {
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));
        uint256[] memory found = a2a.searchAgentsBySkill(999);
        assertEq(found.length, 0);
    }

    /// @dev 重复登记同一 skill 不产生重复项（集合去重）
    function test_Canonical_SkillSearch_NoDuplicatesOnReAdd() public {
        canonical.mint(creator, 0);
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(canonical));

        vm.startPrank(creator);
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "1.0.0", 0, address(0));
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "2.0.0", 0, address(0));
        vm.stopPrank();

        uint256[] memory found = a2a.searchAgentsBySkill(SKILL_TEXT);
        assertEq(found.length, 1);
        assertEq(found[0], 0);
    }

    // ── 切换身份：setIdentityRegistry 后检索仍可用 ───────────────────────

    function test_SwitchIdentity_SkillSearchStillWorks() public {
        MockCanonicalIdentity previous = new MockCanonicalIdentity();
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(previous));
        canonical.mint(creator, 0);
        a2a.setIdentityRegistry(address(canonical)); // owner == this

        vm.prank(creator);
        a2a.addAgentSkill(0, SKILL_TEXT, "https://agent0.example", "1.0.0", 0, address(0));

        uint256[] memory found = a2a.searchAgentsBySkill(SKILL_TEXT);
        assertEq(found.length, 1);
        assertEq(found[0], 0);
    }
}
