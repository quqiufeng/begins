#!/bin/sh
# rtnl / TX 队列看护：检出 storm 时冻结现场（sysrq-w 抓全部 D 态栈）+ 落盘
FORBIDDEN="adapter reset deferred"
LOG=/var/log/rtnl-watch.log
STORM=/var/log/rtnl-storm.log
mkdir -p /var/log
echo "[watch] start $(date '+%F %T')" >> $LOG

last_dump=0
while true; do
    n=$(dmesg | grep -c "$FORBIDDEN" 2>/dev/null; true)
    dfc=$(dmesg | grep -c "Tx Ring full when queue awake" 2>/dev/null; true)
    ts=$(cut -d. -f1 /proc/uptime)

    if [ "$n" -gt 0 ] || [ "$dfc" -gt 0 ]; then
        now=$(date +%s)
        if [ $((now - last_dump)) -ge 60 ]; then
            last_dump=$now
            {
                echo "===== STORM $(date '+%F %T') uptime=${ts}s deferred=$n ringfull=$dfc ====="
                echo "--- qdisc 状态 ---"
                tc -s qdisc show dev eth0 2>/dev/null
                echo "--- 全部 D 态任务栈 ---"
                for p in /proc/[0-9]*; do
                    st=$(awk '{print $3}' "$p/stat" 2>/dev/null)
                    [ "$st" = "D" ] || continue
                    echo "### D $p $(tr -d '\0' < "$p/comm" 2>/dev/null) wchan=$(cat "$p/wchan" 2>/dev/null)"
                    cat "$p/stack" 2>/dev/null
                done
                echo "--- sysrq-w 全局阻塞栈 ---"
                echo w > /proc/sysrq-trigger
                sleep 1
                dmesg | tail -400
                echo "--- eth0 计数 ---"
                cat /sys/class/net/eth0/statistics/tx_* 2>/dev/null
            } >> $STORM 2>&1
            sync
            echo "[watch] storm dumped at uptime ${ts}s deferred=$n ringfull=$dfc" >> $LOG
        fi
    fi
    sleep 2
done
