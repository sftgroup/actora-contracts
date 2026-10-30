// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {SettlementRegistry} from "../src/erc8004-extensions/SettlementRegistry.sol";

/**
 * @title DeploySettlementRegistry
 * @notice 只部署 SettlementRegistry（WS9 链上结算承诺，普通 Ownable，非代理）。
 *
 *         用途：x402 / A2A 等非 ERC-8183 轨道的结算证明兜底 —— 平台中继把每笔结算
 *         以 `settlementRef = keccak256(reference)` 写入，`SettlementRegistryVerifier`
 *         供 PaymentReputationOracle 与付款方的 SettlementProof 逐字段核对。
 *         BSC 的 ERC-8183 轨道走直读（Option C），不依赖本合约；BSC 的 x402 / A2A 轨道才需要。
 *
 *         部署本身不改变运行时行为：网关的 `SETTLEMENT_COMMIT_ENABLED` 保持 false 时，
 *         不会有任何链上写入。
 *
 *         用法（每链独立执行）：
 *
 *           # 1) 模拟（不花钱）
 *           DEPLOYER=0x978e92477ff613c307e25bf0ed1d50e9483782c4 \
 *           forge script script/DeploySettlementRegistry.s.sol:DeploySettlementRegistry \
 *             --rpc-url https://bsc-rpc.publicnode.com
 *
 *           # 2) 广播（可选同时授权 writer）
 *           PRIVATE_KEY=<pk> SETTLEMENT_WRITER=<writer> \
 *           forge script script/DeploySettlementRegistry.s.sol:DeploySettlementRegistry \
 *             --rpc-url https://bsc-rpc.publicnode.com --broadcast --chain 56
 *
 *         可选 env：
 *           DEPLOYER            dry-run 时的模拟发送者（PRIVATE_KEY 缺省时使用）
 *           SETTLEMENT_WRITER   指定则部署后立即 setWriter(writer, true)
 *
 *         部署后回填：gateway/.env 的 `SETTLEMENT_REGISTRY_<CHAIN>`。
 */
contract DeploySettlementRegistry is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : vm.envAddress("DEPLOYER");
        address writer = vm.envOr("SETTLEMENT_WRITER", address(0));

        // 有私钥走签名广播；无则用地址做纯模拟（此时不能带 --broadcast）。
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast(deployer);
        }

        SettlementRegistry registry = new SettlementRegistry();

        if (writer != address(0)) {
            registry.setWriter(writer, true);
        }

        vm.stopBroadcast();

        // ── 部署即校验 ────────────────────────────────────────────────
        require(registry.owner() == deployer, "settlement: owner");
        if (writer != address(0)) {
            require(registry.writers(writer), "settlement: writer");
        }

        console.log("");
        console.log("==============================================");
        console.log("  SettlementRegistry - Deployment Summary");
        console.log("  ChainId:", block.chainid);
        console.log("  Block:", block.number);
        console.log("==============================================");
        console.log("  SettlementRegistry:", address(registry));
        console.log("  Owner:             ", registry.owner());
        if (writer != address(0)) {
            console.log("  Writer authorized: ", writer);
        } else {
            console.log("  Writer authorized:  none (set SETTLEMENT_WRITER or call setWriter later)");
        }
        console.log("==============================================");
        console.log("  Env: SETTLEMENT_REGISTRY_<CHAIN> =", address(registry));
        console.log("==============================================");
    }
}
