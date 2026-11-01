#!/usr/bin/env bash
# 泄露 owner 轮换：把三链上由 0x978e…2C4 持有的合约交权给冷钱包，并把平台收款改到收费冷钱包。
#
# 用法（在 contracts/ 目录执行）：
#   NEW_OWNER=0xfab6e886cf64b13991ade48a2e7d6aecd1b7ef0a \
#   NEW_COLLECTOR=0x1663ed8ebd398aead19fea2ee676fad4bfffbdcb \
#   PRIVATE_KEY=<泄露 EOA 私钥> \
#   ./script/rotate-owner.sh base
#
#   第二个参数：bsc | ethereum | base | all      默认 all
#   可选 env：
#     NEW_COLLECTOR=<addr>        改平台收款地址；已改过可省略
#     DRY_RUN=true                只做前置校验与计划打印，不广播
#     SKIP_FEE_ZERO=true          跳过 ZeroPlatformFee（默认会先清零平台费再交权）
#     SKIP_PREFLIGHT_GAS=1        跳过 gas 余额检查
#     WRITER=<addr> + WRITER_ACTION=grant|revoke  轮换 SettlementRegistry writer
#
# 顺序（每链）：ZeroPlatformFee → [RotateSettlementWriter] → RotateOwnership → 复验
# 注意：ZeroPlatformFee / RotateSettlementWriter 都要求 signer 仍是 owner，必须先跑。
#
# 两阶段推荐用法（避免网关写结算中断）：
#   1) WRITER=<新热钱包> WRITER_ACTION=grant SKIP_FEE_ZERO=true ./script/rotate-owner.sh all
#   2) 换掉生产 .env 的 SETTLEMENT_WRITER_PRIVATE_KEY 并重启网关
#   3) WRITER=0x978e…2C4 WRITER_ACTION=revoke SKIP_FEE_ZERO=true ./script/rotate-owner.sh all

set -euo pipefail

CHAIN="${1:-all}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_FEE_ZERO="${SKIP_FEE_ZERO:-false}"

: "${NEW_OWNER:?NEW_OWNER 未设置（新 owner 冷钱包）}"
: "${PRIVATE_KEY:?PRIVATE_KEY 未设置（当前 owner 私钥）}"
# NEW_COLLECTOR 可选：第一轮已改完收款地址，补跑轮换时不再需要。

RPC_BSC="https://bsc-rpc.publicnode.com"
RPC_ETHEREUM="https://ethereum-rpc.publicnode.com"
RPC_BASE="https://base-rpc.publicnode.com"

declare -A CHAIN_ID=([bsc]=56 [ethereum]=1 [base]=8453)
declare -A RPC=([bsc]="$RPC_BSC" [ethereum]="$RPC_ETHEREUM" [base]="$RPC_BASE")
# 单链实测 gas（2026-11-01 第二批：3 笔 transferOwnership + 1 笔 setWriter）：
#   每笔约 3 万 gas；BSC/ETH/Base 每批 4 笔 → 约 12 万 gas。
#   阈值按 grant + revoke 两阶段各一批（合计 8 笔）估：
#     BSC 0.05 gwei → 约 1e13 wei；ETH 45 gwei → 约 8e15 wei；Base 0.01 gwei → 约 2e12 wei。
#   取 1.5~2 倍余量。
declare -A MIN_GAS_WEI=([bsc]=20000000000000 [ethereum]=10000000000000000 [base]=3000000000000)

