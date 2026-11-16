#!/bin/sh
# A/V 对齐验证：同一时刻比较 节点位置 与 mpv time-pos
N=/tmp/tvplay-node.sh
P() { printf '%s\n' "$1" | perl -MIO::Socket::UNIX -e '
  my $s = IO::Socket::UNIX->new(Peer => "/tmp/mpv.sock") or exit 1;
  my $l = <STDIN>; print $s $l; my $r = <$s>;
  $r =~ /"data":([0-9.]+)/ and print "$1\n";' 2>/dev/null; }
sample() {
	nodep=$(sh "$N" state | cut -d' ' -f1)
	apos=$(P '{"command":["get_property","time-pos"]}')
	echo "  画面(节点)=${nodep}s  声音=${apos}s  差=$(awk -v a="$apos" -v b="$nodep" 'BEGIN{printf "%+.2f", a-b}')s"
}
D0=$(pgrep -f v4l2hevc-gl)
echo "解码器 PID=$D0  位置=$(sh "$N" state | cut -d' ' -f1)s"
echo "--- key fwd (+30s) ---"
T0=$(date +%s%N); sh "$N" key fwd; T1=$(date +%s%N)
echo "seek 全程 $(( (T1-T0)/1000000 ))ms   解码器 PID=$(pgrep -f v4l2hevc-gl)"
sample
sleep 2; sample
echo "--- key back (-10s) ---"
sh "$N" key back
sample
sleep 2; sample
echo "--- 暂停 → fwd → 检查是否仍暂停 ---"
sh "$N" key toggle
sleep 0.5
sh "$N" key fwd
sleep 1
echo -n "  pause 状态: "; P '{"command":["get_property","pause"]}'
echo -n "  解码器是否被 STOP(T=已停): "; grep State /proc/$(pgrep -f v4l2hevc-gl | head -1)/status | head -1
sample
sh "$N" key toggle
sleep 1
echo -n "  恢复后 pause: "; P '{"command":["get_property","pause"]}'
sample
