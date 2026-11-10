#!/bin/bash
# 用法: closure.sh <driver.c> [更多.c ...]
# 方法: 源文件里出现的标识符 ∩ Module.symvers 导出符号 = 该驱动的内核 API 面（可静态求得的下界）
SRC_TREE=/opt/linux/src/linux-7.2.12
SYMVERS=$HOME/kernel-meta-7.2.12/Module.symvers
awk -F'\t' '{print $2}' "$SYMVERS" | sort -u > /tmp/exported.txt
for f in "$@"; do
  # 去掉注释与字符串，抽标识符
  sed -e 's://.*::' -e 's:/\*[^*]*\*/::g' "$f" \
  | grep -oE '\b[A-Za-z_][A-Za-z0-9_]*\b' | sort -u > /tmp/ids.txt
  comm -12 /tmp/ids.txt /tmp/exported.txt
done | sort -u
