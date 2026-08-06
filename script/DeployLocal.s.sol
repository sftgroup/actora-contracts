// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {SubscriptionManager} from "../src/SubscriptionManager.sol";
import {MockUSDC} from "../src/mock/MockUSDC.sol";

/// @title DeployLocal
/// @notice Deploy a standalone IdentityRegistry + SubscriptionManager on a
///         local dev chain (anvil), create one plan for agent #1, and deploy a
///         MockUSDC (6-decimal stablecoin) minted to the deployer, so all the
///         payment rails (chain / fiat / x402 / stablecoin / MPP / period /
///         a2a) can be exercised end-to-end locally without a real network.
///
///         Usage:
///           forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///             --broadcast --legacy
///         Env:
///           PRIVATE_KEY      deployer private key (anvil account #0 by default)
///           PLAN_PRICE_WEI   plan price in wei (default 1000000000000000000 = 1 native)
///           PLAN_PERIOD      day | week | month | year (default "month")
///           USDC_MINT_AMOUNT mock USDC atomic units minted to the deployer
///                            (default 1000000 * 1e6 = 1M mUSDC)
contract DeployLocal is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 planPriceWei = vm.envOr("PLAN_PRICE_WEI", uint256(1e18));
        string memory planPeriod = vm.envOr("PLAN_PERIOD", string("month"));
        uint256 usdcMintAmount = vm.envOr("USDC_MINT_AMOUNT", uint256(1_000_000 * 1e6));

        vm.startBroadcast(deployerPrivateKey);

        IdentityRegistry ir = new IdentityRegistry();
        console.log("IdentityRegistry:", address(ir));

        SubscriptionManager sm = new SubscriptionManager(250); // 2.5% platform fee
        console.log("SubscriptionManager:", address(sm));

        sm.createPlan(1, planPriceWei, planPeriod, address(0), 0);
        console.log("Plan #1 created for agent #1");
        console.log("  price =", planPriceWei, "wei");
        console.log("  period =", planPeriod);

        MockUSDC usdc = new MockUSDC("Mock USD Coin");
        // `msg.sender` inside a forge script is the *script contract* address,
        // not the broadcaster — mint to the deployer EOA instead.
        address deployer = vm.addr(deployerPrivateKey);
        usdc.mint(deployer, usdcMintAmount);
        console.log("MockUSDC:", address(usdc));
        console.log("  minted", usdcMintAmount, "to", deployer);

        vm.stopBroadcast();

        console.log("Deployer:", deployer);
    }
}
