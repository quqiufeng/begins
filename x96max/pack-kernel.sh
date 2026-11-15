#!/usr/bin/env bash
# pack-kernel.sh — 单独打 ophub 需要的四件套（boot/dtb/modules/header）+ sha256sums
#
# 与 rebuild-from-zero.sh 的 §19.5 阶段等价，区别：不编译、不做 initrd，
# 直接拿 $OUT 里已有的 Image/modules/System.map 打包。两套各打各的包仓：
#   full → /x96-build/pkgs/full，trim → /x96-build/pkgs/trim
# 打完按需同步进 ophub 的 kernel/stable/7.2.12（同一时刻只放一套，--stage）。
#
# 用法：
#   ./x96max/pack-kernel.sh                # 打全量版（kbuild-7.2.12 + src-full 按需解压）
#   ./x96max/pack-kernel.sh --trim         # 打裁剪版（kbuild-trim + src-clean）
#   ./x96max/pack-kernel.sh --trim --stage # 打完并把裁剪包放进 ophub 目录（做裁剪镜像前必做）
#   ./x96max/pack-kernel.sh -n             # 只打印三元组与 sha 校验，不落包
#   ./x96max/full/pack-kernel.sh | ./x96max/trim/pack-kernel.sh   # 两套固定入口
#
# 与 X96max.md §19.5 一致，唯一差异：KSRC 用现有源码树（/opt/linux/src 原版树已删）。
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SELF_DIR/lib/mode.sh"

M=${X96_CFG_MODE:-full}; DRY=0; FORCE=0; STAGE=0
for a in "$@"; do
  case $a in
    -t|--trim)    M=trim ;;
    --full)       M=full ;;
    --mode)       M=${2:?--mode 需要 full|trim}; shift ;;
    --mode=*)     M=${a#*=} ;;
    -n|--dry-run) DRY=1 ;;
    -f|--force)   FORCE=1 ;;
    --stage)      STAGE=1 ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,"");print;next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "多余参数: $a（本脚本只吃选项，试 --help）" >&2; exit 2 ;;
  esac
done
x96_mode "$M"

[[ -f $OUT/arch/arm64/boot/Image ]] || { echo "缺内核产物: $OUT/arch/arm64/boot/Image（先跑 build-kernel.sh --$MODE）" >&2; exit 1; }
[[ -d $KSRC ]] || { echo "缺源码树: $KSRC" >&2; exit 1; }
[[ -f $INITRD && -f $UINITRD ]] || {
  echo "缺 initrd: $INITRD 或 $UINITRD（先跑 rebuild-from-zero.sh --from initrd --mode $MODE）" >&2; exit 1; }
[[ -d $OUT/modules/lib/modules/$KNAME ]] || {
  echo "缺模块目录: $OUT/modules/lib/modules/$KNAME（先跑 build-kernel.sh --$MODE）" >&2; exit 1; }

# 打包前校验：$OUT/.config 必须等于 configs/ 归档里本 MODE 的一份，否则说明配置没进归档
# （打完的包无法溯源），默认拒绝，--force 才继续。
S1=$(sha256sum "$OUT/.config" | cut -c1-12)
HIT=0
for f in "$X96_REPO"/configs/config-$KV-x96-$MODE-[0-9]*; do
  [[ -f $f ]] || continue
  if [[ $(sha256sum "$f" | cut -c1-12) == "$S1" ]]; then
    echo "  配置溯源 OK：$(basename "$f")（$S1 字节一致）"; HIT=1
  elif x96_cfg_same "$OUT/.config" "$f"; then
    echo "  配置溯源 OK：$(basename "$f")（语义一致，olddefconfig 噪声已忽略）"; HIT=1
  fi
done
if [[ $HIT -eq 0 ]]; then
  echo "警告：$OUT/.config（$S1）不在 configs/ 归档里，打出的包无法溯源" >&2
  ls -l "$X96_REPO"/configs/config-"$KV"-x96-"$MODE"-[0-9]* 2>/dev/null | sed 's/^/  /' >&2 || true
  if [[ $FORCE -eq 0 ]]; then echo "  加 --force 仍要打包" >&2; exit 1; fi
  echo "  --force：继续打包" >&2
fi
echo "MODE=$MODE  KNAME=$KNAME  OUT=$OUT  KSRC=$KSRC  PKGS=$PKGS  CFG=$S1"
echo "  （ophub 落地目录 $KERNDIR${STAGE:+；打完 --stage 同步}）"
if [[ $DRY -eq 1 ]]; then echo "  dry-run：不写 $PKGS、不落 tar.gz。"; exit 0; fi

W=$(mktemp -d "$ROOT/pkgs/.stage-$MODE-XXXX")
mkdir -p "$W"/{boot,dtb,modules,header}

# --- boot ---
cp "$OUT/.config"                "$W/boot/config-$KNAME"
cp "$OUT/System.map"             "$W/boot/System.map-$KNAME"
cp "$OUT/arch/arm64/boot/Image"  "$W/boot/vmlinuz-$KNAME"
cp "$INITRD"                     "$W/boot/initrd.img-$KNAME"
cp "$UINITRD"                    "$W/boot/uInitrd-$KNAME"
tar -czf "$W/boot-$KNAME.tar.gz" -C "$W/boot" .

# --- dtb（只放 X96 Max）---
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$W/dtb/"
tar -czf "$W/dtb-amlogic-$KNAME.tar.gz" -C "$W/dtb" .

# --- modules ---
tar -czf "$W/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

# --- header（复刻 ophub collect_headers）---
H=$W/header
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
tar -czf "$W/header-$KNAME.tar.gz" -C "$H" .

(cd "$W" && sha256sum ./*.tar.gz > sha256sums)

# 落进本 MODE 的包仓（另一套的文件不动，包名带 KNAME 也不会撞）
mkdir -p "$PKGS"
rm -f "$PKGS"/*.tar.gz "$PKGS"/sha256sums
cp "$W"/*.tar.gz "$W"/sha256sums "$PKGS"/
rm -rf "$W"

[[ $STAGE -eq 1 ]] && x96_stage_pkgs
ls -lh "$PKGS"
cat "$PKGS/sha256sums"
