// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/erc8004-core/IdentityRegistry.sol";
import "../src/erc8004-core/ReputationRegistry.sol";
import "../src/erc8004-core/ValidationRegistry.sol";
import "../../src/erc8004-interfaces/IERC8004Validation.sol";
import "../../src/erc8004-extensions/ConfigurationRegistry.sol";
import "../../src/erc8004-extensions/MultiEndpointRegistry.sol";
import "../../src/erc8004-extensions/A2AProtocolRegistry.sol";

/**
 * @title WS4 可插拔身份配置测试
 * @notice 验证扩展/核心注册表可将指向的 ERC-8004 identity 注册表从 immutable 改为
 *         owner 可配置：仅 owner 可调用、零地址被拒绝、切换后 identityRegistry 返回
 *         新地址、发出 IdentityRegistryUpdated 事件，且 erc721Identity 与新地址一致。
 */
contract IdentityConfigurableTest is Test {
    event IdentityRegistryUpdated(address indexed previous, address indexed current);

    ERC8004IdentityRegistry internal identity;
    ERC8004IdentityRegistry internal newIdentity;
    address internal nonOwner = makeAddr("nonOwner");

    function setUp() public {
        identity = new ERC8004IdentityRegistry();
        newIdentity = new ERC8004IdentityRegistry();
    }

    // ── ConfigurationRegistry ────────────────────────────────────────────

    function test_ConfigurationRegistry_SetIdentityRegistry() public {
        ConfigurationRegistry target = new ConfigurationRegistry(address(identity));
        assertEq(address(target.identityRegistry()), address(identity));

        // 1) 非 owner 调用 revert
        vm.prank(nonOwner);
        vm.expectRevert();
        target.setIdentityRegistry(address(newIdentity));

        // 2) owner 调用成功：地址更新 + 事件 + erc721Identity 同步
        vm.expectEmit(true, true, false, true);
        emit IdentityRegistryUpdated(address(identity), address(newIdentity));
        target.setIdentityRegistry(address(newIdentity));
        assertEq(address(target.identityRegistry()), address(newIdentity));
        assertEq(address(target.erc721Identity()), address(newIdentity));

        // 3) 零地址 revert
        vm.expectRevert(ConfigurationRegistry.Configuration__InvalidInput.selector);
        target.setIdentityRegistry(address(0));
    }

    // ── MultiEndpointRegistry ────────────────────────────────────────────

    function test_MultiEndpointRegistry_SetIdentityRegistry() public {
        MultiEndpointRegistry target = new MultiEndpointRegistry(address(identity));
        assertEq(address(target.identityRegistry()), address(identity));

        vm.prank(nonOwner);
        vm.expectRevert();
        target.setIdentityRegistry(address(newIdentity));

        vm.expectEmit(true, true, false, true);
        emit IdentityRegistryUpdated(address(identity), address(newIdentity));
        target.setIdentityRegistry(address(newIdentity));
        assertEq(address(target.identityRegistry()), address(newIdentity));
        assertEq(address(target.erc721Identity()), address(newIdentity));

        vm.expectRevert(MultiEndpointRegistry.MultiEndpoint__InvalidInput.selector);
        target.setIdentityRegistry(address(0));
    }

    // ── A2AProtocolRegistry ──────────────────────────────────────────────

    function test_A2AProtocolRegistry_SetIdentityRegistry() public {
        A2AProtocolRegistry target = new A2AProtocolRegistry(address(identity));
        assertEq(address(target.identityRegistry()), address(identity));

        vm.prank(nonOwner);
        vm.expectRevert();
        target.setIdentityRegistry(address(newIdentity));

        vm.expectEmit(true, true, false, true);
        emit IdentityRegistryUpdated(address(identity), address(newIdentity));
        target.setIdentityRegistry(address(newIdentity));
        assertEq(address(target.identityRegistry()), address(newIdentity));
        assertEq(address(target.erc721Identity()), address(newIdentity));

        vm.expectRevert(A2AProtocolRegistry.A2AProtocol__InvalidInput.selector);
        target.setIdentityRegistry(address(0));
    }

    // ── ValidationRegistry ───────────────────────────────────────────────

    function test_ValidationRegistry_SetIdentityRegistry() public {
        ValidationRegistry target = new ValidationRegistry(address(identity));
        assertEq(address(target.identityRegistry()), address(identity));

        vm.prank(nonOwner);
        vm.expectRevert();
        target.setIdentityRegistry(address(newIdentity));

        vm.expectEmit(true, true, false, true);
        emit IdentityRegistryUpdated(address(identity), address(newIdentity));
        target.setIdentityRegistry(address(newIdentity));
        assertEq(address(target.identityRegistry()), address(newIdentity));

        vm.expectRevert(IERC8004Validation.ERC8004__ZeroAddress.selector);
        target.setIdentityRegistry(address(0));
    }

    // ── ReputationRegistry（核心，经 BaseReputationRegistry） ─────────────

    function test_ReputationRegistry_SetIdentityRegistry() public {
        ReputationRegistry target = new ReputationRegistry(address(identity));
        assertEq(address(target.identityRegistry()), address(identity));

        vm.prank(nonOwner);
        vm.expectRevert();
        target.setIdentityRegistry(address(newIdentity));

        vm.expectEmit(true, true, false, true);
        emit IdentityRegistryUpdated(address(identity), address(newIdentity));
        target.setIdentityRegistry(address(newIdentity));
        assertEq(address(target.identityRegistry()), address(newIdentity));

        vm.expectRevert(BaseReputationRegistry.BaseReputation__InvalidIdentityRegistry.selector);
        target.setIdentityRegistry(address(0));
    }
}
