// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {SubscriptionManager} from "../src/SubscriptionManager.sol";
// ERC-8004 contracts — renamed to avoid conflict with AgentX IdentityRegistry
import {ReputationRegistry} from "../src/erc8004-core/ReputationRegistry.sol";
import {A2AProtocolRegistry} from "../src/erc8004-extensions/A2AProtocolRegistry.sol";
import {ConfigurationRegistry} from "../src/erc8004-extensions/ConfigurationRegistry.sol";
import {MultiEndpointRegistry} from "../src/erc8004-extensions/MultiEndpointRegistry.sol";

/**
 * @title DeployEthereum
 * @notice ⚠️ DEPRECATED（2026-10-22）：生产链请改用 `DeployCanonicalExtensions.s.sol`。
 *         本脚本会 `new IdentityRegistry()`，部署出自建 legacy 身份层，与官方 canonical 单例不兼容。
 *         仅保留用于历史复现 / 独立测试链。
 *
 * @notice Deploy all 6 core AgentX contracts to Ethereum Mainnet
 *         Chain ID 1 (mainnet). EIP-1559 supported, so no --legacy flag
 *         needed.
 *
 *         Deployment order (dependency-aware, same as DeployBsc):
 *           1. IdentityRegistry          — no deps
 *           2. ReputationRegistry        — depends on IdentityRegistry
 *           3. ConfigurationRegistry     — depends on IdentityRegistry
 *           4. MultiEndpointRegistry     — depends on IdentityRegistry
 *           5. A2AProtocolRegistry       — depends on IdentityRegistry
 *           6. SubscriptionManager v3    — no deps (standalone)
 *
 *         Usage (Ethereum mainnet):
 *           PRIVATE_KEY=<deployer-pk> forge script script/DeployEthereum.s.sol:DeployEthereum \
 *             --rpc-url https://ethereum-rpc.publicnode.com \
 *             --broadcast --verify --chain 1
 *
 *         IMPORTANT: deployer must hold ETH for gas. After deployment, write
 *         the emitted addresses back into the gateway .env
 *         (IDENTITY_REGISTRY_ETHEREUM, SUBSCRIPTION_MANAGER_ETHEREUM,
 *         A2A_PROTOCOL_ETHEREUM, REPUTATION_REGISTRY_ETHEREUM,
 *         CONFIGURATION_REGISTRY_ETHEREUM, MULTI_ENDPOINT_ETHEREUM) and set
 *         PLANS_SYNC_FROM_BLOCK_ETHEREUM / SUBSCRIPTIONS_SYNC_FROM_BLOCK_ETHEREUM
 *         to the SubscriptionManager deploy block (see the summary log).
 *         Also update sdk KNOWN_CHAINS[1] (contracts + deployed:true) and
 *         restart the gateway — the market watcher picks the chain up
 *         automatically once the addresses are configured.
 */
contract DeployEthereum is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 initialFeeBps = 250; // 2.5% platform fee

        vm.startBroadcast(deployerPrivateKey);

        // 1. IdentityRegistry (foundation — all other contracts depend on it)
        IdentityRegistry ir = new IdentityRegistry();
        console.log("===== IdentityRegistry =====");
        console.log("  Address:", address(ir));

        // 2. ReputationRegistry
        ReputationRegistry rep = new ReputationRegistry(address(ir));
        console.log("===== ReputationRegistry =====");
        console.log("  Address:", address(rep));

        // 3. ConfigurationRegistry
        ConfigurationRegistry cfg = new ConfigurationRegistry(address(ir));
        console.log("===== ConfigurationRegistry =====");
        console.log("  Address:", address(cfg));

        // 4. MultiEndpointRegistry
        MultiEndpointRegistry multi = new MultiEndpointRegistry(address(ir));
        console.log("===== MultiEndpointRegistry =====");
        console.log("  Address:", address(multi));

        // 5. A2AProtocolRegistry
        A2AProtocolRegistry a2a = new A2AProtocolRegistry(address(ir));
        console.log("===== A2AProtocolRegistry =====");
        console.log("  Address:", address(a2a));

        // 6. SubscriptionManager v3 (standalone, but tied to IR agents)
        SubscriptionManager sm = new SubscriptionManager(initialFeeBps);
        console.log("===== SubscriptionManager v3 =====");
        console.log("  Address:", address(sm));
        console.log("  PlatformFeeBps:", initialFeeBps);

        vm.stopBroadcast();

        console.log("");
        console.log("==============================================");
        console.log("  Deployment Summary - Ethereum Mainnet");
        console.log("  ChainId:", block.chainid);
        console.log("  SM deploy block:", block.number);
        console.log("==============================================");
        console.log("  IdentityRegistry:      ", address(ir));
        console.log("  ReputationRegistry:    ", address(rep));
        console.log("  ConfigurationRegistry: ", address(cfg));
        console.log("  MultiEndpointRegistry: ", address(multi));
        console.log("  A2AProtocolRegistry:   ", address(a2a));
        console.log("  SubscriptionManager v3:", address(sm));
        console.log("==============================================");
        console.log("  Deployer:", vm.addr(deployerPrivateKey));
        console.log("==============================================");
    }
}