declare -A SM=(
  [bsc]=0x5a36150C5865B4dA16218724a1c5668561E4d981
  [ethereum]=0xF3D14ac4D51BC4B7354838af3137248476D540BD
  [base]=0x41A42cDe1bd7AA39a9beB3745Ae08f50e8656B36
)
declare -A A2A=(
  [bsc]=0x97cad48D250C00A394449A5E613773e82b20089D
  [ethereum]=0x5a36150C5865B4dA16218724a1c5668561E4d981
  [base]=0x88cce24854505e2d3DC8625a0Bf27Cca10f901C1
)
declare -A VAL=(
  [bsc]=0x3d430c9188bBb8Cfac84024449821F92Ee7C1C76
  [ethereum]=0x7d81Cf6b7cFa21675aFB604C8E6451F5565cAB5e
  [base]=0x17507588a0DacCBa4c30411D4b98F6507C475ae9
)
# Configuration / MultiEndpoint：BSC、ETH 原属各自部署者，Base 属泄露地址；2026-11-01 已全部交权。
declare -A CFG=(
  [bsc]=0xd9B984cF591dc1C3663991e7D75c44C2bDE1a9BB
  [ethereum]=0x2Bf6962301164A301e4fEC9036aB97edcBcE1bCa
  [base]=0x5EF8c35738311B971A64de64487E1E304Ae53993
)
declare -A MULTI=(
  [bsc]=0x80Bc36634693d7935109f5cdbc95E64a9c1bdA6a
  [ethereum]=0xE93fbED3Df2a5D357856f2f2712B3c1Ebb8d026f
  [base]=0xB8065829dBb450B8fC7375D910521EA641EC6Ee5
)
# 第二批：PaymentReputationOracle（V1/V2）与 SettlementRegistry 三链 owner 同样是泄露地址。
declare -A PRO=(
  [bsc]=0x7aef91ee08cefc3020783d547362c6fe411943f7
  [ethereum]=0x072f387799e329e36131f0422bb406f33975b6d9
  [base]=0x4b9cdbefb6d57b44566c8a0a176836e75650b490
)
declare -A PRO2=(
  [bsc]=0x16782b8911DbCe39D8841A767417Fd24934C2C13
  [ethereum]=0xc1964fd80Da1c924F0fe5380D26C266CE33d398F
  [base]=0x7aef91EE08ceFc3020783D547362c6Fe411943f7
)
declare -A SETTLE=(
  [bsc]=0x4f623c3db52ce8b617d96eaed267452a796d03fa
  [ethereum]=0xca738863ec4015a4cde94408dc6b15f0463cf0a7
  [base]=0xaa9ad3f55bcbaefeb3ba3de8fd6cc640632fa3fb
)

SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")

