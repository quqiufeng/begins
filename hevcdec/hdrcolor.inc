/* hdrcolor.inc —— HDR 色彩路径的唯一实现
 *
 * 软映射（v4l2hevc.c，就地改 NV12）和 GL 映射（glout.c，256 项浮点 LUT）
 * 原本各抄了一份 PQ/曲线/OETF 的数学，两份已经漂移（sat 默认 0.85 vs 0.90、
 * gain 有没有乘 sat、bt709_encode 返回 16..235 还是 0..1）。这里收成一份纯函数，
 * 两边 #include 同一段文本；hdr-selftest.c 也 #include 它，所以"测的就是跑的"。
 *
 * 全部纯函数：无全局、无 I/O、不依赖 libm 之外的任何东西。
 */
#ifndef HDRCOLOR_INC
#define HDRCOLOR_INC

#include <math.h>

enum { HC_CLIP = 0, HC_CURVE = 1, HC_REINHARD = 2, HC_HABLE = 3 };
/* 色度增益的算法：
 *   HC_GAIN_CODE —— 码值域比值 nout/n（历史实现）：PQ 码是近似对数、709 码是近似
 *                   幂函数，比值没有物理意义，暗部会趋 0（彩色变灰）、高光过冲。
 *   HC_GAIN_LIN  —— 线性光比值 (屏幕光/源光)：拐点以下 d=x ⇒ g=1（不动作），正好对上
 *                   逐通道映射在膝点以下的恒等段；进入软膝后自然 <1。
 *
 * 实测（hdr-selftest [2b]/[6]，sat=0.85 target=200 knee=0.7）：
 *   Y 码   17     96     128    160    224
 *   code  0.002  0.717  1.192  1.269  0.895     ← 暗部彩色被压成灰、中间过冲
 *   lin   0.850  0.850  0.850  0.391  0.027     ← 膝点以下恒 sat，高光去饱和很猛
 * 所以在"暗部低饱和"区 lin 明显更贴逐通道参考（4.7 vs 21.3 码），但
 * 高光区 lin 比 code 多去饱和 13.9 码（709 黄 600nit：217 vs 175，参考 40）——
 * 逐通道色调映射其实*从不去饱和*（纯红 1000nit 压完还是纯红），这是标量增益
 * 补不出来的部分，不是 lin 独有的错。选 lin 的理由是膝点以下无害，不是高光更准。
 */
enum { HC_GAIN_CODE = 0, HC_GAIN_LIN = 1 };

/* 传递函数：直接沿用 VUI transfer_characteristics 的枚举值，省一层映射表。
 * 0 是"码流没写 VUI"——按 PQ 处理（历史行为，HDR 片几乎都是 PQ）；
 * 其它任何非 PQ/HLG 的值（1=BT.709、6=BT.601、14/15=2020 常数亮度…）
 * 都是 SDR，直接透传，不做任何映射。
 */
enum { HC_TF_UNKNOWN = 0, HC_TF_709 = 1, HC_TF_PQ = 16, HC_TF_HLG = 18 };

struct hdrcolor {
	int on;
	int curve;		/* HC_* */
	double src_peak;	/* 内容峰值 nits：曲线肩部的终点。来自 SEI maxCLL，
				 * 缺省才退回 1000。0/<=target 表示"源不出显示白"→ 不动。
				 */
	double target;		/* 显示参考白 nits */
	double sat;		/* 色度增益里的饱和度系数 */
	double knee;		/* HC_CURVE 的拐点 0..1 */
	int full;		/* 源是全范围（少见） */
	int gain_mode;		/* HC_GAIN_* */
	int transfer;		/* HC_TF_*：决定码值→线性光用哪条 EOTF */
};

