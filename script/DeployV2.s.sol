// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// ERC-8004 新一代（core 身份 + core 注册表 + extensions）
import {ERC8004IdentityRegistry} from "../src/erc8004-core/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/erc8004-core/ReputationRegistry.sol";
import {ValidationRegistry} from "../src/erc8004-core/ValidationRegistry.sol";
import {ConfigurationRegistry} from "../src/erc8004-extensions/ConfigurationRegistry.sol";
import {MultiEndpointRegistry} from "../src/erc8004-extensions/MultiEndpointRegistry.sol";
import {A2AProtocolRegistry} from "../src/erc8004-extensions/A2AProtocolRegistry.sol";
import {TokenPriceOracle} from "../src/erc8004-extensions/TokenPriceOracle.sol";
import {AgentWallet} from "../src/erc8004-extensions/AgentWallet.sol";
import {ERC8004SubscriptionManager} from "../src/erc8004-extensions/SubscriptionManager.sol";

/**
 * @title DeployV2
 * @notice WS1 新链部署脚本：只部署 **ERC-8004 一代**（不部署旧版 IdentityRegistry /
 *         SubscriptionManager）。按依赖顺序：core 身份 → core 注册表 → extensions →
 *         订阅（含 AgentWallet / TokenPriceOracle 依赖），并在部署后**校验依赖接线**。
 *
 *         与旧脚本的区别：`script/DeployBsc.s.sol` 以**旧版** IdentityRegistry 为底座，
 *         再把它交给 ERC-8004 扩展（接口错配）；本脚本以 **ERC8004IdentityRegistry**
 *         为底座，接口天然匹配。
 *
 *         存量链（已部署旧版）不跑本脚本，改用 ERC8004IdentityAdapter 让扩展读旧身份。
 *
 *         用法：
 *           PRIVATE_KEY=<deployer-pk> \
 *           FEE_COLLECTOR=<addr>  \   # 可选，默认 deployer
 *           forge script script/DeployV2.s.sol:DeployV2 \
 *             --rpc-url <RPC> --broadcast --verify --chain <ID>
 */
contract DeployV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. core 身份（一切依赖的根）
        ERC8004IdentityRegistry identity = new ERC8004IdentityRegistry();

        // 2. core 注册表
        ReputationRegistry reputation = new ReputationRegistry(address(identity));
        ValidationRegistry validation = new ValidationRegistry(address(identity));

        // 3. extensions（均只依赖 identity）
        ConfigurationRegistry configuration = new ConfigurationRegistry(address(identity));
        MultiEndpointRegistry multiEndpoint = new MultiEndpointRegistry(address(identity));
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(identity));

        // 4. 订阅所需的依赖：价格预言机 + Agent 钱包
        TokenPriceOracle priceOracle = new TokenPriceOracle();
        AgentWallet agentWallet = new AgentWallet(address(identity));

        // 5. 订阅（依赖 identity + agentWallet + priceOracle + feeCollector）
        ERC8004SubscriptionManager subscriptions = new ERC8004SubscriptionManager(
            address(identity),
            address(agentWallet),
            address(priceOracle),
            feeCollector
        );

        vm.stopBroadcast();

        // ── 校验依赖接线（部署即验证，避免"地址填错"类事故）────────────────
        require(address(reputation.identityRegistry()) == address(identity), "V2: reputation.identity != identity");
        require(address(validation.identityRegistry()) == address(identity), "V2: validation.identity != identity");
        require(address(configuration.identityRegistry()) == address(identity), "V2: configuration.identity != identity");
        require(address(multiEndpoint.identityRegistry()) == address(identity), "V2: multiEndpoint.identity != identity");
        require(address(a2a.identityRegistry()) == address(identity), "V2: a2a.identity != identity");
        require(address(agentWallet.identityRegistry()) == address(identity), "V2: agentWallet.identity != identity");
        require(address(subscriptions.identityRegistry()) == address(identity), "V2: subscriptions.identity != identity");
        require(address(subscriptions.agentWallet()) == address(agentWallet), "V2: subscriptions.agentWallet != agentWallet");
        require(address(subscriptions.priceOracle()) == address(priceOracle), "V2: subscriptions.priceOracle != priceOracle");

        // ── 输出 ──────────────────────────────────────────────────────────
        console.log("");
        console.log("==============================================");
        console.log("  Deployment Summary - ERC-8004 V2");
        console.log("  ChainId:", block.chainid);
        console.log("  Deploy block:", block.number);
        console.log("==============================================");
        console.log("  IdentityRegistry (core): ", address(identity));
        console.log("  ReputationRegistry:      ", address(reputation));
        console.log("  ValidationRegistry:      ", address(validation));
        console.log("  ConfigurationRegistry:   ", address(configuration));
        console.log("  MultiEndpointRegistry:   ", address(multiEndpoint));
        console.log("  A2AProtocolRegistry:     ", address(a2a));
        console.log("  TokenPriceOracle:        ", address(priceOracle));
        console.log("  AgentWallet:             ", address(agentWallet));
        console.log("  SubscriptionManager v2:  ", address(subscriptions));
        console.log("==============================================");
        console.log("  FeeCollector:", feeCollector);
        console.log("  Deployer:    ", deployer);
        console.log("==============================================");
    }
}
