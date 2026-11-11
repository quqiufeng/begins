#!/usr/bin/env bash
# 真·全新构建 + 计时。用法: tools/trim/clean-build.sh <config> [jobs]
# 起因: 本树 make clean/mrproper 不删 .o，测得的是"增量时间"。
set -euo pipefail
CFG=$(realpath "${1:?用法: clean-build.sh <config> [jobs]}")   # 必须绝对化：下面要 cd 进树里
J=${2:-$(nproc)}
TREE=$(realpath "${TREE:-$HOME/kernel/src/linux-7.2.12}")
cd "$TREE"

echo "== 清场（不依赖 make clean）=="
cp "$CFG" /tmp/cfg-keep.$$
make mrproper >/dev/null 2>&1 || true
find . -name '*.o' -delete
find . -name '.*.cmd' -delete
find . -name '*.ko' -delete
N=$(find . -name '*.o' | wc -l)
[ "$N" -eq 0 ] || { echo "清场失败，仍有 $N 个 .o"; exit 1; }
echo "  .o = 0 ✓"

cp /tmp/cfg-keep.$$ .config && rm -f /tmp/cfg-keep.$$
make olddefconfig >/dev/null 2>&1

echo "== 构建 -j$J =="
S=$(date +%s)
make -j"$J" -s > /tmp/trim-build.log 2>&1
RC=$?
E=$(date +%s)
D=$((E-S))

echo "== 结果 =="
echo "  耗时    $((D/60))分$((D%60))秒 (rc=$RC)"
echo "  单元    $(find . -name '*.o' | wc -l)"
echo "  .ko     $(find . -name '*.ko' | wc -l)"
echo "  vmlinux $(du -h vmlinux 2>/dev/null | cut -f1)"
echo "  bzImage $(du -h arch/x86/boot/bzImage 2>/dev/null | cut -f1)"
echo "  warning $(grep -c 'warning:' /tmp/trim-build.log || true)"
echo "  日志    /tmp/trim-build.log"
exit $RC
