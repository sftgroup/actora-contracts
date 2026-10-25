// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PaymentReputationOracleV2} from "../src/erc8004-extensions/PaymentReputationOracleV2.sol";

/**
 * @title DeployPaymentReputationOracleV2
 * @notice 只部署 V2 Oracle 并接线（复用已有的 SettlementRegistry / Verifier / canonical Registry）。
 *
 *         环境变量：
 *           PRIVATE_KEY              部署私钥（必填）
 *           SETTLEMENT_VERIFIER      已部署的核验器地址（必填）
 *           SUBSCRIPTION_MANAGER     该链 SubscriptionManager 地址（必填）
 *           WEIGHT_AMOUNT_CAP        单笔计入上限（原子单位，默认 100e18）
 *           WEIGHT_MAX_AGE           时间衰减窗口秒数（默认 180 days）
 *           WEIGHT_PAYER_CAP         同一 payer 免罚笔数（默认 3）
 *           REPUTATION_REGISTRY      可选；canonical ReputationRegistry
 *           ORACLE_OWNER             可选；默认 deployer
 */
contract DeployPaymentReputationOracleV2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 amountCap = vm.envOr("WEIGHT_AMOUNT_CAP", uint256(100 ether));
        uint256 maxAge = vm.envOr("WEIGHT_MAX_AGE", uint256(180 days));
        uint256 payerCap = vm.envOr("WEIGHT_PAYER_CAP", uint256(3));
        address verifier = vm.envAddress("SETTLEMENT_VERIFIER");
        address manager = vm.envAddress("SUBSCRIPTION_MANAGER");
        address reputation = vm.envOr("REPUTATION_REGISTRY", address(0));
        address owner = vm.envOr("ORACLE_OWNER", deployer);

        require(verifier != address(0), "SETTLEMENT_VERIFIER required");
        require(manager != address(0), "SUBSCRIPTION_MANAGER required");

        vm.startBroadcast(pk);

        PaymentReputationOracleV2 oracle =
            new PaymentReputationOracleV2(amountCap, maxAge, payerCap, manager);

        oracle.setSettlementVerifier(verifier);
        if (reputation != address(0)) oracle.setReputationRegistry(reputation);
        if (owner != deployer) oracle.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("===== PaymentReputationOracleV2 =====");
        console.log("  Address:", address(oracle));
        console.log("  amountCap:", amountCap);
        console.log("  maxAge:", maxAge);
        console.log("  payerCap:", payerCap);
        console.log("  verifier:", verifier);
        console.log("  subscriptionManager:", manager);
        console.log("  reputationRegistry:", reputation);
        console.log("  owner:", owner);

        console.log("");
        console.log("Write back to gateway .env:");
        console.log("  PAYMENT_REPUTATION_ORACLE_V2=", address(oracle));
    }
}