/* 是否按 HDR 处理：PQ/HLG 是，明确标了 SDR 的不是，没写 VUI 的按 PQ 兜底 */
static int hc_is_hdr(const struct hdrcolor *c)
{
	return c->transfer == HC_TF_PQ || c->transfer == HC_TF_HLG ||
	       c->transfer == HC_TF_UNKNOWN;
}

static const char *hc_tf_name(int tf)
{
	switch (tf) {
	case HC_TF_PQ:  return "PQ";
	case HC_TF_HLG: return "HLG";
	case HC_TF_UNKNOWN: return "未标(PQ兜底)";
	default: return "SDR";
	}
}

/* SMPTE ST 2084 PQ EOTF：码值 n∈[0,1] → 绝对亮度 nits */
static double hc_pq_eotf(double n)
{
	const double m1 = 0.1593017578125, m2 = 78.84375;
	const double c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	double np, num, den;

	if (n <= 0.0) return 0.0;
	if (n > 1.0) n = 1.0;
	np = pow(n, 1.0 / m2);
	num = np - c1;
	den = c2 - c3 * np;
	if (num <= 0.0 || den <= 0.0) return 0.0;
	return 10000.0 * pow(num / den, 1.0 / m1);
}

/* PQ 逆（OETF）：绝对亮度 nits → 码值 n∈[0,1] */
static double hc_pq_oetf(double L)
{
	const double m1 = 0.1593017578125, m2 = 78.84375;
	const double c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	double lp;

	if (L <= 0.0) return 0.0;
	lp = pow(L / 10000.0, m1);
	return pow((c1 + c2 * lp) / (1.0 + c3 * lp), m2);
}

/* BT.2100 HLG：电信号 e∈[0,1] → 场景线性光 Ls∈[0,1]（逆 OETF）
 * 分段常数 a/b/c 用 BT.2100 表 5 的值（b = 1-4a = 0.28466892，c = 0.5-a·ln4） */
static double hc_hlg_inv_oetf(double e)
{
	const double a = 0.17883277, b = 0.28466892, c = 0.55991073;

	if (e <= 0.0) return 0.0;
	if (e >= 1.0) return 1.0;
	if (e <= 0.5) return e * e / 3.0;
	return (exp((e - c) / a) + b) / 12.0;
}

/* HLG 正 OETF（自检/参考用）：场景线性光 Ls∈[0,1] → 电信号 e∈[0,1] */
static double hc_hlg_oetf(double ls)
{
	const double a = 0.17883277, b = 0.28466892, c = 0.55991073;

	if (ls <= 0.0) return 0.0;
	if (ls >= 1.0) return 1.0;
	return (ls <= 1.0 / 12.0) ? sqrt(3.0 * ls) : a * log(12.0 * ls - b) + c;
}

/* HLG OOTF：场景光 → 显示光（nits）。
 *   γ = 1.2 + 0.42·log10(Lw/1000)（BT.2100 参考峰值 1000nits 时 γ=1.2）
 *   Ld = Lw · Ls^γ
 * 黑电平抬升 β=sqrt(3·(Lb/Lw)^(1/γ)) 近似为 0：盒子屏 Lb≈0.05nits 时
 * β≈0.02，低于 8bit 输出的一级码值，省掉不影响结果却少两个 pow。
 */
static double hc_hlg_eotf(double e, double lw)
{
	double gamma, ls;

	if (!(lw > 100.0)) lw = 1000.0;		/* HLG 的参考峰值 */
	if (lw > 4000.0) lw = 4000.0;
	gamma = 1.2 + 0.42 * log10(lw / 1000.0);
	ls = hc_hlg_inv_oetf(e);
	return lw * pow(ls, gamma);
}

/* 码值 n∈[0,1] → 绝对亮度 nits，按 c->transfer 选 EOTF */
static double hc_src_lin(const struct hdrcolor *c, double n)
{
	if (c->transfer == HC_TF_HLG)
		return hc_hlg_eotf(n, c->src_peak > 0.0 ? c->src_peak : 1000.0);
	return hc_pq_eotf(n);
}

