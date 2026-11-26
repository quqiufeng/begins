#!/bin/bash
# 用法: measure.sh <标签>   —— 对当前 chromium 页面测 fps + 每核 CPU + 内存
L=/opt/reader/bin/luajit
TAG=${1:-run}
SID=$(ps -o sid= -p $(pgrep -x cage) | tr -d ' ')
MPID=$(ps -eo pid=,sid=,args= | awk -v s=$SID '$2==s && /--type=renderer/ {print $1; exit}')
echo "---- $TAG ----  renderer=$MPID  threads=$(ls /proc/$MPID/task | wc -l)"

# 页面计数归零
$L /tmp/cdp_do.lua - "window.__t0=performance.now();window.__stats.f=0;window.__stats.canvasMs=0;1" >/dev/null 2>&1

cs(){ awk '/^cpu[0-9]/{print $1, $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
cs > /tmp/_c1
ls /proc/$MPID/task > /tmp/_th
for t in $(cat /tmp/_th); do echo "$t $(awk '{print $14+$15}' /proc/$MPID/task/$t/stat 2>/dev/null) $(cat /proc/$MPID/task/$t/comm 2>/dev/null)"; done > /tmp/_a
sleep 8
cs > /tmp/_c2
echo "每核 (8s):"
join /tmp/_c1 /tmp/_c2 | awk '{dt=$4-$2; di=$5-$3; printf "  %-5s %5.1f%%\n", $1, (dt>0)?(dt-di)*100/dt:0}'
echo "渲染进程线程 (>1%):"
for t in $(cat /tmp/_th); do
  t2=$(awk '{print $14+$15}' /proc/$MPID/task/$t/stat 2>/dev/null)
  t1=$(awk -v p=$t '$1==p{print $2}' /tmp/_a); n=$(awk -v p=$t '$1==p{print $3}' /tmp/_a)
  [ -n "$t1" ] && echo "$(awk -v d=$((t2-t1)) 'BEGIN{printf "%.1f", d/8}') $n"
done | awk '$1>1' | sort -gr | head -10 | sed 's/^/  /'
S=$(for t in $(cat /tmp/_th); do t2=$(awk '{print $14+$15}' /proc/$MPID/task/$t/stat 2>/dev/null); t1=$(awk -v p=$t '$1==p{print $2}' /tmp/_a); [ -n "$t1" ] && echo $((t2-t1)); done | awk '{s+=$1}END{print s}')
awk -v s=$S 'BEGIN{printf "  renderer 合计 %.1f%% 单核\n", s/8}'
echo "页面 fps:"
$L /tmp/cdp_do.lua - "JSON.stringify({fps:+(window.__stats.f/((performance.now()-window.__t0)/1000)).toFixed(1),f:window.__stats.f,canvasMs:+(window.__stats.canvasMs/window.__stats.f).toFixed(1)})" 2>&1 | grep '^\[js'
echo "内存 PSS:"
TT=0; for p in $(ps -eo pid=,sid= | awk -v s=$SID '$2==s{print $1}'); do v=$(awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null); TT=$((TT+${v:-0})); done
echo "  cage 全家族 PSS $((TT/1024)) MB"
awk '/MemAvailable/{printf "  系统 available %.0f MB\n", $2/1024}' /proc/meminfo
