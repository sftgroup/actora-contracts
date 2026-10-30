// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/erc8004-core/IdentityRegistry.sol";
import "../src/erc8004-extensions/ERC8004IdentityAdapter.sol";
import "../src/erc8004-extensions/AgentWallet.sol";
import "../src/erc8004-extensions/PaymentGateway.sol";

/**
 * @dev canonical 模拟：有 ERC-721 `ownerOf`，**无** `getCurrentAgentId`（触发适配器 canonical 探测）；0-based。
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
 * @title 扩展的 canonical 读取适配（PaymentGateway / AgentWallet）
 * @notice 两者只读 `identityRegistry.agentExists(agentId)` + ERC-721 `ownerOf`，
 *         因此把 identity 指向 `ERC8004IdentityAdapter`（双模式只读桥）即可兼容
 *         旧版 / 官方 canonical 单例。此处验证经适配器在两种模式下 `agentExists` 均可用。
 */
contract ExtensionCanonicalReadsTest is Test {
    ERC8004IdentityRegistry internal legacy; // 有 getCurrentAgentId + agentExists（1-based）
    MockCanonicalIdentity internal canonical; // 无 getCurrentAgentId（0-based）
    address internal creator = makeAddr("creator");

    function setUp() public {
        legacy = new ERC8004IdentityRegistry();
        canonical = new MockCanonicalIdentity();
        vm.deal(creator, 10 ether); // 供注册费 / 充值的 value 调用
    }

    function _canonicalAdapter() internal returns (ERC8004IdentityAdapter) {
        return new ERC8004IdentityAdapter(address(canonical));
    }

    // ── AgentWallet：depositNative 由 agentExists 把关 ───────────────────

    function test_AgentWallet_LegacyAdapter_DepositNative() public {
        vm.prank(creator);
        uint256 agentId = legacy.register{value: 0.001 ether}("ipfs://a");

        AgentWallet wallet = new AgentWallet(address(new ERC8004IdentityAdapter(address(legacy))));
        vm.prank(creator);
        wallet.depositNative{value: 1 ether}(agentId);

        (uint256 nativeBal, , ) = wallet.getAgentWalletBalance(agentId);
        assertEq(nativeBal, 1 ether);
    }

    function test_AgentWallet_CanonicalAdapter_DepositNative() public {
        canonical.mint(creator, 0);
        ERC8004IdentityAdapter adapter = _canonicalAdapter();
        assertTrue(adapter.canonicalMode());

        AgentWallet wallet = new AgentWallet(address(adapter));
        vm.prank(creator);
        wallet.depositNative{value: 1 ether}(0);

        (uint256 nativeBal, , ) = wallet.getAgentWalletBalance(0);
        assertEq(nativeBal, 1 ether);
    }

    function test_AgentWallet_CanonicalAdapter_UnknownAgentReverts() public {
        AgentWallet wallet = new AgentWallet(address(_canonicalAdapter()));
        vm.prank(creator);
        vm.expectRevert(AgentWallet.AgentWallet__InvalidAgent.selector);
        wallet.depositNative{value: 1 ether}(999);
    }

    /// @dev 已验证的路径：先指向旧版，再经 setIdentityRegistry 切到 canonical 适配器
    function test_AgentWallet_SwitchToCanonicalAdapter() public {
        vm.prank(creator);
        uint256 legacyId = legacy.register{value: 0.001 ether}("ipfs://a");

        AgentWallet wallet = new AgentWallet(address(legacy));
        vm.prank(creator);
        wallet.depositNative{value: 1 ether}(legacyId); // 旧版直连可用

        canonical.mint(creator, 0);
        wallet.setIdentityRegistry(address(_canonicalAdapter())); // 切到 canonical

        vm.prank(creator);
        wallet.depositNative{value: 1 ether}(0); // canonical agentId 0 可用
        (uint256 nativeBal, , ) = wallet.getAgentWalletBalance(0);
        assertEq(nativeBal, 1 ether);
    }

    // ── PaymentGateway：initiatePayment 由 agentExists 把关 ──────────────

    function _gateway(ERC8004IdentityAdapter adapter) internal returns (PaymentGateway) {
        return new PaymentGateway(
            address(adapter),
            address(0xA11CE),
            address(0xB0B),
            address(0xCAFE),
            address(0xFEE)
        );
    }

    function test_PaymentGateway_CanonicalAdapter_UnknownAgentReverts() public {
        PaymentGateway pg = _gateway(_canonicalAdapter());
        vm.expectRevert(PaymentGateway.PaymentGateway__InvalidAgent.selector);
        pg.initiatePayment(999, address(0), 1, PaymentGateway.PaymentType.OneTime, 0, "", false, false);
    }

    /// @dev agent 存在 → 越过 agentExists 关卡，随后因 native 值不匹配 amount 而 revert InvalidAmount
    ///      （若 agentExists 误判为 false，则会 revert InvalidAgent —— 故此断言证明关卡已通过）
    function test_PaymentGateway_CanonicalAdapter_PassesAgentGate() public {
        canonical.mint(creator, 0);
        PaymentGateway pg = _gateway(_canonicalAdapter());

        vm.prank(creator);
        vm.expectRevert(PaymentGateway.PaymentGateway__InvalidAmount.selector);
        pg.initiatePayment{value: 0}(0, address(0), 1, PaymentGateway.PaymentType.OneTime, 0, "", false, false);
    }

    function test_PaymentGateway_LegacyAdapter_PassesAgentGate() public {
        vm.prank(creator);
        uint256 agentId = legacy.register{value: 0.001 ether}("ipfs://a");

        PaymentGateway pg = _gateway(new ERC8004IdentityAdapter(address(legacy)));
        vm.prank(creator);
        vm.expectRevert(PaymentGateway.PaymentGateway__InvalidAmount.selector);
        pg.initiatePayment{value: 0}(agentId, address(0), 1, PaymentGateway.PaymentType.OneTime, 0, "", false, false);
    }
}
