#!/bin/sh
# 重装遥控守护：清掉重复实例（之前 pgrep -x 失效，名字 16 字符被内核截成 15）
# 匹配串写在文件里，不会误伤 ssh 会话
set -u
PAT='rcinputd-aarch'

echo "== 清理旧实例 =="
pkill -f "$PAT" 2>/dev/null
sleep 0.5
pgrep -f "$PAT" >/dev/null 2>&1 && { pkill -9 -f "$PAT"; sleep 0.3; }
echo "残留: $(pgrep -f "$PAT" | wc -l)"

# 释放独占后设备应可再 grab
sleep 0.2
: > /tmp/tvplay-rc.log
setsid nohup /tmp/rcinputd-aarch64 >>/tmp/tvplay-rc.log 2>&1 </dev/null &
sleep 0.8
echo "== 启动日志 =="
cat /tmp/tvplay-rc.log

echo "== mpvctl 在位？ =="
ls -l /tmp/mpvctl-aarch64 2>&1
