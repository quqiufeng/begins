#!/usr/bin/env bash
# rebuild-from-zero.sh — 从 0 重跑 X96max.md §19.3→§19.6
#   .config 编译 7.2.12-x96 内核 → initrd/uInitrd → boot/dtb/modules/header 四包 → 可刷镜像
#
# 用法：
#   ./x96max/rebuild-from-zero.sh              # 全流程（先清空旧产物）
#   ./x96max/rebuild-from-zero.sh --from initrd # 跳过内核，复用 kbuild-*/Image
#   ./x96max/rebuild-from-zero.sh --from pkgs   # 只重打四包
#   ./x96max/rebuild-from-zero.sh --from image  # 只重做镜像（复用四包）
#   ./x96max/rebuild-from-zero.sh --no-clean    # 不清旧产物
#
# 路径全部可覆盖：X96_BUILD_ROOT(默认 /x96-build) / X96_KSRC / X96_KNAME
# 日志落 $X96_BUILD_ROOT/logs/from0-<ts>/，每步一个文件。
# 需要：aarch64-linux-gnu-gcc、qemu-aarch64-static、mkimage、sudo（loop 挂载 base 镜像）
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$SELF_DIR")                       # kernel 仓库根
ROOT=${X96_BUILD_ROOT:-/x96-build}
KSRC=${X96_KSRC:-/opt/linux/src/linux-7.2.12}
KNAME=${X96_KNAME:-7.2.12-x96}
OUT=$ROOT/kbuild-${KNAME%-x96}
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/${KNAME%-x96}
BASE=${X96_BASE_IMAGE:-$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img}
CFG=$SELF_DIR/kernel/config-$KNAME

FROM=clean; CLEAN=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --from) FROM=$2; CLEAN=0; shift 2 ;;
    --no-clean) CLEAN=0; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
  esac
done
case $FROM in clean|kernel|initrd|pkgs|image) ;; *) echo "--from 只能是 clean|kernel|initrd|pkgs|image" >&2; exit 2 ;; esac

step() { printf '=== [%s] %s ===\n' "$(date +%H:%M:%S)" "$*"; }
run_stage() { case $FROM in clean) return 0;; kernel) [[ $1 == kernel ]];; initrd) [[ $1 == initrd ]];;
  pkgs) [[ $1 == pkgs ]];; image) [[ $1 == image ]];; esac; }

for v in CFG BASE; do [[ -e ${!v} ]] || { echo "缺文件: $v=${!v}" >&2; exit 1; }; done
[[ -d $KSRC ]] || { echo "缺内核源码树: $KSRC" >&2; exit 1; }
for t in aarch64-linux-gnu-gcc qemu-aarch64-static mkimage zstd; do
  command -v $t >/dev/null || { echo "缺工具: $t" >&2; exit 1; }
done

LOG=$ROOT/logs/from0-$(date +%m%d-%H%M)
mkdir -p "$LOG"
echo "LOG=$LOG"
echo "ROOT=$ROOT  KSRC=$KSRC  KNAME=$KNAME  FROM=$FROM  CLEAN=$CLEAN"

# ---------------- 0. 清空旧产物 ----------------
if [[ $CLEAN == 1 ]]; then
  step "0 clean"
  {
    du -sh "$OUT" "$ROOT/pkgs" "$K" "$ROOT/armbian-build/cache/rootfs" 2>/dev/null || true
    rm -rf "$OUT" "$ROOT/pkgs"
    rm -f "$K"/*.tar.gz "$K"/sha256sums; rm -rf "$K"/*/
    rm -f "$ROOT/initrd.img-$KNAME" "$ROOT/uInitrd-$KNAME"
    # 源码 rootfs 缓存由 root 拥有，删掉才会真重建
    sudo rm -f "$ROOT"/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst || true
    # ophub 上一轮的 s905x2 成品（不动 6.18.60 基础镜像）
    rm -f "$ROOT"/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0_amlogic_s905x2_*
    echo "清理后:"; ls -la "$K" 2>/dev/null
  } >"$LOG/0-clean.log" 2>&1
fi

