// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/IdentityRegistry.sol";
import "../src/SubscriptionManager.sol";

/**
 * @title DeployAgentX to OxaChain L1
 * @notice Deploy IdentityRegistry + SubscriptionManager (v3 with ReentrancyGuard)
 *         to OxaChain L1 (Chain ID 19505, Clique PoA, RPC: http://REDACTED_HOST:18545)
 *
 *         Usage:
 *           forge script script/DeployOxaChain.s.sol:DeployOxaChain \
 *             --rpc-url http://REDACTED_HOST:18545 \
 *             --broadcast --legacy
 *
 *         NOTE: --legacy is required because Clique PoA doesn't support EIP-1559 fee estimation
 */
contract DeployOxaChain is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 initialFeeBps = 250; // 2.5% platform fee

        vm.startBroadcast(deployerPrivateKey);

        IdentityRegistry registry = new IdentityRegistry();
        console.log("IdentityRegistry:", address(registry));

        SubscriptionManager subscriptions = new SubscriptionManager(initialFeeBps);
        console.log("SubscriptionManager:", address(subscriptions));

        console.log("PlatformFeeBps:", initialFeeBps);

        vm.stopBroadcast();
    }
}
