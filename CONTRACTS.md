# AgentX Contracts — Deployment & Reference

> Last updated: 2026-07-21 (full L1 6-contract suite) ｜ 费率说明对齐：2026-10-04

---

## Deployed Contracts

### Sepolia Testnet — All Contracts

| # | Contract | Solc | Address | Source |
|---|----------|------|---------|--------|
| 1 | IdentityRegistry | 0.8.24 | `0xe94ad380d3F8d08a7590eda0C84f354a93F96e5F` | `contracts/legacy/src/IdentityRegistry.sol` |
| 2 | SubscriptionManager v3 | 0.8.24 | `0xC15fE80b9d800abb72121F353a6ae6d6E9077E63` | `contracts/legacy/src/SubscriptionManager.sol` |
| 3 | PaymentGateway | 0.8.20 | `0x59eA58c0089314C0fCc86A4ff646fb6dAE571C96` | `contracts/legacy/src/erc8004-extensions/PaymentGateway.sol` |
| 4 | AgentFactory | 0.8.20 | `0xc93eCc808583dd7700bD85D5a7Ad91D54EDbdE7D` | `contracts/legacy/src/erc8004-extensions/AgentFactory.sol` |
| 5 | ReputationRegistry | 0.8.20 | `0xeb6B410ea71b8d9dA0c96f6A91d35027CE143DC9` | `contracts/legacy/src/erc8004-core/ReputationRegistry.sol` |
| 6 | ConfigurationRegistry | 0.8.20 | `0x68DcE00e4C9077c94BC68016cD14B09557faEA6c` | `contracts/src/erc8004-extensions/ConfigurationRegistry.sol` |
| 7 | MultiEndpointRegistry | 0.8.20 | `0xEB5e866f186d4B73F97aa0d70B86f2C6e2e21Cb7` | `contracts/src/erc8004-extensions/MultiEndpointRegistry.sol` |
| 8 | A2AProtocolRegistry | 0.8.20 | `0xEdb0022c250B38e281B3EF1418037889fC5C6092` | `contracts/src/erc8004-extensions/A2AProtocolRegistry.sol` |

> Sources verified on Sepolia Blockscout. All 8 contracts open-source.
>
> **2026-10-27 归档**：`IdentityRegistry`、`SubscriptionManager`、`PaymentGateway`、`AgentFactory`、`ReputationRegistry` 已从 `contracts/src/` 迁至 `contracts/legacy/`（不再参与新部署，仅保留源码与历史地址记录）；`AgentWallet` / `AgentMigrator` 同步归档。

### OxaChain L1 (19505) — 已下线（2026-10-20）

> OxaChain 已从平台移除，下列地址仅作历史记录，**不再使用**。现行市场链为 BSC / Ethereum / Base，完整地址表见 [`DEPLOYMENT.md §4.2`](../DEPLOYMENT.md)。

| Contract | Version | Address | Owner |
|----------|---------|---------|-------|
| IdentityRegistry | v1 | `0xbf5F9db266c8c97E3334466C88597Eb758AfE212` | `0x8E86...60ba` |
| SubscriptionManager | v3 | `0x019AC9d945467478Dd371CDbD70cb2f325800E6B` | `0x8E86...60ba` |
| ReputationRegistry | v1 | `0x6a18C2664E1b42063860d864b6448b824d7B843F` | `0x8E86...60ba` |
| ConfigurationRegistry | v1 | `0x07280674ccc2898Fd038A9e3C22005CA83ffD2F8` | `0x8E86...60ba` |
| A2AProtocolRegistry | v2 | `0x7F42a7dC4A0F3C107664C3750bE1B5B6fa6BEb86` | `0x8E86...60ba` |
| MultiEndpointRegistry | v1 | `0xB361d04F49000013FC131D3C59C41c8486C64f8c` | `0x8E86...60ba` |

> Deployed 2026-07-21. Full 6-contract suite deployed on L1. A2AProtocolRegistry v2 deployed via forge create from `contracts/src/erc8004-extensions/A2AProtocolRegistry.sol`.

### RPC Endpoints

| Chain | Chain ID | RPC |
|-------|----------|-----|
| BSC（默认） | 56 | `https://bsc-rpc.publicnode.com` |
| Ethereum | 1 | `https://ethereum-rpc.publicnode.com` |
| Base | 8453 | `https://base-rpc.publicnode.com` |
| Sepolia | 11155111 | `https://ethereum-sepolia-rpc.publicnode.com` |

