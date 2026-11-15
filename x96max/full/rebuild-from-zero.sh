#!/usr/bin/env bash
# full/rebuild-from-zero.sh — 「full」套的固定入口（全流程 19.3→19.6）
# 这里不写任何参数：真正的逻辑在同名引擎，参数全由 ../lib/mode.sh 按 MODE=full 决定。
#   full: config-7.2.12-x96-full  + src-full(按需解压) + kbuild-7.2.12  → 7.2.12-x96
#   trim: config-7.2.12-x96-trim  + src-clean  + kbuild-trim    → 7.2.12-x96-trim
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export X96_CFG_MODE=full
exec "$SELF_DIR/../rebuild-from-zero.sh" "$@"
