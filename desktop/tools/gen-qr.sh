#!/bin/sh
# gen-qr.sh — 生成桌面「更新 Key」二维码（assets/icons/qr.png）
#
# 二维码内容是 8080 那把初始化页（lite setup --host 0.0.0.0 --port 8080，
# 见 /etc/systemd/system/lite-setup.service）：手机扫码即可改 DEEPSEEK_API_KEY，
# 不用把电视上的键盘/遥控器拿来打字。
#
# 出图走 tools/gen_qr.lua：LuaJIT FFI 直接调系统 libqrencode.so.4 + libz.so.1，
# 不走 qrencode CLI —— CLI 的 -s/-m 语义随发行版漂，装没装也两说；FFI 版一个文件、
# 进程内出 PNG，改了参数立刻可见。CLI 只留作兜底（没有 luajit 的极老镜像）。
#
# 内容来源优先级：$DESKTOP_QR_URL > 参数 > http://<第一个非回环 IPv4>:8080/
# 之所以不写死 IP：盒子是 DHCP，换网就废。IP 由 gen_qr.lua 用 getifaddrs 取。
# 图标必须白底黑块：反色（暗底亮块）一半以上手机扫不出来，别为了配暗色主题反色。
#
# 用法：tools/gen-qr.sh [URL]   （改了 IP/端口就再跑一次，桌面重开即生效）

set -e
cd "$(dirname "$0")/.."

if command -v luajit >/dev/null 2>&1; then
	exec luajit tools/gen_qr.lua --scale 16 --margin 4 --level M "$@"
fi

# ---- 兜底：qrencode CLI ----
url=${1:-${DESKTOP_QR_URL:-}}
if [ -z "$url" ]; then
	ip=$(ip -4 -o addr show scope global 2>/dev/null | awk "NR==1{split(\$4,a,\"/\"); print a[1]}")
	[ -n "$ip" ] || ip=127.0.0.1
	url="http://$ip:8080/"
fi
command -v qrencode >/dev/null 2>&1 || { echo "缺 luajit 与 qrencode（apt install qrencode）" >&2; exit 1; }
qrencode -l M -s 16 -m 4 -o assets/icons/qr.png "$url"
echo "qr.png <- $url"
