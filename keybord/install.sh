#!/bin/bash
# install.sh — 把 keybd 部署到盒子（/opt/keybord）并接管遥控器
#
#   ./install.sh                 # 拷到 192.168.1.121:/opt/keybord 并起服务
#   ./install.sh --no-service    # 只拷文件
#   HOST=192.168.1.121 PORT=22 ./install.sh
set -eu

HOST=${HOST:-192.168.1.121}
PORT=${PORT:-22}
DEST=${DEST:-/opt/keybord}
SRC=$(cd "$(dirname "$0")" && pwd)
# 系统 luajit deb 已卸载（2026-11-18），统一走自编译版；可用 LUAJIT=... 覆盖
LUAJIT=${LUAJIT:-/opt/reader/bin/luajit}
UNIT=/etc/systemd/system/keybd.service

echo "==> 拷到 $HOST:$DEST"
ssh -p "$PORT" "root@$HOST" "mkdir -p $DEST/apps $DEST/maps $DEST/keys"
scp -P "$PORT" -q "$SRC"/keybd.lua "$SRC"/act.lua "$SRC"/explore.lua "$SRC"/sock.lua \
	"$SRC"/evdev.lua "$SRC"/keynames.lua "$SRC"/pctl.lua "root@$HOST:$DEST/"
# libpctl.so：播放器控制面 FFI（hevcdec/pctl_ffi.c 编出来的），有就一起装
SO=$(ls "$SRC"/../hevcdec/libpctl-aarch64.so 2>/dev/null || true)
[ -n "$SO" ] && scp -P "$PORT" -q "$SO" "root@$HOST:$DEST/libpctl.so"
scp -P "$PORT" -q "$SRC"/apps/*.lua "root@$HOST:$DEST/apps/"
# maps/<app>.lua：实测键位覆盖（改键位只动这里，不用碰 apps/）
[ -n "$(ls "$SRC"/maps/*.lua 2>/dev/null)" ] && scp -P "$PORT" -q "$SRC"/maps/*.lua "root@$HOST:$DEST/maps/"
# keys/<app>.lua：第二步落地的固定脚本（键码表 + 执行器），按键的唯一入口
scp -P "$PORT" -q "$SRC"/keys/base.lua "$SRC"/keys/*.lua "root@$HOST:$DEST/keys/"
[ -f "$SRC/config.lua" ] && scp -P "$PORT" -q "$SRC/config.lua" "root@$HOST:$DEST/"

if [ "${1:-}" = "--no-service" ]; then
	echo "==> 跳过服务安装"
	exit 0
fi

echo "==> 写 $UNIT"
ssh -p "$PORT" "root@$HOST" "cat > $UNIT" <<EOF
[Unit]
Description=keybd remote/keyboard dispatcher (LuaJIT, per-app automation)
After=multi-user.target

[Service]
Type=simple
WorkingDirectory=/opt/keybord
Environment=KEYBD_ROOT=/opt/keybord
Environment=LOG=/tmp/keybd.log
Environment=GRAB=1
Environment=REPEAT_MS=220
Environment=DEDUP_MS=40
Environment=DISPATCH=exec
ExecStart=$LUAJIT /opt/keybord/keybd.lua
Restart=always
RestartSec=2
StandardOutput=append:/tmp/keybd.log
StandardError=append:/tmp/keybd.log

[Install]
WantedBy=multi-user.target
EOF

echo "==> 停掉旧的按键守护，避免抢设备"
ssh -p "$PORT" "root@$HOST" "
  systemctl disable --now reader-remote.service 2>/dev/null || true
  pkill -f 'rcinputd-aarch64' 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable keybd.service >/dev/null 2>&1
  systemctl restart keybd.service || true
  sleep 1.5
  systemctl --no-pager --lines=8 status keybd.service | head -20 || true"

echo
echo "==> 自检"
ssh -p "$PORT" "root@$HOST" "$LUAJIT /opt/keybord/act.lua --apps; echo
  $LUAJIT -e 'dofile(\"/opt/keybord/keys/reader.lua\")' --list | head -8
  echo; $LUAJIT /opt/keybord/keybd.lua --apps | head -12"
