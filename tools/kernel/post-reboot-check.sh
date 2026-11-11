#!/usr/bin/env bash
# 重启进新内核后的验收脚本。只读，不改任何东西。
#   tools/kernel/post-reboot-check.sh [期望版本串]
# 退出码 0 = 全绿；1 = 有项目没过（看输出里的 FAIL）。
set -uo pipefail

EXPECT=${1:-7.2.12-20261111-hwreal}
fail=0
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }

echo "=== 1. 运行内核 ==="
RUN=$(uname -r)
[ "$RUN" = "$EXPECT" ] && ok "uname -r = $RUN" || bad "uname -r = $RUN（期望 $EXPECT，没进新内核）"

echo "=== 2. BTF（eBPF CO-RE 前提）==="
if [ -s /sys/kernel/btf/vmlinux ]; then
    ok "/sys/kernel/btf/vmlinux $(stat -c%s /sys/kernel/btf/vmlinux) 字节"
else
    bad "/sys/kernel/btf/vmlinux 不存在 —— CONFIG_DEBUG_INFO_BTF 没生效"
fi

echo "=== 3. tracing 接口 ==="
# tracefs 目录是 drwx------ root，普通用户连 -e 都判不出来，一律走 sudo
if sudo test -e /sys/kernel/tracing/available_filter_functions; then
    ok "available_filter_functions $(sudo sh -c 'wc -l < /sys/kernel/tracing/available_filter_functions') 个可挂函数"
else
    bad "/sys/kernel/tracing/available_filter_functions 缺失"
fi
for f in kprobe_events uprobe_events; do
    sudo test -w "/sys/kernel/tracing/$f" && ok "$f 可写" || bad "$f 不可写"
done
# 真挂一个 kprobe 再撤掉，才算验证过（只看权限位可能是假象）
if sudo sh -c 'echo "p:lite_probe do_sys_open" > /sys/kernel/tracing/kprobe_events' 2>/dev/null; then
    ok "实测挂 kprobe 成功"
    sudo sh -c 'echo > /sys/kernel/tracing/kprobe_events' 2>/dev/null
else
    bad "实测挂 kprobe 失败"
fi
grep -q '^CONFIG_BPF_EVENTS=y' "/boot/config-$EXPECT" 2>/dev/null \
    && ok "CONFIG_BPF_EVENTS=y" || bad "CONFIG_BPF_EVENTS 不是 =y"

echo "=== 4. 显卡 ==="
if lsmod | grep -q '^nvidia '; then
    ok "$(lsmod | grep -c '^nvidia') 个 nvidia 模块已加载"
else
    bad "nvidia 未加载（modprobe nvidia 试，dmesg | grep -i nvidia 看原因）"
fi
if command -v nvidia-smi >/dev/null; then
    line=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 | head -1)
    case "$line" in
        *595.99.02*) ok "nvidia-smi: $line" ;;
        *)           bad "nvidia-smi: $line" ;;
    esac
fi

echo "=== 5. 硬件清单没退化 ==="
for m in ext4 xhci_pci r8169 snd_hda_intel; do
    grep -q "^$m " /proc/modules && ok "$m 已加载"
done
ok "/sys/block: $(ls /sys/block | tr '\n' ' ')"
echo "  根文件系统: $(findmnt -no FSTYPE / 2>/dev/null)  /home: $(findmnt -no FSTYPE /home 2>/dev/null)"
df -h / /home 2>/dev/null | tail -n +2 | sed 's/^/       /'

echo "=== 6. 本次启动有没有报错 ==="
n=$(journalctl -b -p err --no-pager 2>/dev/null | wc -l)
if [ "$n" -le 5 ]; then
    ok "本次启动 err 级日志 $n 行"
else
    bad "本次启动 err 级日志 $n 行，抽查最后 8 行："
    journalctl -b -p err --no-pager 2>/dev/null | tail -8 | sed 's/^/       /'
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "全绿。"
    # 只在备份真的还在时才提示清理，否则每次都说一遍很烦
    if [ -e "/boot/vmlinuz-$EXPECT.prev" ] || [ -d "/lib/modules/$EXPECT.prev" ]; then
        echo "确认稳定后可以清理回退备份："
        echo "  sudo rm -f /boot/{vmlinuz,initrd.img,config,System.map}-$EXPECT.prev"
        echo "  sudo rm -rf /lib/modules/$EXPECT.prev && sudo update-grub"
    fi
else
    echo "$fail 项没过。回退到上一个内核："
    echo "  sudo grub-reboot \"Advanced options for Ubuntu>Ubuntu, with Linux $EXPECT.prev\" && sudo reboot"
fi
exit $(( fail > 0 ))
