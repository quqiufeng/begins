#!/bin/bash
# 用法: prof.sh <标签> [秒]  —— 按进程归集 CPU + 渲染/GPU 进程热点线程
TAG=${1:-run}; SEC=${2:-8}
L=/opt/reader/bin/luajit
SID=$(ps -o sid= -p $(pgrep -x cage) | tr -d ' ')
PL=""
for p in $(ps -eo pid=,sid= | awk -v s=$SID '$2==s{print $1}'); do
  ty=$(tr '\0' ' ' < /proc/$p/cmdline | grep -oE -- '--type=[a-z-]+' | head -1)
  [ -z "$ty" ] && [ "$(cat /proc/$p/comm)" = "cage" ] && ty=cage
  [ -z "$ty" ] && [ "$(cat /proc/$p/comm)" = "chromium" ] && ty=browser
  [ -z "$ty" ] && ty=$(cat /proc/$p/comm)
  PL="$PL $p:$ty"
done

snap(){ for e in $PL; do p=${e%%:*}; t=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null); echo "$p ${t:-0}"; done; }
cs(){ awk '/^cpu[0-9]/{print $1, $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
$L /tmp/cdp_do.lua - "window.__t0=performance.now();window.__stats.f=0;window.__stats.canvasMs=0;1" >/dev/null 2>&1
snap > /tmp/_p1; cs > /tmp/_c1
  RP=$(ps -eo pid=,sid=,rss=,args= | awk -v s=$SID '$2==s && /--type=renderer/ {print $1, $3}' | sort -k2 -nr | head -1 | cut -d' ' -f1)
  GP=$(ps -eo pid=,sid=,args= | awk -v s=$SID '$2==s && /--type=gpu-process/ {print $1; exit}')
  ls /proc/$RP/task > /tmp/_rth 2>/dev/null; ls /proc/$GP/task > /tmp/_gth 2>/dev/null
  for t in $(cat /tmp/_rth 2>/dev/null); do echo "R $t $(awk '{print $14+$15}' /proc/$RP/task/$t/stat 2>/dev/null) $(cat /proc/$RP/task/$t/comm 2>/dev/null)"; done > /tmp/_r1
  for t in $(cat /tmp/_gth 2>/dev/null); do echo "G $t $(awk '{print $14+$15}' /proc/$GP/task/$t/stat 2>/dev/null) $(cat /proc/$GP/task/$t/comm 2>/dev/null)"; done > /tmp/_g1
sleep $SEC
snap > /tmp/_p2; cs > /tmp/_c2
echo "---- $TAG ----"
echo "每核:"
join /tmp/_c1 /tmp/_c2 | awk '{dt=$4-$2;di=$5-$3;printf "  %-5s %5.1f%%\n",$1,(dt>0)?(dt-di)*100/dt:0}'
echo "各进程 (单核%):"
for e in $PL; do p=${e%%:*}; ty=${e##*:}
  t2=$(awk -v p=$p '$1==p{print $2}' /tmp/_p2); t1=$(awk -v p=$p '$1==p{print $2}' /tmp/_p1)
  [ -n "$t1" ] && echo "$(awk -v d=$((t2-t1)) -v s=$SEC 'BEGIN{printf "%.1f", d/s}') $ty $p"
done | sort -gr | head -8 | awk '{printf "  %6s%%  %-14s pid %s\n",$1,$2,$3}'
for spec in "R /tmp/_r1 $RP renderer" "G /tmp/_g1 $GP gpu"; do
  set -- $spec; tag=$1; f=$2; pid=$3; name=$4
  [ -z "$pid" ] && continue
  echo "$name 热点线程:"
  while read -r g t ticks comm; do
    t2=$(awk '{print $14+$15}' /proc/$pid/task/$t/stat 2>/dev/null); [ -z "$t2" ] && continue
    echo "$(awk -v d=$((t2-ticks)) -v s=$SEC 'BEGIN{printf "%.1f", d/s}') $comm"
  done < $f | awk '$1>2' | sort -gr | head -8 | awk '{printf "  %6s%%  %s\n",$1,$2}'
done
echo "页面:"
$L /tmp/cdp_do.lua - "JSON.stringify({fps:window.__stats?+(window.__stats.f/((performance.now()-window.__t0)/1000)).toFixed(1):null,f:window.__stats?window.__stats.f:null,canvasMs:window.__stats?+(window.__stats.canvasMs/Math.max(1,window.__stats.f)).toFixed(1):null,realFps:window.__stats?+(window.__stats.f/((performance.now()-window.__t0)/1000)).toFixed(1):null})" 2>&1 | grep '^\[js'
TT=0; for p in $(ps -eo pid=,sid= | awk -v s=$SID '$2==s{print $1}'); do v=$(awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null); TT=$((TT+${v:-0})); done
awk -v t=$TT '/MemAvailable/{printf "内存: cage家族 PSS %.0f MB, 系统 available %.0f MB\n", t/1024, $2/1024}' /proc/meminfo