### Deployers

| Chain | Address |
|-------|---------|
| BSC | `0x8017925F7eEcA3713F03983113788321891F7D1f` |
| Ethereum | `0xBDc6E9a23705D6De23e324A6b4a386dDB254F287` |
| Base | `0x978e92477ff613c307e25Bf0ed1D50E9483782C4`（原部署者，**私钥已泄露、已弃用**） |
| Sepolia | `0x4F7744F97AaC9Ad7f0a67de75b149aDb87464103` |

### Owners & 收款地址（2026-11-01 轮换）

> 2026-11-01：Base 部署者 EOA `0x978e…2C4` 私钥确认泄露。三链 **27 个合约**（每链 9 个）的 `owner` 已全部转出，`platformFeeCollector` 与 `SettlementRegistry` 的 writer 同步更换。全部合约均为**非代理**（`ADMIN_SLOT` / `IMPL_SLOT` 为空），权限面只有各合约 `onlyOwner`。
>
> 每链 9 个 = `SubscriptionManager`、`A2AProtocolRegistry`、`TokenPriceOracle`、`ValidationRegistry`、`SettlementRegistry`、`PaymentReputationOracle`、`PaymentReputationOracleV2`、`ConfigurationRegistry`、`MultiEndpointRegistry`。分三轮完成：① 主合约 14 个；② 扩展合约 9 个（V1/V2 oracle + settlement，原属泄露地址）；③ `ConfigurationRegistry` / `MultiEndpointRegistry` 6 个（BSC 属部署者 `0x8017…7D1f`、ETH 属 `0xBDc6…F287`、Base 属泄露地址）。

| 项 | 值 |
|---|---|
| 新 owner（冷钱包） | `0xfab6e886cf64b13991ade48a2e7d6aecd1b7ef0a`（27/27 已复验，2026-11-01） |
| 新 `platformFeeCollector` | `0x1663ed8ebd398aead19fea2ee676fad4bfffbdcb`（三链） |
| 新 settlement writer（热钱包） | `0x76749c66DBc3B6450b587898ba0046bef93b10d2`（三链 `writers=true`；泄露地址 `writers=false` 已撤销） |
| 原 owner（已失效） | `0x978e92477ff613c307e25Bf0ed1D50E9483782C4` |
| 原 collector | `0xA5e36e1D04bA9AE91C17EF01997C89322D5AE6ff`（非泄露，余额已清） |
| 未纳入轮换 | 三链 X402 Escrow 属 `0xff92…464a`，由 **Keel** 侧控制，**不属我方资产**；三链 `IdentityRegistry` / `ReputationRegistry` 指向官方 ERC-8004 canonical 单例（`0x8004A169…` / `0x8004BAa1…`），非自建、无 owner 权限 |
| 轮换脚本 | `script/RotateOwnership.s.sol`（9 个扩展合约目标，幂等）、`script/RotateSettlementWriter.s.sol`（`ACTION=grant\|revoke`）、`script/rotate-owner.sh`（三链封装，`DRY_RUN=1` 预演，前置校验 `owner == signer`） |

---

## SubscriptionManager v3

### Deployment

| Parameter | Value |
|-----------|-------|
| Constructor arg（历史，非现行费率） | `500`（部署时命令记录，见下方「费率说明」） |
| Compiler | solc 0.8.24 |
| EvmVersion | cancun |
| Optimizer | on, 200 runs |
| Tx Hash | `0x3dbf09f83e7064b5f53dc7f279049be5c13ffe69e602de6550887d3718830537` |
| Command | `forge create --legacy --constructor-args 500` |

### 费率说明（平台费率 · 单一来源，2026-11-01 三链清零）

> **现行平台费率 = `0` bps（全链路零抽成）。** 以链上 `defaultPlatformFee()` 读数为**唯一真值**。

| 事项 | 值 | 依据 |
|---|---|---|
| **现行费率** | **0 bps** | 2026-11-01 三链实测：BSC / Ethereum `defaultPlatformFee()` = `0`；Base `defaultPlatformFee()` = `0`，且 3 个存量 plan 的 `platformFeePercentage` 均为 `0` |
| 清零执行 | `script/ZeroPlatformFee.s.sol` | BSC 由轮换前 owner 执行；Ethereum / Base 在 owner 转移后由新 owner `0xfab6…EF0a` 执行 |
| 部署时构造参数（历史） | 本文件下方记录为 `500` | 旧 v3 部署命令 `--constructor-args 500`；部署后曾被改为 `250` |
| 生产链（2026-10-31 实测，已被上方覆盖） | 250 bps | 旧读数，仅作历史对照 |
| 允许范围 | 0–2000 bps（0–20%） | `setPlatformFee` / `setDefaultPlatformFee` 约束 |

