#!/bin/bash
# 安装预编译内核 7.2.12-x98（x98h / H618 百兆网口版）
#
# 用法（目标盒子上，root）:
#   tar -xjf x98h-kernel-7.2.12-x98.tar.bz2 && cd x98h-kernel-7.2.12-x98 && ./install.sh
#
# 参数:
#   -y, --yes          不问直接装
#   --keep-env         完全不碰 /boot/armbianEnv.txt
#   --boot-scr         连 /boot/boot.cmd+boot.scr 一起装（默认不动）
#   --dtb <name>       覆盖 fdtfile，如 allwinner/sun50i-h618-x98h.dtb
#   --display <mode>   覆盖 video=，如 1920x1080@60 或 2560x1440@60e
#   --no-edid          去掉 drm.edid_firmware（接真显示器用真 EDID）
#
# 环境变量（测试用）: X98_ROOT=/tmp/fr 装到假根；X98_TEST=1 跳过 uid/arch 检查
set -euo pipefail

KVER=7.2.12-x98
SRC=$(cd "$(dirname "$0")" && pwd)
R="${X98_ROOT:-}"
ASSUME_YES=0
KEEP_ENV=0
BOOT_SCR=0
DTB=""
DISPLAY=""
NO_EDID=0

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=1 ;;
    --keep-env)  KEEP_ENV=1 ;;
    --boot-scr)  BOOT_SCR=1 ;;
    --dtb)       DTB="${2:?--dtb 需要参数}"; shift ;;
    --display)   DISPLAY="${2:?--display 需要参数}"; shift ;;
    --no-edid)   NO_EDID=1 ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

if [ "${X98_TEST:-0}" != 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "必须 root"; exit 1; }
  [ "$(uname -m)" = aarch64 ] || { echo "目标必须是 aarch64"; exit 1; }
fi

echo "== 0. 包 =="
echo "  目录 $SRC"
echo "  内核 $KVER"
echo "  根   ${R:-/}"

BK="${R}/root/kernel-backup-$(date +%Y%m%d-%H%M%S)"
echo "== 1. 备份 → $BK =="
mkdir -p "$BK/boot" "$BK/modules" "$BK/firmware"
for f in Image uInitrd uInitrd-$KVER armbianEnv.txt boot.cmd boot.scr; do
  [ -e "${R}/boot/$f" ] && cp -a "${R}/boot/$f" "$BK/boot/" || true
done
[ -d "${R}/boot/dtb" ] && cp -a "${R}/boot/dtb" "$BK/boot/" || true
[ -d "${R}/lib/modules/$KVER" ] && cp -a "${R}/lib/modules/$KVER" "$BK/modules/" || true
[ -d "${R}/lib/firmware/edid" ] && cp -a "${R}/lib/firmware/edid" "$BK/firmware/" || true
echo "  $(du -sh "$BK" | cut -f1)"

if [ "$ASSUME_YES" = 0 ]; then
  echo
  echo "即将覆盖 ${R}/boot/{Image,uInitrd,dtb} 与 ${R}/lib/modules/$KVER"
  printf "继续? [y/N] "
  read -r ans || ans=""
  case "$ans" in y|Y|yes) ;; *) echo "已取消"; exit 1 ;; esac
fi

echo "== 2. 内核 + initrd =="
install -m 0755 "$SRC/boot/Image"   "${R}/boot/Image"
install -m 0755 "$SRC/boot/uInitrd" "${R}/boot/uInitrd"
install -m 0755 "$SRC/boot/uInitrd" "${R}/boot/uInitrd-$KVER"
install -m 0644 "$SRC/boot/config-$KVER"     "${R}/boot/config-$KVER"
install -m 0644 "$SRC/boot/System.map-$KVER" "${R}/boot/System.map-$KVER"
echo "  Image   $(sha256sum "${R}/boot/Image"   | cut -c1-16)"
echo "  uInitrd $(sha256sum "${R}/boot/uInitrd" | cut -c1-16)"

echo "== 3. dtb =="
mkdir -p "${R}/boot/dtb/allwinner"
cp -a "$SRC/boot/dtb/allwinner/." "${R}/boot/dtb/allwinner/"
echo "  $(ls "${R}/boot/dtb/allwinner/"*.dtb | wc -l) 个"

