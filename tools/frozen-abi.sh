#!/usr/bin/env bash
#
# WS1 冻结合约 ABI 门禁
#
# 用途：阻止 @custom:frozen 合约新增/变更外部接口（ABI）。注释、格式、内部实现
#       变更不会触发；只有 ABI（函数/事件/错误签名）变化才会失败。
#
# 用法：
#   tools/frozen-abi.sh           # 校验（CI 用），ABI 变化 → 退出码 1
#   tools/frozen-abi.sh --write   # 重新生成快照（有意改动冻结合约时）
#
# 依赖：forge（foundry）、python3（规范化 JSON）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SNAP_DIR="$ROOT/.frozen-abi"

# 冻结合约清单（fully-qualified target）。新增冻结合约时在此追加。
# 两个冻结合约已于 2026-10-27 归档至 legacy/，故统一在 legacy profile 下检查。
export FOUNDRY_PROFILE=legacy
TARGETS=(
  "legacy/src/IdentityRegistry.sol:IdentityRegistry"
  "legacy/src/SubscriptionManager.sol:SubscriptionManager"
)

MODE="check"
if [ "${1:-}" = "--write" ]; then MODE="write"; fi

# 规范化 JSON：键排序 + 缩进，保证跨环境输出稳定可 diff（不加尾随换行）
canon() {
  python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=2, sort_keys=True)'
}

mkdir -p "$SNAP_DIR"
fail=0

for target in "${TARGETS[@]}"; do
  name="${target##*:}"
  snap="$SNAP_DIR/${name}.abi.json"
  current="$(forge inspect "$target" abi --json | canon)"

  if [ "$MODE" = "write" ]; then
    printf '%s' "$current" > "$snap"
    echo "wrote $snap"
    continue
  fi

  if [ ! -f "$snap" ]; then
    echo "::error::缺少冻结 ABI 快照: $snap（运行 tools/frozen-abi.sh --write 生成）"
    fail=1
    continue
  fi

  if diff <(printf '%s' "$current") <(canon < "$snap") >/dev/null; then
    echo "ok: $name 未变化"
  else
    echo "::error::冻结合约 '$name' 的 ABI 发生变化 —— 冻结合约禁止新增/变更外部接口。"
    echo "----- diff (current vs snapshot) -----"
    diff <(printf '%s' "$current") <(canon < "$snap") | head -n 60 || true
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "若为有意的接口变更：更新 .frozen-abi/ 快照（tools/frozen-abi.sh --write），"
  echo "并在 PR 说明为何必须改动已冻结合约。"
  exit 1
fi

echo "frozen-abi: 所有冻结合约 ABI 未变化"