- **结论**：对外材料、计费、SDK 一律按 **0 抽成**（按次收款直达 `agents.payout_address`）；`0` 是可变配置，owner 可随时调回。
- 生产链完整地址表（含 BSC/ETH/Base）见 [`DEPLOYMENT.md §4.2`](../DEPLOYMENT.md)。

### V3 Audit Fixes (from v2 at `0x04CACa...`)

| Fix | What |
|-----|------|
| Reentrancy Guard | Added OpenZeppelin `ReentrancyGuard`, `nonReentrant` on subscribe/cancel/release/withdraw |
| State-before-call | subscribe(): ETH refund + ERC20 transferFrom moved AFTER all state writes |
| State-before-call | cancelSubscription(): status/trial/fundsReleased written BEFORE external refund |
| Creator Fund Lock | subscribe(): old subscription escrow released before overwrite |
| Precision Loss | Confirmed correct: `(amount * bps) / 10000` |
| Selfdestruct | Confirmed absent (false positive) |

### V3 New Features (from v2)

（同 v2）ETH + ERC20 多币种 / 试用托管 / 退款 / 平台费抽成 / releaseFunds

| Parameter | Value |
|-----------|-------|
| Constructor arg（历史，非现行费率） | `500`（部署时命令记录，见下方「费率说明」） |
| Compiler | solc 0.8.24 |
| EvmVersion | cancun |
| Optimizer | on, 200 runs |
| Tx Hash | `0x31b4224758f65789a8dd953759294cf974ead3ca49f26a59bebcbc95172ca90f` |
| Gas Used | ~2,260,000 |
| Command | `forge create --legacy --constructor-args 500` |

### V2 New Features (vs v1 at `0x62AB37...`)

| Feature | Method | Description |
|---------|--------|-------------|
| Platform Fee | `platformFeeBps()` / `setPlatformFee(bps)` | 0-2000 bps (0-20%), deducted from each payment |
| Fee Withdrawal | `withdrawPlatformFees(token, to)` | Owner withdraws collected fees |
| Multi-Currency | `payToken` in `createPlan` | `address(0)` = ETH, else ERC20 |
| Token Whitelist | `setTokenWhitelist(token, allowed)` / `tokenWhitelist(token)` | Gate which ERC20 tokens can be used |
| Trial Escrow | `trialDays` in `createPlan` | Funds held in contract during trial |
| Fund Release | `releaseFunds(subscriptionId)` | Creator releases escrowed funds after trial |
| Trial Refund | automatic on `cancelSubscription` during trial | 100% refund (including platform fee) |
| Detailed Query | `getSubscriptionDetail(subscriptionId)` | 12 fields including trial/escrow/payToken |

### State Machine

```
subscribe(planId)
  │
  ├─ trialDays > 0
  │   ├─ funds escrowed
  │   ├─ trialActive = true
  │   └─ cancel during trial → 100% refund (TrialRefunded event)
  │
  ├─ releaseFunds(subscriptionId) — only by subscriber
  │   ├─ trialActive → false
  │   ├─ fundsReleased → true
  │   ├─ platform fee deducted → platformFeesCollected
  │   └─ remainder → creator (FundsReleased event)
  │
  └─ expires → SubscriptionExpired event
```

### Full ABI

