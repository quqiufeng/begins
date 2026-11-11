#!/usr/bin/env bash
# 一条命令：编内核 → 装模块 → 装内核 → 强制重建显卡驱动 → 重打 initrd。
# 顺序不能反：DKMS 靠 /lib/modules/<ver>/build 这个软链找源码，而这个软链是
# make modules_install 建的；先 make install 后 modules_install 会让驱动编不出来。
#
#   tools/kernel/build-install.sh            # 增量编 + 全套安装
#   tools/kernel/build-install.sh --clean    # 先 make clean
#   JOBS=8 tools/kernel/build-install.sh     # 指定并行度（默认 nproc）
set -euo pipefail

KDIR=${KDIR:-/home/quqiufeng/kernel/src/linux-7.2.12}
JOBS=${JOBS:-$(nproc)}
CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

cd "$KDIR"
if [ "$CLEAN" -eq 1 ]; then
    echo "=== make clean ==="
    make clean
fi

echo "=== 编译（-j$JOBS）==="
make -j"$JOBS"

VER=$(make -s kernelrelease)
echo
echo "=== 覆盖同名版本前留备份（可启动的退路）==="
if [ -f "/boot/vmlinuz-$VER" ]; then
    for f in vmlinuz initrd.img config System.map; do
        [ -f "/boot/$f-$VER" ] && sudo cp -a "/boot/$f-$VER" "/boot/$f-$VER.prev"
    done
    [ -d "/lib/modules/$VER" ] && sudo cp -a "/lib/modules/$VER" "/lib/modules/$VER.prev"
    echo "  已存 *-$VER.prev"
else
    echo "  首次安装该版本，无需备份"
fi

echo
echo "=== 安装模块 + 内核（install 的钩子会强制重建显卡驱动）==="
sudo make -j"$JOBS" modules_install
sudo make install

echo
echo "=== 兜底：再跑一次强制同步（钩子已跑过则为幂等快路径）==="
tools/kernel/sync-drivers.sh -k "$VER"

echo
echo "=== 收尾 ==="
sudo update-grub 2>&1 | tail -2
echo
echo "装好了。跑稳后清理备份："
echo "  sudo rm -f /boot/{vmlinuz,initrd.img,config,System.map}-$VER.prev"
echo "  sudo rm -rf /lib/modules/$VER.prev && sudo update-grub"
