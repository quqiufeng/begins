#!/usr/bin/env bash
# rebuild-from-zero.sh — 从 0 重跑 X96max.md §19.3→§19.6（两套：full 完整树 / trim 裁剪版）
#   编译内核 → initrd/uInitrd → boot/dtb/modules/header 四包 → 可刷镜像
#
# 用法：
#   ./x96max/rebuild-from-zero.sh                # 全量套（默认，先清空全量套旧产物）
#   ./x96max/rebuild-from-zero.sh --trim         # 裁剪套（src-trim + kbuild-trim + 7.2.12-x96-trim）
#   ./x96max/rebuild-from-zero.sh --mode trim    # 同上
#   ./x96max/rebuild-from-zero.sh --from initrd   # 跳过内核，复用 kbuild-*/Image
#   ./x96max/rebuild-from-zero.sh --from pkgs     # 只重打四包
#   ./x96max/rebuild-from-zero.sh --from image    # 只重做镜像（复用四包）
#   ./x96max/rebuild-from-zero.sh --no-clean      # 不清旧产物
#   两套的固定入口：./x96max/full/rebuild-from-zero.sh、./x96max/trim/rebuild-from-zero.sh
#
# 两套参数全部由 lib/mode.sh 给出，互不覆盖：
#   MODE  CFG(=x96max/kernel/config-7.2.12-x96-<MODE>)  KSRC        OUT           KNAME              PKGS
#   full  config-7.2.12-x96-full                          src-full    kbuild-7.2.12 7.2.12-x96        pkgs/full
#   trim  config-7.2.12-x96-trim                          src-trim    kbuild-trim   7.2.12-x96-trim   pkgs/trim
# 成品：recovery/x96-full-autoinstall.img.gz / recovery/x96-trim-autoinstall.img.gz
# 路径可覆盖：X96_BUILD_ROOT(默认 /x96-build) / X96_KSRC / X96_KOUT / X96_KNAME / X96_CFG / X96_CFG_MODE
# 日志落 $X96_BUILD_ROOT/logs/from0-<MODE>-<ts>/，每步一个文件。
# 需要：aarch64-linux-gnu-gcc、qemu-aarch64-static、mkimage、sudo（loop 挂载 base 镜像）
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SELF_DIR/lib/mode.sh"

M=${X96_CFG_MODE:-full}
FROM=clean; CLEAN=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --from) FROM=$2; CLEAN=0; shift 2 ;;
    --no-clean) CLEAN=0; shift ;;
    --clean-src) export X96_CLEAN_SRC=1; shift ;;   # 编完删掉按需解压的全量树
    --full) M=full; shift ;;
    --trim) M=trim; shift ;;
    --mode) M=${2:?--mode 需要 full|trim}; shift 2 ;;
    --mode=*) M=${1#*=}; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
  esac
done

x96_mode "$M" || exit 2
BASE=${X96_BASE_IMAGE:-$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img}
case $FROM in clean|kernel|initrd|pkgs|image) ;; *) echo "--from 只能是 clean|kernel|initrd|pkgs|image" >&2; exit 2 ;; esac

step() { printf '=== [%s] %s ===\n' "$(date +%H:%M:%S)" "$*"; }
run_stage() { case $FROM in clean) return 0;; kernel) [[ $1 == kernel ]];; initrd) [[ $1 == initrd ]];;
  pkgs) [[ $1 == pkgs ]];; image) [[ $1 == image ]];; esac; }

for v in CFG BASE; do [[ -e ${!v} ]] || { echo "缺: $v=${!v}" >&2; exit 1; }; done
# 源码树：full 缺席就现解压（不要求常驻）；trim 的裁剪树必须有（src-trim/src-clean/$KV-trim 自动找）
x96_ensure_src || exit 1
mkdir -p "$OUT" "$ROOT/logs" "$(dirname "$IMG")"
for t in aarch64-linux-gnu-gcc qemu-aarch64-static mkimage zstd; do
  command -v $t >/dev/null || { echo "缺工具: $t" >&2; exit 1; }
done

LOG=$ROOT/logs/from0-$MODE-$(date +%m%d-%H%M)
mkdir -p "$LOG"
echo "LOG=$LOG"
x96_mode_show
echo "FROM=$FROM  CLEAN=$CLEAN  INITRD=$INITRD  IMG_GZ=$IMG_GZ"

