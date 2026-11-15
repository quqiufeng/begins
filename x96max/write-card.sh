#!/bin/bash
# write-card.sh — 安全写卡 + 可信校验（X96 Max 镜像 → SD/U 盘）
#
# 为什么需要这个脚本（2026-11-15 实测踩坑）：
#   1. 桌面自动挂载（gsettings automount / udisks2）会在 dd 之后把 sdb2 以 rw 挂上，
#      ext4 做日志回放 → 经不稳的读路径读到错字节 → 写回卡里，把垃圾"固化"成真实损坏。
#      实测症状：/usr/lib/udev/hwdb.d/20-pci-vendor-model.hwdb 字符错位、长度不变、
#      e2fsck 却干净。所以写卡前必须关掉自动挂载。
#   2. USB 读卡器大块读会返回错字节（bs=1M 几乎必错，bs=256K 也有 ~0.1%），
#      且同一位置重读多次给出**相同的错字节** —— "重读 3 次一致"不能证明内容正确。
#      所以**裸盘 cmp 不是判据**，判据在文件系统层（本脚本第 5 步）。
#
# 用法:
   sudo ./write-card.sh <img|img.gz> /dev/sdX [--yes] [--verify-only] [--img-cache DIR] [--bs 4M]
   sudo ./write-card.sh <img|img.gz> /dev/sdX --verify-only   # 只校验已写好的卡，不动数据
#
# 做的事:
#   0 安全检查（拒绝系统盘/已挂载）→ 1 关自动挂载、停 udisks2（退出时自动恢复）
#   2 dd 写入 + flush → 3 分区表比对 → 4 前 4MiB（U-Boot/分区表）3 次重读容错
#   5 逐分区：e2fsck -fn + 文件清单 + 逐文件 sha256 / diff -r → 6 恢复设置并报告
#
# 退出码: 0=全部通过  1=用法错  2=设备被拒  3=校验失败  4=写盘失败
set -uo pipefail

BS=4M
IMG_CACHE="${X96_IMG_CACHE:-${TMPDIR:-/tmp}}"
ASSUME_YES=0
VERIFY_ONLY=0
SRC=""; DEV=""

die()  { echo "错误: $1" >&2; exit "${2:-1}"; }
log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=1 ;;
    --verify-only|--verify) VERIFY_ONLY=1 ;;
    --img-cache) IMG_CACHE="$2"; shift ;;
    --bs)        BS="$2"; shift ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    -*)          die "未知选项 $1" 1 ;;
    *) if   [ -z "$SRC" ]; then SRC="$1"
       elif [ -z "$DEV" ]; then DEV="$1"
       else die "多余参数 $1" 1; fi ;;
  esac
  shift
done
[ -n "$SRC" ] && [ -n "$DEV" ] || die "用法: write-card.sh <img|img.gz> /dev/sdX [--yes]" 1
[ "$(id -u)" = 0 ] || die "要用 sudo/root 运行" 1
[ -e "$SRC" ]      || die "镜像不存在: $SRC" 1
[ -b "$DEV" ]      || die "不是块设备: $DEV" 1

# ---------- 0) 设备安全闸 ----------
log "0) 设备安全检查"
DISK=$(basename "$DEV")
[ "$(lsblk -dno TYPE "$DEV")" = disk ] || die "$DEV 不是整盘设备（要 /dev/sdX，不要 /dev/sdX1）" 2

ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOTDISK=$(lsblk -sno NAME "$ROOTSRC" 2>/dev/null | tail -1)
[ "$ROOTDISK" = "$DISK" ] && die "$DEV 是系统盘（/ 在它上面），拒绝" 2

BUSY=$(lsblk -lnpo NAME,MOUNTPOINTS "$DEV" 2>/dev/null | awk 'NF>1 && $2!=""')
if [ -n "$BUSY" ]; then
  warn "有分区正被挂载:"; echo "$BUSY" | sed 's/^/      /'
  die "先卸载再写（自动挂载没关干净，见文档 §10.1.3）" 2
fi
ok "$DEV 是 $(lsblk -dno MODEL,SIZE "$DEV" | xargs)，未挂载，非系统盘"

# ---------- 1) 关自动挂载（关键）----------
log "1) 关闭桌面自动挂载 / 停 udisks2"
G_AM=$(gsettings get org.gnome.desktop.media-handling automount 2>/dev/null || echo "")
G_AMO=$(gsettings get org.gnome.desktop.media-handling automount-open 2>/dev/null || echo "")
UDISK_ACTIVE=$(systemctl is-active udisks2 2>/dev/null || echo inactive)
LP=""

restore_env() {
  log "6) 恢复自动挂载设置"
  [ -n "$G_AM" ]  && gsettings set org.gnome.desktop.media-handling automount "$G_AM" 2>/dev/null \
                  && echo "  automount=$G_AM"
  [ -n "$G_AMO" ] && gsettings set org.gnome.desktop.media-handling automount-open "$G_AMO" 2>/dev/null \
                  && echo "  automount-open=$G_AMO"
  [ "$UDISK_ACTIVE" = active ] && systemctl start udisks2 2>/dev/null && echo "  udisks2 started"
  for m in /mnt/_wc_img /mnt/_wc_card; do
    mountpoint -q "$m" && umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null
  done
  [ -n "$LP" ] && losetup -d "$LP" 2>/dev/null
  return 0
}
trap restore_env EXIT INT TERM