run_chain() {
  local chain="$1"
  local rpc="${RPC[$chain]}"
  local id="${CHAIN_ID[$chain]}"

  echo ""
  echo "==================== ${chain} (${id}) ===================="

  # ── 前置校验 ──────────────────────────────────────────────────────────
  local owner
  owner=$(cast call "${SM[$chain]}" "owner()(address)" --rpc-url "$rpc" | tr -d '"')
  # 补跑批次：SM 可能已在第一批交给冷钱包，签名者不再是 SM owner，仍允许继续
  # （此时 ZeroPlatformFee 与 collector 变更都会自动跳过）。
  if [ "${owner,,}" != "${SIGNER,,}" ] && [ "${owner,,}" != "${NEW_OWNER,,}" ]; then
    echo "ABORT: ${chain} SubscriptionManager owner=${owner}，签名者=${SIGNER} / 新 owner=${NEW_OWNER}"
    return 1
  fi
  echo "signer=${SIGNER} owner=${owner}"

  local bal
  bal=$(cast balance "$SIGNER" --rpc-url "$rpc")
  echo "signer=${SIGNER} owner 校验通过"
  echo "balance=${bal} wei  (建议 >= ${MIN_GAS_WEI[$chain]})"
  if [ "${SKIP_PREFLIGHT_GAS:-0}" != "1" ] && [ "$bal" -lt "${MIN_GAS_WEI[$chain]}" ]; then
    echo "ABORT: ${chain} gas 不足，先给 $SIGNER 充值"
    return 1
  fi

  local common=(PRIVATE_KEY="$PRIVATE_KEY" NEW_OWNER="$NEW_OWNER"
                SUBSCRIPTION_MANAGER="${SM[$chain]}" A2A_PROTOCOL="${A2A[$chain]}"
                VALIDATION_REGISTRY="${VAL[$chain]}" DRY_RUN="$DRY_RUN"
                PAYMENT_REPUTATION_ORACLE="${PRO[$chain]}"
                PAYMENT_REPUTATION_ORACLE_V2="${PRO2[$chain]}"
                SETTLEMENT_REGISTRY="${SETTLE[$chain]}")
  [ -n "${NEW_COLLECTOR:-}" ] && common+=(NEW_COLLECTOR="$NEW_COLLECTOR")
  [ -n "${CFG[$chain]}" ] && common+=(CONFIGURATION_REGISTRY="${CFG[$chain]}")
  [ -n "${MULTI[$chain]}" ] && common+=(MULTI_ENDPOINT="${MULTI[$chain]}")

  # ── 1. 平台费清零（必须在交权前，脚本内 require owner == signer）────────
  if [ "$SKIP_FEE_ZERO" != "true" ] && [ "$DRY_RUN" != "true" ] && [ "${owner,,}" = "${SIGNER,,}" ]; then
    echo "--- ZeroPlatformFee ---"
    env "${common[@]}" forge script script/ZeroPlatformFee.s.sol:ZeroPlatformFee \
      --rpc-url "$rpc" --broadcast --chain "$id"
  fi

  # ── 2. SettlementRegistry writer 轮换（同样必须在交权前）──────────────
  # WRITER_ACTION=grant|revoke + WRITER=<地址>；不设置则跳过。
  if [ -n "${WRITER:-}" ] && [ -n "${WRITER_ACTION:-}" ]; then
    echo "--- RotateSettlementWriter (${WRITER_ACTION} ${WRITER}) ---"
    local wargs=(PRIVATE_KEY="$PRIVATE_KEY" SETTLEMENT_REGISTRY="${SETTLE[$chain]}"
                 ACTION="$WRITER_ACTION" WRITER="$WRITER" DRY_RUN="$DRY_RUN")
    if [ "$DRY_RUN" = "true" ]; then
      env "${wargs[@]}" forge script script/RotateSettlementWriter.s.sol:RotateSettlementWriter \
        --rpc-url "$rpc" --chain "$id"
    else
      env "${wargs[@]}" forge script script/RotateSettlementWriter.s.sol:RotateSettlementWriter \
        --rpc-url "$rpc" --broadcast --chain "$id"
    fi
  fi

  # ── 3. 改 collector + 转移所有权 ──────────────────────────────────────
  echo "--- RotateOwnership ---"
  if [ "$DRY_RUN" = "true" ]; then
    env "${common[@]}" DRY_RUN=true forge script script/RotateOwnership.s.sol:RotateOwnership \
      --rpc-url "$rpc" --chain "$id"
  else
    env "${common[@]}" forge script script/RotateOwnership.s.sol:RotateOwnership \
      --rpc-url "$rpc" --broadcast --chain "$id"
  fi

  # ── 3. 独立复验（不依赖 forge 输出）──────────────────────────────────
  [ "$DRY_RUN" = "true" ] && return 0
  echo "--- verify ---"
  local oracle
  oracle=$(cast call "${SM[$chain]}" "priceOracle()(address)" --rpc-url "$rpc" | tr -d '"')
  local targets=("${SM[$chain]}" "${A2A[$chain]}" "${VAL[$chain]}" "$oracle"
                 "${PRO[$chain]}" "${PRO2[$chain]}" "${SETTLE[$chain]}")
  [ -n "${CFG[$chain]}" ] && targets+=("${CFG[$chain]}")
  [ -n "${MULTI[$chain]}" ] && targets+=("${MULTI[$chain]}")
  local t now failed=0
  for t in "${targets[@]}"; do
    now=$(cast call "$t" "owner()(address)" --rpc-url "$rpc" | tr -d '"')
    if [ "${now,,}" = "${NEW_OWNER,,}" ]; then
      echo "  OK   $t -> $now"
    else
      echo "  FAIL $t -> $now"
      failed=1
    fi
  done
  local collector fee
  collector=$(cast call "${SM[$chain]}" "platformFeeCollector()(address)" --rpc-url "$rpc" | tr -d '"')
  fee=$(cast call "${SM[$chain]}" "defaultPlatformFee()(uint256)" --rpc-url "$rpc" | tr -d '"')
  echo "  collector=${collector}  defaultPlatformFee=${fee}"
  if [ -n "${NEW_COLLECTOR:-}" ] && [ "${collector,,}" != "${NEW_COLLECTOR,,}" ]; then
    echo "  FAIL collector 未更新"; failed=1
  fi
  if [ -n "${WRITER:-}" ] && [ -n "${WRITER_ACTION:-}" ]; then
    local want="false"
    [ "$WRITER_ACTION" = "grant" ] && want="true"
    local got
    got=$(cast call "${SETTLE[$chain]}" "writers(address)(bool)" "$WRITER" --rpc-url "$rpc" | tr -d '"')
    if [ "${got,,}" = "${want,,}" ]; then
      echo "  OK   writers(${WRITER})=${got}"
    else
      echo "  FAIL writers(${WRITER})=${got}（期望 ${want}）"; failed=1
    fi
  fi
  return $failed
}

case "$CHAIN" in
  bsc|ethereum|base) run_chain "$CHAIN" ;;
  all)
    rc=0
    for c in bsc ethereum base; do
      run_chain "$c" || rc=1
    done
    exit $rc
    ;;
  *) echo "用法: $0 {bsc|ethereum|base|all}"; exit 2 ;;
esac
