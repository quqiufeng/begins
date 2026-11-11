#!/bin/bash
# set-default-kernel.sh —— 把指定内核版本设为 GRUB **持久默认**（不是 next_entry 那种一次性）
# 用法（root 在被设的机器上跑）：
#     sudo bash set-default-kernel.sh <版本号>
# 从远端机器执行为 root（远端需配免密 sudo）：
#     tools/kernel/set-default-kernel.sh <版本号> [user@host]
# 做的事：备份 /etc/default/grub → 改 GRUB_DEFAULT → update-grub → 清 next_entry 残留
set -euo pipefail
ver=${1:?用法: $0 <版本号> [user@host]}
host=${2:-}

if [ -n "$host" ]; then
    ssh -o BatchMode=yes "$host" "sudo -n bash -s -- '$ver'" < "$0"
    exit $?
fi

[ "$(id -u)" = 0 ] || { echo "需要 root（或用第二个参数指定远端 host）" >&2; exit 1; }

# 只从 menuentry 行取标题：grub.cfg 顶部还有 `set default="…"` 也会含 "with Linux $ver"，
# 那种行尾部带引号，直接 grep 会把引号带进来写成 GRUB_DEFAULT="…"" 把 grub 弄坏（踩过）
title=$(sed -n "s/^[[:space:]]*menuentry '\\(Ubuntu, with Linux $ver\\)' .*/\\1/p" \
        /boot/grub/grub.cfg | head -1)
[ -n "$title" ] || {
    echo "grub.cfg 里没有 $ver 的条目 —— 先跑 remote-stage.sh 落盘" >&2
    exit 1
}

# 老内核还在时会进「Advanced options」子菜单；只有一个内核时是顶层条目
if grep -q "submenu 'Advanced options for Ubuntu'" /boot/grub/grub.cfg; then
    want="Advanced options for Ubuntu>$title"
else
    want="$title"
fi
cur=$(sed -n 's/^GRUB_DEFAULT=//p' /etc/default/grub)
echo "  目标条目: $want"
echo "  当前默认: $cur"

if [ "\"$want\"" = "$cur" ]; then
    echo "  ✅ 已经是默认内核，无需修改"
else
    cp -a /etc/default/grub "/etc/default/grub.bak-lite-default-$(date +%Y%m%d-%H%M%S)"
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$want\"|" /etc/default/grub
    if ! update-grub >/dev/null 2>&1 || ! grub-script-check /boot/grub/grub.cfg 2>/dev/null; then
        echo "  ❌ update-grub/语法检查失败，回滚 /etc/default/grub" >&2
        cp -a "$(ls -t /etc/default/grub.bak-lite-default-* | head -1)" /etc/default/grub
        update-grub >/dev/null 2>&1
        exit 1
    fi
    echo "  ✅ 已写入 /etc/default/grub: $(sed -n 's/^GRUB_DEFAULT=//p' /etc/default/grub)"
fi

# 清掉之前 grub-reboot 留下的一次性条目，避免「到底按哪个起」的歧义
if grub-editenv /boot/grub/grubenv list 2>/dev/null | grep -q '^next_entry=.'; then
    grub-editenv /boot/grub/grubenv unset next_entry
    echo "  · 已清除遗留的 next_entry"
fi

# 复核：GRUB_DEFAULT 指向的条目在 grub.cfg 里真的存在
name=$(sed -n 's/^GRUB_DEFAULT="\(.*\)"/\1/p' /etc/default/grub)
last=${name##*>}
grep -qF "menuentry '$last'" /boot/grub/grub.cfg \
    && echo "  ✅ 复核通过：下次重启进 $ver" \
    || { echo "  ❌ 复核失败：grub.cfg 里找不到 '$last'" >&2; exit 1; }
