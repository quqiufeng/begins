#!/bin/sh
# VDECDBG 时间线分析器
# 用法: vdecdbg-analyze.sh [样本数] [dmesg|文件]
# 每行: 时间 irq(+Δ) seq_o seq_c 差距 dst q pend vififo drain age
# 隔行: hw wptr status shift_rp
# 末尾给异常判定：esparser 供料停 / ISR 丢(固件卡帧) / 完成中断丢(DPB 泄漏)
N=${1:-40}
SRC=${2:-dmesg}
if [ "$SRC" = "dmesg" ]; then
	dmesg | grep VDECDBG
else
	cat "$SRC"
fi | tail -n $((N * 2)) | awk '
/VDECDBG irq=/ {
	t = ""; if (match($0, /\[[ 0-9.]+\]/)) t = substr($0, RSTART + 1, RLENGTH - 2)
	irq = seqo = seqc = dst = q = pend = vififo = drain = age = "?"
	if (match($0, /irq=[0-9]+/))    { a = substr($0, RSTART + 4, RLENGTH - 4); split(a, b, "("); irq = b[1] }
	if (match($0, /seq_o=[0-9]+/))  seqo = substr($0, RSTART + 6, RLENGTH - 6)
	if (match($0, /seq_c=[0-9]+/))  seqc = substr($0, RSTART + 6, RLENGTH - 6)
	if (match($0, /dst=[0-9]+/))    dst = substr($0, RSTART + 4, RLENGTH - 4)
	if (match($0, /q=[0-9]+/))      q = substr($0, RSTART + 2, RLENGTH - 2)
	if (match($0, /pend=[0-9]+/))   pend = substr($0, RSTART + 5, RLENGTH - 5)
	if (match($0, /vififo=[0-9]+/)) vififo = substr($0, RSTART + 7, RLENGTH - 7)
	if (match($0, /drain=[0-9]+\/[0-9]+/)) drain = substr($0, RSTART + 6, RLENGTH - 6)
	if (match($0, /age=[0-9]+ms/))  age = substr($0, RSTART + 4, RLENGTH - 6)
	gap = seqo - seqc
	dirq = (pirq == "") ? "-" : irq - pirq
	printf "%-12s irq=%-7s +%-4s so=%-6s sc=%-6s 差=%-2s dst=%-3s q=%-2s pend=%-2s vif=%-5s drain=%-4s age=%sms\n", t, irq, dirq, seqo, seqc, gap, dst, q, pend, vififo, drain, age
	pirq = irq; pgap = gap
	ns++
}
/VDECDBG hw/ {
	w = "?"; s = "?"; sr = "?"
	if (match($0, /wptr=[0-9a-f]+/))      w = substr($0, RSTART + 5, RLENGTH - 5)
	if (match($0, /status=[0-9a-f]+/))    s = substr($0, RSTART + 7, RLENGTH - 7)
	if (match($0, /shift_rp=[0-9a-f]+/))  sr = substr($0, RSTART + 9, RLENGTH - 9)
	printf "%-12s   hw wptr=%s status=%s shift_rp=%s\n", "", w, s, sr
	if (nh == 0) hw1 = w" "s; hwN = w" "s
	nh++
}
END {
	printf "\n--- 判定 ---\n样本数=%d hw样本=%d\n", ns, nh
	if (ns < 2) { print "样本不足"; exit }
	if (dirq == 0 && gap == pgap) print "[!] irq 停且完成序号不推进 → ISR 丢/固件卡帧（看 hw wptr 是否冻结）"
	else print "[.] irq 在跑且序号在动 → 驱动侧健康"
	if (pgap != "" && gap - pgap > 3) print "[!] 完成缺口扩大 (" pgap "→" gap ") → 完成中断丢失/DPB 泄漏"
	if (vififo + 0 > 20000) print "[!] vififo 高水位 " vififo " → esparser 积压/供料受限"
	if (pend + 0 > 6) print "[!] pend=" pend " 异常（健康 3）"
	if (nh > 3 && hw1 == hwN) print "[!] hw wptr/status 全程不变 → 固件不再推进"
}'