[ -n "$G_AM" ]  && gsettings set org.gnome.desktop.media-handling automount false 2>/dev/null && echo "  automount=false"
[ -n "$G_AMO" ] && gsettings set org.gnome.desktop.media-handling automount-open false 2>/dev/null && echo "  automount-open=false"
[ "$UDISK_ACTIVE" = active ] && systemctl stop udisks2 2>/dev/null && echo "  udisks2 stopped"
if grep -q "^$DEV" /proc/mounts; then
  bad "$DEV 仍有挂载"; awk -v d="$DEV" '$1~d' /proc/mounts | sed 's/^/      /'
  die "关掉自动挂载后仍被挂载，请手动 umount" 2
fi
ok "自动挂载已关，$DEV 无挂载"

# ---------- 解压镜像（校验需要落盘的 img）----------
case "$SRC" in
  *.gz|*.xz)
    IMG="$IMG_CACHE/$(basename "${SRC%.*}")"
    if [ -f "$IMG" ] && [ "$IMG" -nt "$SRC" ]; then
      ok "复用已解压镜像 $IMG"
    else
      NEED=$(gzip -l "$SRC" 2>/dev/null | awk 'NR==2{print $2}')
      AVAIL=$(df -Pk "$IMG_CACHE" | awk 'NR==2{print $4}')
      if [ -n "$NEED" ] && [ "$((NEED/1024))" -gt "$AVAIL" ]; then
        die "$IMG_CACHE 空间不足（需约 $((NEED/1048576))MiB）" 1
      fi
      echo "  解压到 $IMG ..."
      gzip -dc "$SRC" > "$IMG" || die "解压失败" 1
    fi ;;
  *) IMG="$SRC" ;;
esac
IMGSZ=$(stat -c %s "$IMG")
printf '  镜像 %s = %s 字节 (%s MiB)\n' "$(basename "$IMG")" "$IMGSZ" "$((IMGSZ/1048576))"

