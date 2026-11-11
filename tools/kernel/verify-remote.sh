#!/bin/bash
# verify-remote.sh —— 远端新内核验收：启动 / 驱动 / 调试设施 / 体积
# 用法：tools/kernel/verify-remote.sh [远端] [版本号]
set -uo pipefail
host=${1:-192.168.1.68}
ver=${2:-}
pass=0; fail=0
ok(){ echo "  ✅ $*"; pass=$((pass+1)); }
bad(){ echo "  ❌ $*"; fail=$((fail+1)); }

r(){ ssh -o BatchMode=yes "$host" "$@" 2>&1; }

echo "== 0. 启动 =="
running=$(r 'uname -r')
echo "  运行中: $running"
if [ -n "$ver" ]; then
    [ "$running" = "$ver" ] && ok "新内核在跑" || bad "期望 $ver，实际 $running"
fi
# 可引导内核数 = 有 vmlinuz 且有对应 /lib/modules 的（.prev 之类备份不算自身版本）
kcount=$(r 'n=0; for f in /boot/vmlinuz-*; do b=${f#/boot/vmlinuz-}; [ -d "/lib/modules/$b" ] && n=$((n+1)); done; echo $n')
if [ "$(r 'cat /proc/sys/kernel/panic')" = "10" ]; then
    if [ "${kcount:-0}" -le 1 ] 2>/dev/null; then
        ok "panic=10 生效（只有这份内核，panic 后重启回同一份，无退路）"
    else
        ok "panic=10 生效（$kcount 个内核可引导，panic 后可回落）"
    fi
else
    bad "panic 不是 10"
fi
[ "${kcount:-0}" -le 1 ] 2>/dev/null && echo "  · 注意：系统里只剩 $kcount 个可引导内核，出问题无法远程切回"
true
r 'dmesg -l err,crit,alert' | grep -v '^$' | head -5 | sed 's/^/  · /'

echo "== 1. 驱动 =="
pci=$(r 'for d in /sys/bus/pci/devices/*; do printf "%s %s\n" "$(cat $d/uevent | grep ^PCI_ID= | cut -d= -f2)" "$(basename $(readlink -f $d/driver 2>/dev/null) 2>/dev/null)"; done')
echo "$pci" | sed 's/^/  /'
for want in i915 snd_hda_intel r8169 nvme ahci ehci-pci lpc_ich i801_smbus; do
    echo "$pci" | grep -q " $want$" && ok "PCI 驱动 $want 已绑定" || bad "PCI 驱动 $want 未绑定"
done
r 'ls /dev/nvme0n1 /dev/dri/card*' >/dev/null 2>&1 && ok "块设备/DRM 节点存在" || bad "缺 /dev/nvme0n1 或 /dev/dri/card0"
r 'grep -c . /proc/asound/cards >/dev/null && head -2 /proc/asound/cards | tail -1' | sed 's/^/  · 声卡: /'
r 'ip -br addr show enp2s0 | grep -q " UP "' && ok "网卡 enp2s0 UP" || bad "enp2s0 没起来"
r 'lsusb | wc -l' | sed 's/^/  · USB 设备数: /'
r 'cat /proc/sys/kernel/tainted' | grep -qx 0 && ok "内核无 taint" || bad "内核有 taint（闭源模块？）"

echo "== 2. 调试设施 =="
# tracefs 根目录是 0700 root，普通用户连 ls 都进不去 —— 探针一律走 sudo -n（远端配了免密）
tracers=$(r 'sudo -n cat /sys/kernel/tracing/available_tracers 2>/dev/null || sudo -n cat /sys/kernel/debug/tracing/available_tracers 2>/dev/null')
echo "  · tracers: ${tracers:-<空>}"
echo "$tracers" | grep -q function_graph && ok "function_graph 可用" || bad "function_graph 不可用"
echo "$tracers" | grep -q function && ok "function tracer 可用" || bad "function tracer 不可用"
r 'sudo -n test -w /sys/kernel/tracing/kprobe_events' >/dev/null 2>&1 \
    && ok "kprobe_events 可写" || bad "kprobe_events 不可用"
nfn=$(r 'sudo -n cat /sys/kernel/tracing/available_filter_functions 2>/dev/null | wc -l')
echo "$nfn" | grep -qE '^[0-9]+$' && [ "$nfn" -gt 1000 ] \
    && ok "可 kprobe 的函数列表可读: $nfn 个" || bad "available_filter_functions 不可读（${nfn:-空}）"
