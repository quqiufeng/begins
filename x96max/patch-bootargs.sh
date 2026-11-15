#!/bin/bash
# 给 U 盘 p1 的 uEnv.txt 里 APPEND= 追加内核参数（幂等，可反复跑）
#
# 用法:
#   sudo ./x96max/patch-bootargs.sh [-l] [参数...]     # 追加参数
#   sudo ./x96max/patch-bootargs.sh -r <参数串>        # 删除指定参数
#   sudo ./x96max/patch-bootargs.sh -l                 # 只列出当前 APPEND
#   sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678  # USB 掉盘修复套餐
#
# 环境变量: X96_ROOT_LABEL(默认 ROOTFS) / X96_ROOT_UUID(可选)

set -euo pipefail

LABEL="${X96_ROOT_LABEL:-ROOTFS}"
UUID="${X96_ROOT_UUID:-}"
ROOT="${X96_BUILD_ROOT:-/x96-build}"

REMOVE=""
LIST_ONLY=0
USBFIX=""
ARGS=()
while (( $# )); do
  case "$1" in
    -l|--list)   LIST_ONLY=1; shift ;;
    -r|--remove) REMOVE=1; shift ;;
    --usb-fix)   USBFIX="${2:?--usb-fix 需要 VID:PID}"; shift 2 ;;
    -h|--help)   sed -n '2,13p' "$0"; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

# ---- 找 p1（boot, vfat）----
if [ -n "$UUID" ]; then
  P2=$(blkid -U "$UUID" 2>/dev/null || true)
  [ -n "$P2" ] || { echo "X 没找到 UUID=$UUID"; exit 1; }
else
  P2=$(blkid -L "$LABEL" 2>/dev/null || true)
  [ -n "$P2" ] || { echo "X 没找到 LABEL=$LABEL（设置 X96_ROOT_LABEL 或 X96_ROOT_UUID）"; exit 1; }
fi
DISK=$(lsblk -no PKNAME "$P2" | head -1)
P1="/dev/${DISK}1"
[ -b "$P1" ] || { echo "X 找不到 boot 分区 $P1"; exit 1; }

# 已挂载就复用，否则临时挂
# 注意：必须 `|| true`。findmnt 在"未挂载"时返回 1，配合 set -e/pipefail 会让
# 整个赋值失败，脚本**无任何输出**直接退出 1（2026-11-15 实测：写完卡 p1 未挂载
# 时 patch-bootargs.sh 静默失败，只有"已挂载"这种巧合情形才跑得通）。
MNT=$(findmnt -no TARGET "$P1" 2>/dev/null | head -1 || true)
TMPMNT=0
if [ -z "$MNT" ]; then
  MNT=$(mktemp -d)
  mount "$P1" "$MNT"
  TMPMNT=1
  trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
fi

UENV="$MNT/uEnv.txt"
[ -f "$UENV" ] || { echo "X $P1 里没有 uEnv.txt"; exit 1; }

CUR=$(grep -E '^APPEND=' "$UENV" | head -1 | sed 's/^APPEND=//')

if [ "$LIST_ONLY" = 1 ]; then
  echo "p1: $P1   挂载点: $MNT"
  echo "APPEND ($(wc -w <<<"$CUR") 个参数):"
  for w in $CUR; do echo "  $w"; done
  exit 0
fi

# ---- USB 掉盘修复套餐 ----
if [ -n "$USBFIX" ]; then
  ARGS+=("usb-storage.quirks=${USBFIX}:u" "usbcore.autosuspend=-1")
fi

[ ${#ARGS[@]} -gt 0 ] || { echo "X 没给参数（-h 看用法）"; exit 1; }

NEW="$CUR"
if [ -n "$REMOVE" ]; then
  for a in "${ARGS[@]}"; do
    # 按 key=value 精确删，也支持只给 key（删 key=*）
    NEW=$(tr ' ' '\n' <<<"$NEW" | grep -vxF "$a" | grep -v "^${a%%=*}=" | paste -sd' ' - || true)
  done
else
  for a in "${ARGS[@]}"; do
    if grep -qwF "$a" <<<"$NEW"; then
      echo "  = 已存在，跳过: $a"
    else
      NEW="$NEW $a"
      echo "  + 追加: $a"
    fi
  done
fi
NEW=$(tr -s ' ' <<<"$NEW" | sed 's/^ //; s/ $//')

[ "$NEW" != "$CUR" ] || { echo "无变化，不写盘"; exit 0; }

BAK="$ROOT/uEnv.txt.bak.$(date +%s)"
cp "$UENV" "$BAK"
echo "  备份: $BAK"

python3 - "$UENV" "$NEW" <<'PY'
import sys, io
path, new = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
out, hit = [], False
for ln in s.splitlines(True):
    if ln.startswith('APPEND=') and not hit:
        out.append('APPEND=' + new + '\n'); hit = True
    else:
        out.append(ln)
if not hit:
    out.append('APPEND=' + new + '\n')
io.open(path, 'w', encoding='utf-8').write(''.join(out))
PY

sync
echo "  写入完成 → $UENV"
echo
echo "新 APPEND:"
for w in $NEW; do echo "  $w"; done
