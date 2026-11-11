#!/bin/bash
# remote-install.sh —— 本地产物装到远端小机箱（rsync 不在时也能用）
#
# 用法：tools/kernel/remote-install.sh <版本号> [树目录] [远端]
#   tools/kernel/remote-install.sh 7.2.12-sandy-dbg-20261111
#
# 做四件事：
#   ① INSTALL_MOD_PATH 暂存目录 → modules_install（不动本机 /lib/modules）
#   ② 打包 vmlinuz / config / System.map / modules.tar.gz → scp
#   ③ 远端：落 /lib/modules + /boot，depmod、update-initramfs、update-grub
#   ④ grub-reboot 到新条目（一次性）：新内核起不来 → 再重启自动回老内核
#      第 4 个参数 --persist 则直接设为持久默认（跳过一次性）
set -euo pipefail

ver=${1:?用法: $0 <版本号> [树] [远端] [--persist|--no-grub-reboot]}
tree=${2:-$HOME/kernel/build/sandy-20261111/tree}
host=${3:-192.168.1.68}
work=$(dirname "$tree")
stage=$work/stage-$ver
bundle=$work/bundle-$ver

echo "== ① modules_install 到暂存目录 =="
rm -rf "$stage"
make -C "$tree" INSTALL_MOD_PATH="$stage" modules_install >/dev/null
ko=$(find "$stage/lib/modules/$ver" -name '*.ko*' | wc -l)
modsz=$(du -sh "$stage/lib/modules/$ver" | cut -f1)
echo "   $ko 个模块 / $modsz"

echo "== ② 打包 =="
mkdir -p "$bundle"
cp "$tree/arch/x86/boot/bzImage" "$bundle/vmlinuz-$ver"
cp "$tree/.config" "$bundle/config-$ver"
cp "$tree/System.map" "$bundle/System.map-$ver"
tar -czf "$bundle/modules-$ver.tar.gz" -C "$stage/lib/modules" "$ver"
ls -lh "$bundle"

echo "== ③ 传到 $host =="
scp -q "$bundle"/vmlinuz-* "$bundle"/config-* "$bundle"/System.map-* "$bundle"/modules-*.tar.gz "$host":/tmp/
scp -q "$(dirname "$0")/remote-stage.sh" "$(dirname "$0")/set-default-kernel.sh" "$host":/tmp/

echo "== ④ 远端安装 =="
# 第三个参数透传给 remote-stage.sh：--persist 直接转正 / --no-grub-reboot 只落盘
mode=${4:-}
ssh -t "$host" "sudo bash /tmp/remote-stage.sh '$ver' $mode"
