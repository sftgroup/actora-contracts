// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PaymentReputationOracle} from "../src/erc8004-extensions/PaymentReputationOracle.sol";
import {SettlementRegistry, SettlementRegistryVerifier} from "../src/erc8004-extensions/SettlementRegistry.sol";
import {Erc8183Verifier} from "../src/erc8004-extensions/Erc8183Verifier.sol";

/**
 * @title DeployPaymentReputationOracle
 * @notice WS9（B2 支付可信闭环）一键部署：权重 Oracle + 两条结算核验通道。
 *
 *         部署顺序（依赖感知）：
 *           1. PaymentReputationOracle   — 权重参数 immutable（发布即冻结）
 *           2. SettlementRegistry        — Option A 兜底（非 BSC rail / 其他链）
 *           3. SettlementRegistryVerifier— 读 2) 的 ISettlementVerifier
 *           4. Erc8183Verifier           — Option C 主路径（仅当配置了 ERC8183_COMMERCE）
 *           5. 接线：setSettlementVerifier / setReputationRegistry / setWriter
 *
 *         环境变量：
 *           PRIVATE_KEY                    部署私钥（必填）
 *           WEIGHT_AMOUNT_CAP              单笔计入上限（原子单位，默认 100e18）
 *           WEIGHT_MAX_AGE                 时间衰减窗口秒数（默认 180 days）
 *           WEIGHT_PAYER_CAP               同一 payer 免罚笔数（默认 3）
 *           VERIFIER_MODE                  'erc8183'（默认）| 'registry'
 *           ERC8183_COMMERCE               BSC 官方 ERC-8183/APEX AgenticCommerce 地址（mode=erc8183 必填）
 *           IDENTITY_REGISTRY              ERC-8004 identity（Erc8183Verifier 校验 provider 归属，必填）
 *           REPUTATION_REGISTRY            可选；设置后接线 mirrorToRegistry
 *           SETTLEMENT_WRITER              可选；授权该地址写 SettlementRegistry（网关中继）
 *           ORACLE_OWNER                   可选；默认 deployer，部署后移交 owner
 *
 *         用法（BSC 主网）：
 *           PRIVATE_KEY=<pk> \
 *           ERC8183_COMMERCE=0x... IDENTITY_REGISTRY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432 \
 *           REPUTATION_REGISTRY=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63 \
 *           forge script script/DeployPaymentReputationOracle.s.sol:DeployPaymentReputationOracle \
 *             --rpc-url https://bsc-dataseed.binance.org --broadcast --verify --chain 56
 *
 *         非 BSC 链（无 ERC-8183）：
 *           VERIFIER_MODE=registry ... --chain 1
 */
contract DeployPaymentReputationOracle is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 amountCap = vm.envOr("WEIGHT_AMOUNT_CAP", uint256(100 ether));
        uint256 maxAge = vm.envOr("WEIGHT_MAX_AGE", uint256(180 days));
        uint256 payerCap = vm.envOr("WEIGHT_PAYER_CAP", uint256(3));
        string memory mode = vm.envOr("VERIFIER_MODE", string("erc8183"));
        address commerce = vm.envOr("ERC8183_COMMERCE", address(0));
        address identity = vm.envAddress("IDENTITY_REGISTRY");
        address reputation = vm.envOr("REPUTATION_REGISTRY", address(0));
        address writer = vm.envOr("SETTLEMENT_WRITER", address(0));
        address owner = vm.envOr("ORACLE_OWNER", deployer);

        require(identity != address(0), "IDENTITY_REGISTRY required");
        bool useErc8183 = keccak256(bytes(mode)) == keccak256(bytes("erc8183"));
        if (useErc8183) require(commerce != address(0), "ERC8183_COMMERCE required for erc8183 mode");

        vm.startBroadcast(pk);

        // 1) 权重 Oracle（参数 immutable）
        PaymentReputationOracle oracle = new PaymentReputationOracle(amountCap, maxAge, payerCap);
        console.log("===== PaymentReputationOracle =====");
        console.log("  Address:", address(oracle));
        console.log("  amountCap:", amountCap);
        console.log("  maxAge:", maxAge);
        console.log("  payerCap:", payerCap);

        // 2) Option A：链上结算承诺注册表
        SettlementRegistry registry = new SettlementRegistry();
        console.log("===== SettlementRegistry (Option A) =====");
        console.log("  Address:", address(registry));

        // 3) Option A 核验器
        SettlementRegistryVerifier registryVerifier = new SettlementRegistryVerifier(address(registry));
        console.log("===== SettlementRegistryVerifier =====");
        console.log("  Address:", address(registryVerifier));

        // 4/5) 选择主核验通道并接线
        address verifier = address(registryVerifier);
        if (useErc8183) {
            Erc8183Verifier erc8183Verifier = new Erc8183Verifier(commerce, identity);
            verifier = address(erc8183Verifier);
            console.log("===== Erc8183Verifier (Option C) =====");
            console.log("  Address:", verifier);
            console.log("  commerce:", commerce);
        } else {
            console.log("===== Verifier mode: registry (Option A) =====");
        }

        oracle.setSettlementVerifier(verifier);
        console.log("  Oracle.settlementVerifier =", verifier);

        if (reputation != address(0)) {
            oracle.setReputationRegistry(reputation);
            console.log("  Oracle.reputationRegistry =", reputation);
        }

        if (writer != address(0)) {
            registry.setWriter(writer, true);
            console.log("  SettlementRegistry.writer =", writer);
        }

        if (owner != deployer) {
            oracle.transferOwnership(owner);
            registry.transferOwnership(owner);
            console.log("  Ownership transferred to:", owner);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("Write back to gateway .env:");
        console.log("  PAYMENT_REPUTATION_ORACLE_ADDRESS=", address(oracle));
        console.log("  SETTLEMENT_REGISTRY_ADDRESS=", address(registry));
    }
}
