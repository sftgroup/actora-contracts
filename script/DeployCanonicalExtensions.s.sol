// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ValidationRegistryUpgradeable} from "../src/erc8004-canonical/ValidationRegistryUpgradeable.sol";
import {ERC8004Bootstrap} from "../src/erc8004-canonical/ERC8004Bootstrap.sol";

import {TokenPriceOracle} from "../src/erc8004-extensions/TokenPriceOracle.sol";
import {ERC8004SubscriptionManager} from "../src/erc8004-extensions/SubscriptionManager.sol";
import {A2AProtocolRegistry} from "../src/erc8004-extensions/A2AProtocolRegistry.sol";
import {ConfigurationRegistry} from "../src/erc8004-extensions/ConfigurationRegistry.sol";
import {MultiEndpointRegistry} from "../src/erc8004-extensions/MultiEndpointRegistry.sol";
import {AgentFactory} from "../src/erc8004-extensions/AgentFactory.sol";
import {AgentMigrator} from "../src/erc8004-extensions/AgentMigrator.sol";

/**
 * @title DeployCanonicalExtensions
 * @notice P1.1：以官方 canonical IdentityRegistry 为构造参数，部署全套扩展合约。
 *
 *         与 `DeployBsc.s.sol` / `DeployEthereum.s.sol` / `DeployBase.s.sol` 的区别：
 *           - **不再 `new IdentityRegistry()` / `new ReputationRegistry()`**；
 *             身份/信誉层直接复用官方单例（BSC/ETH/Base 同址）。
 *           - 所有扩展的 `identityRegistry` 指向 canonical 单例，agentId 为 0-based 全局编号。
 *           - Validation 按 2026-10-20 定案自部署 verbatim（BSC/Base 官方 0.0.1 不兼容）。
 *
 *         部署顺序（依赖感知）：
 *           1. TokenPriceOracle
 *           2. SubscriptionManager    (identity, priceOracle, feeCollector)
 *           3. A2AProtocolRegistry    (identity)
 *           4. ConfigurationRegistry  (identity)
 *           5. MultiEndpointRegistry  (identity)
 *           6. AgentFactory           (identity, multiEndpoint)
 *           7. ValidationRegistry     (verbatim, UUPS 代理, identity)
 *           8. AgentMigrator          (可选：legacy → canonical，需 LEGACY_IDENTITY)
 *
 *         用法（每链独立执行，顺序 ETH → Base → BSC）：
 *           PRIVATE_KEY=<pk> \
 *           FEE_COLLECTOR=<addr> \
 *           DEPLOY_VALIDATION=true \
 *           LEGACY_IDENTITY=<该链 legacy IdentityRegistry> \
 *           forge script script/DeployCanonicalExtensions.s.sol:DeployCanonicalExtensions \
 *             --rpc-url <RPC> --broadcast --verify --chain <ID>
 *
 *         可选 env：
 *           CANONICAL_IDENTITY  默认 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432（三链同址）
 *           FEE_BPS             默认 250（2.5%），0 = 不改
 *           DEPLOY_VALIDATION   默认 true
 *           LEGACY_IDENTITY     默认 0；为 0 时跳过 AgentMigrator
 *
 *         部署完成后把输出地址写入 gateway/.env（`*_<CHAIN>`）与 sdk KNOWN_CHAINS。
 */
