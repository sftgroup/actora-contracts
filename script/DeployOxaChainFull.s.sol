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
 * @title DeployOxaChainFull
 * @notice Deploy all 6 core AgentX contracts to OxaChain L1
 *         Chain ID 19505, Clique PoA, RPC: http://REDACTED_HOST:18545
 *         Explorer: http://REDACTED_HOST:18400
 *
 *         Deployment order (dependency-aware):
 *           1. IdentityRegistry          — no deps
 *           2. ReputationRegistry        — depends on IdentityRegistry
 *           3. ConfigurationRegistry     — depends on IdentityRegistry
 *           4. MultiEndpointRegistry     — depends on IdentityRegistry
 *           5. A2AProtocolRegistry       — depends on IdentityRegistry
 *           6. SubscriptionManager v3    — no deps (standalone)
 *
 *         Usage:
 *           forge script script/DeployOxaChainFull.s.sol:DeployOxaChainFull \
 *             --rpc-url http://REDACTED_HOST:18545 \
 *             --broadcast --legacy
 *
 *         NOTE: --legacy required (Clique PoA no EIP-1559)
 */
contract DeployOxaChainFull is Script {
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
        console.log("  Deployment Summary - OxaChain L1 (19505)");
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