# ---------------- 0. 清空旧产物（只清本套） ----------------
if [[ $CLEAN == 1 ]]; then
  step "0 clean"
  {
    du -sh "$OUT" "$PKGS" "$ROOT/armbian-build/cache/rootfs" 2>/dev/null || true
    rm -rf "$OUT" "$PKGS"
    rm -f "$INITRD" "$UINITRD"
    rm -f "$KERNDIR"/*.tar.gz "$KERNDIR"/sha256sums 2>/dev/null || true
    # 源码 rootfs 缓存由 root 拥有，删掉才会真重建
    sudo rm -f "$ROOT"/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst || true
    # ophub 上一轮的 s905x2 成品（不动 6.18.60 基础镜像）
    rm -f "$ROOT"/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0_amlogic_s905x2_*
    echo "清理后:"; ls -la "$PKGS" 2>/dev/null
  } >"$LOG/0-clean.log" 2>&1
fi

# ---------------- 19.3 编译内核 ----------------
if run_stage kernel; then
  step "19.3 kernel ($MODE)"
  mkdir -p "$OUT"
  cp "$CFG" "$OUT/.config"
  (
    cd "$KSRC"
    make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image modules
    make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- amlogic/meson-g12a-x96-max.dtb
    make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      INSTALL_MOD_PATH="$OUT/modules" modules_install
  ) >"$LOG/19.3.log" 2>&1
  grep '^CONFIG_LOCALVERSION=' "$OUT/.config" | tee -a "$LOG/19.3.log"
  ls -l "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" \
        "$OUT/modules/lib/modules/$KNAME" | tee -a "$LOG/19.3.log"
fi

# ---------------- 19.4 initrd / uInitrd ----------------
if run_stage initrd; then
  step "19.4 initrd ($MODE)"
  {
    LOOP=$(sudo losetup -Pf --show "$BASE")
    echo "LOOP=$LOOP"
    # 6.18.60 base 是单分区镜像（p1=rootfs）；旧两分区镜像才有 p2。分区节点由 udev 异步生成。
    for _ in $(seq 20); do [[ -b ${LOOP}p1 ]] && break; sleep 0.3; done
    PART=${LOOP}p2
    [[ -b $PART ]] || PART=${LOOP}p1
    [[ -b $PART ]] || { echo "无可用分区: ${LOOP}p1 / ${LOOP}p2" >&2; exit 1; }
    echo "PART=$PART"
    trap 'sudo umount /mnt/x96root/sys /mnt/x96root/proc /mnt/x96root/dev 2>/dev/null || true
          sudo umount /mnt/x96root 2>/dev/null || true
          sudo losetup -d "$LOOP" 2>/dev/null || true' EXIT
    sudo mkdir -p /mnt/x96root
    sudo mount "$PART" /mnt/x96root
    sudo cp -a "$OUT/modules/lib/modules/$KNAME" /mnt/x96root/lib/modules/
    sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-$KNAME
    sudo cp "$OUT/.config"    /mnt/x96root/boot/config-$KNAME
    sudo cp "$OUT/System.map" /mnt/x96root/boot/System.map-$KNAME
    sudo mount --bind /dev  /mnt/x96root/dev
    sudo mount --bind /proc /mnt/x96root/proc
    sudo mount --bind /sys  /mnt/x96root/sys
    sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/
    sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c \
      "depmod -a $KNAME && update-initramfs -c -k $KNAME"
    sudo cp /mnt/x96root/boot/initrd.img-$KNAME "$ROOT/"
    sudo umount /mnt/x96root/sys /mnt/x96root/proc /mnt/x96root/dev
    sudo umount /mnt/x96root
    sudo losetup -d "$LOOP"
    trap - EXIT
    # 等待窗口 30s → 90s：USB 读卡器启动时 sda 在 ~37.5s 才枚举，
    # 而 init 的 30s 预算扣掉 rootdelay 后必然先放弃（rootdelay 只会挖预算，不会加预算）。
    sudo "$SELF_DIR/patch-initrd-wait.sh" "$ROOT/initrd.img-$KNAME" --inplace
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
      -d "$ROOT/initrd.img-$KNAME" "$ROOT/uInitrd-$KNAME"
    ls -l "$ROOT/initrd.img-$KNAME" "$ROOT/uInitrd-$KNAME"
  } >"$LOG/19.4.log" 2>&1
fi

# ---------------- 19.5 四个内核包（本套包仓） ----------------
if run_stage pkgs; then
  step "19.5 packages ($MODE)"
  {
    X96_BUILD_ROOT="$ROOT" X96_CFG_MODE="$MODE" "$SELF_DIR/pack-kernel.sh" --mode "$MODE" --force
  } >"$LOG/19.5.log" 2>&1
fi

# ---------------- 19.6 可刷镜像 ----------------
if run_stage image; then
  step "19.6 image ($MODE)"
  X96_BUILD_ROOT="$ROOT" X96_BASE_IMAGE="$BASE" \
    "$SELF_DIR/build-image.sh" --mode "$MODE" >"$LOG/19.6.log" 2>&1
fi

step "done"
if [[ -f $IMG_GZ ]]; then ls -lh "$IMG_GZ" | tee "$LOG/done.log"; sha256sum "$IMG_GZ" | tee -a "$LOG/done.log"
else echo "（本次未跑 image 阶段，无 $IMG_GZ）" | tee "$LOG/done.log"; fi
