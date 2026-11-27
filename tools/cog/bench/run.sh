#!/bin/bash
# cogbench/run.sh —— 单档：run.sh NAME "ENV..." "cog额外参数"
# 量 A(局部脏区)/B(全屏重绘) 的 rAF fps + cog+WPEWebProcess 的 CPU%
set -u
DIR=/tmp/cogbench
LOG=/tmp/cogrt/cogbench.log
FPS=$DIR/fps.log
URL="${URL:-http://127.0.0.1:8080/page.html}"
WAIT="${WAIT:-20}"
NAME="${1:-base}"; ENVS="${2:-}"; CARGS="${3:-}"

pids() { pgrep -x cog; pgrep -x WPEWebProcess; }
cpu_ticks() { local sum=0 t; for p in $(pids); do t=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null) && sum=$((sum+t)); done; echo $sum; }

# 收掉上一档（WPEWebProcess 会残留并继续霸着 DRM fd）
pkill -x cog >/dev/null 2>&1; pkill -x WPEWebProcess >/dev/null 2>&1; sleep 1

# desktop 是 Restart=always，不 mask 会抢 DRM master
systemctl mask --runtime desktop >/dev/null 2>&1
systemctl stop desktop >/dev/null 2>&1; sleep 1.5

bus=/tmp/cogrt/bus
[ -S "$bus" ] || { dbus-daemon --session --address="unix:path=$bus" --fork --print-pid >/dev/null 2>&1; sleep 0.3; }
export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"

: > "$FPS"
env $ENVS cog -P drm -O renderer=gles $CARGS "$URL" >"$LOG" 2>&1 &
sleep 6
c1=$(cpu_ticks)
sleep "$WAIT"
c2=$(cpu_ticks)
alive=$(pgrep -x cog >/dev/null && echo ALIVE || echo DEAD)
pct=$(( (c2 - c1) / WAIT ))
grep -aq "Cannot set mode" "$LOG" && alive="$alive+NOMASTER"
grep -aqi "Segmentation\|Aborted" "$LOG" && alive="$alive+CRASH"

python3 - "$NAME" "$pct" "$alive" <<'PY'
import sys, json, statistics
name, cpu, alive = sys.argv[1], sys.argv[2], sys.argv[3]
def md(p):
    v=[float(x['fps']) for x in (json.loads(l) for l in open('/tmp/cogbench/fps.log') if l.strip()) if x.get('p')==p]
    return (round(statistics.median(v),1), len(v)) if v else (0.0,0)
a,na=md('0'); b,nb=md('1')
print(f"{name:<16} A={a:6.1f}  B={b:6.1f}  cpu={cpu:>4}%  {alive}  n={na}/{nb}")
open('/tmp/cogbench/result.txt','a').write(f"{name}\t{a}\t{b}\t{cpu}\t{alive}\t{na}/{nb}\n")
PY

pkill -x cog >/dev/null 2>&1; pkill -x WPEWebProcess >/dev/null 2>&1; sleep 1
systemctl unmask --runtime desktop >/dev/null 2>&1
systemctl start desktop >/dev/null 2>&1