/* BT.709 OETF：线性光 d∈[0,1] → 电信号 e∈[0,1]（不含 16/219 偏移） */
static double hc_bt709_oetf(double d)
{
	if (d <= 0.0) return 0.0;
	if (d >= 1.0) return 1.0;
	return (d < 0.018) ? 4.5 * d : 1.099 * pow(d, 0.45) - 0.099;
}

/* BT.709 EOTF（逆向，自检/参考用） */
static double hc_bt709_eotf(double e)
{
	if (e <= 0.0) return 0.0;
	if (e >= 1.0) return 1.0;
	return (e < 0.081) ? e / 4.5 : pow((e + 0.099) / 1.099, 1.0 / 0.45);
}

static double hc_hable(double x)
{
	const double A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
	double f1, fw;

	if (x <= 0.0) return 0.0;
	f1 = (x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F);
	fw = (1.0 * (A * 1.0 + C * B) + D * E) / (1.0 * (A * 1.0 + B) + D * F);
	return f1 / fw;
}

/* 源峰值，单位是"显示参考白"：1000nits 源 / 200nits 屏 = 5.0。
 * 老实现里这个值谁都没用（曲线只认 knee），所以 TM_SRC_PEAK 调多少
 * 输出都一模一样；这里给它一个唯一的用处——肩部的终点。
 */
static double hc_src_x(const struct hdrcolor *c)
{
	double xs = (c->target > 1.0) ? c->src_peak / c->target : 1.0;

	if (!(xs > 1.0)) xs = 1.0;
	if (xs > 100.0) xs = 100.0;	/* 10000nits/100nits 的极端，防除零 */
	return xs;
}

/* 归一化亮度 x（1.0 = 显示参考白）→ 屏幕线性光 d∈[0,1] */
static double hc_curve(const struct hdrcolor *c, double x)
{
	switch (c->curve) {
	case HC_CLIP:
		return x > 1.0 ? 1.0 : x;
	case HC_REINHARD:
		return 2.0 * x / (1.0 + x);
	case HC_HABLE:
		return hc_hable(x);
	default: {
		/*
		 * 肩部曲线：膝点 k 以下恒等（1:1，不动暗部和中段），
		 * k..xs 之间把源高光压进 k..1.0，xs 以上硬限。
		 *
		 *   d = k + u / (1 + u·(1/(1-k) - 1/(xs-k))),  u = x-k
		 *
		 * 端点：d(k)=k、d(xs)=1；斜率 d'(k)=1（和膝点以下接得上，
		 * 不出现 Mach 带）；u>0 时单调，不会像 Hermite/BT.2390 那样在
		 * 大压缩比下过冲到 1 以上把高光截平。
		 *
		 * 关键是分母里的 1/(xs-k)：老实现按 (1-k) 归一，等于假设
		 * "源峰值就在显示白"，于是 400nits(2.0x) 已经到 0.996、上面
		 * 全平——src_peak 完全没用上。按 xs 归一后，同样的 400nits
		 * 落在 0.958，1000nits 才到 1.0，高光层次留得下来。
		 */
		double xs = hc_src_x(c), k = c->knee, u, a, b;

		if (xs <= 1.0)		/* 源不出显示白：没有要压的东西 */
			return x > 1.0 ? 1.0 : x;
		if (x <= k)
			return x;
		if (x >= xs)
			return 1.0;
		u = x - k;
		a = 1.0 - k;		/* 到显示白还剩多少 */
		b = xs - k;		/* 到源峰值还剩多少（a < b） */
		if (a < 1e-3)		/* knee≈1 的退化，防除零 */
			a = 1e-3;
		if (b <= a)		/* xs 贴在膝点上，肩部退化成硬限 */
			b = a + 1e-3;
		return k + u / (1.0 + u * (1.0 / a - 1.0 / b));
	}
	}
}

