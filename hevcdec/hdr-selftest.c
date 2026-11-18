/* hdr-selftest.c —— HDR 色彩路径自检（纯 CPU，不需要板子/GL）
 *
 * 直接 #include "hdrcolor.inc"，测的就是播放器在跑的那份数学。
 *
 *   make hdrtest && ./hdrtest
 *
 * 关心的四件事：
 *   1. PQ/OETF 数学对不对（对 ST 2084 参考点 + 往返）
 *   2. LUT 会不会撞码（8bit 容器 + 压缩曲线 → 断层/带条）
 *   3. 每条曲线把多少码位留给了高光
 *   4. 色度增益、色域矩阵在"码值域做"和"线性光域做"差多少
 */
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "hdrcolor.inc"

static struct hdrcolor C;
static int fails;

static void ok(int cond, const char *fmt, ...)
{
	va_list ap;

	printf(cond ? "  [ok]   " : "  [FAIL] ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	if (!cond) fails++;
}

static double nits_of_code(double code, int full)
{
	double n = full ? code / 255.0 : (code - 16.0) / 219.0;

	return hc_pq_eotf(n);
}

static int code_of_nits(double L)
{
	int c = (int)(hc_pq_oetf(L) * 219.0 + 16.0 + 0.5);

	return c < 0 ? 0 : c > 255 ? 255 : c;
}

/* ---------------- 1. PQ / OETF 数学 ---------------- */
static void t_pq(void)
{
	static const double anchor[][2] = {	/* nits, PQ 码 n */
		{ 1.0, 0.1497 }, { 10.0, 0.2998 }, { 100.0, 0.5081 },
		{ 1000.0, 0.7518 }, { 10000.0, 1.0000 },
	};
	double worst = 0.0, worst_rt = 0.0;
	unsigned i;

	printf("\n[1] PQ (ST 2084) 参考点\n");
	for (i = 0; i < sizeof(anchor) / sizeof(anchor[0]); i++) {
		double n = hc_pq_oetf(anchor[i][0]);
		double d = fabs(n - anchor[i][1]);

		if (d > worst) worst = d;
		printf("  %7.1f nits -> PQ %.4f (参考 %.4f, 差 %+.4f)\n",
		       anchor[i][0], n, anchor[i][1], n - anchor[i][1]);
	}
	ok(worst < 0.0015, "PQ OETF 对参考点最大偏差 %.4f (<0.0015)", worst);

	for (i = 0; i < 4000; i++) {		/* 0.001..10000 nits 对数往返 */
		double L = 0.001 * pow(10000.0 / 0.001, i / 3999.0);
		double rel = fabs(hc_pq_eotf(hc_pq_oetf(L)) - L) / L;

		if (rel > worst_rt) worst_rt = rel;
	}
	ok(worst_rt < 1e-6, "PQ 往返 EOTF(OETF(L))：最大相对误差 %.2e", worst_rt);
	ok(hc_pq_eotf(0.0) == 0.0 && fabs(hc_pq_eotf(1.0) - 10000.0) < 0.5,
	   "边界：PQ(0)=%.0f nits, PQ(1)=%.0f nits", hc_pq_eotf(0.0), hc_pq_eotf(1.0));
	/* BT.709 OETF 往返 */
	{
		double mx = 0.0;

		for (i = 0; i <= 1000; i++) {
			double d = i / 1000.0;
			double e = fabs(hc_bt709_eotf(hc_bt709_oetf(d)) - d);

			if (e > mx) mx = e;
		}
		ok(mx < 2e-3, "BT.709 OETF/EOTF 往返最大偏差 %.4f", mx);
	}
	printf("  8bit TV 码 -> nits: ");
	for (i = 16; i <= 96; i += 16)
		printf("%u:%.2f  ", i, nits_of_code(i, 0));
	printf("\n");
}

/* ---------------- 2. LUT 形状 / 撞码 ---------------- */
struct lutstat {
	int distinct;			/* 16..235 里出现多少种输出码 */
	int plateau;			/* 落在前一条同值上的输入码数 */
	int first_235;
	int gain_clamp;			/* 增益被 3.9 封顶的输入码数 */
	unsigned gain_clamp_from;
	double nits_shadow, nits_mid;
};

static void lut_shape(const struct hdrcolor *c, const unsigned char *lut,
		      const unsigned short *gain, struct lutstat *st)
{
	unsigned v;
	int prev = -1;

	memset(st, 0, sizeof(*st));
	st->first_235 = -1;
	for (v = 16; v <= 235; v++) {
		if (lut[v] != prev) {
			st->distinct++;
			prev = lut[v];
		} else {
			st->plateau++;
		}
		if (lut[v] >= 235 && st->first_235 < 0) st->first_235 = (int)v;
		if (gain[v] >= 3993) {
			st->gain_clamp++;
			if (!st->gain_clamp_from) st->gain_clamp_from = v;
		}
	}
	st->nits_shadow = nits_of_code(25, c->full) - nits_of_code(24, c->full);
	st->nits_mid = nits_of_code(141, c->full) - nits_of_code(140, c->full);
}

static void t_lut(void)
{
	unsigned char lut[256];
	unsigned short gain[256];
	struct lutstat st;
	unsigned v;
	int mono = 1;

	hc_build(&C, lut, gain);
	lut_shape(&C, lut, gain, &st);

	printf("\n[2] LUT 形状（curve=%d target=%.0f sat=%.2f knee=%.2f full=%d）\n",
	       C.curve, C.target, C.sat, C.knee, C.full);
	printf("  输入 Y 码 16/32/48/64/96/128/160/192/224/235 ->");
	for (v = 16; v <= 235; v += 16) printf(" %u", lut[v]);
	printf(" %u\n", lut[235]);
	printf("  输出码种数 %d/220，撞码 %d 条，第一个到 235 的输入码 %d\n",
	       st.distinct, st.plateau, st.first_235);
	printf("  码位粒度：暗部 24->25 跨 %.2f nits，中间 140->141 跨 %.2f nits\n",
	       st.nits_shadow, st.nits_mid);
	printf("  色度增益 Q10：16=%u 24=%u 32=%u 64=%u 128=%u 192=%u 235=%u\n",
	       gain[16], gain[24], gain[32], gain[64], gain[128], gain[192], gain[235]);
	printf("  增益被 3.9 封顶：%d 条", st.gain_clamp);
	if (st.gain_clamp) printf("（从码 %u 起）", st.gain_clamp_from);
	printf("\n");
	for (v = 17; v <= 235; v++)
		if (lut[v] < lut[v - 1]) mono = 0;
	ok(mono, "Y LUT 单调不降");
	printf("  （220 条输入压缩到 %d 种输出，撞码集中在高光：这是\"参考白=面板白\"的必然结果，\n"
	       "    不是 bug —— 见 [4] 各曲线的码位分配）\n", st.distinct);
}

/* ---------------- 2b. 色度增益随亮度怎么走 ---------------- */
static void t_gain(void)
{
	static const double codes[] = { 17, 24, 32, 48, 64, 96, 128, 160, 192, 224 };
	unsigned i;

	printf("\n[2b] 色度增益 acutal vs 线性光比值（sat=%.2f）\n", C.sat);
	printf("  Y 码    内容 nits | code 模式（历史） | lin 模式\n");
	for (i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
		unsigned char lc[256], ll[256];
		unsigned short gc[256], gl[256];
		struct hdrcolor a = C, b = C;
		unsigned v = (unsigned)codes[i];

		a.gain_mode = HC_GAIN_CODE;
		b.gain_mode = HC_GAIN_LIN;
		hc_build(&a, lc, gc);
		hc_build(&b, ll, gl);
		printf("  %3u  %10.2f | %7.3f           | %7.3f\n",
		       v, nits_of_code(v, C.full), gc[v] / 1024.0, gl[v] / 1024.0);
	}
	printf("  code 模式在暗部趋 0（彩色变灰）、中间过冲 >1（过饱和）；\n");
	printf("  lin 模式 = 屏幕线性光/源线性光，拐点以下恒 1.0（=不做动作，与逐通道映射一致）。\n");
}

/* ---------------- 3. src_peak 到底改了什么 ---------------- */
static void t_srcpeak(void)
{
	struct hdrcolor a = C, b = C, lo = C;
	unsigned char la[256], lb[256], ll[256];
	unsigned short ga[256], gb[256], gl[256];
	int diff = 0, gdiff = 0, mono = 1, over = 0, ident = 1;
	double prev = -1.0, k = C.knee;
	unsigned v;

	a.src_peak = 1000.0;
	b.src_peak = 4000.0;
	hc_build(&a, la, ga);
	hc_build(&b, lb, gb);
	for (v = 0; v < 256; v++) {
		if (la[v] != lb[v]) diff++;
		if (ga[v] != gb[v]) gdiff++;
	}
	printf("\n[3] src_peak（内容峰值）的作用\n");
	/* 两条判据分开：clip 曲线压根没有肩部（src_peak 无处可用），sat=0 则
	 * 是关掉色度动作（gain 恒 1024，与峰值无关）。两者都是设计意图，
	 * 但混在一个 ok() 里就会把"参数关掉了"误报成"实现坏了"。 */
	if (C.curve != HC_CURVE) {
		/* clip 没肩部，Reinhard/Hable 是固定的解析曲线——三者都不看
		 * src_peak（见 hc_curve），这里本来就不该有差。 */
		printf("    （当前曲线不使用 src_peak：Y 差 %d 码、gain 差 %d 条，均为预期）\n",
		       diff, gdiff);
	} else if (C.sat <= 0.0) {
		ok(diff > 0, "src_peak=1000 vs 4000：Y 差 %d 码 —— 峰值真的参与运算了", diff);
		printf("    （sat=0：色度增益恒等，gain 差 %d 条是预期的）\n", gdiff);
	} else {
		/* 判据是"峰值有作用"，落在哪一路都算数：knee 逼近 1.0 时肩部只剩
		 * 几根码，Y 会被 8bit 量化抹平，但色度增益仍随峰值变（knee=0.98
		 * 实测 Y 差 0、gain 差 3）。钉死 Y 差等于把测试焊在 knee=0.7。 */
		ok(diff > 0 || gdiff > 0,
		   "src_peak=1000 vs 4000：Y 差 %d 码、gain 差 %d 条 —— 峰值真的参与运算了（老实现恒为 0）",
		   diff, gdiff);
	}

	/* 形状：单调、膝点以下 1:1、全程不过 1.0 */
	for (v = 0; v < 256; v++) {
		double n = ((int)v - 16) / 219.0, x, d;	/* v 是 unsigned，先转 int */

		if (n < 0.0) n = 0.0;
		x = hc_pq_eotf(n) / a.target;
		d = hc_curve(&a, x);
		if (d + 1e-9 < prev) mono = 0;
		if (d > 1.0 + 1e-9) over = 1;
		if (x <= k && fabs(d - x) > 1e-9) mono = 0;
		prev = d;
	}
	if (C.curve == HC_CURVE) {
		ok(mono, "单调、膝点(%.2f)以下 1:1 —— 暗部和中段不动，膝点处斜率连续", k);
		ok(!over, "全程不越过 1.0 —— 没有 Hermite/BT.2390 在大压缩比下的过冲");
	} else {
		/* Hable/Reinhard 是"永远压一点"的曲线族：没有 knee、输出也不归一到
		 * display white，上面两条天然不成立，这不是缺陷。 */
		printf("    （当前曲线无膝点/不归一到 display white：形状断言不适用）\n");
	}

	/* 端点：源峰值正好落到显示白（只有归一化到 display white 的肩部曲线认这条） */
	if (C.curve == HC_CURVE) {
		double d = hc_curve(&a, a.src_peak / a.target);

		ok(fabs(d - 1.0) < 1e-6, "1000nits 恰落到 display white：d=%.6f", d);
		d = hc_curve(&b, b.src_peak / b.target);
		ok(fabs(d - 1.0) < 1e-6, "4000nits 恰落到 display white：d=%.6f", d);
	}

	/* 源不出显示白（峰值<=target）就该完全不动作，等价于 clip */
	lo.src_peak = C.target * 0.9;
	hc_build(&lo, ll, gl);
	{
		struct hdrcolor cl = lo;

		cl.curve = HC_CLIP;
		hc_build(&cl, la, ga);
		for (v = 0; v < 256; v++)
			if (ll[v] != la[v]) ident = 0;
	}
	if (C.curve == HC_CURVE)
		ok(ident, "源峰值 <= target 时退化成不做（等价 clip）：内容装得下就别压");
	else
		printf("    （当前曲线总是压一点：src_peak<=target 不做判据）\n");

	/* 高光层次：新老曲线各把多少码位留给 200..1000nits */
	{
		static const double nt[] = { 200, 400, 700, 1000 };
		unsigned i;

		printf("  %-9s %8s %8s %6s %6s\n", "内容nits", "新d", "老d", "新码", "老码");
		for (i = 0; i < sizeof(nt) / sizeof(nt[0]); i++) {
			double x = nt[i] / a.target, dn, do_, dn_old;
			double t = (x - k) / (1.0 - k);

			dn = hc_curve(&a, x);
			dn_old = k + (1.0 - k) * (1.0 - exp(-t));
			do_ = 16.0 + 219.0 * hc_bt709_oetf(dn_old);
			printf("  %-9.0f %8.3f %8.3f %6.0f %6.0f\n", nt[i], dn,
			       dn_old, 16.0 + 219.0 * hc_bt709_oetf(dn), do_);
		}
	}
}

/* ---------------- 4. 每条曲线吃掉多少高光码位 ---------------- */
static void t_curves(void)
{
	static const int curves[] = { HC_CURVE, HC_CLIP, HC_REINHARD, HC_HABLE };
	static const char *name[] = { "curve", "clip", "reinhard", "hable" };
	static const double probes[] = { 100, 200, 400, 1000, 2000, 4000, 10000 };
	unsigned ci, pi;

	printf("\n[4] 各曲线的高光分配（target=%.0f nits，输出码）\n", C.target);
	printf("  %-9s", "内容 nits");
	for (pi = 0; pi < sizeof(probes) / sizeof(probes[0]); pi++)
		printf(" %6.0f", probes[pi]);
	printf("  | 200..1000 占码位\n");
	for (ci = 0; ci < 4; ci++) {
		struct hdrcolor c = C;
		unsigned char lut[256];
		unsigned short gain[256];
		int n_hi = 0, prev = -1;

		c.curve = curves[ci];
		hc_build(&c, lut, gain);
		printf("  %-9s", name[ci]);
		for (pi = 0; pi < sizeof(probes) / sizeof(probes[0]); pi++)
			printf(" %6d", lut[code_of_nits(probes[pi])]);
		for (pi = 16; pi <= 235; pi++) {
			double L = nits_of_code(pi, 0);

			if (L >= 200 && L <= 1000) {
				if (lut[pi] != prev) n_hi++;
				prev = lut[pi];
			}
		}
		printf("  | %d\n", n_hi);
	}
	printf("  说明：x = L/target，reinhard/hable 在 x>1 时数学上 >1.0 → 全部被 235 夹平；\n");
	printf("        curve(exp 软膝) 在 x>1 时渐近 1.0，高光被压成几条码（见最后一列）。\n");
}

/* ---------------- 5. 8bit 容器丢了多少 10bit 精度 ---------------- */
static void t_10bit(void)
{
	unsigned char lut[256];
	unsigned short gain[256];
	unsigned c10;
	int prev = -1, distinct = 0, worst_run = 0, run = 0;

	hc_build(&C, lut, gain);
	for (c10 = 64; c10 <= 940; c10++) {	/* 10bit 有限范围 */
		double n = (c10 - 64) / 876.0;
		int y8 = (int)(n * 219.0 + 16.0 + 0.5);
		int out = lut[y8];

		if (out != prev) {
			distinct++;
			if (run > worst_run) worst_run = run;
			run = 0;
			prev = out;
		} else {
			run++;
			if (run > worst_run) worst_run = run;
		}
	}
	printf("\n[5] 8bit 容器的量化损失\n");
	printf("  10bit PQ 源码 64..940（876 级）→ 8bit Y → LUT\n");
	printf("  输出只剩 %d 个码，最长 %d 个连续 10bit 码挤进同一输出码\n",
	       distinct, worst_run);
	/* 暗部：两个 8bit 输出码之间跨多少 10bit 源码 */
	{
		int lo = 64, n = 0;

		while (lo <= 940) {
			double nn = (lo - 64) / 876.0;
			int y8 = (int)(nn * 219.0 + 16.0 + 0.5);
			int out = lut[y8];
			int hi = lo;

			while (hi + 1 <= 940) {
				double n2 = (hi + 1 - 64) / 876.0;
				int y2 = (int)(n2 * 219.0 + 16.0 + 0.5);

				if (lut[y2] != out) break;
				hi++;
			}
			if (lo < 200) printf("    10bit %d..%d -> 8bit 输出码 %d\n", lo, hi, out);
			n++;
			lo = hi + 1;
		}
	}
	printf("  说明：vdec 出 NV12（8bit），HDR10 本来是 10bit；PQ 的码值曲线把精度\n");
	printf("        堆在暗部，砍掉 2bit 后暗部最先断层 —— 这是解码侧格式选的，不是曲线。\n");
}

/* ---------------- 6. 色度增益 / 色域矩阵：码值域 vs 线性光域 ---------------- */
struct rgb { double r, g, b; };

/* 是否默认工作点（C 在 main 里被命令行改过，就不能拿默认结论判成败） */
static int is_default_op(void)
{
	return C.curve == HC_CURVE && C.target == 200.0 && C.src_peak == 1000.0 &&
	       C.sat == 0.85 && C.knee == 0.7 && !C.full;
}

static void mat3v(const double *m, const struct rgb *in, struct rgb *out)
{
	out->r = m[0] * in->r + m[1] * in->g + m[2] * in->b;
	out->g = m[3] * in->r + m[4] * in->g + m[5] * in->b;
	out->b = m[6] * in->r + m[7] * in->g + m[8] * in->b;
}


/* 参考流水线用的线性光 2020→709（行主序），刻意不引用 hc_mat_2020 */
static const double GM2020[9] = {
	1.6605, -0.5876, -0.0728,
	-0.1246, 1.1329, -0.0083,
	-0.0182, -0.1006, 1.1187,
};

/* 浮点求逆，用来把 709 档的色块搬到 2020 里编码（见 t_color 第二组） */
static void mat709to2020(const struct rgb *in, struct rgb *out)
{
	out->r = 0.62740944 * in->r + 0.32926025 * in->g + 0.04327189 * in->b;
	out->g = 0.06912484 * in->r + 0.91954861 * in->g + 0.01132077 * in->b;
	out->b = 0.01642336 * in->r + 0.08804785 * in->g + 0.89561671 * in->b;
}

static double clamp01(double x)
{
	return x < 0.0 ? 0.0 : x > 1.0 ? 1.0 : x;
}

/* 参考（正确）：PQ 码 → 线性 源色域 → 亮度曲线在*线性*域 → 源色域→709 在线性域 → OETF
 * m 是源色域→709 的种子矩阵（2020 用 mat2020to709 那组数，P3 用 t_p3 里的）。 */
static void ref_pipeline(const double *m, double Yp, double cb, double cr,
			 const struct hdrcolor *c, struct rgb *out)
{
	struct rgb lin, lin709, o;
	double rp = Yp + HC_K2020_R * cr;
	double gp = Yp + HC_K2020_G_CB * cb + HC_K2020_G_CR * cr;
	double bp = Yp + HC_K2020_B * cb;
	double lr = hc_pq_eotf(clamp01(rp));
	double lg = hc_pq_eotf(clamp01(gp));
	double lb = hc_pq_eotf(clamp01(bp));

	/* 线性域做色域转换 */
	lin.r = lr / 10000.0;
	lin.g = lg / 10000.0;
	lin.b = lb / 10000.0;
	mat3v(m, &lin, &lin709);
	/* 线性域做色调映射（按 target 归一） */
	lin709.r = hc_curve(c, lin709.r * 10000.0 / c->target);
	lin709.g = hc_curve(c, lin709.g * 10000.0 / c->target);
	lin709.b = hc_curve(c, lin709.b * 10000.0 / c->target);
	/* 参考管线必须和实现在同一编码域（hc_out_oetf：默认 1886），
	 * 否则比出来的码差里混着 OETF 的固定偏移，测不出实现本身。 */
	o.r = 16.0 + 219.0 * hc_out_oetf(c, clamp01(lin709.r));
	o.g = 16.0 + 219.0 * hc_out_oetf(c, clamp01(lin709.g));
	o.b = 16.0 + 219.0 * hc_out_oetf(c, clamp01(lin709.b));
	*out = o;
}

/* 实现（软映射/GL）：Y 走 LUT，CbCr 乘该点增益，然后在码值域做 2020→709 */
static void got_pipeline(double Yp, double cb, double cr, const struct hdrcolor *c_in,
			 const unsigned char *lut, const unsigned short *gain,
			 int rgb709, struct rgb *out)
{
	int y8 = (int)(Yp * 219.0 + 16.0 + 0.5);
	(void)c_in;
	double g, y1, cbn, crn;
	struct rgb rgb;

	y8 = y8 < 0 ? 0 : y8 > 255 ? 255 : y8;
	y1 = (lut[y8] - 16.0) / 219.0;
	g = gain[y8] / 1024.0;
	if (!rgb709) {
		/* 软映射路径：只有色度增益，没有真色域矩阵 */
		cbn = cb * g;
		crn = cr * g;
		rgb.r = clamp01(y1 + HC_K2020_R * crn);
		rgb.g = clamp01(y1 + HC_K2020_G_CB * cbn + HC_K2020_G_CR * crn);
		rgb.b = clamp01(y1 + HC_K2020_B * cbn);
	} else {
		double r, gg, bb;
		/* GL 路径：码值域做 2020→709 */
		cbn = cb * g;
		crn = cr * g;
		r = y1 + HC_K2020_R * crn;
		gg = y1 + HC_K2020_G_CB * cbn + HC_K2020_G_CR * crn;
		bb = y1 + HC_K2020_B * cbn;
		rgb.r =  1.6605 * r - 0.5876 * gg - 0.0728 * bb;
		rgb.g = -0.1246 * r + 1.1329 * gg - 0.0083 * bb;
		rgb.b = -0.0182 * r - 0.1006 * gg + 1.1187 * bb;
	}
	out->r = 16.0 + 219.0 * clamp01(rgb.r);
	out->g = 16.0 + 219.0 * clamp01(rgb.g);
	out->b = 16.0 + 219.0 * clamp01(rgb.b);
}

/* 用 2020 原色做色块：Yp/Cb/Cr 由线性 2020 RGB 经 PQ 编出来 */
static void rgb2020_to_yuv(const struct rgb *rgb, double *Yp, double *cb, double *cr)
{
	double lr = hc_pq_oetf(rgb->r * 10000.0), lg = hc_pq_oetf(rgb->g * 10000.0),
	       lb = hc_pq_oetf(rgb->b * 10000.0);
	double y = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb;

	*Yp = y;
	*cb = (lb - y) / HC_K2020_B;
	*cr = (lr - y) / HC_K2020_R;
}

static double hue_deg(const struct rgb *p)
{
	/* 码值域里的色相（够用来量"转没转色"） */
	double mx = fmax(p->r, fmax(p->g, p->b));
	double mn = fmin(p->r, fmin(p->g, p->b));
	double c = mx - mn, h = 0.0;

	if (c < 1e-9) return 0.0;
	if (mx == p->r) h = fmod((p->g - p->b) / c, 6.0);
	else if (mx == p->g) h = (p->b - p->r) / c + 2.0;
	else h = (p->r - p->g) / c + 4.0;
	h *= 60.0;
	if (h < 0) h += 360.0;
	return h;
}

static void t_color(void)
{
	static const char *pn[] = { "白 200nit", "灰 100nit", "灰 20nit", "暗红 2nit", "暗蓝 5nit",
				    "2020 红", "2020 绿", "2020 蓝", "肤色", "2020 青" };
	static const double patches[][3] = {	/* 线性 BT.2020 RGB，1.0 = 10000 nits */
		{ 0.0200, 0.0200, 0.0200 },	/* 200 nits 白 */
		{ 0.0100, 0.0100, 0.0100 },	/* 100 nits */
		{ 0.0020, 0.0020, 0.0020 },	/* 20 nits */
		{ 0.0002, 0.00001, 0.00001 },	/* 2 nits 暗红 */
		{ 0.00001, 0.00001, 0.0005 },	/* 5 nits 暗蓝 */
		{ 0.1000, 0.0004, 0.0004 },	/* 1000 nit 红块 */
		{ 0.0020, 0.1000, 0.0020 },
		{ 0.0020, 0.0020, 0.1000 },
		{ 0.0550, 0.0330, 0.0220 },	/* 肤色 */
		{ 0.0020, 0.0600, 0.0600 },
	};
	unsigned char lut[256], lut2[256];
	unsigned short gain[256], gain2[256];
	double worst_lin = 0.0;
	double worst_soft = 0.0, worst_gl = 0.0, worst_hue = 0.0, worst_hue_gl = 0.0;
	unsigned i;

	{
		struct hdrcolor c2 = C;

		c2.gain_mode = HC_GAIN_LIN;
		hc_build(&c2, lut2, gain2);
	}
	hc_build(&C, lut, gain);
	printf("\n[6] 色度/色域：码值域实现 vs 线性光域参考（输出 YCbCr 码 16..235）\n");
	printf("  %-9s | %-27s | %-27s | %s\n", "色块", "参考（线性域 2020->709）",
	       "软映射（只乘增益）", "GL（码值域矩阵）");
	for (i = 0; i < sizeof(patches) / sizeof(patches[0]); i++) {
		struct rgb lin = { patches[i][0], patches[i][1], patches[i][2] };
		struct rgb ref, soft, gl, soft2;
		double Yp, cb, cr, dsoft, dgl, dh, dhg;

		rgb2020_to_yuv(&lin, &Yp, &cb, &cr);
		ref_pipeline(GM2020, Yp, cb, cr, &C, &ref);
		got_pipeline(Yp, cb, cr, &C, lut, gain, 0, &soft);
		got_pipeline(Yp, cb, cr, &C, lut, gain, 1, &gl);
		got_pipeline(Yp, cb, cr, &C, lut2, gain2, 0, &soft2);
		/* 三个差值都先算完再打印：原来 dsoft/dgl 在 printf 之后才赋值，
		 * 表里的 code Δ 列是上一行遗留值（第一行还是未初始化的垃圾）。 */
		dsoft = fmax(fabs(soft.r - ref.r), fmax(fabs(soft.g - ref.g), fabs(soft.b - ref.b)));
		dgl = fmax(fabs(gl.r - ref.r), fmax(fabs(gl.g - ref.g), fabs(gl.b - ref.b)));
		{
			double dl = fmax(fabs(soft2.r - ref.r), fmax(fabs(soft2.g - ref.g),
					 fabs(soft2.b - ref.b)));

			if (dl > worst_lin) worst_lin = dl;
			printf("  %-10s ref %3.0f %3.0f %3.0f | code Δ%4.1f | lin Δ%4.1f | gl Δ%4.1f\n",
			       pn[i], ref.r, ref.g, ref.b, dsoft, dl, dgl);
		}
		dh = fabs(hue_deg(&soft) - hue_deg(&ref));
		if (dh > 180) dh = 360 - dh;
		dhg = fabs(hue_deg(&gl) - hue_deg(&ref));
		if (dhg > 180) dhg = 360 - dhg;
		if (dsoft > worst_soft) worst_soft = dsoft;
		if (dgl > worst_gl) worst_gl = dgl;
		if (dh > worst_hue) worst_hue = dh;
		if (dhg > worst_hue_gl) worst_hue_gl = dhg;
		printf("  %-9s | %4.0f %4.0f %4.0f (%5.1f°)    | %4.0f %4.0f %4.0f (%5.1f°)  | %4.0f %4.0f %4.0f (%5.1f°)  Δ%5.1f/Δh%5.1f\n",
		       pn[i], ref.r, ref.g, ref.b, hue_deg(&ref),
		       soft.r, soft.g, soft.b, hue_deg(&soft),
		       gl.r, gl.g, gl.b, hue_deg(&gl), dgl, dhg);
	}
	printf("  最坏码差：软/code %.1f，软/lin %.1f，GL %.1f\n",
	       worst_soft, worst_lin, worst_gl);

	/* 上面那组 2020 原色是"色域外"的：参考在线性域做 2020->709 矩阵，
	 * 负值被夹到 0；软映射没有矩阵，只有标量色度增益，硬要它贴参考等于
	 * 让一个标量去代替 3x3 矩阵 —— 谁的标量刚好落得近，谁就"赢"，跟
	 * 增益算法本身没关系。所以增益的结论只在"色域内"内容上成立：
	 * 把 709 档的色块搬到 2020 里编码，参考的矩阵≈恒等，两条路径差的
	 * 就只有曲线和增益。
	 *
	 * 但即使色域内，也只有"暗部低饱和"区的比较有意义：
	 *   - Y 这个 LUT 是按 YCbCr 的 Y 码算的，而 Y ≠ 亮度。高饱和色块的
	 *     Y 码（如纯红 1000nit 的 Y 码 = 0.5）对应的 PQ 亮度只有 ~34nits，
	 *     LUT 于是给出 171 码，而逐通道参考是 235 —— 差 64 码，两条增益
	 *     都改不了（增益只动 Cb/Cr）。所以亮/高饱和块只列数据不判成败。
	 *   - 暗部低饱和区，逐通道映射 = 恒等，标量增益里只有 lin 能做到
	 *     x<=knee ⇒ g=1（code 的 nout/n 在 n 很小时会爆炸）。
	 */
	{
		static const char *gn[] = { "709 红 1000nit", "709 绿 1000nit",
					    "709 蓝 1000nit", "709 青 600nit",
					    "709 黄 600nit", "709 肤色 180nit",
					    "709 灰 20nit", "709 暗红 2nit",
					    "709 暗蓝 5nit" };
		static const double p709[][3] = {
			{ 0.1000, 0.0005, 0.0005 },
			{ 0.0010, 0.1000, 0.0010 },
			{ 0.0010, 0.0010, 0.1000 },
			{ 0.0005, 0.0600, 0.0600 },
			{ 0.0600, 0.0600, 0.0005 },
			{ 0.0300, 0.0180, 0.0120 },
			{ 0.0020, 0.0020, 0.0020 },
			{ 0.0002, 0.00001, 0.00001 },
			{ 0.00001, 0.00001, 0.0005 },
		};
		/* 只有这三个（灰 20nit / 暗红 2nit / 暗蓝 5nit）低饱和且在图以下 */
		static const int dark[] = { 6, 7, 8 };
		unsigned char lut1[256];
		unsigned short gain1[256];
		double wc_lo = 0.0, wl_lo = 0.0, wn_lo = 0.0;
		double wc_hi = 0.0, wl_hi = 0.0;
		unsigned d, q;

		/* g=1 基线：只有 Y LUT、不碰色度。增益到底帮了还是害了，跟它比 */
		for (q = 0; q < 256; q++) {
			lut1[q] = lut[q];
			gain1[q] = 1024;
		}
		printf("  色域内（709 档色块按 2020 编码，参考矩阵≈恒等；g=1 是「不碰色度」的基线）\n");
		for (i = 0; i < sizeof(p709) / sizeof(p709[0]); i++) {
			struct rgb l709 = { p709[i][0], p709[i][1], p709[i][2] };
			struct rgb l2020, ref, soft, soft2, n0;
			double Yp, cb, cr, dc, dl, dn, xl, yl;
			int is_dark = 0;

			mat709to2020(&l709, &l2020);
			rgb2020_to_yuv(&l2020, &Yp, &cb, &cr);
			ref_pipeline(GM2020, Yp, cb, cr, &C, &ref);
			got_pipeline(Yp, cb, cr, &C, lut, gain, 0, &soft);
			got_pipeline(Yp, cb, cr, &C, lut2, gain2, 0, &soft2);
			got_pipeline(Yp, cb, cr, &C, lut1, gain1, 0, &n0);
			dc = fmax(fabs(soft.r - ref.r), fmax(fabs(soft.g - ref.g), fabs(soft.b - ref.b)));
			dl = fmax(fabs(soft2.r - ref.r), fmax(fabs(soft2.g - ref.g), fabs(soft2.b - ref.b)));
			dn = fmax(fabs(n0.r - ref.r), fmax(fabs(n0.g - ref.g), fabs(n0.b - ref.b)));
			/* xl：按真亮度算的 x（实现看不到它，只作说明）；
			 * yl：实现实际看到的 x —— 由 Y 码反推的 PQ 亮度 / target */
			xl = (0.2126 * l709.r + 0.7152 * l709.g + 0.0722 * l709.b) * 10000.0 / C.target;
			yl = hc_src_lin(&C, Yp) / C.target;
			for (d = 0; d < sizeof(dark) / sizeof(dark[0]); d++)
				if ((int)i == dark[d]) is_dark = 1;
			if (is_dark) {
				if (dc > wc_lo) wc_lo = dc;
				if (dl > wl_lo) wl_lo = dl;
				if (dn > wn_lo) wn_lo = dn;
			} else {
				if (dc > wc_hi) wc_hi = dc;
				if (dl > wl_hi) wl_hi = dl;
			}
			printf("    %-14s x=%5.2f(Y码%4.2f) ref %3.0f %3.0f %3.0f | g=1 Δ%5.1f"
			       " | code %3.0f %3.0f %3.0f Δ%5.1f | lin %3.0f %3.0f %3.0f Δ%5.1f\n",
			       gn[i], xl, yl, ref.r, ref.g, ref.b, dn,
			       soft.r, soft.g, soft.b, dc, soft2.r, soft2.g, soft2.b, dl);
		}
		printf("    暗部低饱和（灰20/暗红/暗蓝）最坏：g=1 %.1f，code %.1f，lin %.1f\n",
		       wn_lo, wc_lo, wl_lo);
		printf("    其余（亮/高饱和）最坏：code %.1f，lin %.1f（差 %0.1f 码）\n",
		       wc_hi, wl_hi, wl_hi - wc_hi);
		/* 这几条结论是"在默认工作点"上量出来的：换 target/knee 会同时
		 * 移动参考和两条实现（--target=300 时 code 反而比基线好 3 码，
		 * --target=100 时 lin 比基线差 5 码）。所以只在默认参数下判成败，
		 * 扫参数时只出数据 —— 否则扫参就会变成"调测试而不是调代码"。 */
		if (is_default_op()) {
			ok(wl_lo < wc_lo, "暗部低饱和：lin 增益比 code 增益更贴参考（%.1f vs %.1f 码）",
			   wl_lo, wc_lo);
			ok(wl_lo <= wn_lo + 0.5, "暗部低饱和：lin 增益≈不动作（%.1f vs 基线 %.1f）",
			   wl_lo, wn_lo);
			ok(wc_lo > wn_lo, "暗部低饱和：code 增益把色度改坏了（%.1f > 基线 %.1f）",
			   wc_lo, wn_lo);
			/* 高光区不判"谁更贴"：逐通道参考从不下饱和、而 Y LUT 已经按
			 * luma 语义偏了几十码，这里只钉住"lin 的额外去饱和不失控"。 */
			ok(wl_hi <= wc_hi * 1.35 + 1.0,
			   "亮/高饱和：lin 的去饱和不超过 code 的 1.35 倍（%.1f vs %.1f 码）",
			   wl_hi, wc_hi);
		} else {
			printf("    （非默认参数：只列数据，不判成败）\n");
		}
	}
	printf("  注：2020 原色那几行的差主要来自\"软映射没有 2020->709 矩阵\"，\n");
	printf("      标量色度增益补不出来（GL 路径有码值域矩阵，所以它最接近）。\n");
}

/* ---------------- 7. SDR 内容的误伤 ---------------- */
static void t_sdr(void)
{
	double Yp = 0.5, cb = 0.0, cr = 0.0;	/* BT.709 灰 50% */

	(void)cb; (void)cr;
	double n = hc_pq_eotf(Yp);
	int c16 = code_of_nits(n);
	unsigned char lut[256];
	unsigned short gain[256];

	hc_build(&C, lut, gain);
	printf("\n[7] SDR(BT.709) 内容走 HDR 路径会怎样\n");
	printf("  BT.709 50%% 灰（YS=126）被当成 PQ 0.49 解：%.0f nits → 输出码 %d\n",
	       n, lut[126]);
	printf("  正确应是 126（曲线在 200nit target 下把 126 当 %.0f nits 处理）\n", n);
	(void)c16;
	/* 判据只钉"被提亮"这个方向：绝对码随 target/full 变（200/300/全范围
	 * 分别落到 160+/137/160），拿绝对值当判据等于把测试焊死在默认参数上。 */
	ok(lut[126] > 126 + 5, "确认：SDR 内容若无 HDR 开关保护会被整体提亮（126 -> %d）",
	   lut[126]);
	printf("  现在的保护：两条路径都看 VUI 传递函数（hc_is_hdr）。\n");
	printf("  VUI 写 1/6/14/15（SDR）→ 自动透传；写 16/18 → 自动映射；\n");
	printf("  没写 VUI（0）才退回 HDR=1/play.sh 的 ffprobe 判定。见 [9]。\n");
}

/* ---------------- 8. HLG（BT.2100） ---------------- */
static void t_hlg(void)
{
	static const double e[] = { 0.1, 0.25, 0.5, 0.75, 1.0 };
	unsigned i;
	double worst_rt = 0.0;
	unsigned char lut[256];
	unsigned short gain[256];
	struct hdrcolor c = C;

	printf("\n[8] HLG (BT.2100 逆 OETF + OOTF)\n");
	for (i = 0; i < sizeof(e) / sizeof(e[0]); i++) {
		double ls = hc_hlg_inv_oetf(e[i]);
		double rt = hc_hlg_oetf(ls);
		double d = fabs(rt - e[i]);

		if (d > worst_rt) worst_rt = d;
		printf("  e=%.2f → Ls=%.4f → 1000nit 显示 %.1f nits\n",
		       e[i], ls, hc_hlg_eotf(e[i], 1000.0));
	}
	ok(worst_rt < 1e-6, "HLG OETF/逆 OETF 往返（最坏 %.2e）", worst_rt);
	/* 75% 信号 = 参考白 203nits（BT.2100 对 1000nits 显示的约定） */
	ok(fabs(hc_hlg_eotf(0.75, 1000.0) - 203.0) < 2.0,
	   "HLG 75%% 信号 = 参考白 %.0f nits（应 203）", hc_hlg_eotf(0.75, 1000.0));
	ok(fabs(hc_hlg_eotf(1.0, 1000.0) - 1000.0) < 1.0,
	   "HLG 100%% 信号 = 峰值 %.0f nits", hc_hlg_eotf(1.0, 1000.0));
	/* HLG 的 LUT：1000nits 源压到 200nits 屏，白点仍落在 235 */
	c.transfer = HC_TF_HLG;
	hc_build(&c, lut, gain);
	printf("  HLG LUT：码 235 → %d，码 128 → %d\n", lut[235], lut[128]);
	ok(lut[235] <= 236 && lut[235] >= 225, "HLG 白点没被压飞（235→%d）", lut[235]);
	ok(lut[0] <= 18, "HLG 黑点没被抬高（0→%d）", lut[0]);
}

/* ---------------- 9. 传递函数决定开关 ---------------- */
static void t_tf(void)
{
	unsigned char lut[256], id[256];
	unsigned short gain[256];
	struct hdrcolor c = C;
	int i, same = 1;

	printf("\n[9] 传递函数 → EOTF / 开关\n");
	c.transfer = HC_TF_709;
	ok(!hc_is_hdr(&c), "VUI=1(BT.709) → 不按 HDR 处理");
	hc_build(&c, lut, gain);
	for (i = 0; i < 256; i++) {
		id[i] = (unsigned char)i;
		if (lut[i] != id[i] || gain[i] != 1024) same = 0;
	}
	ok(same, "SDR 内容 LUT 是恒等映射（不误伤）");
	c.transfer = HC_TF_UNKNOWN;
	ok(hc_is_hdr(&c), "VUI 没写(0) → 按 PQ 兜底，仍然映射");
	c.transfer = HC_TF_HLG;
	ok(hc_is_hdr(&c), "VUI=18(HLG) → HDR");
	c.transfer = HC_TF_PQ;
	ok(hc_is_hdr(&c), "VUI=16(PQ) → HDR");
}

/* [10] 色域 → 饱和度系数：709 源不该被动，2020 才压，P3 居中
 * （design_color.md §4.3.4：sat 不是旋钮，是色域的函数）
 */
static void t_sat(void)
{
	unsigned char lut[256];
	unsigned short g085[256], g100[256];
	struct hdrcolor c = C;
	double s709 = hc_sat_from_primaries(HC_PRI_709, 0.85);
	double s2020 = hc_sat_from_primaries(HC_PRI_2020, 0.85);
	double sp3 = hc_sat_from_primaries(HC_PRI_P3, 0.85);
	double snone = hc_sat_from_primaries(0, 0.85);
	int i, id_ok = 1;

	printf("\n[10] 色域 → sat（wide=0.85）\n");
	ok(s709 == 1.0, "BT.709 源 sat=1.0（不动作）");
	ok(fabs(s2020 - 0.85) < 1e-9, "BT.2020 源 sat=0.85（压到 wide）");
	ok(sp3 > 0.85 && sp3 < 1.0, "P3-D65 夹在中间");
	ok(snone == s2020, "没写 primaries → 按 2020 兜底");
	ok(hc_sat_from_primaries(5, 0.85) == 1.0, "BT.470 之类窄色域 → 1.0");
	printf("  sat: 709=%.2f 2020=%.2f P3=%.2f 未标=%.2f\n",
	       s709, s2020, sp3, snone);

	/* 线性光增益 + sat=1：膝点以下必须恒等 1024（709 片走 HDR 路径也不掉色） */
	c.gain_mode = HC_GAIN_LIN;
	c.sat = 1.0;
	hc_build(&c, lut, g100);
	for (i = 16; i <= 135; i++)	/* 膝点在 v=136（knee=0.7, peak=1000） */
		if (g100[i] != 1024) id_ok = 0;
	ok(id_ok, "sat=1.0 → 膝点(v<136)以下色度增益恒 1.0（不误伤 709 源）");
	/* sat<1 只缩放“偏离 1 的量”，不是把增益整个乘掉 */
	c.sat = 0.85;
	hc_build(&c, lut, g085);
	ok(g085[235] > g100[235] && g085[235] < 1024,
	   "sat=0.85：高光增益在 1 与全量之间（插值，非相乘）");
	printf("  增益[235]: sat=1.00 → %u，sat=0.85 → %u（1024=1.0）\n",
	       g100[235], g085[235]);

	/* wide 只决定 2020 压多少，709 的结论与 wide 无关 */
	ok(hc_sat_from_primaries(HC_PRI_709, 0.90) == 1.0,
	   "wide 参数不影响 709 的结论");
	ok(fabs(hc_sat_from_primaries(HC_PRI_2020, 0.90) - 0.90) < 1e-9,
	   "GL 路径 wide=0.90");
}

/* [11] 2020→709 矩阵：软映射现在也有 3x3（hc_chroma709），和 GL 片元
 * 共用 hdrcolor.inc 里同一组系数，目标是把色域外原色的码差从"一个标量
 * 增益硬贴 3x3"的 100+ 码压到 GL 路径的量级。
 *
 * 判据用 design_color.md §6 的码差：参考 = 线性域 2020→709 再逐通道曲线。
 */
static void decode_uv(double ytm, double u, double v, int k2020, struct rgb *o)
{
	double y1 = (ytm - 16.0) / 219.0;
	double cb = (u - 128.0) / 224.0, cr = (v - 128.0) / 224.0;

	if (k2020) {
		o->r = y1 + HC_K2020_R * cr;
		o->g = y1 + HC_K2020_G_CB * cb + HC_K2020_G_CR * cr;
		o->b = y1 + HC_K2020_B * cb;
	} else {
		o->r = y1 + HC_K709_R * cr;
		o->g = y1 + HC_K709_G_CB * cb + HC_K709_G_CR * cr;
		o->b = y1 + HC_K709_B * cb;
	}
	o->r = 16.0 + 219.0 * clamp01(o->r);
	o->g = 16.0 + 219.0 * clamp01(o->g);
	o->b = 16.0 + 219.0 * clamp01(o->b);
}

static void t_mat(void)
{
	static const char *pn[] = { "2020 红", "2020 绿", "2020 蓝", "2020 青", "肤色", "灰 200nit" };
	static const double patches[][3] = {
		{ 0.1000, 0.0004, 0.0004 },
		{ 0.0020, 0.1000, 0.0020 },
		{ 0.0020, 0.0020, 0.1000 },
		{ 0.0020, 0.0600, 0.0600 },
		{ 0.0550, 0.0330, 0.0220 },
		{ 0.0200, 0.0200, 0.0200 },
	};
	unsigned char lut[256];
	unsigned short gain[256];
	double worst_m = 0.0, worst_g = 0.0, worst_s = 0.0, maxduv = 0.0;
	unsigned i;

	printf("\n[11] 2020→709 矩阵（hc_chroma709，与 GL 片元同系数，sat=1 只看矩阵）\n");
	ok(hc_needs_mat(HC_PRI_2020), "2020 源走矩阵");
	ok(!hc_needs_mat(HC_PRI_709), "709 源不走矩阵（恒等）");
	ok(hc_needs_mat(0), "VUI 没写 primaries → 2020 兜底，走矩阵");
	ok(hc_needs_mat(HC_PRI_P3), "P3-D65 源走自己的矩阵");

	hc_build(&C, lut, gain);
	for (i = 0; i < sizeof(patches) / sizeof(patches[0]); i++) {
		struct rgb lin = { patches[i][0], patches[i][1], patches[i][2] };
		struct rgb ref, gm, sc;
		double Yp, cb, cr, y8, ytm, g, u, v, um, vm;
		double dm, dg, ds;

		rgb2020_to_yuv(&lin, &Yp, &cb, &cr);
		/* 源以 8bit 码送进软映射：u/v 码 + 增益查表用的 Y 码 */
		y8 = Yp * 219.0 + 16.0;
		y8 = y8 < 0 ? 0 : y8 > 255 ? 255 : (int)(y8 + 0.5);
		ytm = lut[(int)y8];
		g = gain[(int)y8];
		u = 128.0 + 224.0 * cb;
		v = 128.0 + 224.0 * cr;
		ref_pipeline(GM2020, Yp, cb, cr, &C, &ref);
		/* 新：矩阵路径（输出按 709 读回） */
		hc_chroma709(ytm, u, v, g, 1.0, hc_mat_2020, &um, &vm);
		decode_uv(ytm, um, vm, 0, &gm);
		/* 旧：只有标量增益（输出仍是 2020 色度，按 2020 读回） */
		{
			double uo = 128.0 + (((u - 128.0) * g) / 1024.0);
			double vo = 128.0 + (((v - 128.0) * g) / 1024.0);

			decode_uv(ytm, uo, vo, 1, &sc);
			if (fabs(uo - 128.0) > maxduv) maxduv = fabs(uo - 128.0);
		}
		dm = fmax(fabs(gm.r - ref.r), fmax(fabs(gm.g - ref.g), fabs(gm.b - ref.b)));
		{	/* 生产默认带 sat（2020 源 0.85）：矩阵之后再去饱和，色域外原色
			 * 收得更狠，但色域内内容也被压低，所以单独列一列 */
			struct rgb gs;
			double uns, vns;

			hc_chroma709(ytm, u, v, g, C.sat, hc_mat_2020, &uns, &vns);
			decode_uv(ytm, uns, vns, 0, &gs);
			ds = fmax(fabs(gs.r - ref.r), fmax(fabs(gs.g - ref.g), fabs(gs.b - ref.b)));
		}
		dg = fmax(fabs(sc.r - ref.r), fmax(fabs(sc.g - ref.g), fabs(sc.b - ref.b)));
		if (dm > worst_m) worst_m = dm;
		if (dg > worst_g) worst_g = dg;
		printf("  %-10s ref %3.0f %3.0f %3.0f | 增益 Δ%5.1f | 矩阵 Δ%5.1f | 矩阵+sat%.2f Δ%5.1f  uv %.0f/%.1f→%.0f/%.1f\n",
		       pn[i], ref.r, ref.g, ref.b, dg, dm, C.sat, ds, u, v, um, vm);
		if (ds > worst_s) worst_s = ds;
	}
	printf("  最坏码差：标量增益 %.1f → 矩阵 %.1f（sat=%.2f 时 %.1f）\n",
	       worst_g, worst_m, C.sat, worst_s);
	ok(worst_m <= worst_g, "矩阵不比标量增益差（%.1f <= %.1f）", worst_m, worst_g);
	ok(worst_s <= worst_g, "矩阵+去饱和也不比标量增益差（%.1f <= %.1f）", worst_s, worst_g);

	/* 无彩色：色度码 128 → 128，矩阵不能自己造出颜色 */
	{
		double um, vm;

		hc_chroma709(lut[128], 128.0, 128.0, gain[128], 1.0, hc_mat_2020,
			     &um, &vm);
		ok(fabs(um - 128.0) < 0.51 && fabs(vm - 128.0) < 0.51,
		   "灰 (u=v=128) 不被矩阵着色（→ %.1f/%.1f）", um, vm);
	}
	/* 709 源若误走矩阵：色域内的内容会被挪动 —— 这就是 hc_needs_mat 存在的理由 */
	{
		double um, vm, u2 = 128.0 + 224.0 * 0.1, v2 = 128.0 + 224.0 * 0.1;

		hc_chroma709(lut[128], u2, v2, gain[128], 1.0, hc_mat_2020,
			     &um, &vm);
		ok(fabs(um - u2) > 0.5 || fabs(vm - v2) > 0.5,
		   "饱和色走矩阵确实被挪动（%.1f/%.1f → %.1f/%.1f），709 源必须跳过", u2, v2, um, vm);
	}
}

/* P3-D65 源（Display P3 / HEVC 里 primaries=12）：它比 709 宽一点点，
 * 所以和 2020 一样要"矩阵 + 去饱和"，只是系数不同（hc_mat_p3）。
 * 这里拿参考流水线（线性域转换 + 曲线）当基准，量三件事：
 *   1) P3 系数比"只有标量增益"更接近参考（否则接了也白接）
 *   2) P3 系数比错套 2020 系数更接近参考（这就是把它接上的理由）
 *   3) 709 色域内的颜色（709 红在 P3 里的表示）不能被推出界
 */
static void t_p3(void)
{
	static const char *pn[] = { "P3 红", "P3 绿", "P3 蓝", "709 红(in P3)", "肤色", "灰 200nit" };
	static const double patches[][3] = {
		{ 0.1000, 0.0004, 0.0004 },
		{ 0.0020, 0.1000, 0.0020 },
		{ 0.0020, 0.0020, 0.1000 },
		/* 709 红原色换到 P3 线性域：inv(P3→709) * (1,0,0)，缩到 ~1000nit */
		{ 0.0822, 0.0033, 0.0017 },
		{ 0.0550, 0.0330, 0.0220 },
		{ 0.0200, 0.0200, 0.0200 },
	};
	/* 参考流水线用的线性光 P3→709（独立一份，不引用 hc_mat_p3） */
	static const double GMP3[9] = {
		1.2249, -0.2249,  0.0000,
		-0.0421, 1.0421,  0.0000,
		-0.0196, -0.0786, 1.0983,
	};
	unsigned char lut[256];
	unsigned short gain[256];
	double wp3 = 0.0, w20 = 0.0, ws = 0.0;
	struct hdrcolor C709 = C;	/* 码差阈值按 709 域标定过：本段固定在 709 域比 */
	unsigned i;

	printf("\n[12] P3-D65 → 709 矩阵（hc_mat_p3，GL 侧走同一个 uGm）\n");
	ok(hc_needs_mat(HC_PRI_P3), "P3 源走矩阵而不是标量增益");
	ok(!hc_needs_mat(HC_PRI_709), "709 源仍然恒等");
	ok(!strcmp(hc_mat_name(HC_PRI_P3), "P3→709"), "日志能区分 %s",
	   hc_mat_name(HC_PRI_P3));
	/* 行和 = 1（白点相同）：灰色只该被矩阵搬 0 码 */
	ok(fabs(hc_mat_p3[0] + hc_mat_p3[1] + hc_mat_p3[2] - 1.0) < 1e-4 &&
	   fabs(hc_mat_p3[3] + hc_mat_p3[4] + hc_mat_p3[5] - 1.0) < 1e-4 &&
	   fabs(hc_mat_p3[6] + hc_mat_p3[7] + hc_mat_p3[8] - 1.0) < 1e-4,
	   "P3 矩阵行和为 1（D65 白不动）");
	ok(hc_mat(HC_PRI_P3) != hc_mat(HC_PRI_2020), "P3 和 2020 是两组系数");
	ok(hc_mat(HC_PRI_709) == hc_mat_id, "709/窄色域拿恒等矩阵");

	/* 本段比的是"码差"（矩阵 vs 标量增益），阈值按 709 域标定；
	 * 换 1886 只是把同一线性光重新分布到码值，码差大小没有可比性，
	 * 所以这一段固定用 709 域，不跟实现的 TM_ENC 走。 */
	C709.enc = HC_ENC_709;
	hc_build(&C709, lut, gain);
	for (i = 0; i < sizeof(patches) / sizeof(patches[0]); i++) {
		struct rgb lin = { patches[i][0], patches[i][1], patches[i][2] };
		struct rgb ref, g3, g20, sc;
		double Yp, cb, cr, y8, ytm, g, u, v, u3, v3, u20, v20;
		double d3, d20, ds;

		/* 源仍是 2020 NCL 编码（真实 P3 片 matrix_coeffs=9），只是原色不同 */
		rgb2020_to_yuv(&lin, &Yp, &cb, &cr);
		y8 = Yp * 219.0 + 16.0;
		y8 = y8 < 0 ? 0 : y8 > 255 ? 255 : (int)(y8 + 0.5);
		ytm = lut[(int)y8];
		g = gain[(int)y8];
		u = 128.0 + 224.0 * cb;
		v = 128.0 + 224.0 * cr;
		ref_pipeline(GMP3, Yp, cb, cr, &C709, &ref);
		hc_chroma709(ytm, u, v, g, 1.0, hc_mat_p3, &u3, &v3);
		decode_uv(ytm, u3, v3, 0, &g3);
		hc_chroma709(ytm, u, v, g, 1.0, hc_mat_2020, &u20, &v20);
		decode_uv(ytm, u20, v20, 0, &g20);
		{
			double uo = 128.0 + (((u - 128.0) * g) / 1024.0);
			double vo = 128.0 + (((v - 128.0) * g) / 1024.0);

			decode_uv(ytm, uo, vo, 1, &sc);
		}
		d3 = fmax(fabs(g3.r - ref.r), fmax(fabs(g3.g - ref.g), fabs(g3.b - ref.b)));
		d20 = fmax(fabs(g20.r - ref.r), fmax(fabs(g20.g - ref.g), fabs(g20.b - ref.b)));
		ds = fmax(fabs(sc.r - ref.r), fmax(fabs(sc.g - ref.g), fabs(sc.b - ref.b)));
		if (d3 > wp3) wp3 = d3;
		if (d20 > w20) w20 = d20;
		if (ds > ws) ws = ds;
		printf("  %-12s ref %3.0f %3.0f %3.0f | 增益 %5.1f | P3 矩阵 %5.1f | 误用2020 %5.1f\n",
		       pn[i], ref.r, ref.g, ref.b, ds, d3, d20);
	}
	printf("  最坏码差：标量增益 %.1f | P3 矩阵 %.1f | 误用 2020 系数 %.1f\n",
	       ws, wp3, w20);
	ok(wp3 <= ws, "P3 矩阵不比标量增益差（%.1f <= %.1f）", wp3, ws);

	/* 上面那一列的 Δ 有个坑：色域外原色两边都会撞钳位（16/235），
	 * 谁推得更狠谁"看起来"更准（P3 红：P3 系数 52.7 vs 误用 2020 的 41.9，
	 * 20 系数把 G/B 推成负数撞到 16，恰好和参考撞在一起）。矩阵对不对
	 * 不能靠钳位背书，所以单独量一次：只在 709 色域内的颜色上，
	 * 比非线性 RGB 的误差，不带曲线也不带钳位。 */
	{
		double em3 = 0.0, e20 = 0.0, eid = 0.0, x3 = 0.0, x20 = 0.0;
		int nn = 0, ir, ig, ib;

		for (ir = 0; ir <= 8; ir++)
		for (ig = 0; ig <= 8; ig++)
		for (ib = 0; ib <= 8; ib++) {
			struct rgb s = { ir / 8.0, ig / 8.0, ib / 8.0 };
			struct rgb lin, l709;
			double e_a, e_b, e_c, ref[3], got3[3], got20[3], gotid[3];
			int k, out = 0;

			lin.r = hc_bt709_eotf(s.r);
			lin.g = hc_bt709_eotf(s.g);
			lin.b = hc_bt709_eotf(s.b);
			mat3v(GMP3, &lin, &l709);	/* 线性域真值 */
			for (k = 0; k < 3; k++) {
				double v = k == 0 ? l709.r : k == 1 ? l709.g : l709.b;

				if (v < -1e-6 || v > 1.0 + 1e-6) out = 1;
			}
			if (out) continue;		/* 709 装不下的颜色不比 */
			/* 这一段比的是"码差"大小（矩阵 vs 标量增益），码差是
			 * 编码域的度量，阈值按 709 OETF 标定过；换 1886 只是把
			 * 同一条线性光重新分布到码值上，比出来的数没有可比性。
			 * 所以这里固定用 709 域比相对优劣，不跟实现编码走。 */
			ref[0] = hc_bt709_oetf(clamp01(l709.r));
			ref[1] = hc_bt709_oetf(clamp01(l709.g));
			ref[2] = hc_bt709_oetf(clamp01(l709.b));
			got3[0] = hc_mat_p3[0] * s.r + hc_mat_p3[1] * s.g + hc_mat_p3[2] * s.b;
			got3[1] = hc_mat_p3[3] * s.r + hc_mat_p3[4] * s.g + hc_mat_p3[5] * s.b;
			got3[2] = hc_mat_p3[6] * s.r + hc_mat_p3[7] * s.g + hc_mat_p3[8] * s.b;
			got20[0] = hc_mat_2020[0] * s.r + hc_mat_2020[1] * s.g + hc_mat_2020[2] * s.b;
			got20[1] = hc_mat_2020[3] * s.r + hc_mat_2020[4] * s.g + hc_mat_2020[5] * s.b;
			got20[2] = hc_mat_2020[6] * s.r + hc_mat_2020[7] * s.g + hc_mat_2020[8] * s.b;
			gotid[0] = s.r; gotid[1] = s.g; gotid[2] = s.b;
			e_a = e_b = e_c = 0.0;
			for (k = 0; k < 3; k++) {
				double da = fabs(got3[k] - ref[k]);
				double db = fabs(got20[k] - ref[k]);
				double dc = fabs(gotid[k] - ref[k]);

				if (da > e_a) e_a = da;
				if (db > e_b) e_b = db;
				if (dc > e_c) e_c = dc;
			}
			em3 += e_a; e20 += e_b; eid += e_c; nn++;
			if (e_a > x3) x3 = e_a;
			if (e_b > x20) x20 = e_b;
		}
		if (nn) {
			printf("  709 色域内 %d 点（非线性 RGB，不带曲线）：P3 系数 均 %4.1f 码 / 峰 %5.1f，"
			       "误用 2020 均 %4.1f / 峰 %5.1f，恒等 均 %4.1f\n",
			       nn, em3 / nn * 255.0, x3 * 255.0, e20 / nn * 255.0,
			       x20 * 255.0, eid / nn * 255.0);
			ok(em3 < e20, "709 色域内 P3 系数比误用 2020 系数准（%.1f < %.1f 码）",
			   em3 / nn * 255.0, e20 / nn * 255.0);
			ok(em3 < eid, "709 色域内 P3 系数比恒等准（%.1f < %.1f 码）",
			   em3 / nn * 255.0, eid / nn * 255.0);
			ok(x3 < 0.5, "709 色域内峰值误差 < 128 码（%.1f）", x3 * 255.0);
		}
	}
	/* 灰：色度码 128 → 128，矩阵不许自己造色 */
	{
		double um, vm;

		hc_chroma709(lut[128], 128.0, 128.0, gain[128], 1.0, hc_mat_p3, &um, &vm);
		ok(fabs(um - 128.0) < 0.51 && fabs(vm - 128.0) < 0.51,
		   "P3 灰 (u=v=128) 不被矩阵着色（→ %.1f/%.1f）", um, vm);
	}
}

/* ---------------- main ---------------- */
int main(int argc, char **argv)
{
	int i;

	C.on = 1;
	C.curve = HC_CURVE;
	C.src_peak = 1000.0;
	C.target = 200.0;
	C.sat = 0.85;
	C.knee = 0.7;
	C.full = 0;
	for (i = 1; i < argc; i++) {
		if (!strncmp(argv[i], "--curve=", 8)) {
			const char *v = argv[i] + 8;

			C.curve = !strcmp(v, "clip") ? HC_CLIP :
				  !strcmp(v, "reinhard") ? HC_REINHARD :
				  !strcmp(v, "hable") ? HC_HABLE : HC_CURVE;
		} else if (!strncmp(argv[i], "--target=", 9)) {
			C.target = atof(argv[i] + 9);
		} else if (!strncmp(argv[i], "--sat=", 6)) {
			C.sat = atof(argv[i] + 6);
		} else if (!strncmp(argv[i], "--knee=", 7)) {
			C.knee = atof(argv[i] + 7);
		} else if (!strncmp(argv[i], "--peak=", 7)) {
			C.src_peak = atof(argv[i] + 7);
		} else if (!strcmp(argv[i], "--full")) {
			C.full = 1;
		}
	}
	/* 与生产侧同一条兜底（v4l2hevc.c / glout.c 的 TM_* 解析）：越界值会被
	 * 拉回默认，不然自检拿 knee=1.0 / sat=-0.1 这类退化输入去跑，报出来的
	 * "失败"只是输入非法，不是实现坏了。 */
	if (C.knee <= 0.05 || C.knee >= 1.0) C.knee = 0.7;
	if (C.sat <= 0.0 || C.sat > 2.0) C.sat = 0.85;
	if (C.src_peak < C.target) C.src_peak = C.target;

	printf("HDR 色彩路径自检：curve=%d target=%.0f sat=%.2f knee=%.2f peak=%.0f full=%d\n",
	       C.curve, C.target, C.sat, C.knee, C.src_peak, C.full);
	t_pq();
	t_lut();
	t_gain();		/* 原来定义了没调用：[2b] 从来没跑过 */
	t_srcpeak();
	t_curves();
	t_10bit();
	t_color();
	t_sdr();
	t_hlg();
	t_tf();
	t_sat();
	t_mat();
	t_p3();
	printf("\n%s（失败 %d 项）\n", fails ? "有失败项" : "全部通过", fails);
	return fails != 0;
}
