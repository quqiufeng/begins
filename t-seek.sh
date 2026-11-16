#!/bin/sh
# 软 seek 验证：解码器 PID 必须不变，ffmpeg 必须换新
N=/tmp/tvplay-node.sh
D0=$(pgrep -f v4l2hevc-gl)
F0=$(pgrep -f 'sh -c ffmpeg|ffmpeg -hide' | tr '\n' ' ')
P0=$(sh "$N" state | cut -d' ' -f1)
echo "前: 解码器=$D0  ffmpeg=$F0  位置=${P0}s"
echo "--- 现在按 key fwd（+30s） ---"
T0=$(date +%s%N)
sh "$N" key fwd
T1=$(date +%s%N)
D1=$(pgrep -f v4l2hevc-gl)
F1=$(pgrep -f 'sh -c ffmpeg|ffmpeg -hide' | tr '\n' ' ')
echo "后: 解码器=$D1  ffmpeg=$F1"
echo "耗时: $(( (T1-T0)/1000000 )) ms"
echo "位置: $(sh "$N" state | cut -d' ' -f1)s"
[ "$D0" = "$D1" ] && echo "✔ 解码器全程未重启（DRM 未释放 → 不会黑屏/掉控制台）" \
                   || echo "✘ 解码器被重启了！$D0 → $D1"
[ "$F0" != "$F1" ] && echo "✔ 供流已换新" || echo "✘ 供流没换"
echo "--- 3s 后音画对齐检查 ---"
sleep 3
echo "节点位置: $(sh "$N" state | cut -d' ' -f1)s"
echo "音频位置: $(grep -o 'A: [0-9:]*' /tmp/tvplay.log | tail -1)"
echo "--- get_property time-pos ---"
printf '%s\n' '{"command":["get_property","time-pos"]}' | perl -MIO::Socket::UNIX -e '
  my $s = IO::Socket::UNIX->new(Peer => "/tmp/mpv.sock") or exit 1;
  my $l = <STDIN>; print $s $l; my $r = <$s>; print "$r\n";' 2>/dev/null
echo "--- 播放是否在走 ---"
sleep 2
grep -o 'A: [0-9:]*' /tmp/tvplay.log | tail -1
