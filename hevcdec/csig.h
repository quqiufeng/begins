/* csig.h —— 内容信号（content signal）：码流里自带的 HDR 亮度/颜色信息
 *
 * 为什么单独一个头：两条上屏路径都要用它（v4l2hevc.c 的软映射、glout.c 的
 * GL LUT），而 glout.c 还会被 gl-selftest 单独链接（不链 v4l2hevc.c）。
 * 所以这里放一个弱定义：谁带 CSIG_OWNER 谁出强定义（目前只有 v4l2hevc.c）。
 *
 * 一个结构体装完，不再分两份：
 *   VUI（SPS）    primaries / transfer / matrix / range，以及 SPS 的 bit_depth
 *   SEI 137       mastering_min/max_luminance（×0.0001，单位 nits）
 *   SEI 144       max_cll / max_fall（nits，就是内容峰值）
 *
 * 0 一律表示"码流没给"：maxCLL=0、母版亮度=0、primaries=0 都不是合法值，
 * 所以不需要额外的 seen 标志位，少一对状态就少一处不同步。
 *
 * 优先级：TM_SRC_PEAK（显式）> max_cll > mastering_max_luminance > 1000 兜底。
 * 兜底一定要打印出来——静默用一个假峰值，就是之前那个"固定 1000"的老问题。
 */
#ifndef CSIG_H
#define CSIG_H

#include <math.h>
#include <string.h>

/* 字段顺序固定，别随手插在中间：v4l2hevc.c 的调试打印按名取值。 */
struct ColorMetadata {
	int primaries;			/* VUI colour_primaries: 1=709 9=2020 12=P3 */
	int transfer;			/* VUI transfer_characteristics: 1=709 16=PQ 18=HLG */
	int matrix;			/* VUI matrix_coeffs: 1=709 9=2020NCL 14=ICtCp */
	int range;			/* VUI video_full_range_flag: 0=limited 1=full */
	int bit_depth;			/* 8/10/12，limited 展开的移位量靠它 */
	float mastering_min_luminance;	/* SEI 137，nits */
	float mastering_max_luminance;	/* SEI 137，nits */
	float max_cll;			/* SEI 144，nits */
	float max_fall;			/* SEI 144，nits */
};

#ifdef CSIG_OWNER
struct ColorMetadata g_cm;				/* 强定义 */
unsigned long g_csig_seen;				/* 解析过多少含 SEI 的 AU（调试） */
#else
__attribute__((weak)) struct ColorMetadata g_cm;	/* 单独链接时兜住符号 */
__attribute__((weak)) unsigned long g_csig_seen;
#endif

/* 母版原色 → colour_primaries 枚举。SEI 137 给的是 CIE 坐标（×0.00002），
 * 我们只保留"属于哪个色域"这个结论；容差 0.05 覆盖量化舍入。
 * 混着写（如 2020 红蓝 + P3 绿）返 0，不硬套。 */
static __attribute__((unused)) int cm_prim_from_sei(const double prim[3][2],
						   const double wp[2])
{
	static const struct { int id; double p[3][2], w[2]; } t[] = {
		{ 1,  {{.640,.330},{.300,.600},{.150,.060}}, {.3127,.3290} }, /* BT.709 */
		{ 12, {{.680,.320},{.265,.690},{.150,.060}}, {.3127,.3290} }, /* Display P3 */
		{ 9,  {{.708,.292},{.170,.797},{.131,.046}}, {.3127,.3290} }, /* BT.2020 */
	};
	double best = 1e9;
	int id = 0, i, c;

	for (i = 0; i < 3; i++) {
		double d = 0.0;

		for (c = 0; c < 3; c++)
			d += fabs(prim[c][0] - t[i].p[c][0]) +
			     fabs(prim[c][1] - t[i].p[c][1]);
		d += fabs(wp[0] - t[i].w[0]) + fabs(wp[1] - t[i].w[1]);
		if (d < best) { best = d; id = t[i].id; }
	}
	return best < 0.05 ? id : 0;
}

/* 换片/换码流时把上一片的内容信息清干净。
 * 不清的后果：上一片是 HDR1000，这一片是 SDR 且没写 VUI/SEI，
 * csig_peak() 还返回 1000，映射照旧一路压下去——整片发灰，而且日志里
 * 看不出破绽（峰值"有来源"）。 */
static __attribute__((unused)) void cm_reset(void)
{
	memset(&g_cm, 0, sizeof(g_cm));
}

/* 传递函数名字：只给日志用 */
static __attribute__((unused)) const char *cm_tf_name(void)
{
	switch (g_cm.transfer) {
	case 1:  return "BT.709(SDR)";
	case 6:  return "BT.601(SDR)";
	case 14: return "BT.2020-10bit(SDR)";
	case 15: return "BT.2020-12bit(SDR)";
	case 16: return "PQ";
	case 18: return "HLG";
	case 0:  return "未标";
	default: return "其它(SDR)";
	}
}

/* 码流自称是 HDR 吗？1=PQ/HLG，0=SDR，-1=没写（调用侧自己决定兜底） */
static __attribute__((unused)) int cm_is_hdr(void)
{
	if (g_cm.transfer == 16 || g_cm.transfer == 18)
		return 1;
	return g_cm.transfer ? 0 : -1;
}

/* 色域名：只认枚举，不再拿浮点坐标去猜 */
static __attribute__((unused)) const char *cm_gamut(void)
{
	switch (g_cm.primaries) {
	case 1:  return "BT.709";
	case 9:  return "BT.2020";
	case 12: return "P3-D65";
	case 0:  return "无 VUI/SEI";
	default: return "其它";
	}
}

/* limited(16-235/64-940/256-3760) → full 的右移量，8bit 为 0 */
static __attribute__((unused)) int cm_range_shift(void)
{
	int bd = g_cm.bit_depth;

	return bd > 8 ? bd - 8 : 0;
}

/* 真实内容峰值：0 = 还没有可靠信息（调用侧退回默认并必须说出来） */
static __attribute__((unused)) double csig_peak(void)
{
	if (g_cm.max_cll > 0.0f)
		return g_cm.max_cll;
	if (g_cm.mastering_max_luminance > 0.0f)
		return g_cm.mastering_max_luminance;
	return 0.0;
}

#endif /* CSIG_H */