# ---------------- 19.3 编译内核 ----------------
if run_stage kernel; then
  step "19.3 kernel"
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
  step "19.4 initrd"
  {
    LOOP=$(sudo losetup -Pf --show "$BASE")
    echo "LOOP=$LOOP"
    trap 'sudo umount /mnt/x96root/sys /mnt/x96root/proc /mnt/x96root/dev 2>/dev/null || true
          sudo umount /mnt/x96root 2>/dev/null || true
          sudo losetup -d "$LOOP" 2>/dev/null || true' EXIT
    sudo mkdir -p /mnt/x96root
    sudo mount "${LOOP}p2" /mnt/x96root
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
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
      -d "$ROOT/initrd.img-$KNAME" "$ROOT/uInitrd-$KNAME"
    ls -l "$ROOT/initrd.img-$KNAME" "$ROOT/uInitrd-$KNAME"
  } >"$LOG/19.4.log" 2>&1
fi

# ---------------- 19.5 四个内核包 ----------------
if run_stage pkgs; then
  step "19.5 packages"
  {
    mkdir -p "$K"/{boot,dtb,modules,header}
    cp "$OUT/.config"                   "$K/boot/config-$KNAME"
    cp "$OUT/System.map"                "$K/boot/System.map-$KNAME"
    cp "$OUT/arch/arm64/boot/Image"     "$K/boot/vmlinuz-$KNAME"
    cp "$ROOT/initrd.img-$KNAME"        "$K/boot/initrd.img-$KNAME"
    cp "$ROOT/uInitrd-$KNAME"           "$K/boot/uInitrd-$KNAME"
    tar -czf "$K/boot-$KNAME.tar.gz" -C "$K/boot" .

    cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
    tar -czf "$K/dtb-amlogic-$KNAME.tar.gz" -C "$K/dtb" .

    tar -czf "$K/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

    H=$K/header; rm -rf "$H"; mkdir -p "$H"
    (
      cd "$KSRC"
      head_list=$(mktemp); obj_list=$(mktemp)
      {
        find . arch/arm64 -maxdepth 1 -name 'Makefile*'
        find include scripts -type f -o -type l
        find arch/arm64 -name Kbuild.platforms -o -name Platform
        find $(find arch/arm64 -name include -o -name scripts -type d) -type f
      } >"$head_list"
      {
        grep -q '^CONFIG_OBJTOOL=y' "$OUT/include/config/auto.conf" 2>/dev/null && echo tools/objtool/objtool
        find arch/arm64/include include scripts -type f
        [[ -f Module.symvers ]] && echo Module.symvers
        grep -q '^CONFIG_GCC_PLUGINS=y' "$OUT/include/config/auto.conf" 2>/dev/null && find scripts/gcc-plugins -name '*.so'
        true
      } >"$obj_list"
      tar --exclude '*.orig' -cf - -T "$head_list" | tar -xf - -C "$H"
      tar --exclude '*.orig' -cf - -T "$obj_list"  | tar -xf - -C "$H"
      rm -f "$head_list" "$obj_list"
    )
    mkdir -p "$H/include" "$H/arch/arm64/include" "$H/scripts"
    cp -a "$OUT/include/."            "$H/include/"
    cp -a "$OUT/arch/arm64/include/." "$H/arch/arm64/include/"
    cp -a "$OUT/scripts/."            "$H/scripts/"
    cp -a "$OUT/.config" "$OUT/Module.symvers" "$H/"
    tar -czf "$K/header-$KNAME.tar.gz" -C "$H" .

    rm -rf "$H"
    (cd "$K" && sha256sum *.tar.gz > sha256sums)
    mkdir -p "$ROOT/pkgs"; cp "$K"/*.tar.gz "$K"/sha256sums "$ROOT/pkgs/"
    ls -lh "$K"; cat "$K/sha256sums"
  } >"$LOG/19.5.log" 2>&1
fi

# ---------------- 19.6 可刷镜像 ----------------
if run_stage image; then
  step "19.6 image"
  X96_BUILD_ROOT="$ROOT" X96_BASE_IMAGE="$BASE" "$SELF_DIR/build-image.sh" >"$LOG/19.6.log" 2>&1
fi

step "done"
IMG=$ROOT/recovery/x96src-autoinstall.img.gz
if [[ -f $IMG ]]; then ls -lh "$IMG" | tee "$LOG/done.log"; sha256sum "$IMG" | tee -a "$LOG/done.log"
else echo "（本次未跑 image 阶段，无 $IMG）" | tee "$LOG/done.log"; fi
