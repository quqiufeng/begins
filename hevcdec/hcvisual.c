/* hcvisual.c —— 把 GL 片元的逐像素数学搬到 CPU，渲对照图用眼睛验
 *
 * 为什么要有这个：hdr-selftest 验的是"码差对参考"，数字对不代表画面对。
 * 混剪片 HDR/SDR 换段那类问题（色偏、发白、过饱和）人眼一眼就看出来，
 * 数字表格看不出来。板子不在手边时，这是唯一能"看到"映射结果的途径。
 *
 * 片元来源：glout.c 的 FS（uLut/uGm/uSat 那段），逐行照抄；
 * 表来源：hdrcolor.inc 的 hc_build / hc_mat —— 与播放器同一份代码，
 * 所以图上看到的就是屏上会看到的（唯一差别是 GPU 的精度和 dither 种子）。
 *
 * 输出 PPM（P6），外面用 convert/ffmpeg 转 PNG。
 *   ./hcvisual out.ppm   → 三栏：直显 / 曲线+标量增益 / 曲线+标量增益+矩阵
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "hdrcolor.inc"

/* ---------------- 场景：线性 2020 RGB + 目标 nits ---------------- */

struct patch {
	const char *name;
	double r, g, b;		/* 线性 2020 RGB，0..1 为色域内原色 */
	double nits;		/* 该色块的内容亮度 */
};

#define P(n, R, G, B, L) { n, R, G, B, L }

static const struct patch patches[] = {
	/* 第一行：2020 原色（色域外，最能暴露矩阵有没有生效） */
	P("2020红", 1.000, 0.000, 0.000, 1000),
	P("2020绿", 0.000, 1.000, 0.000, 1000),
	P("2020蓝", 0.000, 0.000, 1.000, 1000),
	P("2020青", 0.000, 1.000, 1.000, 1000),
	P("2020黄", 1.000, 1.000, 0.000, 1000),
	P("2020品红", 1.000, 0.000, 1.000, 1000),
	P("灰1000", 1.000, 1.000, 1.000, 1000),
	P("肤色", 0.420, 0.260, 0.190, 203),
	/* 第二行：灰阶（看曲线形状：肩部压缩、暗部有没有塌） */
	P("白100", 1, 1, 1, 100),
	P("白203", 1, 1, 1, 203),
	P("白400", 1, 1, 1, 400),
	P("白600", 1, 1, 1, 600),
	P("白800", 1, 1, 1, 800),
	P("白1000", 1, 1, 1, 1000),
	P("白2000", 1, 1, 1, 2000),
	P("白4000", 1, 1, 1, 4000),
	/* 第三行：中等饱和色 @203（SDR 亮度，混剪片 SDR 段大概长这样） */
	P("中红", 0.700, 0.060, 0.050, 203),
	P("中绿", 0.080, 0.600, 0.090, 203),
	P("中蓝", 0.060, 0.090, 0.650, 203),
	P("中青", 0.060, 0.560, 0.600, 203),
	P("中黄", 0.700, 0.620, 0.070, 203),
	P("中品红", 0.680, 0.070, 0.630, 203),
	P("暖灰", 0.400, 0.330, 0.280, 203),
	P("冷灰", 0.290, 0.330, 0.400, 203),
	/* 第四行：暗部低饱和（HC_GAIN_LIN 说这里"不动作"，正好验这句） */
	P("灰10", 1, 1, 1, 10),
	P("灰5", 1, 1, 1, 5),
	P("灰2", 1, 1, 1, 2),
	P("灰1", 1, 1, 1, 1),
	P("暗红50", 0.100, 0.020, 0.015, 50),
	P("暗绿50", 0.020, 0.095, 0.025, 50),
	P("暗蓝50", 0.015, 0.025, 0.100, 50),
	P("暗肤色", 0.090, 0.055, 0.040, 50),
};
#define NPATCH ((int)(sizeof(patches) / sizeof(patches[0])))
#define COLS 8
#define ROWS ((NPATCH + COLS - 1) / COLS)
#define PX 112

/* ---------------- 绝对色度 → 8bit 有限范围编码 ---------------- */