contract DeployCanonicalExtensions is Script {
    /// @dev 官方 canonical IdentityRegistry（BSC / Ethereum / Base 同址）
    address internal constant DEFAULT_CANONICAL_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address canonical = vm.envOr("CANONICAL_IDENTITY", DEFAULT_CANONICAL_IDENTITY);
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(250));
        bool deployValidation = vm.envOr("DEPLOY_VALIDATION", true);
        address legacy = vm.envOr("LEGACY_IDENTITY", address(0));

        require(canonical.code.length > 0, "canonical identity has no code");
        require(feeCollector != address(0), "feeCollector is zero");

        vm.startBroadcast(pk);

        // 1) 价格预言机（无依赖）
        TokenPriceOracle priceOracle = new TokenPriceOracle();

        // 2) 订阅管理（依赖 identity / oracle）
        ERC8004SubscriptionManager subscriptions = new ERC8004SubscriptionManager(
            canonical,
            address(priceOracle),
            feeCollector
        );
        if (feeBps > 0) {
            subscriptions.setDefaultPlatformFee(feeBps);
        }

        // 3) A2A / 配置 / 端点
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(canonical);
        ConfigurationRegistry config = new ConfigurationRegistry(canonical);
        MultiEndpointRegistry endpoints = new MultiEndpointRegistry(canonical);

        // 4) Agent 工厂（依赖 identity + endpoint）
        AgentFactory factory = new AgentFactory(canonical, address(endpoints));

        // 5) Validation（verbatim canonical，UUPS 代理）
        ValidationRegistryUpgradeable validationImpl;
        address validation = address(0);
        if (deployValidation) {
            validationImpl = new ValidationRegistryUpgradeable();
            ERC8004Bootstrap bootstrap = new ERC8004Bootstrap();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(bootstrap),
                abi.encodeCall(ERC8004Bootstrap.initialize, (deployer, canonical))
            );
            UUPSUpgradeable(address(proxy)).upgradeToAndCall(
                address(validationImpl),
                abi.encodeCall(ValidationRegistryUpgradeable.initialize, (canonical))
            );
            validation = address(proxy);
        }

        // 6) 迁移器（可选：仅在配置 LEGACY_IDENTITY 时部署）
        AgentMigrator migrator;
        if (legacy != address(0)) {
            migrator = new AgentMigrator(legacy, canonical);
        }

        vm.stopBroadcast();

        // ── 部署即校验 ────────────────────────────────────────────────
        require(address(subscriptions.identityRegistry()) == canonical, "sm: identity");
        require(address(subscriptions.priceOracle()) == address(priceOracle), "sm: oracle");
        require(address(a2a.identityRegistry()) == canonical, "a2a: identity");
        require(address(config.identityRegistry()) == canonical, "config: identity");
        require(address(endpoints.identityRegistry()) == canonical, "endpoints: identity");
        require(address(factory.identityRegistry()) == canonical, "factory: identity");
        require(factory.canonicalMode(), "factory: canonical not detected");
        if (deployValidation) {
            require(
                ValidationRegistryUpgradeable(validation).getIdentityRegistry() == canonical,
                "validation: identity"
            );
            require(OwnableUpgradeable(validation).owner() == deployer, "validation: owner");
        }
        if (legacy != address(0)) {
            require(address(migrator.legacyRegistry()) == legacy, "migrator: legacy");
            require(address(migrator.canonicalRegistry()) == canonical, "migrator: canonical");
        }

        // ── 输出（直接对应 gateway/.env 键名）────────────────────────
        console.log("");
        console.log("==============================================");
        console.log("  Canonical Extensions - Deployment Summary");
        console.log("  ChainId:", block.chainid);
        console.log("  Block:", block.number);
        console.log("==============================================");
        console.log("  Canonical Identity:", canonical);
        console.log("  TokenPriceOracle:          ", address(priceOracle));
        console.log("  SubscriptionManager:       ", address(subscriptions));
        console.log("  A2AProtocolRegistry:       ", address(a2a));
        console.log("  ConfigurationRegistry:     ", address(config));
        console.log("  MultiEndpointRegistry:     ", address(endpoints));
        console.log("  AgentFactory:              ", address(factory));
        if (deployValidation) {
            console.log("  ValidationRegistry:        ", validation);
            console.log("    impl:", address(validationImpl));
        }
        if (legacy != address(0)) {
            console.log("  AgentMigrator:             ", address(migrator));
            console.log("    legacy:", legacy);
        }
        console.log("==============================================");
        console.log("  FeeCollector:", feeCollector);
        console.log("  FeeBps:      ", feeBps);
        console.log("  Deployer:    ", deployer);
        console.log("==============================================");
        console.log("  Env: IDENTITY_REGISTRY_<CHAIN>     =", canonical);
        console.log("  Env: SUBSCRIPTION_MANAGER_<CHAIN>  =", address(subscriptions));
        console.log("  Env: A2A_PROTOCOL_<CHAIN>          =", address(a2a));
        console.log("  Env: CONFIGURATION_REGISTRY_<CHAIN>=", address(config));
        console.log("  Env: MULTI_ENDPOINT_<CHAIN>        =", address(endpoints));
        if (deployValidation) {
            console.log("  Env: VALIDATION_REGISTRY_<CHAIN>   =", validation);
        }
        console.log("==============================================");
    }
}