/* 色域压缩系数由 primaries 派生，不再是独立旋钮（design_color.md §4.3.4）。
 * 709 源本来就在目标色域内 → 1.0，一个像素都不动；2020 最宽 → wide；
 * P3-D65 居中，按 u'v' 面积比的对数插值（2020/709≈1.90，P3/709≈1.25）。
 * 面积比取对数是因为"多压多少"正比于多出来的色域体积，不是线性。
 * primaries=0（码流没写）按 2020 处理：PQ/HLG 内容事实上都是 2020，
 * 但调用侧得把"默认"标出来。窄色域（BT.470/SMPTE-C 之类）一律 1.0。
 */
enum { HC_PRI_709 = 1, HC_PRI_2020 = 9, HC_PRI_P3 = 12 };

static double hc_sat_from_primaries(int primaries, double wide)
{
	double area;

	switch (primaries) {
	case HC_PRI_2020:
	case 0:		/* 没写 VUI/SEI：按 2020 兜底 */
		area = 1.90;
		break;
	case HC_PRI_P3:
		area = 1.25;
		break;
	default:	/* 709 及其它窄色域：不动作 */
		return 1.0;
	}
	if (wide >= 1.0) return 1.0;
	if (wide <= 0.0) return 1.0;
	return 1.0 - (1.0 - wide) * (log(area) / log(1.90));
}

/* 生成 8bit 表：lut[v] = 输出 Y 码（有限范围 16..235），
 * gain[v] = Q10 色度增益（1024 = 1.0），full=0 时输入按 (v-16)/219 归一化。
 */
static void hc_build(const struct hdrcolor *c, unsigned char lut[256],
		     unsigned short gain[256])
{
	int v;

	for (v = 0; v < 256; v++) {
		double n = c->full ? v / 255.0 : (v - 16) / 219.0;
		double L, x, d, code, nout, g = 1.0;

		if (n < 0.0) n = 0.0;
		if (n > 1.0) n = 1.0;
		/* SDR 源（VUI 明确写了非 PQ/HLG 的传递函数）：任何映射都是错的，
		 * 一律透传。没写 VUI 的码流仍按 PQ 兜底（hc_is_hdr）。 */
		if (!c->on || !hc_is_hdr(c)) {
			lut[v] = (unsigned char)v;
			gain[v] = 1024;
			continue;
		}
		L = hc_src_lin(c, n);
		x = L / c->target;
		d = hc_curve(c, x);
		code = 16.0 + 219.0 * hc_bt709_oetf(d);
		if (code < 0.0) code = 0.0;
		if (code > 255.0) code = 255.0;
		lut[v] = (unsigned char)(code + 0.5);
		nout = (code - 16.0) / 219.0;
		if (c->gain_mode == HC_GAIN_LIN) {
			/* 输出线性光 / 输入线性光；L 用 nits，d 是 0..1 的屏幕光 */
			double lout = d * c->target;

			g = (L > 0.05) ? lout / L : 1.0;
		} else if (n > 0.004) {
			g = nout / n;
		} else {
			g = 0.0;
		}
		/* sat 只调"增益的作用量"：sat=1 全量、sat=0 不动作（g 恒等 1）。
		 * 早期写法是 g *= sat，它连恒等段一起乘掉——膝点以下 g=1 会变成
		 * 0.85，等于给本该不动的暗部统一去饱和 15%（709 蓝 1000nit 实测：
		 * 不碰色度 Δ58.0 → 乘 sat Δ68.9），和 design_color.md §4.3.4
		 * "709 源 sat=1.0，只在 2020→709 时压"直接冲突。改插值后暗部无害。
		 */
		g = 1.0 + c->sat * (g - 1.0);
		if (g < 0.0) g = 0.0;
		if (g > 3.9) g = 3.9;
		gain[v] = (unsigned short)(g * 1024.0 + 0.5);
	}
}

