#!/bin/bash
# box-cog.sh —— 在盒子（x96/x98h）上起停 cog 浏览器直出（DRM/KMS），并抓 HDMI 画面。
# 用法：box-cog.sh start [URL] | stop | status | reload | open URL | prev | shot [out.raw]
# 依赖：/usr/bin/cog（Debian 包 cog 0.18.x）、/root/grabscreen-aarch64、dbus-daemon（cogctl 需要）
set -u
BUS=/tmp/cogrt/bus
DIR=/tmp/cogrt
RAW=$DIR/shot.raw
LOG=$DIR/cog.log
GRAB=/root/grabscreen-aarch64
mkdir -p "$DIR"

bus_up() {
  # 固定 socket 起一个 session bus，供 cog 与 cogctl 共用
  [ -S "$BUS" ] && return 0
  dbus-daemon --session --address="unix:path=$BUS" --fork --print-pid >/dev/null 2>&1 || return 1
  sleep 0.3
  [ -S "$BUS" ]
}
export_cog_env() { export DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS"; }

cog_pid() { pgrep -x cog | head -1; }

cmd_start() {
  local url="${1:-about:blank}"
  # desktop 是 Restart=always，光 stop 会被 systemd 拉回来抢 DRM master
  # → cog 报 "Cannot set mode (Permission denied)"，屏幕停在桌面最后一帧。
  # 必须 mask --runtime（只在本 runtime 生效，重启盒子自动恢复）。
  systemctl mask --runtime desktop >/dev/null 2>&1
  systemctl stop desktop >/dev/null 2>&1; sleep 2
  pkill -x cog >/dev/null 2>&1; sleep 1
  bus_up || { echo "dbus 起不来"; exit 1; }
  export_cog_env
  # renderer=gles 是关键：cog 自己 gbm 分配 LINEAR 缓冲做 scanout，
  # 默认 renderer=modeset 会把 WebProcess 的 AFBC buffer 直接挂 plane，sun4i 只认 LINEAR → EINVAL。
  env cog -P drm -O renderer=gles "$url" >"$LOG" 2>&1 &
  local i
  for i in $(seq 1 30); do
    sleep 1
    cog_pid >/dev/null && grep -qa "Load" "$LOG" && break
  done
  echo "cog pid=$(cog_pid) url=$url"
  echo "desktop=$(systemctl is-active desktop) bus=$BUS"
  grep -aiE "fail|error|CRITICAL" "$LOG" | head -3
}

cmd_stop() {
  pkill -x cog >/dev/null 2>&1; sleep 3
  systemctl unmask --runtime desktop >/dev/null 2>&1
  systemctl start desktop >/dev/null 2>&1; sleep 2
  echo "cog=$(cog_pid || echo none) desktop=$(systemctl is-active desktop)"
}

cmd_status() {
  echo "cog pid: $(cog_pid || echo none)"
  echo "desktop: $(systemctl is-active desktop)"
  export_cog_env
  [ -n "$(cog_pid)" ] && echo "cogctl appid: $(cogctl appid 2>&1)"
  ss -ltn 2>/dev/null | grep -E ":9222" | sed 's/^/inspector: /'
  grep -aiE "Load|fail|error" "$LOG" 2>/dev/null | tail -3
}

cmd_ctl() {  # open/reload/prev/next/quit/ping
  export_cog_env
  local sub="$1"; shift
  case "$sub" in
    ping)     cogctl ping 2>&1 && echo "(ping ok)" ;;
    *)        cogctl "$sub" "$@" 2>&1 ;;
  esac
}

cmd_shot() {
  local out="${1:-$RAW}"
  "$GRAB" /dev/dri/card0 "$out" >/dev/null 2>&1
  echo "$out $(stat -c %s "$out" 2>/dev/null)"
}

case "${1:-status}" in
  start)  shift; cmd_start "${1:-}" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  open|reload|previous|next|ping|quit) cmd_ctl "$@" ;;
  shot)   shift; cmd_shot "${1:-$RAW}" ;;
  *) echo "用法: $0 start [URL] | stop | status | open URL | reload | previous | next | ping | quit | shot [out.raw]"; exit 2 ;;
esac
