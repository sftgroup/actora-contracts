// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {A2AProtocolRegistry} from "../src/erc8004-extensions/A2AProtocolRegistry.sol";

/**
 * @title DeployA2A
 * @notice Deploy A2AProtocolRegistry (with getUserTasks fix) to a given chain.
 *         Constructor arg: IdentityRegistry address
 *
 *         Sepolia:
 *           forge script script/DeployA2A.s.sol:DeployA2A \
 *             --rpc-url $SEPOLIA_RPC \
 *             --broadcast --verify \
 *             --constructor-args 0x000000000000000000000000e94ad380d3F8d08a7590eda0C84f354a93F96e5F
 */
contract DeployA2A is Script {
    function run() external {
        address ir = vm.envAddress("IDENTITY_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        A2AProtocolRegistry a2a = new A2AProtocolRegistry(ir);
        console.log("A2AProtocolRegistry deployed at:", address(a2a));

        vm.stopBroadcast();
    }
}