r 'test -r /sys/kernel/btf/vmlinux && echo "$(stat -c%s /sys/kernel/btf/vmlinux)"' | grep -qE '^[0-9]+$' \
    && ok "BTF 在内核里（bpftrace/BCC 能用）: $(r 'stat -c%s /sys/kernel/btf/vmlinux') 字节" || bad "没有 /sys/kernel/btf/vmlinux"
r 'sudo -n test -w /proc/sysrq-trigger' >/dev/null 2>&1 && ok "/proc/sysrq-trigger 可写" || bad "sysrq 不可写"
r 'test -d /sys/kernel/debug' >/dev/null 2>&1 && ok "debugfs 挂载" || bad "debugfs 没挂"
nu=$(r 'sudo -n grep -c uprobe /proc/kallsyms')
echo "$nu" | grep -qE '^[0-9]+$' && [ "$nu" -gt 0 ] \
    && ok "uprobe 符号在内核里: $nu 个（eCapture 可用）" || bad "没找到 uprobe 符号"
r 'command -v perf bpftrace trace-cmd 2>/dev/null' | sed 's/^/  · 工具: /'

echo "== 3. 网络（netfilter/nftables/iptables）=="
# 注意：dbg2 第一版把 CONFIG_NETFILTER 全裁了，nft/iptables 直接不可用。
# 这里不只查模块存在，还要真写规则、真看 counter 涨，避免「能加载但不通」蒙混过关。
nfmods=$(r 'sudo -n modprobe nf_tables 2>&1; sudo -n modprobe nft_ct 2>&1; sudo -n modprobe iptable_filter 2>&1; lsmod | grep -cE "^(nf_tables|nft_ct|iptable_filter) "')
[ "${nfmods:-0}" -ge 3 ] && ok "nf_tables/nft_ct/iptable_filter 模块可加载" || bad "netfilter 模块加载失败: $(echo "$nfmods" | tail -1)"

r 'sudo -n nft list ruleset' >/dev/null 2>&1 \
    && ok "nft list ruleset 可用（nfnetlink 通路通）" || bad "nft list ruleset 失败"

# 真建表/链/规则：; 在单引号里，避开 ssh 两层转义
r "sudo -n nft delete table ip _vt 2>/dev/null; printf 'add table ip _vt\nadd chain ip _vt o { type filter hook output priority 0 ; }\nadd rule ip _vt o tcp dport 9 counter drop\n' | sudo -n nft -f -" >/dev/null 2>&1
r 'sudo -n nft list table ip _vt' 2>/dev/null | grep -q 'counter' \
    && ok "nft 可写入规则（table/chain/rule 落盘成功）" || bad "nft 写规则失败"

pk=$(r "sudo -n timeout 1 bash -c 'echo x > /dev/tcp/127.0.0.1/9' >/dev/null 2>&1; sudo -n nft list table ip _vt 2>/dev/null | grep -oE 'packets [0-9]+' | head -1 | awk '{print \$2}'")
if [ "${pk:-0}" -ge 1 ] 2>/dev/null; then
    ok "规则真生效：打到 :9 的包被计数 $pk 个（数据面通）"
else
    bad "规则没生效：counter=$pk（数据面不通）"
fi
r 'sudo -n nft delete table ip _vt 2>/dev/null; true' >/dev/null 2>&1

r 'sudo -n iptables -t filter -L -n >/dev/null 2>&1' && ok "iptables filter 表可用（兼容层）" || bad "iptables filter 表不可用"
r 'sudo -n iptables -t nat -L -n >/dev/null 2>&1' && ok "iptables nat 表可用（兼容层）" || bad "iptables nat 表不可用"

echo "== 4. 体积 =="
r 'ls -l /boot/vmlinuz-$(uname -r) /boot/initrd.img-$(uname -r) 2>/dev/null | awk "{print \"  · \"\$9\": \"\$5\" 字节\"}"'
r 'du -sh /lib/modules/$(uname -r) | sed "s/^/  · 模块: /"'
r 'free -m | awk "/^Mem:/{print \"  · 内存占用: \"\$(NF-2)\" MB / \"\$2\" MB\"}"'
r 'awk "/^MemTotal:/{t=\$2}/^MemAvailable:/{a=\$2}END{printf \"  · 开机后可用 %.0f MB (%.0f%% 剩余)\\n\", a/1024, a/t*100}" /proc/meminfo'

echo
echo "结果: PASS=$pass FAIL=$fail"

# 全绿且确实跑在目标内核上 → 把它转成 GRUB 持久默认（幂等，已是默认就跳过）
if [ "$fail" -eq 0 ] && [ -n "$ver" ] && [ "$running" = "$ver" ]; then
    echo "== 5. 转正为默认内核 =="
    bash "$(dirname "$0")/set-default-kernel.sh" "$ver" "$host" | sed 's/^/  /'
fi
