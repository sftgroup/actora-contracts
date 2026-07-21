# AgentX Contracts — Deployment & Reference

> Last updated: 2026-07-21 (full L1 6-contract suite)

---

## Deployed Contracts

### Sepolia Testnet — All Contracts

| # | Contract | Solc | Address | Source |
|---|----------|------|---------|--------|
| 1 | IdentityRegistry | 0.8.24 | `0xe94ad380d3F8d08a7590eda0C84f354a93F96e5F` | `contracts/src/IdentityRegistry.sol` |
| 2 | SubscriptionManager v3 | 0.8.24 | `0xC15fE80b9d800abb72121F353a6ae6d6E9077E63` | `contracts/src/SubscriptionManager.sol` |
| 3 | PaymentGateway | 0.8.20 | `0x59eA58c0089314C0fCc86A4ff646fb6dAE571C96` | `contracts/src/platform/PaymentGateway.sol` |
| 4 | AgentFactory | 0.8.20 | `0xc93eCc808583dd7700bD85D5a7Ad91D54EDbdE7D` | `contracts/src/platform/AgentFactory.sol` |
| 5 | ReputationRegistry | 0.8.20 | `0xeb6B410ea71b8d9dA0c96f6A91d35027CE143DC9` | `contracts/src/platform/ReputationRegistry.sol` |
| 6 | ConfigurationRegistry | 0.8.20 | `0x68DcE00e4C9077c94BC68016cD14B09557faEA6c` | `contracts/src/platform/ConfigurationRegistry.sol` |
| 7 | MultiEndpointRegistry | 0.8.20 | `0xEB5e866f186d4B73F97aa0d70B86f2C6e2e21Cb7` | `contracts/src/platform/MultiEndpointRegistry.sol` |
| 8 | A2AProtocolRegistry | 0.8.20 | `0xEdb0022c250B38e281B3EF1418037889fC5C6092` | `contracts/src/platform/A2AProtocolRegistry.sol` |

> Sources verified on Sepolia Blockscout. All 8 contracts open-source.

### OxaChain L1 (Mainnet) — Core Only

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
| Sepolia | 11155111 | `https://ethereum-sepolia-rpc.publicnode.com` |
| OxaChain L1 | 19505 | `https://rpc-oxa.0xainet.top` |

### Deployers

| Chain | Address |
|-------|---------|
| Sepolia | `0x4F7744F97AaC9Ad7f0a67de75b149aDb87464103` |
| OxaChain L1 | `0x8E869A0624fF9e766Df71b5B08897d00E4d260ba` |

---

## SubscriptionManager v3

### Deployment

| Parameter | Value |
|-----------|-------|
| Constructor arg | `500` (platformFeeBps = 5%) |
| Compiler | solc 0.8.24 |
| EvmVersion | cancun |
| Optimizer | on, 200 runs |
| Tx Hash | `0x3dbf09f83e7064b5f53dc7f279049be5c13ffe69e602de6550887d3718830537` |
| Command | `forge create --legacy --constructor-args 500` |

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
| Constructor arg | `500` (platformFeeBps = 5%) |
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
event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
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
  src/SubscriptionManager.sol:SubscriptionManager \
  --constructor-args <initialFeeBps>

# IdentityRegistry (no constructor args)
forge create \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy \
  --broadcast \
  src/IdentityRegistry.sol:IdentityRegistry
```

### Verify (Optional)

```bash
forge verify-contract \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  <address> \
  src/SubscriptionManager.sol:SubscriptionManager
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