```solidity
// ── Read ──
function platformFeeBps() external view returns (uint256);
function tokenWhitelist(address token) external view returns (bool);
function getPlan(uint256 planId) external view returns (SubscriptionPlan memory);
function hasActiveSubscription(address subscriber, uint256 agentId) external view returns (bool);
function getSubscription(address subscriber, uint256 agentId) external view returns (...);
function getSubscriptionDetail(uint256 subscriptionId) external view returns (Subscription memory);
function getUserSubscriptions(address user) external view returns (uint256[] memory);

// ── Write ──
function createPlan(uint256 agentId, uint256 price, string period, address payToken, uint256 trialDays) external returns (uint256);
function subscribe(uint256 planId) external payable returns (uint256);
function releaseFunds(uint256 subscriptionId) external;
function cancelSubscription(uint256 subscriptionId) external;

// ── Admin ──
function setPlatformFee(uint256 _bps) external onlyOwner;
function setTokenWhitelist(address token, bool allowed) external onlyOwner;
function withdrawPlatformFees(address token, address to) external onlyOwner;

// ── Events ──
event PlanCreated(uint256 indexed planId, uint256 indexed agentId, uint256 price, string period, address payToken, uint256 trialDays);
event Subscribed(uint256 indexed subscriptionId, address indexed subscriber, uint256 indexed agentId, uint256 expiresAt);
event SubscriptionCancelled(uint256 indexed subscriptionId);
event SubscriptionExpired(uint256 indexed subscriptionId);
event TrialRefunded(uint256 indexed subscriptionId, address indexed subscriber, uint256 amount, address payToken);
event FundsReleased(uint256 indexed subscriptionId, address indexed creator, uint256 amount, address payToken);
event PlatformFeeUpdated(uint256 indexed agentId, uint256 oldFee, uint256 newFee, address indexed updatedBy, uint256 timestamp);
event TokenWhitelistUpdated(address indexed token, bool allowed);
event PlatformFeeCollected(address indexed token, uint256 amount);
```

### Structs

```solidity
struct Subscription {
    uint256 subscriptionId;
    address subscriber;
    uint256 agentId;
    SubscriptionStatus status;  // 0=Inactive, 1=Active, 2=Expired, 3=Cancelled
    uint256 startedAt;
    uint256 expiresAt;
    string period;              // "day" | "week" | "month" | "quarter" | "year"
    address payToken;           // address(0) = ETH
    uint256 amountPaid;
    bool trialActive;
    uint256 trialEndsAt;
    bool fundsReleased;
}

struct SubscriptionPlan {
    uint256 planId;
    uint256 agentId;
    address creator;
    uint256 price;
    string period;
    bool active;
    address payToken;
    uint256 trialDays;          // 0 = no trial
}
```

---

## IdentityRegistry v1

### Deployment

| Parameter | Value |
|-----------|-------|
| Tx Hash | `0x2907e643479c78066c8024a956e6f9b26d3c846d07d42e60f7f0003e74c0f82b` |
| Gas Used | ~925,000 |

### ABI

```solidity
function isRegistered(uint256 agentId) external view returns (bool);
function getAgent(uint256 agentId) external view returns (address owner, string metaUri, bytes data, bool active, bool locked, uint256 createdAt);
function getAgentsByOwner(address owner) external view returns (uint256[] memory);
```

---

## How to Deploy (Contract Upgrade)

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Set env vars
export SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
export PRIVATE_KEY="<deployer-private-key>"
```

### Build & Test

```bash
cd agentx/contracts
forge build
forge test -vvv
```

### Deploy

```bash
# SubscriptionManager
forge create \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --broadcast \
  legacy/src/SubscriptionManager.sol:SubscriptionManager \
  --constructor-args <initialFeeBps>

# IdentityRegistry (no constructor args)
forge create \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --broadcast \
  legacy/src/IdentityRegistry.sol:IdentityRegistry
```

### Verify (Optional)

```bash
forge verify-contract \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  <address> \
  legacy/src/SubscriptionManager.sol:SubscriptionManager
```

### Post-Deploy Checklist

1. Update contract address in `agentx/sdk/src/config/config.ts`
2. Update `agentx/frontend/.env.production` (`NEXT_PUBLIC_SUBSCRIPTION_MANAGER_ADDRESS`)
3. Update `agentx/frontend/src/vendor/agentx-sdk/config.ts`
4. Update this file (`agentx/contracts/CONTRACTS.md`)
5. Rebuild SDK dist: `cd agentx/sdk && npx tsc`
6. Push all changes to GitHub
7. Deploy frontend build to test server

---

## Version History

| Date | Contract | Version | Address | Changes |
|------|----------|---------|---------|---------|
| 2026-07-13 | IdentityRegistry | v1 | `0xe94ad3...` | Initial deployment |
| 2026-07-13 | SubscriptionManager | v1 | `0x62AB37...` | Initial: subscribe, cancel, verify |
| 2026-07-13 | SubscriptionManager | v2 | `0x04CACa...` | +platform fee, +ERC20, +trial escrow, +releaseFunds |
| 2026-07-13 | SubscriptionManager | v3 | `0xC15fE8...` | Audit fixes: reentrancy guard, state-before-call, fund lock |