static double pq_oetf(double L)		/* 绝对亮度 nits → PQ 归一码 0..1 */
{
	const double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
	const double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
	double y = L / 10000.0, yp;

	if (y < 0.0) y = 0.0;
	yp = pow(y, m1);
	return pow((c1 + c2 * yp) / (1.0 + c3 * yp), m2);
}

/* 线性 2020 RGB（已按 nits 归一）→ PQ 编码 → BT.2020 NCL YCbCr 有限范围 8bit */
static void rgb2yuv(const double rgb[3], int *y8, int *u8, int *v8)
{
	double r = pq_oetf(rgb[0]), g = pq_oetf(rgb[1]), b = pq_oetf(rgb[2]);
	double Y = 0.2627 * r + 0.6780 * g + 0.0593 * b;
	double cb = (b - Y) / (2.0 * (1.0 - 0.0593));
	double cr = (r - Y) / (2.0 * (1.0 - 0.2627));
	double o[3];

	o[0] = 16.0 + 219.0 * Y;
	o[1] = 128.0 + 224.0 * cb;
	o[2] = 128.0 + 224.0 * cr;
	for (int i = 0; i < 3; i++) {
		if (o[i] < 0) o[i] = 0;
		if (o[i] > 255) o[i] = 255;
	}
	*y8 = (int)lrint(o[0]);
	*u8 = (int)lrint(o[1]);
	*v8 = (int)lrint(o[2]);
}

/* ---------------- 片元（照抄 glout.c 的 FS） ---------------- */

struct tmtab {
	unsigned char lut[256];
	unsigned short gain[256];
};

/* mode: 0 = 直显（HDR 当 SDR 显示），1 = 曲线+标量增益，2 = 再加矩阵 */
static void frag(const struct tmtab *t, int mode, const double *m, double sat,
		 int y8, int u8, int v8, int px, int py, unsigned char out[3])
{
	double yo, g, Y1, cb, cr, o[3];

	if (mode == 0) {		/* 直显：不查表、不缩放色度、不上矩阵 */
		yo = y8;
		g = 1.0;
	} else {
		yo = t->lut[y8];
		g = t->gain[y8] / 1024.0;
	}
	Y1 = (yo - 16.0) / 219.0;
	cb = (u8 - 128.0) / 224.0 * g;
	cr = (v8 - 128.0) / 224.0 * g;
	o[0] = Y1 + 1.47460 * cr;
	o[1] = Y1 - 0.16455 * cb - 0.57135 * cr;
	o[2] = Y1 + 1.88140 * cb;
	if (mode == 2) {
		double r = m[0] * o[0] + m[1] * o[1] + m[2] * o[2];
		double gg = m[3] * o[0] + m[4] * o[1] + m[5] * o[2];
		double b = m[6] * o[0] + m[7] * o[1] + m[8] * o[2];
		o[0] = r; o[1] = gg; o[2] = b;
	}
	for (int i = 0; i < 3; i++) {
		if (o[i] < 0.0) o[i] = 0.0;
		if (o[i] > 1.0) o[i] = 1.0;
	}
	{
		double lum = 0.2126 * o[0] + 0.7152 * o[1] + 0.0722 * o[2];
		for (int i = 0; i < 3; i++)
			o[i] = lum + sat * (o[i] - lum);
	}
	{
		/* 与 GL 片元一致：TPDF（两路均匀噪声相加，±1 LSB）。单路 ±0.5
		 * 的 RPDF 只能消掉均值偏差，噪声功率仍随信号走，压不住 LUT
		 * 把 220 码压成 112 码后的等高线。 */
		double d1 = fmod(sin(px * 12.9898 + py * 78.233) * 43758.5453, 1.0);
		double d2 = fmod(sin(py * 39.3467 + px * 11.1351 + 71.0) * 24634.6345, 1.0);

		if (d1 < 0) d1 += 1.0;
		if (d2 < 0) d2 += 1.0;
		for (int i = 0; i < 3; i++) {
			double v = o[i] + (d1 + d2 - 1.0) / 255.0;
			if (v < 0.0) v = 0.0;
			if (v > 1.0) v = 1.0;
			out[i] = (unsigned char)lrint(v * 255.0);
		}
	}
}

