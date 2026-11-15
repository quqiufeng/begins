#!/usr/bin/env bash
# pack-kernel.sh — 单独打 ophub 需要的四件套（boot/dtb/modules/header）+ sha256sums
#
# 与 rebuild-from-zero.sh 的 §19.5 阶段等价，区别：不编译、不做 initrd，
# 直接拿 $OUT 里已有的 Image/modules/System.map 打包。用于改完配置只需重打包、
# 或 build-kernel.sh 编完后手动补包。
#
# 用法：
#   ./x96max/pack-kernel.sh                # 打包 7.2.12-x96
#   X96_KNAME=... X96_BUILD_ROOT=... ./x96max/pack-kernel.sh
#
# 与 X96max.md §19.5 一致，唯一差异：KSRC 用裁剪树 src-linux（/opt/linux/src 原版树已删）。
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${X96_BUILD_ROOT:-/x96-build}
KNAME=${X96_KNAME:-7.2.12-x96}
KV=${KNAME%-x96}                          # 7.2.12
OUT=${X96_KOUT:-$ROOT/kbuild-$KV}
KSRC=${X96_KSRC:-$ROOT/src-linux}
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/$KV

[[ -f $OUT/arch/arm64/boot/Image ]] || { echo "缺内核产物: $OUT/arch/arm64/boot/Image（先跑 build-kernel.sh）" >&2; exit 1; }
[[ -d $KSRC ]] || { echo "缺裁剪源码树: $KSRC" >&2; exit 1; }
[[ -f $ROOT/initrd.img-$KNAME && -f $ROOT/uInitrd-$KNAME ]] || {
  echo "缺 initrd: $ROOT/initrd.img-$KNAME 或 uInitrd-$KNAME（先跑 rebuild-from-zero.sh --from initrd）" >&2; exit 1; }

mkdir -p "$K"/{boot,dtb,modules,header}

# --- boot ---
cp "$OUT/.config"                        "$K/boot/config-$KNAME"
cp "$OUT/System.map"                     "$K/boot/System.map-$KNAME"
cp "$OUT/arch/arm64/boot/Image"          "$K/boot/vmlinuz-$KNAME"
cp "$ROOT/initrd.img-$KNAME"             "$K/boot/initrd.img-$KNAME"
cp "$ROOT/uInitrd-$KNAME"                "$K/boot/uInitrd-$KNAME"
tar -czf "$K/boot-$KNAME.tar.gz" -C "$K/boot" .

# --- dtb（只放 X96 Max）---
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-$KNAME.tar.gz" -C "$K/dtb" .

# --- modules ---
tar -czf "$K/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

# --- header（复刻 ophub collect_headers）---
H=$K/header
rm -rf "${H:?}"/*
(
  cd "$KSRC"
  head_list=$(mktemp); obj_list=$(mktemp)
  {
    find . arch/arm64 -maxdepth 1 -name 'Makefile*'
    find include scripts \( -type f -o -type l \)
    find arch/arm64 -name Kbuild.platforms -o -name Platform
    find $(find arch/arm64 -name include -o -name scripts -type d) -type f
  } >"$head_list"
  {
    [[ -n "$(grep '^CONFIG_OBJTOOL=y' "$OUT/include/config/auto.conf" 2>/dev/null || true)" ]] && echo tools/objtool/objtool
    find arch/arm64/include include scripts -type f
    [[ -f Module.symvers ]] && echo Module.symvers
    [[ -n "$(grep '^CONFIG_GCC_PLUGINS=y' "$OUT/include/config/auto.conf" 2>/dev/null || true)" ]] && find scripts/gcc-plugins -name '*.so'
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

(cd "$K" && sha256sum ./*.tar.gz > sha256sums)
mkdir -p "$ROOT/pkgs"; cp "$K"/*.tar.gz "$K"/sha256sums "$ROOT/pkgs/"
ls -lh "$K"
cat "$K/sha256sums"
