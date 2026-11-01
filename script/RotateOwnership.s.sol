// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * @title RotateOwnership
 * @notice 把一条链上「由泄露 EOA 持有的合约」的 owner 一次性转给冷钱包，
 *         并在交权前把平台收款地址改到新的收费冷钱包。
 *
 *         背景：`0x978e92477ff613c307e25Bf0ed1D50E9483782C4` 私钥已泄露，
 *         它是三链上 SubscriptionManager / A2A / Validation / Oracle /
 *         Configuration / MultiEndpoint 的 owner（全部非代理，无 ProxyAdmin）。
 *         唯一止血路径就是用该私钥自己发 `transferOwnership`。
 *
 *         执行顺序（脚本内固定）：
 *           1. SubscriptionManager.setPlatformFeeCollector(NEW_COLLECTOR)
 *              —— 交权前改，避免冷钱包多跑一笔；
 *           2. 逐个 target 调 `transferOwnership(NEW_OWNER)`；
 *           3. SubscriptionManager 最后转（它是费率/收款的总闸）。
 *
 *         费率清零不在本脚本里（见 `ZeroPlatformFee.s.sol`），
 *         必须在交权前用同一把私钥跑完，否则之后要用冷钱包私钥重跑。
 *
 *         用法（每链独立执行，env 里只填本链地址）：
 *           PRIVATE_KEY=<泄露 EOA 私钥> \
 *           NEW_OWNER=0xfab6e886cf64b13991ade48a2e7d6aecd1b7ef0a \
 *           NEW_COLLECTOR=0x1663ed8ebd398aead19fea2ee676fad4bfffbdcb \
 *           SUBSCRIPTION_MANAGER=<addr> \
 *           A2A_PROTOCOL=<addr> \
 *           VALIDATION_REGISTRY=<addr> \
 *           [CONFIGURATION_REGISTRY=<addr>] [MULTI_ENDPOINT=<addr>] \
 *           [PAYMENT_REPUTATION_ORACLE=<addr>] \
 *           [PAYMENT_REPUTATION_ORACLE_V2=<addr>] \
 *           [SETTLEMENT_REGISTRY=<addr>] \
 *           forge script script/RotateOwnership.s.sol:RotateOwnership \
 *             --rpc-url <RPC> --broadcast --chain <ID>
 *
 *         可选 env：
 *           DRY_RUN=true   只做前置校验并打印计划，不广播
 *
 *         幂等：已经是 NEW_OWNER 的合约会跳过，因此可安全重跑。
 */
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface ISubscriptionManagerAdmin is IOwnable {
    function priceOracle() external view returns (address);
    function platformFeeCollector() external view returns (address);
    function setPlatformFeeCollector(address collector) external;
}

contract RotateOwnership is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address newOwner = vm.envAddress("NEW_OWNER");
        address newCollector = vm.envOr("NEW_COLLECTOR", address(0));
        address smAddr = vm.envAddress("SUBSCRIPTION_MANAGER");
        address a2a = vm.envAddress("A2A_PROTOCOL");
        address validation = vm.envAddress("VALIDATION_REGISTRY");
        address configuration = vm.envOr("CONFIGURATION_REGISTRY", address(0));
        address multiEndpoint = vm.envOr("MULTI_ENDPOINT", address(0));
        address paymentOracle = vm.envOr("PAYMENT_REPUTATION_ORACLE", address(0));
        address paymentOracleV2 = vm.envOr("PAYMENT_REPUTATION_ORACLE_V2", address(0));
        address settlementRegistry = vm.envOr("SETTLEMENT_REGISTRY", address(0));
        bool dryRun = vm.envOr("DRY_RUN", false);

        require(newOwner != address(0), "NEW_OWNER is zero");
        require(newOwner != signer, "NEW_OWNER must differ from current owner");
        require(smAddr.code.length > 0, "SUBSCRIPTION_MANAGER has no code");
        require(a2a.code.length > 0, "A2A_PROTOCOL has no code");
        require(validation.code.length > 0, "VALIDATION_REGISTRY has no code");

        ISubscriptionManagerAdmin sm = ISubscriptionManagerAdmin(smAddr);
        // 补跑批次：SM 可能已在第一批交给 NEW_OWNER，此时签名者不再持有它，
        // 但本批只转 PRO / Settlement 等漏掉的合约，仍应允许继续。
        require(
            sm.owner() == signer || sm.owner() == newOwner,
            "PRIVATE_KEY cannot control the SubscriptionManager"
        );

        // ── 组装目标清单：Oracle 从 SM 读，SM 放最后 ──────────────────────
        address[9] memory targets;
        uint256 n = 0;
        targets[n++] = sm.priceOracle();
        targets[n++] = a2a;
        targets[n++] = validation;
        if (configuration != address(0)) targets[n++] = configuration;
        if (multiEndpoint != address(0)) targets[n++] = multiEndpoint;
        if (paymentOracle != address(0)) targets[n++] = paymentOracle;
        if (paymentOracleV2 != address(0)) targets[n++] = paymentOracleV2;
        if (settlementRegistry != address(0)) targets[n++] = settlementRegistry;
        targets[n++] = smAddr;

        console.log("");
        console.log("==============================================");
        console.log("  RotateOwnership - Plan");
        console.log("==============================================");
        console.log("  signer (current owner):", signer);
        console.log("  NEW_OWNER:             ", newOwner);
        console.log("  NEW_COLLECTOR:         ", newCollector);
        console.log("  collector (before):    ", sm.platformFeeCollector());
        console.log("  targets:               ", n);

        // ── 前置校验 + 计划打印 ──────────────────────────────────────────
        uint256 pending = 0;
        for (uint256 i = 0; i < n; i++) {
            address t = targets[i];
            require(t != address(0), "target is zero");
            require(t.code.length > 0, "target has no code");

            address current = IOwnable(t).owner();
            if (current == newOwner) {
                console.log("  [skip] already rotated:", t);
                continue;
            }
            require(current == signer, "target is owned by someone else");
            console.log("  [tx] transferOwnership:", t);
            pending++;
        }

        bool collectorPending =
            newCollector != address(0) && sm.platformFeeCollector() != newCollector;
        if (collectorPending) {
            console.log("  [tx] setPlatformFeeCollector:", newCollector);
        }

        if (dryRun) {
            console.log("");
            console.log("  DRY_RUN=true - nothing broadcast.");
            console.log("  pending transfers:", pending);
            console.log("==============================================");
            return;
        }

        // ── 广播 ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);

        if (collectorPending) {
            sm.setPlatformFeeCollector(newCollector);
        }
        for (uint256 i = 0; i < n; i++) {
            if (IOwnable(targets[i]).owner() != signer) continue;
            IOwnable(targets[i]).transferOwnership(newOwner);
        }

        vm.stopBroadcast();

        // ── 事后校验 ────────────────────────────────────────────────────
        console.log("");
        console.log("  --- verify ---");
        for (uint256 i = 0; i < n; i++) {
            address current = IOwnable(targets[i]).owner();
            require(current == newOwner, "ownership not transferred");
            console.log("  owner = newOwner:", targets[i]);
        }
        if (newCollector != address(0)) {
            require(sm.platformFeeCollector() == newCollector, "collector not updated");
        }
        console.log("  collector (after):", sm.platformFeeCollector());
        console.log("==============================================");
    }
}