/* ---------------- 出图 ---------------- */

#define PANELS 3

int main(int argc, char **argv)
{
	const char *out = argc > 1 ? argv[1] : "hcvisual.ppm";
	/* 后四个参数留给扫参：target knee peak primaries。
	 * 调曲线时靠它出图对比，比改源码重编快。 */
	double target = argc > 2 ? atof(argv[2]) : 200.0;
	double knee = argc > 3 ? atof(argv[3]) : 0.70;
	double peak = argc > 4 ? atof(argv[4]) : 1000.0;
	int pr = argc > 5 ? atoi(argv[5]) : HC_PRI_2020;
	struct hdrcolor C;
	struct tmtab t;
	const double *m;
	double sat;
	int w = COLS * PX * PANELS, h = ROWS * PX;
	unsigned char *img;
	FILE *f;

	memset(&C, 0, sizeof(C));
	C.on = 1;
	C.curve = HC_CURVE;
	C.src_peak = peak;	/* SEI144 maxCLL */
	C.target = target;	/* 显示参考白 */
	C.knee = knee;
	C.full = 0;
	C.enc = hc_enc_env();	/* TM_ENC=709 回到旧编码，默认 bt1886 */
	C.gain_mode = HC_GAIN_LIN;
	C.transfer = HC_TF_PQ;
	C.sat = hc_sat_from_primaries(pr, 0.85);	/* 软映射路径的宽色域系数 */
	hc_build(&C, t.lut, t.gain);
	m = hc_mat(pr);
	sat = C.sat;

	printf("hcvisual: %s  curve=%d peak=%.0f target=%.0f sat=%.2f knee=%.2f\n",
	       hc_mat_name(pr), C.curve, C.src_peak, C.target, sat, C.knee);

	img = calloc((size_t)w * h * 3, 1);
	if (!img) return 1;

	for (int p = 0; p < NPATCH; p++) {
		double lin[3];
		int y8, u8, v8, cx = p % COLS, cy = p / COLS;

		lin[0] = patches[p].r * patches[p].nits;
		lin[1] = patches[p].g * patches[p].nits;
		lin[2] = patches[p].b * patches[p].nits;
		rgb2yuv(lin, &y8, &u8, &v8);
		printf("  %-9s %5.0fnits  YUV=%3d,%3d,%3d", patches[p].name,
		       patches[p].nits, y8, u8, v8);

		for (int mode = 0; mode < PANELS; mode++) {
			unsigned char rgb[3];
			int x0 = (mode * COLS + cx) * PX, y0 = cy * PX;

			for (int y = 0; y < PX; y++) {
				for (int x = 0; x < PX; x++) {
					unsigned char *q;
					/* 每块留 2px 黑边，方便分块看 */
					if (x < 2 || y < 2 || x >= PX - 2 || y >= PX - 2) {
						rgb[0] = rgb[1] = rgb[2] = 0;
					} else {
						frag(&t, mode, m, sat, y8, u8, v8,
						     x, y, rgb);
					}
					q = img + ((size_t)(y0 + y) * w +
						   (size_t)(x0 + x)) * 3;
					q[0] = rgb[0];
					q[1] = rgb[1];
					q[2] = rgb[2];
				}
			}
		}
		/* 顺带打印三个面板的 RGB，图上和图下对得上 */
		{
			unsigned char a[3], b[3], c[3];
			frag(&t, 0, m, sat, y8, u8, v8, 4, 4, a);
			frag(&t, 1, m, sat, y8, u8, v8, 4, 4, b);
			frag(&t, 2, m, sat, y8, u8, v8, 4, 4, c);
			printf("  直显=%02x%02x%02x 增益=%02x%02x%02x 矩阵=%02x%02x%02x\n",
			       a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]);
		}
	}

	f = fopen(out, "wb");
	if (!f) { perror(out); free(img); return 1; }
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	fwrite(img, 1, (size_t)w * h * 3, f);
	fclose(f);
	free(img);
	printf("写出 %s（%dx%d，左→右：直显 / 曲线+标量增益 / 曲线+标量增益+矩阵）\n",
	       out, w, h);
	return 0;
}
