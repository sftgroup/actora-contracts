// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ValidationRegistryUpgradeable} from "../src/erc8004-canonical/ValidationRegistryUpgradeable.sol";
import {ERC8004Bootstrap} from "../src/erc8004-canonical/ERC8004Bootstrap.sol";

/**
 * @title DeployValidationRegistry
 * @notice 只部署 ValidationRegistry（verbatim canonical 2.0.0 + UUPS 代理），
 *         不触碰已有的 TokenPriceOracle / SubscriptionManager / A2AProtocolRegistry。
 *
 *         为什么不复用 `DeployCanonicalExtensions`：那个脚本开头会**无条件重发**
 *         SubscriptionManager / A2A 等合约，重跑会产出一套无人使用的新地址，
 *         并与市场正在使用的订阅合约分叉。
 *
 *         为什么自部署而不是用官方实例（2026-10-30 实测）：
 *           - ETH：`0x8004Cb1B…` 已是 2.0.0，但 slot0 绑的是**测试网** identity
 *             `0x8004A818…`，对主网 agentId 不可用；
 *           - Base / BSC：`0x8004Cb1B…` 只是 MinimalUUPS 占位实现，四个方法选择器 0 命中。
 *         因此三链都需要自部署一份，并把 identity 绑到 canonical `0x8004A169…`。
 *
 *         用法（每链独立执行；先 dry-run 看 gas，再 --broadcast）：
 *
 *           # 1) 模拟（不花钱，不需要私钥）：DEPLOYER 用现有部署地址即可
 *           DEPLOYER=0x978e92477ff613c307e25bf0ed1d50e9483782c4 \
 *           forge script script/DeployValidationRegistry.s.sol:DeployValidationRegistry \
 *             --rpc-url https://bsc-rpc.publicnode.com
 *
 *           # 2) 广播（私钥只留在本机 shell 环境，不要写入任何文件）
 *           PRIVATE_KEY=<pk> \
 *           forge script script/DeployValidationRegistry.s.sol:DeployValidationRegistry \
 *             --rpc-url https://bsc-rpc.publicnode.com --broadcast --verify --chain 56
 *
 *         可选 env：
 *           CANONICAL_IDENTITY  默认 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432（三链同址）
 *           DEPLOYER            dry-run 时的模拟发送者（PRIVATE_KEY 缺省时使用）
 *
 *         部署后回填：gateway/.env 的 `VALIDATION_REGISTRY_<CHAIN>`。
 */
contract DeployValidationRegistry is Script {
    /// @dev 官方 canonical IdentityRegistry（BSC / Ethereum / Base 同址）
    address internal constant DEFAULT_CANONICAL_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function run() external {
        address canonical = vm.envOr("CANONICAL_IDENTITY", DEFAULT_CANONICAL_IDENTITY);
        require(canonical.code.length > 0, "canonical identity has no code");

        // 私钥缺省时退化为纯模拟：只用于 dry-run，配合 --broadcast 会由 forge 侧拦截。
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : vm.envAddress("DEPLOYER");

        // 有私钥走签名广播；无则用地址做纯模拟（此时不能带 --broadcast）。
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast(deployer);
        }

        // 1) 实现合约（verbatim canonical 2.0.0）
        ValidationRegistryUpgradeable impl = new ValidationRegistryUpgradeable();

        // 2) 垫片引导代理（真实实现的 initialize 是 onlyOwner，新代理 owner 为 0 会 revert）
        ERC8004Bootstrap bootstrap = new ERC8004Bootstrap();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bootstrap),
            abi.encodeCall(ERC8004Bootstrap.initialize, (deployer, canonical))
        );

        // 3) 升级到真实实现并初始化
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(
            address(impl),
            abi.encodeCall(ValidationRegistryUpgradeable.initialize, (canonical))
        );

        vm.stopBroadcast();

        // ── 部署即校验 ────────────────────────────────────────────────
        ValidationRegistryUpgradeable validation = ValidationRegistryUpgradeable(address(proxy));
        require(validation.getIdentityRegistry() == canonical, "validation: identity");
        require(OwnableUpgradeable(address(proxy)).owner() == deployer, "validation: owner");
        require(
            keccak256(bytes(validation.getVersion())) == keccak256(bytes("2.0.0")),
            "validation: version"
        );

        console.log("");
        console.log("==============================================");
        console.log("  ValidationRegistry - Deployment Summary");
        console.log("  ChainId:", block.chainid);
        console.log("  Block:", block.number);
        console.log("==============================================");
        console.log("  Canonical Identity:", canonical);
        console.log("  ValidationRegistry: ", address(proxy));
        console.log("  Implementation:     ", address(impl));
        console.log("  Bootstrap:          ", address(bootstrap));
        console.log("  Version:            ", validation.getVersion());
        console.log("==============================================");
        console.log("  Deployer:", deployer);
        console.log("  Env: VALIDATION_REGISTRY_<CHAIN> =", address(proxy));
        console.log("==============================================");
    }
}