echo "== 4. 模块 =="
rm -rf "${R}/lib/modules/$KVER"
mkdir -p "${R}/lib/modules"
cp -a "$SRC/lib/modules/$KVER" "${R}/lib/modules/"
echo "  $(find "${R}/lib/modules/$KVER/kernel" -name '*.ko' | wc -l) 个 .ko"

echo "== 5. EDID 固件 =="
mkdir -p "${R}/lib/firmware/edid"
cp -a "$SRC/lib/firmware/edid/." "${R}/lib/firmware/edid/"
echo "  benq-qhd.bin $(md5sum "${R}/lib/firmware/edid/benq-qhd.bin" | cut -c1-16)"

echo "== 6. depmod =="
if [ -n "$R" ]; then
  depmod -b "$R" -a "$KVER"
else
  depmod -a "$KVER"
fi
echo "  modules.dep $(wc -l < "${R}/lib/modules/$KVER/modules.dep") 行"

if [ "$BOOT_SCR" = 1 ]; then
  echo "== 7. boot.cmd / boot.scr =="
  install -m 0644 "$SRC/boot/boot.cmd" "${R}/boot/boot.cmd"
  install -m 0755 "$SRC/boot/boot.scr" "${R}/boot/boot.scr"
  echo "  已装（原文件在 $BK/boot/）"
else
  echo "== 7. boot.cmd / boot.scr 不动（--boot-scr 才装）=="
fi

if [ "$KEEP_ENV" = 0 ]; then
  echo "== 8. 合并 armbianEnv.txt =="
  ENVF="${R}/boot/armbianEnv.txt"
  [ -e "$ENVF" ] && cp -a "$ENVF" "$BK/armbianEnv.txt.orig"
  [ -e "$ENVF" ] || { echo "  目标无 armbianEnv.txt，直接拷模板"; cp -a "$SRC/boot/armbianEnv.txt" "$ENVF"; }
  python3 - "$SRC/boot/armbianEnv.txt" "$ENVF" "$DTB" "$DISPLAY" "$NO_EDID" <<'PY'
import sys, io, re
src, dst, dtb, disp, noedid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
take = {"verbosity", "bootlogo", "fdtfile", "overlay_prefix", "extraargs"}
want = {}
for line in io.open(src, encoding="utf-8"):
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.rstrip("\n").split("=", 1)
        want[k.strip()] = v
if dtb:
    want["fdtfile"] = dtb
if disp or noedid:
    args = want["extraargs"]
    if disp:
        if re.search(r"video=HDMI-A-1:\S+", args):
            args = re.sub(r"(video=HDMI-A-1:)\S+", lambda m: m.group(1) + disp, args)
        else:
            args += " video=HDMI-A-1:" + disp
    if noedid:
        args = re.sub(r"\s*drm\.edid_firmware=\S+", "", args)
    want["extraargs"] = re.sub(r"\s+", " ", args).strip()
out, seen = [], set()
for line in io.open(dst, encoding="utf-8"):
    s = line.rstrip("\n")
    if "=" in s and not s.lstrip().startswith("#"):
        k = s.split("=", 1)[0].strip()
        if k in take and k in want:
            out.append("%s=%s" % (k, want[k])); seen.add(k); continue
    out.append(s)
for k in sorted(take - seen):
    if k in want:
        out.append("%s=%s" % (k, want[k]))
io.open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
kept = [l for l in out if l.startswith(("rootdev=", "rootfstype=", "extraboardargs="))]
print("  保留本机专属: " + " ".join(kept))
PY
  grep -E "^(fdtfile|extraargs|rootdev)" "$ENVF" | sed 's/^/  /'
else
  echo "== 8. 跳过 armbianEnv.txt (--keep-env) =="
fi

echo
echo "== 完成 =="
echo "  回滚: BK=$BK ; 把 $BK/boot/{Image,uInitrd} + $BK/boot/dtb + $BK/modules/$KVER + $BK/boot/armbianEnv.txt.orig 拷回原位"
echo "  生效: reboot"
echo
echo "注意: extraargs 里写死视频模式与 EDID。接的不是 BenQ QHD，用 --display 1920x1080@60 --no-edid 重装。"
