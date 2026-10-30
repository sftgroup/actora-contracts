// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/IdentityRegistry.sol";
import "../src/SubscriptionManager.sol";

/**
 * @title DeployAgentX v2
 * @notice Deploy IdentityRegistry + SubscriptionManager (v2 with platform fee).
 *         Usage: forge script script/Deploy.s.sol:DeployAgentX --rpc-url sepolia --broadcast --verify
 */
contract DeployAgentX is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 initialFeeBps = vm.envOr("INITIAL_PLATFORM_FEE_BPS", uint256(250)); // default 2.5%

        vm.startBroadcast(deployerPrivateKey);

        IdentityRegistry registry = new IdentityRegistry();
        console.log("IdentityRegistry deployed at:", address(registry));

        SubscriptionManager subscriptions = new SubscriptionManager(initialFeeBps);
        console.log("SubscriptionManager deployed at:", address(subscriptions));

        // Log platform fee config
        console.log("Platform fee (bps): %d", initialFeeBps);
        console.log("  = %d.%d%%", initialFeeBps * 100 / 10000, initialFeeBps * 100 % 10000 / 100);

        vm.stopBroadcast();

        console.log("---");
        console.log("Add these to .env:");
        console.log("NEXT_PUBLIC_IDENTITY_REGISTRY_ADDRESS=", address(registry));
        console.log("NEXT_PUBLIC_SUBSCRIPTION_MANAGER_ADDRESS=", address(subscriptions));
    }
}
