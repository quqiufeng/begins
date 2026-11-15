#!/bin/bash
# 校验「卡 vs 备份镜像」：两侧都 ro,noload 挂载，逐文件 sha256 对拍。
# 不用裸盘 cmp：读卡器大块读可能对两边返回同样的错字节，cmp 通过而实际都错。
# noload = 不回放 ext4 日志，绝不写卡。
set -uo pipefail
O=${1:?用法: verify-card.sh <备份目录> [整盘设备]}
DEV=${2:-/dev/sdb}
T=$(mktemp -d /tmp/vfy-XXXX)
declare -a LOOPS MNT
cleanup() {
  for m in "${MNT[@]}"; do sudo umount -l "$m" 2>/dev/null; done
  for l in "${LOOPS[@]}"; do sudo losetup -d "$l" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

manifest() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ); }

rc=0
for idx in 1 2; do
  img="$O/${DEV##*/}${idx}.img.gz"
  [ -f "$img" ] || { echo "缺 $img"; rc=1; continue; }
  mc="$T/c$idx"; mi="$T/i$idx"; mkdir -p "$mc" "$mi"

  # noload 只有 ext4 认，vfat 传了会直接 EINVAL 挂不上
  ft=$(lsblk -no FSTYPE "${DEV}${idx}" | tr -d ' ')
  [ "$ft" = ext4 ] && OPTS="ro,noload" || OPTS="ro"
  sudo mount -o "$OPTS" "${DEV}${idx}" "$mc" || { echo "${DEV}${idx} 挂不上"; rc=1; continue; }
  MNT+=("$mc")

  gunzip -c "$img" > "$T/p$idx.img"
  lp=$(sudo losetup -r -f --show "$T/p$idx.img") || { echo "loop 建不了"; rc=1; continue; }
  LOOPS+=("$lp")
  sudo mount -o "$OPTS" "$lp" "$mi" || { echo "loop 挂不上"; rc=1; continue; }
  MNT+=("$mi")

  manifest "$mc" > "$T/mc$idx.txt"
  manifest "$mi" > "$T/mi$idx.txt"
  nc=$(wc -l < "$T/mc$idx.txt"); ni=$(wc -l < "$T/mi$idx.txt")
  if diff -q "$T/mc$idx.txt" "$T/mi$idx.txt" >/dev/null; then
    echo "✔ ${DEV}${idx}: $nc 个文件 sha256 全一致"
  else
    echo "✘ ${DEV}${idx}: 不一致（卡 $nc / 镜像 $ni）"; diff "$T/mc$idx.txt" "$T/mi$idx.txt" | head -20; rc=1
  fi
  # 符号链接单列比对（sha256sum 跟随之，目标不同也得暴露）
  ( cd "$mc" && find . -type l -printf '%p -> %l\n' | sort ) > "$T/lc$idx.txt"
  ( cd "$mi" && find . -type l -printf '%p -> %l\n' | sort ) > "$T/li$idx.txt"
  diff -q "$T/lc$idx.txt" "$T/li$idx.txt" >/dev/null \
    && echo "  ✔ 符号链接 $(wc -l < "$T/lc$idx.txt") 条一致" \
    || { echo "  ✘ 符号链接不一致"; diff "$T/lc$idx.txt" "$T/li$idx.txt" | head; rc=1; }
done

echo "=== 结果: $([ $rc -eq 0 ] && echo 全部通过 || echo 有失败) ==="
exit $rc
