#!/usr/bin/env bash
# 强制把 DKMS 的显卡驱动对齐到当前刚编出来的内核。
#
# dkms autoinstall 的坑：LOCALVERSION 不变时 DKMS 用「内核版本串」当 key，
# 认为这个内核已经构建过 → 直接跳过，.ko 还是上一次编的。
# vermagic 相同、module_layout CRC 也往往相同，于是模块能"半个"加载进去，
# 个别符号报 "disagrees about version of symbol"，症状像驱动坏了而不是没重编。
# 所以这里一律 --force，并用 Module.symvers 逐符号验 CRC，不验等于没做。
#
# 用法：
#   tools/kernel/sync-drivers.sh                 # 强制重建 + 校验 + 重打 initrd
#   tools/kernel/sync-drivers.sh --check         # 只体检，不改任何东西
#   tools/kernel/sync-drivers.sh -k <ver>        # 指定内核版本串（默认 make kernelrelease）
#   tools/kernel/sync-drivers.sh --no-initramfs  # 跳过 update-initramfs
#
# 退出码：0 全部对齐；1 有模块 CRC 不一致或构建失败；2 环境/参数问题。

set -euo pipefail

KDIR=${KDIR:-/home/quqiufeng/kernel/src/linux-7.2.12}
MODULES=("nvidia 595.99.02" "gpu-unlock 1.0.0" "v4l2loopback 0.12.7")
CHECK=0
INITRAMFS=1
VER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --no-initramfs) INITRAMFS=0 ;;
        -k) VER=${2:?}; shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -d "$KDIR" ] || { echo "源码树不存在: $KDIR" >&2; exit 2; }

if [ -z "$VER" ]; then
    VER=$(make -s -C "$KDIR" kernelrelease 2>/dev/null) || true
fi
[ -n "$VER" ] || { echo "取不到内核版本串，用 -k 指定" >&2; exit 2; }

SYMVERS=$KDIR/Module.symvers
[ -f "$SYMVERS" ] || { echo "缺 $SYMVERS，先把内核编完" >&2; exit 2; }

MODDIR=/lib/modules/$VER
echo "内核版本串 : $VER"
echo "源码树     : $KDIR"
echo "模块目录   : $MODDIR"
if [ ! -d "$MODDIR/build" ]; then
    if [ "$CHECK" -eq 1 ]; then
        echo "  ⚠ $MODDIR/build 不存在 —— 还没跑 make modules_install，DKMS 编不了"
    else
        echo "!! $MODDIR/build 不存在：先跑 sudo make modules_install，否则 DKMS 无源码可编。" >&2
        echo "   （正确顺序：make -jN  →  sudo make modules_install  →  sudo make install）" >&2
        exit 1
    fi
fi

# ---- CRC 体检：模块期望的符号版本 vs 新内核 Module.symvers ----
# 只看内核导出的符号；nv*/nvKms* 这类是 nvidia 模块间互供的，本来就不在 Module.symvers 里。
verify() {
    python3 - "$SYMVERS" "$MODDIR/updates/dkms" "${MODULES[@]}" <<'PY'
import subprocess, sys, os
symvers, moddir, mods = sys.argv[1], sys.argv[2], sys.argv[3:]
have = {}
for line in open(symvers):
    p = line.split('\t')
    if len(p) >= 2 and p[1]:
        have[p[1]] = p[0].lower()

bad_total = 0
for spec in mods:
    dkms_name, dkms_ver = spec.split()
    prefix = dkms_name.replace('-', '_')
    kos = sorted(f for f in os.listdir(moddir)
                 if f.endswith('.ko') and f.startswith(prefix)) if os.path.isdir(moddir) else []
    if not kos:
        print(f"  {dkms_name:14s} ❌ 模块目录里没有 .ko")
        bad_total += 1
        continue
    for ko in kos:
        out = subprocess.run(['modprobe', '--dump-modversions', os.path.join(moddir, ko)],
                             capture_output=True, text=True).stdout
        want = [l.split() for l in out.splitlines() if len(l.split()) >= 2]
        bad = [(s, c, have[s]) for c, s in want if s in have and have[s] != c.lower()]
        ext = [s for c, s in want if s not in have]
        bad_total += len(bad)
        flag = 'OK' if not bad else 'FAIL'
        print(f"  {ko:22s} 内核符号 {len(want)-len(ext):3d}  CRC不一致 {len(bad):2d}  "
              f"模块间互供 {len(ext):3d}  {flag}")
        for s, a, b in bad[:6]:
            print(f"      {s}: 模块 {a} vs 内核 {b}")
if bad_total == 0:
    print("\n全部模块与内核符号版本一致，可以直接重启。")
else:
    print(f"\n仍有 {bad_total} 个符号 CRC 不一致 —— 别重启，先跑一次不带 --check 的本脚本。")
sys.exit(0 if bad_total == 0 else 1)
PY
}

if [ "$CHECK" -eq 1 ]; then
    echo "=== 体检（不做任何修改）==="
    verify; exit $?
fi

# ---- 强制重建 ----
echo
echo "=== 强制重建 DKMS（--force，绕开 autoinstall 的跳过逻辑）==="
for spec in "${MODULES[@]}"; do
    read -r m v <<<"$spec"
    if ! dkms status -m "$m" -v "$v" -k "$VER" 2>/dev/null | grep -q .; then
        echo "  $m/$v: 该内核下无记录，跳过"
        continue
    fi
    echo "--- $m/$v ---"
    sudo dkms build  -m "$m" -v "$v" -k "$VER" --force 2>&1 | grep -E 'Building|Error|error:|done' || true
    sudo dkms install -m "$m" -v "$v" -k "$VER" --force 2>&1 | grep -E 'Installing|Error|error:|depmod' || true
done

echo
echo "=== 校验符号版本 ==="
if ! verify; then
    echo "!! 校验未通过，initrd 不重打。" >&2
    exit 1
fi

# ---- 重打 initrd：磁盘上的新 .ko 得真正进到 early boot 镜像里 ----
if [ "$INITRAMFS" -eq 1 ]; then
    echo
    echo "=== 重打 initramfs ==="
    sudo update-initramfs -u -k "$VER" 2>&1 | grep -vE '^W: (Possible missing firmware|mkconf|mdadm)' || true
fi

echo
echo "完成。重启前建议："
echo "  uname -r                       # 确认真的重启进新内核了"
echo "  nvidia-smi                     # 驱动版本对得上"
echo "  mount | grep squashfs          # 文件系统那几项还在"