/* BT.2020 NCL 的 YCbCr→RGB 系数（Kr=0.2627 Kb=0.0593） */
#define HC_K2020_R 1.474600
#define HC_K2020_G_CB (-0.164553)
#define HC_K2020_G_CR (-0.571353)
#define HC_K2020_B 1.881400

/* BT.709 NCL 的系数（Kr=0.2126 Kb=0.0722），SDR 内容要用这一组 */
#define HC_K709_R 1.574800
#define HC_K709_G_CB (-0.187324)
#define HC_K709_G_CR (-0.468124)
#define HC_K709_B 1.855600

/* BT.2020 → BT.709 的 3x3。
 *
 * 值得写清楚：上面这九个数就是"线性光 2020→709"的主矩阵——BT.2087 附录给的
 * 那组派生系数和它逐位相同（2020 原色 x/y 白点 D65 → 709，配 Kr/Kb 反推，
 * 得到的就是 [1.6605 -0.5876 -0.0728; ...]）。BT.2087 的意思是"非线性域
 * 直接乘它会不准"，但整条流水线的 Y 已经被 LUT 定死、只剩色度要在码值域里
 * 改，没有线性光这一站，所以这里就是乘在码值域上，误差是设计的一部分
 * （hdr-selftest 的"code Δ"列量的就是它）。
 *
 * 软映射（v4l2hevc.c）和 GL 片元（glout.c）都从这里取：以前 GL 里手抄了
 * 一份、软映射根本没有，同一条片 RENDER=gl 和 RENDER=drm 色域外原色差 100 多码。
 */
#define HC_M_RR  1.6605
#define HC_M_RG (-0.5876)
#define HC_M_RB (-0.0728)
#define HC_M_GR (-0.1246)
#define HC_M_GG  1.1329
#define HC_M_GB (-0.0083)
#define HC_M_BR (-0.0182)
#define HC_M_BG (-0.1006)
#define HC_M_BB  1.1187

/* P3-D65 → BT.709：同一个流程算出来的线性主矩阵（Display P3: R(0.680,0.320)
 * G(0.265,0.690) B(0.150,0.060)，白点 D65 和 709 相同，所以行和恰好 1）。
 * 和 2020 那组一样是乘在码值域。P3 只比 709 多一点点（红原色方向），
 * 所以第一列/第二列比 2020 那组贴近恒等得多，色域外要收的量也小。 */
#define HC_M3_RR  1.2249
#define HC_M3_RG (-0.2249)
#define HC_M3_RB  0.0000
#define HC_M3_GR (-0.0421)
#define HC_M3_GG  1.0421
#define HC_M3_GB  0.0000
#define HC_M3_BR (-0.0196)
#define HC_M3_BG (-0.0786)
#define HC_M3_BB  1.0983

/* 行主序 3x3，给软映射和 GL 的 uGm 用：o = M * rgb。 */
static const double hc_mat_2020[9] = {
	HC_M_RR,  HC_M_RG,  HC_M_RB,
	HC_M_GR,  HC_M_GG,  HC_M_GB,
	HC_M_BR,  HC_M_BG,  HC_M_BB,
};
static const double hc_mat_p3[9] = {
	HC_M3_RR, HC_M3_RG, HC_M3_RB,
	HC_M3_GR, HC_M3_GG, HC_M3_GB,
	HC_M3_BR, HC_M3_BG, HC_M3_BB,
};
static const double hc_mat_id[9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };

/* 这个色域到 709 要走哪组系数：2020（含 VUI 没写的兜底）用 2020 主矩阵，
 * P3-D65 用自己的，709 及其它窄色域恒等（hc_needs_mat 返回 0，不进这段）。 */
static int hc_needs_mat(int primaries)
{
	return primaries == HC_PRI_2020 || primaries == 0 ||
	       primaries == HC_PRI_P3;
}

