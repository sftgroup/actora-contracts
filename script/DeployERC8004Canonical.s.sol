// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Canonical ERC-8004 参考实现（erc-8004/erc-8004-contracts, CC0），原样 vendor，未做任何修改
import {IdentityRegistryUpgradeable} from "../src/erc8004-canonical/IdentityRegistryUpgradeable.sol";
import {ReputationRegistryUpgradeable} from "../src/erc8004-canonical/ReputationRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "../src/erc8004-canonical/ValidationRegistryUpgradeable.sol";
import {ERC8004Bootstrap} from "../src/erc8004-canonical/ERC8004Bootstrap.sol";

// 局部接口：读取 Identity 代理的 ERC-721 元数据
interface IERC721Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/**
 * @title DeployERC8004Canonical
 * @notice 在目标链部署 **canonical ERC-8004 标准注册表**（Identity + Reputation，可选 Validation）。
 *
 *         与 `DeployV2.s.sol`（自研 `erc8004-core` 实现）的区别：
 *           - 使用上游 canonical 实现（接口与主网/各链单例完全一致）；
 *           - **无任何费用**：`register()` 非 payable、无 registrationFee、无平台费；
 *           - 采用 canonical 的 UUPS 代理模式（Identity/Reputation/Validation 各一个 ERC1967 代理）。
 *
 *         由于目标链不是公开链、没有 canonical 单例，也没有 SAFE 确定性工厂，
 *         因此本脚本用普通 CREATE 部署，**地址不会等于主网的 0x8004A…**（那需要 EF 团队的 owner 私钥）。
 *         接口/行为与标准完全一致，地址按链独立。
 *
 *         用法：
 *           PRIVATE_KEY=<deployer-pk> \
 *           ERC8004_OWNER=<addr>        # 可选，默认 deployer；代理 owner（可升级权限）
 *           DEPLOY_VALIDATION=true      # 可选，默认 false（Validation 规范仍在 draft）
 *           forge script script/DeployERC8004Canonical.s.sol:DeployERC8004Canonical \
 *             --rpc-url <RPC> --broadcast --legacy --chain <ID>
 */
contract DeployERC8004Canonical is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("ERC8004_OWNER", deployer);
        bool deployValidation = vm.envOr("DEPLOY_VALIDATION", false);

        vm.startBroadcast(pk);

        // 1) 真实实现（逻辑合约，永不被直接调用）
        IdentityRegistryUpgradeable identityImpl = new IdentityRegistryUpgradeable();
        ReputationRegistryUpgradeable reputationImpl = new ReputationRegistryUpgradeable();
        ValidationRegistryUpgradeable validationImpl;
        if (deployValidation) {
            validationImpl = new ValidationRegistryUpgradeable();
        }

        // 2) 引导垫片（仅用于写入 owner，等价上游 MinimalUUPS 但 owner 参数化）
        ERC8004Bootstrap bootstrap = new ERC8004Bootstrap();

        // 3) Identity 代理：bootstrap 初始化 → 升级到真实实现 → initialize()
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(bootstrap),
            abi.encodeCall(ERC8004Bootstrap.initialize, (owner, address(0)))
        );
        UUPSUpgradeable(address(identityProxy)).upgradeToAndCall(
            address(identityImpl),
            abi.encodeCall(IdentityRegistryUpgradeable.initialize, ())
        );

        // 4) Reputation 代理：接线到 Identity
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(bootstrap),
            abi.encodeCall(ERC8004Bootstrap.initialize, (owner, address(identityProxy)))
        );
        UUPSUpgradeable(address(reputationProxy)).upgradeToAndCall(
            address(reputationImpl),
            abi.encodeCall(ReputationRegistryUpgradeable.initialize, (address(identityProxy)))
        );

        // 5) Validation 代理（可选）
        ERC1967Proxy validationProxy;
        if (deployValidation) {
            validationProxy = new ERC1967Proxy(
                address(bootstrap),
                abi.encodeCall(ERC8004Bootstrap.initialize, (owner, address(identityProxy)))
            );
            UUPSUpgradeable(address(validationProxy)).upgradeToAndCall(
                address(validationImpl),
                abi.encodeCall(ValidationRegistryUpgradeable.initialize, (address(identityProxy)))
            );
        }

        vm.stopBroadcast();

        address identity = address(identityProxy);
        address reputation = address(reputationProxy);

        // ── 部署即校验 ────────────────────────────────────────────────
        // owner 正确（可升级权限归属）
        require(OwnableUpgradeable(identity).owner() == owner, "canonical: identity.owner != owner");
        require(OwnableUpgradeable(reputation).owner() == owner, "canonical: reputation.owner != owner");
        // 标准 ERC-721 元数据（Identity 在 initialize 中设定）
        require(
            keccak256(bytes(IERC721Metadata(identity).name())) == keccak256(bytes("AgentIdentity")),
            "canonical: identity.name"
        );
        require(
            keccak256(bytes(IERC721Metadata(identity).symbol())) == keccak256(bytes("AGENT")),
            "canonical: identity.symbol"
        );
        // Reputation / Validation 正确接线到 Identity
        require(ReputationRegistryUpgradeable(reputation).getIdentityRegistry() == identity, "canonical: reputation.identity != identity");
        if (deployValidation) {
            require(OwnableUpgradeable(address(validationProxy)).owner() == owner, "canonical: validation.owner != owner");
            require(ValidationRegistryUpgradeable(address(validationProxy)).getIdentityRegistry() == identity, "canonical: validation.identity != identity");
        }

        // ── 输出 ──────────────────────────────────────────────────────
        console.log("");
        console.log("==============================================");
        console.log("  Deployment Summary - ERC-8004 CANONICAL");
        console.log("  ChainId:", block.chainid);
        console.log("  Deploy block:", block.number);
        console.log("==============================================");
        console.log("  IdentityRegistry (proxy):   ", identity);
        console.log("    impl:", address(identityImpl));
        console.log("  ReputationRegistry (proxy): ", reputation);
        console.log("    impl:", address(reputationImpl));
        if (deployValidation) {
            console.log("  ValidationRegistry (proxy): ", address(validationProxy));
            console.log("    impl:", address(validationImpl));
        }
        console.log("  Bootstrap (shim):           ", address(bootstrap));
        console.log("==============================================");
        console.log("  Owner:    ", owner);
        console.log("  Deployer: ", deployer);
        console.log("  Fees:     none (register() non-payable)");
        console.log("==============================================");
    }
}
