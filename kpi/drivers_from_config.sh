#!/bin/bash
# 输入: kernel .config  输出: 每个 CONFIG 项 -> 对应源码 .o 列表（仅 drivers/ + fs/ + net/）
CFG=${1:-$HOME/kernel-meta-7.2.12/.config}
TREE=${2:-/opt/linux/src/linux-7.2.12}
cd "$TREE" || exit 1
# 收集所有 Makefile 的 obj-$(CONFIG_X) += y.o / z/ 形式
find drivers -name Makefile -print0 | xargs -0 grep -hoE 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+?=[[:space:]].*' 2>/dev/null \
 | sed -E 's/obj-\$\((CONFIG_[A-Z0-9_]+)\)[[:space:]]*\+?=[[:space:]]*/\1 /' \
 | awk '{c=$1; for(i=2;i<=NF;i++) print c"\t"$i}' | sort -u > /tmp/cfg2obj.txt
grep -E '^CONFIG_[A-Z0-9_]+=[my]$' "$CFG" | sed 's/=[my]$//' | sort -u > /tmp/cfg_on.txt
join -t$'\t' -1 1 -2 1 <(sort /tmp/cfg_on.txt) <(sort /tmp/cfg2obj.txt) 2>/dev/null