static const double *hc_mat(int primaries)
{
	switch (primaries) {
	case HC_PRI_P3:
		return hc_mat_p3;
	case HC_PRI_2020:
	case 0:
		return hc_mat_2020;
	default:
		return hc_mat_id;
	}
}

/* 日志用：走哪条矩阵/增益。以前只打 "2020→709/无"，P3 接上矩阵后光看
 * 这一列分不出走的是哪组，出问题得靠猜。 */
static const char *hc_mat_name(int primaries)
{
	switch (primaries) {
	case HC_PRI_P3:
		return "P3→709";
	case HC_PRI_2020:
	case 0:
		return "2020→709";
	default:
		return "恒等";
	}
}

/* 一个色度样本：源 YCbCr(2020 NCL, 非线性码) → 加色度增益 → 源色域→709 矩阵
 * → 绕 709 亮度轴去饱和 → 编回 YCbCr(709) 的 (u,v) 码。
 *
 * 逆矩阵固定用 BT.2020 NCL（Kr=0.2627/Kb=0.0593）：HEVC 的 P3-D65 片
 * 基本都写 matrix_coeffs=9（2020 NCL），和 primaries 是两件事；真写了
 * 12（chromaticity-derived NCL）也不换——那种片极少，换错反而更远。
 *
 * Y 不在这里算：亮度已经由 Y 平面上的 LUT 定死（含曲线），这里只重算色度，
 * 并且编回时以 LUT 的 Y 为基准 —— 否则矩阵会把整帧亮度挪一点，
 * 显示白又飘回映射前的水平。
 *
 *   ytm  已映射的 Y 码（有限范围 16..235）
 *   u,v  源 (u,v) 码
 *   gain Q10 色度增益（1024 = 1.0）
 *   sat  去饱和系数（1=不动，2020 源由 hc_sat_from_primaries 给）
 *   m    源色域→709 的 3x3（行主序，hc_mat(primaries) 给）
 */
static void hc_chroma709(double ytm, double u, double v, double gain,
			 double sat, const double *m, double *ou, double *ov)
{
	double y1 = (ytm - 16.0) / 219.0;
	double cb = (u - 128.0) * gain / (224.0 * 1024.0);
	double cr = (v - 128.0) * gain / (224.0 * 1024.0);
	double r = y1 + HC_K2020_R * cr;
	double g = y1 + HC_K2020_G_CB * cb + HC_K2020_G_CR * cr;
	double b = y1 + HC_K2020_B * cb;
	double o0, o1, o2, lum;

	o0 = m[0] * r + m[1] * g + m[2] * b;
	o1 = m[3] * r + m[4] * g + m[5] * b;
	o2 = m[6] * r + m[7] * g + m[8] * b;
	if (o0 < 0.0) o0 = 0.0; else if (o0 > 1.0) o0 = 1.0;
	if (o1 < 0.0) o1 = 0.0; else if (o1 > 1.0) o1 = 1.0;
	if (o2 < 0.0) o2 = 0.0; else if (o2 > 1.0) o2 = 1.0;
	/* 去饱和绕亮度轴：色域外的原色矩阵压不回 709 三角形，只能往中性灰收，
	 * 收多少由 sat 决定；亮度（Y 码）保持不动。 */
	lum = 0.2126 * o0 + 0.7152 * o1 + 0.0722 * o2;
	o0 = lum + sat * (o0 - lum);
	o1 = lum + sat * (o1 - lum);
	o2 = lum + sat * (o2 - lum);

	*ou = 128.0 + 224.0 * (o2 - y1) / HC_K709_B;
	*ov = 128.0 + 224.0 * (o0 - y1) / HC_K709_R;
	if (*ou < 0.0) *ou = 0.0; else if (*ou > 255.0) *ou = 255.0;
	if (*ov < 0.0) *ov = 0.0; else if (*ov > 255.0) *ov = 255.0;
}

#endif /* HDRCOLOR_INC */