DEVSZ=$(blockdev --getsize64 "$DEV")
[ "$IMGSZ" -le "$DEVSZ" ] || die "镜像 $((IMGSZ/1048576))MiB 大于设备 $((DEVSZ/1048576))MiB" 2
if [ "$VERIFY_ONLY" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  echo
  read -rp "即将用上面的镜像覆盖 $DEV（全部数据丢失），输入设备名确认: " ans < /dev/tty
  [ "$ans" = "$DEV" ] || die "输入不匹配，已取消" 2
fi

# ---------- 2) 写盘 ----------
if [ "$VERIFY_ONLY" = 1 ]; then
  log "2) --verify-only：跳过写入，只校验卡上现有内容"
  DUR=1
else
  log "2) 写入 $DEV (bs=$BS)"
  T0=$(date +%s)
  dd if="$IMG" of="$DEV" bs="$BS" conv=fsync,notrunc status=progress
  RC=$?
  T1=$(date +%s)
  [ $RC -eq 0 ] || die "dd 失败 RC=$RC" 4
  sync; blockdev --flushbufs "$DEV" 2>/dev/null || true
  DUR=$((T1-T0)); [ "$DUR" -lt 1 ] && DUR=1
  ok "写入完成，${DUR}s，$(( IMGSZ/1048576/DUR ))MB/s"
fi

partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true

FAIL=0

# ---------- 3) 分区表比对 ----------
log "3) 分区表比对（镜像 vs 卡）"
LP=$(losetup -rfP --show "$IMG") || die "losetup 失败" 3
udevadm settle 2>/dev/null || sleep 0.5
norm_sf() { sfdisk -d "$1" 2>/dev/null | grep -E '^/dev/' | sed 's#^/dev/[a-z0-9]*##'; }
SRC_SF=$(norm_sf "$LP"); DST_SF=$(norm_sf "$DEV")
if [ -n "$SRC_SF" ] && [ "$SRC_SF" = "$DST_SF" ]; then
  ok "分区表一致:"; echo "$DST_SF" | sed 's/^/      /'
else
  bad "分区表不一致"; diff <(echo "$SRC_SF") <(echo "$DST_SF") | sed 's/^/      /'; FAIL=1
fi

# ---------- 4) 前 4MiB（U-Boot + 分区表，不在任何分区内）----------
log "4) 前 4MiB 裸区（U-Boot + 分区表）比对，3 次重读容错"
PRE=8192
IMG_PRE=$(dd if="$IMG" bs=512 count=$PRE status=none | sha256sum | cut -d' ' -f1)
PRE_OK=0
for i in 1 2 3; do
  C_PRE=$(dd if="$DEV" bs=512 count=$PRE status=none | sha256sum | cut -d' ' -f1)
  if [ "$C_PRE" = "$IMG_PRE" ]; then PRE_OK=1; ok "第 $i 次重读一致"; break; fi
  warn "第 $i 次重读不一致（读卡器噪声或真实差异）"
done
[ $PRE_OK -eq 1 ] || { bad "前 4MiB 三次重读均不同 —— U-Boot/分区表区可疑，建议重写"; FAIL=1; }

mapfile -t SRC_PARTS < <(lsblk -lnpo NAME,TYPE "$LP"  | awk '$2=="part"{print $1}' | sort -V)
mapfile -t DST_PARTS < <(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1}' | sort -V)
printf '  分区数: 镜像 %d / 卡 %d\n' "${#SRC_PARTS[@]}" "${#DST_PARTS[@]}"
[ "${#SRC_PARTS[@]}" = "${#DST_PARTS[@]}" ] || { bad "分区数量不一致"; FAIL=1; }

# ---------- 5) 逐分区内容比对 ----------
img_mnt=/mnt/_wc_img; card_mnt=/mnt/_wc_card
mkdir -p "$img_mnt" "$card_mnt"

for idx in "${!SRC_PARTS[@]}"; do
  sp=${SRC_PARTS[$idx]}; dp=${DST_PARTS[$idx]:-}
  [ -z "$dp" ] && continue
  n=$((idx+1)); FSTYPE=$(lsblk -dno FSTYPE "$sp")
  log "5.$n) 分区 $n ($FSTYPE: $(basename "$sp") vs $(basename "$dp"))"

  # e2fsck 必须在挂载之前跑
  case "$FSTYPE" in
    ext*)
      if e2fsck -fn "$dp" >/tmp/_wc_e2fsck.log 2>&1; then ok "e2fsck -fn 干净"
      else bad "e2fsck 报错:"; tail -15 /tmp/_wc_e2fsck.log | sed 's/^/      /'; FAIL=1; fi
      ;;
    *) echo "  （$FSTYPE 不做 fsck）" ;;
  esac

  case "$FSTYPE" in ext*) MOUNT_OPTS="-o ro,noload" ;; *) MOUNT_OPTS="-o ro" ;; esac
  mount $MOUNT_OPTS "$sp" "$img_mnt" 2>/dev/null || { warn "镜像分区 $n 挂不上，跳过内容比对"; continue; }
  if ! mount $MOUNT_OPTS "$dp" "$card_mnt" 2>/dev/null; then
    bad "卡上分区 $n 挂不上（文件系统结构损坏）"; umount "$img_mnt"; FAIL=1; continue
  fi

  printf '  条目: 镜像 %s / 卡 %s\n' "$(find "$img_mnt" -xdev | wc -l)" "$(find "$card_mnt" -xdev | wc -l)"

  ( cd "$img_mnt"  && find . | sort ) > /tmp/_wc_l1
  ( cd "$card_mnt" && find . | sort ) > /tmp/_wc_l2
  if diff -q /tmp/_wc_l1 /tmp/_wc_l2 >/dev/null; then
    ok "文件清单一致（$(wc -l < /tmp/_wc_l1) 条）"
  else
    bad "文件清单有差异:"; diff /tmp/_wc_l1 /tmp/_wc_l2 | head -20 | sed 's/^/      /'; FAIL=1
  fi

  # 逐文件 sha256（比 diff -r 更强：不依赖读路径稳定性，且能定位到具体文件）
  ( cd "$img_mnt"  && find . -type f -print0 | sort -z | xargs -0 -r sha256sum 2>/dev/null ) > /tmp/_wc_h1
  ( cd "$card_mnt" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum 2>/dev/null ) > /tmp/_wc_h2
  if diff -q /tmp/_wc_h1 /tmp/_wc_h2 >/dev/null; then
    ok "逐文件 sha256 全部一致（$(wc -l < /tmp/_wc_h1) 个文件）"
  else
    bad "文件内容有差异（下列文件 sha256 不符）:"
    diff /tmp/_wc_h1 /tmp/_wc_h2 | head -20 | sed "s/^/      /"
    FAIL=1
  fi

  umount "$card_mnt"; umount "$img_mnt"
done

sync
rmdir "$img_mnt" "$card_mnt" 2>/dev/null
losetup -d "$LP" 2>/dev/null; LP=""

log "结果"
if [ $FAIL -eq 0 ]; then
  printf '  \033[32m全部通过\033[0m —— 卡内容与镜像等价\n'
  [ "$VERIFY_ONLY" = 1 ] || echo "  写盘 ${DUR}s / $((IMGSZ/1048576))MiB"
  echo
  echo "  下一步：立刻拔卡插到盒子上。卡留在电脑上，任何一次 media-change"
  echo "  都可能触发 rw 挂载并重复污染（这也是本脚本关自动挂载的原因）。"
  exit 0
else
  printf '  \033[31m校验失败\033[0m —— 不要拿去刷机\n'
  echo "  处置：重插卡 → 再跑一次本脚本；连续两次失败换读卡器/换卡。"
  exit 3
fi
