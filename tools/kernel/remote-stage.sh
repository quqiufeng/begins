#!/bin/bash
# remote-stage.sh —— 在远端以 root 跑：落盘新内核 + initramfs + grub，安排一次性启动
# 用法：sudo bash remote-stage.sh <版本号> [--persist|--no-grub-reboot]
#   --persist        直接设为 GRUB 持久默认（一次到位，失败会 panic 重启后仍旧回它 → 慎用）
#   --no-grub-reboot 只落盘，不动启动项（手工 reboot 前的稳妥选择）
#   省略             一次性启动条目：首启失败自动回老内核，验收通过后由 verify-remote.sh 转正
set -euo pipefail

ver=${1:?用法: $0 <版本号>}
mode=${2:-}
cd /tmp

for f in "vmlinuz-$ver" "config-$ver" "System.map-$ver" "modules-$ver.tar.gz"; do
    [ -f "$f" ] || { echo "缺 $f（先 scp 过来）" >&2; exit 1; }
done

echo "== 模块 → /lib/modules/$ver =="
rm -rf "/lib/modules/$ver"
tar -xzf "modules-$ver.tar.gz" -C /lib/modules
chown -R root:root "/lib/modules/$ver"
depmod -a "$ver"
echo "   $(find /lib/modules/$ver -name '*.ko*' | wc -l) 个模块，$(du -sh /lib/modules/$ver | cut -f1)"

echo "== 内核 → /boot =="
install -m 644 -o root -g root "vmlinuz-$ver" "/boot/vmlinuz-$ver"
install -m 644 -o root -g root "config-$ver" "/boot/config-$ver"
install -m 644 -o root -g root "System.map-$ver" "/boot/System.map-$ver"
ls -lh "/boot/vmlinuz-$ver"

echo "== initramfs =="
update-initramfs -c -k "$ver"
ls -lh "/boot/initrd.img-$ver"

echo "== grub =="
# panic=10：新内核真 panic 了也会自己重启，下一次启动回到默认的老内核
if ! grep -q '^GRUB_CMDLINE_LINUX=".*panic=10' /etc/default/grub; then
    cp -a /etc/default/grub "/etc/default/grub.bak-lite-$(date +%Y%m%d)"
    sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 panic=10"/' /etc/default/grub
    sed -i 's/^GRUB_CMDLINE_LINUX=" /GRUB_CMDLINE_LINUX="/' /etc/default/grub
    echo "   + 内核命令行加 panic=10"
fi
update-grub >/dev/null

# 只从 menuentry 行取（顶部 `set default="…"` 也含 "with Linux $ver"，会把尾部引号带进来）
title=$(sed -n "s/^[[:space:]]*menuentry '\\(Ubuntu, with Linux $ver\\)' .*/\\1/p" \
        /boot/grub/grub.cfg | head -1)
[ -n "$title" ] || { echo "grub.cfg 里没找到 $ver 的条目" >&2; exit 1; }
echo "   条目: $title"
echo "   当前默认: $(grep -E '^GRUB_DEFAULT' /etc/default/grub)"

case "$mode" in
    --persist)
        bash /tmp/set-default-kernel.sh "$ver" || {
            echo "   set-default-kernel.sh 失败，回退成一次性条目" >&2
            grub-reboot "Advanced options for Ubuntu>$title"
        }
        echo "   已设为**持久默认**内核 = $ver"
        ;;
    --no-grub-reboot)
        echo "   未改启动项（--no-grub-reboot）"
        ;;
    *)
        grub-reboot "Advanced options for Ubuntu>$title"
        echo "   已设为「下一次启动」= $ver（一次性；失败重启回老内核）"
        echo "   验收通过后转正：tools/kernel/set-default-kernel.sh $ver <远端>"
        ;;
esac

echo "== 就绪：确认无误后 reboot =="
