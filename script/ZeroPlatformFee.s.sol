// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * @title ZeroPlatformFee
 * @notice 把平台协议费清零，含存量 plan。
 *
 *         SubscriptionManager 的费率有两个来源，必须分别处理：
 *           1. `defaultPlatformFee` —— 只在 createPlan 时快照进新 plan，
 *              改它**不影响**已有 plan，但会让之后新建的 plan 为 0；
 *           2. 每个 plan 自己的 `platformFeePercentage` —— 存量的 250 bps
 *              冻结在这里，只能逐 agent 调 `setAgentPlatformFee` 覆盖。
 *
 *         所以清零是两步：
 *           a. setDefaultPlatformFee(0)               → 新 plan 为 0
 *           b. setAgentPlatformFee(agentId, 0) × N    → 存量 plan 为 0
 *
 *         b 的 agent 集合从链上反查：planId 从 1 连续自增（`_planCounter`
 *         先自增后赋值），遍历 1..getTotalPlanCount() 读每个 plan 的 agentId
 *         并去重。只对**真有 plan** 的 agent 发交易，跳过空 agent。
 *         已经是 0 的 agent 会被跳过，因此**可重复执行、重跑几乎不花 gas**。
 *
 *         合约的 setAgentPlatformFee 会遍历该 agent 名下每个 plan 逐个改，
 *         并对每个 plan 发一次 PlatformFeeUpdated(5 参数) 事件；网关索引器
 *         监听该事件回写 subscription_plans.platform_fee_bps，前端随之显示 0。
 *
 *         用法（每链独立执行）：
 *           PRIVATE_KEY=<owner pk> \
 *           SUBSCRIPTION_MANAGER=<addr> \
 *           forge script script/ZeroPlatformFee.s.sol:ZeroPlatformFee \
 *             --rpc-url <RPC> --broadcast --chain <ID>
 *
 *         可选 env：
 *           DRY_RUN=true   只读扫描，不广播（先确认影响面）
 *           MAX_AGENTS=200 单次最多处理多少个 agent；超出部分重跑脚本继续
 */
interface ISubscriptionManager {
    struct SubscriptionPlan {
        uint256 planId;
        uint256 agentId;
        string name;
        string description;
        uint8 planType;
        address token;
        uint256 subscriptionPrice;
        uint256 usagePrice;
        uint8 billingPeriod;
        uint256 maxUsage;
        uint256 totalUsageLimit;
        bool isActive;
        uint256 createdAt;
        uint256 platformFeePercentage;
    }

    function getPlan(uint256 planId) external view returns (SubscriptionPlan memory);
    function getTotalPlanCount() external view returns (uint256);
    function defaultPlatformFee() external view returns (uint256);
    function platformFeeCollector() external view returns (address);
    function owner() external view returns (address);
    function setDefaultPlatformFee(uint256 newFee) external;
    function setAgentPlatformFee(uint256 agentId, uint256 feePercentage) external;
}

contract ZeroPlatformFee is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("SUBSCRIPTION_MANAGER");
        bool dryRun = vm.envOr("DRY_RUN", false);
        uint256 maxAgents = vm.envOr("MAX_AGENTS", uint256(200));

        require(managerAddr.code.length > 0, "SUBSCRIPTION_MANAGER has no code");
        ISubscriptionManager mgr = ISubscriptionManager(managerAddr);

        // owner 校验前置，避免扫完才发现在发无效交易
        address owner = mgr.owner();
        require(owner == vm.addr(pk), "PRIVATE_KEY is not the SubscriptionManager owner");

        uint256 planCount = mgr.getTotalPlanCount();
        console.log("");
        console.log("==============================================");
        console.log("  ZeroPlatformFee - Scan");
        console.log("==============================================");
        console.log("  SubscriptionManager:", managerAddr);
        console.log("  owner:              ", owner);
        console.log("  plan count:         ", planCount);
        console.log("  default fee (before):", mgr.defaultPlatformFee());
        console.log("  feeCollector (kept, amount stays 0):", mgr.platformFeeCollector());

        // ── 反查"有 plan 的 agent"并标记是否需要清零 ────────────────────
        // O(n^2) 去重：适用于脚本规模（当前 plan 数为几十到几百）。
        uint256[] memory agents = new uint256[](planCount);
        bool[] memory needsZero = new bool[](planCount);
        uint256 n = 0;

        for (uint256 planId = 1; planId <= planCount; planId++) {
            ISubscriptionManager.SubscriptionPlan memory p = mgr.getPlan(planId);
            uint256 found = type(uint256).max;
            for (uint256 i = 0; i < n; i++) {
                if (agents[i] == p.agentId) {
                    found = i;
                    break;
                }
            }
            if (found == type(uint256).max) {
                agents[n] = p.agentId;
                needsZero[n] = (p.platformFeePercentage != 0);
                n++;
            } else if (p.platformFeePercentage != 0) {
                needsZero[found] = true;
            }
        }

        uint256 pending = 0;
        for (uint256 i = 0; i < n; i++) {
            if (needsZero[i]) pending++;
        }
        console.log("  agents with plans:  ", n);
        console.log("  agents needing zero:", pending);

        if (dryRun) {
            console.log("");
            console.log("  DRY_RUN=true - nothing broadcast. Rerun without DRY_RUN to apply.");
            console.log("==============================================");
            return;
        }

        // ── 广播 ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);

        if (mgr.defaultPlatformFee() != 0) {
            mgr.setDefaultPlatformFee(0);
            console.log("  defaultPlatformFee -> 0");
        }

        uint256 processed = 0;
        for (uint256 i = 0; i < n && processed < maxAgents; i++) {
            if (!needsZero[i]) continue;
            mgr.setAgentPlatformFee(agents[i], 0);
            processed++;
            console.log("  zeroed agent:", agents[i]);
        }

        vm.stopBroadcast();

        // ── 事后校验 ────────────────────────────────────────────────────
        console.log("");
        console.log("  agents processed:", processed);
        console.log("  default fee (after):", mgr.defaultPlatformFee());
        if (processed < pending) {
            console.log("  REMAINING:          ", pending - processed);
            console.log("  rerun this script to continue (MAX_AGENTS per run).");
        }
        console.log("==============================================");
    }
}
