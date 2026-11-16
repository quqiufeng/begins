/* glout.c —— HDR10 → SDR 色调映射上屏（EGL+GBM+KMS，panfrost GLES3，零拷贝）
 *
 * 为什么不用 CPU：meson vdec 采集缓冲是 Normal-NC 映射，CPU 逐像素实测 4K 一帧
 * ~800ms（~11MB/s）；meson DRM 也没有 GAMMA_LUT/CTM（gamma 只在 DSI 通路），
 * 显示器 BenQ PD2500Q 不吃 HDR。所以走 GPU：NV12 dmabuf 直接当纹理，
 * 片元着色器里 PQ → 亮度压缩 → BT.2020→709 → 编码，画到 GBM surface 再翻页。
 *
 * 测试卡： ./glplay -t [宽 高]      TM=0 看未映射的对比
 * 给 v4l2hevc.c 用： glout_init() / glout_frame()
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <sys/mman.h>
#include <time.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
typedef void (*pfn_image_tex)(GLenum, void *);

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void gdie(const char *m)
{
	printf("GLOUT: %s: %s\n", m, strerror(errno));
	exit(1);
}

#define TM_CLIP 0
#define TM_CURVE 1
#define TM_REINHARD 2
#define TM_HABLE 3

static struct {
	int curve, on;
	double src_peak, target, sat, knee;
} tp;

static double pq_eotf(double n)
{
	const double m1 = 0.1593017578125, m2 = 78.84375;
	const double c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	double np, num, den;

	if (n <= 0.0) return 0.0;
	np = pow(n, 1.0 / m2);
	num = np - c1;
	den = c2 - c3 * np;
	if (num <= 0.0) return 0.0;
	return 10000.0 * pow(num / den, 1.0 / m1);
}

static double pq_oetf(double L)
{
	const double m1 = 0.1593017578125, m2 = 78.84375;
	const double c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	double y = L / 10000.0, ym;

	if (y <= 0.0) return 0.0;
	ym = pow(y, m1);
	return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}
static double bt709_encode(double d)
{
	if (d <= 0.0) return 0.0;
	if (d >= 1.0) return 1.0;
	return (d < 0.018) ? 4.5 * d : 1.099 * pow(d, 0.45) - 0.099;
}

static double curve_hable(double x)
{
	const double A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
	double f1 = (x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F);
	double fw = (A + C * B + D * E) / (A + B + D * F);

	return f1 / fw;
}

static double tm_curve(double x)
{
	switch (tp.curve) {
	case TM_CLIP:
		return x > 1.0 ? 1.0 : x;
	case TM_REINHARD:
		return 2.0 * x / (1.0 + x);
	case TM_HABLE:
		return curve_hable(x);
	default: {
		double k = tp.knee, t;

		if (x <= k) return x;
		t = (x - k) / (1.0 - k);
		return k + (1.0 - k) * (1.0 - exp(-t));
	}
	}
}

/* ---------- LUT → 多项式（去掉依赖纹理采样） ----------
 * 目标机上「依赖纹理采样」的 LUT 每像素多花 ~4.7ns（= 每屏 17ms），
 * 而 8 次多项式只要几个 FMA。这里用最小二乘把 256 项 LUT 拟合成
 * code(n)、gain(n) 两条 7 次曲线，误差打印出来供核对。
 */
#define PDEG 7
#define MAXD 16
static float poly_c[MAXD + 1], poly_g[MAXD + 1];
static int poly_deg = PDEG;

static double poly_eval(const float *c, int deg, double x)
{
	double r = 0;
	int i;

	for (i = deg; i >= 0; i--) r = r * x + c[i];
	return r;
}

/* LUT 第 i 项对应的归一化亮度 n（着色器里用的是同一条公式） */
static double lut_n(int i)
{
	double n = ((double)i - 16.0) / 219.0;

	return n < 0 ? 0 : n > 1 ? 1 : n;
}

/* 最小二乘拟合 lut 的第 which 通道；返回最大绝对误差 */
static double fit_deg(const float *lut, int which, float *coef, int deg)
{
	double A[MAXD + 1][MAXD + 2];
	int n = 256, i, j, k, row;
	double err = 0;

	memset(A, 0, sizeof(A));
	for (i = 0; i < n; i++) {
		double x = lut_n(i);
		double y = lut[i * 4 + which];
		double p[MAXD + 1], pw = 1;

		for (j = 0; j <= deg; j++) { p[j] = pw; pw *= x; }
		for (j = 0; j <= deg; j++)
			for (k = 0; k <= deg; k++)
				A[j][k] += p[j] * p[k];
		for (j = 0; j <= deg; j++) A[j][deg + 1] += p[j] * y;
	}
	for (row = 0; row <= deg; row++) {	/* 高斯消元 */
		int piv = row;

		for (i = row + 1; i <= deg; i++)
			if (fabs(A[i][row]) > fabs(A[piv][row])) piv = i;
		if (piv != row)
			for (j = 0; j <= deg + 1; j++) {
				double t = A[row][j];
				A[row][j] = A[piv][j];
				A[piv][j] = t;
			}
		for (i = row + 1; i <= deg; i++) {
			double f = A[i][row] / A[row][row];

			for (j = row; j <= deg + 1; j++) A[i][j] -= f * A[row][j];
		}
	}
	for (i = 0; i <= deg; i++) coef[i] = 0;
	for (i = deg; i >= 0; i--) {
		double v = A[i][deg + 1];

		for (j = i + 1; j <= deg; j++) v -= A[i][j] * coef[j];
		coef[i] = (float)(v / A[i][i]);
	}
	for (i = 0; i < n; i++) {
		double x = lut_n(i);
		double d = fabs(poly_eval(coef, deg, x) - lut[i * 4 + which]);

		if (d > err) err = d;
	}
	return err;
}

static double fit_poly(const float *lut, int which, float *coef, int deg)
{
	return fit_deg(lut, which, coef, deg);
}

/* 256 项 RGBA32F：r = 输出码(0..1)，g = 色度增益 */
static void build_lut(float *out)
{
	const char *e = getenv("TM");
	int i;

	tp.curve = TM_CURVE;
	tp.src_peak = getenv("TM_SRC_PEAK") ? atof(getenv("TM_SRC_PEAK")) : 1000.0;
	tp.target = getenv("TM_TARGET") ? atof(getenv("TM_TARGET")) : 200.0;
	tp.sat = getenv("TM_SAT") ? atof(getenv("TM_SAT")) : 0.90;
	tp.knee = getenv("TM_KNEE") ? atof(getenv("TM_KNEE")) : 0.7;
	tp.on = 1;
	if (e && (!strcmp(e, "0") || !strcmp(e, "off") || !strcmp(e, "no"))) tp.on = 0;
	if (e && !strcmp(e, "clip")) tp.curve = TM_CLIP;
	if (e && !strcmp(e, "reinhard")) tp.curve = TM_REINHARD;
	if (e && !strcmp(e, "hable")) tp.curve = TM_HABLE;
	if (tp.src_peak < tp.target) tp.src_peak = tp.target;
	if (tp.knee <= 0.05 || tp.knee >= 1.0) tp.knee = 0.7;

	for (i = 0; i < 256; i++) {
		double n = ((double)i - 16.0) / 219.0;
		double L, x, d, code, nout, gain = 1.0;

		if (n < 0.0) n = 0.0;
		if (n > 1.0) n = 1.0;
		if (!tp.on) {
			out[i * 4 + 0] = i / 255.0f;
			out[i * 4 + 1] = 1.0f;
			out[i * 4 + 2] = 0.0f;
			out[i * 4 + 3] = 1.0f;
			continue;
		}
		L = pq_eotf(n);
		x = L / tp.target;
		d = tm_curve(x);
		code = (16.0 + 219.0 * bt709_encode(d)) / 255.0;
		nout = (code * 255.0 - 16.0) / 219.0;
		if (n > 0.004) {
			gain = nout / n;
			if (gain > 3.9) gain = 3.9;
		}
		out[i * 4 + 0] = (float)code;
		out[i * 4 + 1] = (float)gain;
		out[i * 4 + 2] = 0.0f;
		out[i * 4 + 3] = 1.0f;
	}
	{
		double e1 = fit_poly(out, 0, poly_c, poly_deg);
		double e2 = fit_poly(out, 1, poly_g, poly_deg);

		printf("GLOUT: poly 误差 code=%.4f gain=%.4f\n", e1, e2);
	}
	printf("GLOUT: TM %s curve=%d peak=%.0f target=%.0f sat=%.2f knee=%.2f\n",
	       tp.on ? "on" : "off", tp.curve, tp.src_peak, tp.target, tp.sat, tp.knee);
}


/* ---------- GL 着色器 ---------- */
static const char *VS =
	"#version 300 es\n"
	"layout(location=0) in vec2 aPos;\n"
	"out vec2 vUV;\n"
	"void main(){\n"
	"  vUV = vec2(aPos.x*0.5+0.5, 0.5-aPos.y*0.5);\n"
	"  gl_Position = vec4(aPos,0.0,1.0);\n"
	"}\n";

/* pass2 专用：FBO 里的 tex_rgb 已经是 GL 下上顺序（pass1 的 VS 已经翻过一次），
 * 再套 VS 会翻第二次 → 画面上下颠倒。所以 pass2 用不翻的 UV。
 */
static const char *VS2 =
	"#version 300 es\n"
	"layout(location=0) in vec2 aPos;\n"
	"out vec2 vUV;\n"
	"void main(){\n"
	"  vUV = aPos*0.5+0.5;\n"
	"  gl_Position = vec4(aPos,0.0,1.0);\n"
	"}\n";

static const char *FS =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D uY, uC, uLut;\n"
	"uniform float uSat;\n"
	"in vec2 vUV;\n"
	"out vec4 oCol;\n"
	"void main(){\n"
	"  float y8 = texture(uY, vUV).r * 255.0;\n"
	"  vec2  c8 = texture(uC, vUV).rg * 255.0;\n"
	"  vec2  l  = texture(uLut, vec2(y8/255.0, 0.5)).rg;\n"
	"  float yo = l.r * 255.0;\n"
	"  float gain = l.g;\n"
	"  float Y1 = (yo - 16.0) / 219.0;\n"
	"  float cb = (c8.x - 128.0) / 224.0 * gain;\n"
	"  float cr = (c8.y - 128.0) / 224.0 * gain;\n"
	"  vec3 rgb;\n"
	"  rgb.r = Y1 + 1.47460 * cr;\n"
	"  rgb.g = Y1 - 0.16455 * cb - 0.57135 * cr;\n"
	"  rgb.b = Y1 + 1.88140 * cb;\n"
	"  vec3 o;\n"
	"  o.r =  1.6605*rgb.r - 0.5876*rgb.g - 0.0728*rgb.b;\n"
	"  o.g = -0.1246*rgb.r + 1.1329*rgb.g - 0.0083*rgb.b;\n"
	"  o.b = -0.0182*rgb.r - 0.1006*rgb.g + 1.1187*rgb.b;\n"
	"  o = clamp(o, 0.0, 1.0);\n"
	"  float lum = dot(o, vec3(0.2126, 0.7152, 0.0722));\n"
	"  o = mix(vec3(lum), o, uSat);\n"
	"  float dth = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453);\n"
	"  o += (dth - 0.5) / 255.0;\n"
	"  oCol = vec4(clamp(o, 0.0, 1.0), 1.0);\n"
	"}\n";


static const char *FSV[11] = {NULL};
static void build_fsv(void)
{
	FSV[0] = FS;			/* 全功能 */
	FSV[1] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ float y = texture(uY,vUV).r; oCol=vec4(y,y,y,1.0); }\n";
	FSV[2] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" oCol=vec4(y,c,1.0); }\n";
	FSV[3] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" vec2 l=texture(uLut,vec2(y,0.5)).rg; oCol=vec4(y,c.r,l.r,1.0); }\n";
	FSV[4] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" float Y=dot(vec3(y,c),vec3(0.21,0.5,0.29));"
		" oCol=vec4(Y, Y*1.3, Y*0.7, 1.0); }\n";
	FSV[5] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" vec2 l=texture(uLut,vec2(y,0.5)).rg;"
		" vec3 o=clamp(vec3(y,c)*(1.0+l.g*0.1),0.0,1.0);"
		" for(int i=0;i<8;i++) o=o*0.99+0.01*l.r; oCol=vec4(o,1.0); }\n";

	FSV[6] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texture(uLut, vec2(y8, 0.5));"
		" float yo = l.r*255.0, gain = l.g*4.0;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = vec3(1.6605*rgb.r-0.5876*rgb.g-0.0728*rgb.b,"
		" -0.1246*rgb.r+1.1329*rgb.g-0.0083*rgb.b,"
		" -0.0182*rgb.r-0.1006*rgb.g+1.1187*rgb.b);"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";
	FSV[7] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r*255.0;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texelFetch(uLut, ivec2(int(y8+0.5),0), 0);"
		" float yo = l.r*255.0, gain = l.g;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = vec3(1.6605*rgb.r-0.5876*rgb.g-0.0728*rgb.b,"
		" -0.1246*rgb.r+1.1329*rgb.g-0.0083*rgb.b,"
		" -0.0182*rgb.r-0.1006*rgb.g+1.1187*rgb.b);"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";

	FSV[8] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC;\n"
		"uniform float uPc[8], uPg[8], uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"float ev(float c[8], float x){ float r=c[7];"
		" for(int i=6;i>=0;i--) r = r*x + c[i]; return r; }\n"
		"void main(){"
		" float n = clamp((texture(uY,vUV).r*255.0-16.0)/219.0, 0.0, 1.0);"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" float code = ev(uPc, n), gain = ev(uPg, n);"
		" float yo = code*255.0;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = vec3(1.6605*rgb.r-0.5876*rgb.g-0.0728*rgb.b,"
		" -0.1246*rgb.r+1.1329*rgb.g-0.0083*rgb.b,"
		" -0.0182*rgb.r-0.1006*rgb.g+1.1187*rgb.b);"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)-0.5)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";



	FSV[9] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texture(uLut, vec2(y8, 0.5));"
		" float yo = l.r*255.0, gain = l.g*4.0;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = vec3(1.6605*rgb.r-0.5876*rgb.g-0.0728*rgb.b,"
		" -0.1246*rgb.r+1.1329*rgb.g-0.0083*rgb.b,"
		" -0.0182*rgb.r-0.1006*rgb.g+1.1187*rgb.b);"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)-0.5)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";

	FSV[10] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC;\n"
		"uniform float uPc[12], uSat;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float n = clamp((texture(uY,vUV).r*255.0-16.0)/219.0, 0.0, 1.0);"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" float code = uPc[11];"
		" code = code*n + uPc[10]; code = code*n + uPc[9];"
		" code = code*n + uPc[8]; code = code*n + uPc[7];"
		" code = code*n + uPc[6]; code = code*n + uPc[5];"
		" code = code*n + uPc[4]; code = code*n + uPc[3];"
		" code = code*n + uPc[2]; code = code*n + uPc[1];"
		" code = code*n + uPc[0];"
		" float yo = code*255.0;"
		" float gain = min(3.9, (yo-16.0)/219.0/max(n, 0.004));"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = vec3(1.6605*rgb.r-0.5876*rgb.g-0.0728*rgb.b,"
		" -0.1246*rgb.r+1.1329*rgb.g-0.0083*rgb.b,"
		" -0.0182*rgb.r-0.1006*rgb.g+1.1187*rgb.b);"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)-0.5)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";

}
static GLuint mk_shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok = 0;

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048];

		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		printf("GLOUT: 着色器编译失败: %s\n", log);
		exit(1);
	}
	return s;
}

static GLuint mk_prog(const char *vs, const char *fs)
{
	GLuint p = glCreateProgram(), v = mk_shader(GL_VERTEX_SHADER, vs);
	GLuint f = mk_shader(GL_FRAGMENT_SHADER, fs);
	GLint ok = 0;

	glAttachShader(p, v);
	glAttachShader(p, f);
	glLinkProgram(p);
	glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[2048];

		glGetProgramInfoLog(p, sizeof(log), NULL, log);
		printf("GLOUT: 链接失败: %s\n", log);
		exit(1);
	}
	return p;
}

/* ---------- 全局状态 ---------- */
static struct {
	int dfd, fd_in;		/* fd_in：外面（v4l2hevc）已拿到的 DRM master fd */
	struct gbm_device *gbm;
	struct gbm_surface *gs;
	EGLDisplay dpy;
	EGLContext ctx;
	EGLSurface surf;
	EGLConfig cfg;
	GLuint prog, tex_y, tex_c, tex_lut, vao, vbo;
	unsigned sw, sh;		/* 源尺寸 */
	unsigned dw, dh;		/* 屏幕尺寸 */
	int dx, dy;
	unsigned dW, dH;
	uint32_t crtc_id, conn_id, cur_fb;
	drmModeModeInfo mode;
	struct gbm_bo *prev_bo;
	uint32_t prev_fb;
	struct gbm_bo *fly[4];
	int fhead, ftail, nfly;
	double t_sum, t_max, tsum;
	struct { int fy, fc; GLuint ty, tc; } tc[40];	/* 每块 dmabuf 一纹理 */
	int ntc;
	int first, flip_done, ready;
	int inited, scaled, twopass;
	GLuint prog2, tex_rgb, fbo_rgb;
	unsigned rw, rh;
	unsigned frames;
	double t_gl;
} g;

/* ---------- KMS：找 connector/crtc/mode ---------- */
static int kms_pick(void)
{
	drmModeRes *res = drmModeGetResources(g.dfd);
	drmModeConnector *conn = NULL;
	int i;

	if (!res) { printf("GLOUT: getResources 失败\n"); return -1; }
	for (i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(g.dfd, res->connectors[i]);

		if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
			conn = c;
			g.conn_id = c->connector_id;
			break;
		}
		if (c) drmModeFreeConnector(c);
	}
	if (!conn) { printf("GLOUT: 没有已连接的显示器\n"); return -1; }
	g.mode = conn->modes[0];	/* 首选模式 */
	g.dw = g.mode.hdisplay;
	g.dh = g.mode.vdisplay;
	if (g.dw == 0 || g.dh == 0) {	/* 有些 EDID 首选模式不可用 */
		for (i = 1; i < conn->count_modes; i++) {
			if (conn->modes[i].hdisplay >= 1920) {
				g.mode = conn->modes[i];
				g.dw = g.mode.hdisplay;
				g.dh = g.mode.vdisplay;
				break;
			}
		}
	}
	if (conn->encoder_id) {
		drmModeEncoder *enc = drmModeGetEncoder(g.dfd, conn->encoder_id);

		if (enc) { g.crtc_id = enc->crtc_id; drmModeFreeEncoder(enc); }
	}
	if (!g.crtc_id && res->count_crtcs)
		g.crtc_id = res->crtcs[0];
	drmModeFreeConnector(conn);
	drmModeFreeResources(res);
	printf("GLOUT: 屏幕 %ux%u@%u crtc=%u conn=%u\n", g.dw, g.dh,
	       g.mode.vrefresh, g.crtc_id, g.conn_id);
	return 0;
}

/* ---------- 两遍渲染：源分辨率色调映射 + 整屏纯拷贝放大 ----------
 * 单遍在 2560x1440 上做完整 CSC/色调映射实测只有 28fps（片元 ALU+3 采样器
 * 让 panfrost 掉一半吞吐）；拆成
 *   pass1: 源分辨率(w x h) 全功能色调映射 → RGBA8 纹理
 *   pass2: 该纹理 → 屏，纯采样无运算
 * 片元数 720p 的 pass1 = 整屏的 1/4，pass2 是最廉价的一路采样，实测 55fps+。
 */
static const char *FS_COPY =
	"#version 300 es\n"
	"precision mediump float;\n"
	"uniform sampler2D uTex;\n"
	"in vec2 vUV;\n"
	"out vec4 oCol;\n"
	"void main(){ oCol = vec4(texture(uTex, vUV).rgb, 1.0); }\n";

/* 复用调用方已打开的 DRM fd（master 只能有一个，另开 fd 会 SetCrtc EACCES） */
void glout_set_drm_fd(int fd)
{
	g.fd_in = fd;
}

/* ---------- 初始化：DRM + GBM + EGL + GL ---------- */
int glout_init(unsigned sw, unsigned sh)
{
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";
	EGLint ncfg = 0, cattr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
	EGLint cfgattr[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8, EGL_NONE
	};

	if (g.inited) return 0;
	g.sw = sw;
	g.sh = sh;
	if (g.fd_in > 0) {
		g.dfd = g.fd_in;
	} else {
		g.dfd = open(dev, O_RDWR | O_CLOEXEC);
		if (g.dfd < 0) gdie("open card0");
	}
	if (kms_pick() < 0) return -1;
	g.gbm = gbm_create_device(g.dfd);
	if (!g.gbm) gdie("gbm_create_device");
	g.gs = gbm_surface_create(g.gbm, g.dw, g.dh, GBM_FORMAT_XRGB8888,
				  GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	if (!g.gs) gdie("gbm_surface_create");
	g.dpy = eglGetDisplay((EGLNativeDisplayType)g.gbm);
	if (g.dpy == EGL_NO_DISPLAY) { printf("GLOUT: eglGetDisplay 失败\n"); return -1; }
	if (!eglInitialize(g.dpy, NULL, NULL)) {
		printf("GLOUT: eglInitialize 失败 0x%x\n", eglGetError());
		return -1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	if (!eglChooseConfig(g.dpy, cfgattr, &g.cfg, 1, &ncfg) || ncfg < 1) {
		printf("GLOUT: eglChooseConfig 失败 n=%d\n", ncfg);
		return -1;
	}
	g.ctx = eglCreateContext(g.dpy, g.cfg, EGL_NO_CONTEXT, cattr);
	if (g.ctx == EGL_NO_CONTEXT) {
		printf("GLOUT: eglCreateContext 失败 0x%x\n", eglGetError());
		return -1;
	}
	g.surf = eglCreateWindowSurface(g.dpy, g.cfg, (EGLNativeWindowType)g.gs, NULL);
	if (g.surf == EGL_NO_SURFACE) {
		printf("GLOUT: eglCreateWindowSurface 失败 0x%x\n", eglGetError());
		return -1;
	}
	if (!eglMakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) {
		printf("GLOUT: eglMakeCurrent 失败 0x%x\n", eglGetError());
		return -1;
	}
	g.twopass = getenv("GL1PASS") ? 0 : 1;
	g.inited = 1;
	g.first = 1;
	printf("GLOUT: GL %s / 屏 %ux%u\n", glGetString(GL_VERSION), g.dw, g.dh);
	printf("GLOUT: 渲染器 %s (%s)\n", glGetString(GL_RENDERER),
	       glGetString(GL_VENDOR));
	return 0;
}

/* ---------- GL 资源（懒初始化） ---------- */
static int glout_gl_init(void)
{
	float lut[256 * 4];
	const float verts[] = {-1, -1, 1, -1, -1, 1, 1, 1};

	build_lut(lut);
	build_fsv();
	{
		const char *v = getenv("GLFS");
		int k = v ? atoi(v) : 0;

		if (k < 0 || k > 10) k = 0;
		g.prog = mk_prog(VS, FSV[k]);
		if (k) printf("GLOUT: FS 变体 %d\n", k);
	}
	glGenVertexArrays(1, &g.vao);
	glBindVertexArray(g.vao);
	glGenBuffers(1, &g.vbo);
	glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void *)0);
	glGenTextures(1, &g.tex_lut);
	glBindTexture(GL_TEXTURE_2D, g.tex_lut);
	if (getenv("GLLUT8")) {
		unsigned char l8[256 * 4];
		int i;

		for (i = 0; i < 256; i++) {
			float g8 = lut[i * 4 + 1] * (255.0f / 4.0f);

			l8[i * 4 + 0] = (unsigned char)(lut[i * 4 + 0] * 255.0f + 0.5f);
			l8[i * 4 + 1] = (unsigned char)(g8 < 0 ? 0 : g8 > 255 ? 255 : g8 + 0.5f);
			l8[i * 4 + 2] = 0;
			l8[i * 4 + 3] = 255;
		}
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 1, 0, GL_RGBA,
			     GL_UNSIGNED_BYTE, l8);
	} else
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, 256, 1, 0, GL_RGBA,
			     GL_FLOAT, lut);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	g.tex_y = 0;
	g.tex_c = 0;
	return 0;
}

/* dmabuf → EGLImage → 纹理 */
static GLuint import_tex(int fd, unsigned w, unsigned h, unsigned pitch,
			 uint32_t fourcc)
{
	PFNEGLCREATEIMAGEKHRPROC create_image =
		(PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	pfn_image_tex target_tex = (pfn_image_tex)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	EGLint attr[16];
	int n = 0;
	EGLImageKHR img;
	GLuint tex;

	if (!create_image || !target_tex) return 0;
	attr[n++] = EGL_WIDTH; attr[n++] = (EGLint)w;
	attr[n++] = EGL_HEIGHT; attr[n++] = (EGLint)h;
	attr[n++] = EGL_LINUX_DRM_FOURCC_EXT; attr[n++] = (EGLint)fourcc;
	attr[n++] = EGL_DMA_BUF_PLANE0_FD_EXT; attr[n++] = fd;
	attr[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT; attr[n++] = 0;
	attr[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT; attr[n++] = (EGLint)pitch;
	attr[n++] = EGL_NONE;
	img = create_image(g.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
			   NULL, attr);
	if (img == EGL_NO_IMAGE_KHR) {
		printf("GLOUT: import %08x %ux%u pitch=%u 失败 0x%x\n",
		       fourcc, w, h, pitch, eglGetError());
		return 0;
	}
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	target_tex(GL_TEXTURE_2D, (void *)img);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	return tex;
}

/* 换分辨率/缓存满：扔掉所有导入的纹理 */
static void drop_tex(void)
{
	int i;

	for (i = 0; i < g.ntc; i++) {
		if (g.tc[i].ty) glDeleteTextures(1, &g.tc[i].ty);
		if (g.tc[i].tc) glDeleteTextures(1, &g.tc[i].tc);
	}
	g.ntc = 0;
	g.tex_y = g.tex_c = 0;
}

/* seek 后 dmabuf fd 全换了一批：把旧纹理扔掉，按新 fd 重新导入。
 * GL 上下文/EGLDisplay/DRM 都不动，所以屏幕不会黑。
 */
void glout_reset(void)
{
	if (!g.inited) return;
	drop_tex();
}

/* 上屏前抓一帧（GLDUM=/tmp/x.ppm），用来核对色调映射对不对 */
static void dump_frame(void)
{
	const char *p = getenv("GLDUM");
	static int done;
	unsigned char *buf;
	FILE *f;
	unsigned x, y;

	if (!p || done || !g.dw || !g.dh) return;
	done = 1;
	buf = malloc((size_t)g.dw * g.dh * 4);
	if (!buf) return;
	glReadPixels(0, 0, g.dw, g.dh, GL_RGBA, GL_UNSIGNED_BYTE, buf);
	f = fopen(p, "wb");
	if (!f) { free(buf); return; }
	fprintf(f, "P6\n%u %u\n255\n", g.dw, g.dh);
	for (y = 0; y < g.dh; y++) {
		unsigned char *r = buf + (size_t)(g.dh - 1 - y) * g.dw * 4;

		for (x = 0; x < g.dw; x++) fwrite(r + x * 4, 1, 3, f);
	}
	fclose(f);
	free(buf);
	printf("GLOUT: 抓帧 → %s (%ux%u)\n", p, g.dw, g.dh);
}

static void flip_handler(int fd, unsigned seq, unsigned sec, unsigned usec, void *data)
{
	(void)fd; (void)seq; (void)sec; (void)usec;
	*(int *)data = 1;
}

static void wait_flip(void)
{
	drmEventContext ev;

	memset(&ev, 0, sizeof(ev));
	ev.version = DRM_EVENT_CONTEXT_VERSION;
	ev.page_flip_handler = flip_handler;
	g.flip_done = 0;
	while (!g.flip_done) {
		struct pollfd p = {g.dfd, POLLIN, 0};

		if (poll(&p, 1, 200) <= 0) break;
		drmHandleEvent(g.dfd, &ev);
	}
}

/* GBM 前缓冲 → fb_id（每种 bo 复用） */
static uint32_t bo_to_fb(struct gbm_bo *bo)
{
	uint32_t handles[4] = {0}, pitches[4] = {0}, offsets[4] = {0};
	int fd = gbm_bo_get_fd(bo), ret;
	uint32_t fb = 0;
	uint64_t mod = gbm_bo_get_modifier(bo), mods[4] = {mod, 0, 0, 0};
	uint32_t flags;

	if (fd < 0) return 0;
	if (drmPrimeFDToHandle(g.dfd, fd, &handles[0]) != 0) {
		printf("GLOUT: prime fd->handle 失败: %s\n", strerror(errno));
		close(fd);
		return 0;
	}
	close(fd);
	pitches[0] = gbm_bo_get_stride(bo);
	flags = (mod == DRM_FORMAT_MOD_LINEAR || mod == 0x00ffffffffffffffULL) ?
		DRM_MODE_FB_MODIFIERS : 0;
	ret = drmModeAddFB2WithModifiers(g.dfd, g.dw, g.dh,
					 DRM_FORMAT_XRGB8888, handles, pitches,
					 offsets, mods, &fb, flags);
	if (ret && !(flags & DRM_MODE_FB_MODIFIERS))
		ret = drmModeAddFB2(g.dfd, g.dw, g.dh, DRM_FORMAT_XRGB8888,
				    handles, pitches, offsets, &fb, 0);
	if (ret) {
		printf("GLOUT: AddFB2 失败: %s\n", strerror(errno));
		return 0;
	}
	return fb;
}

/* ---------- 画一帧 ---------- */

/* 两遍渲染：pass1 源分辨率全功能色调映射 → 纹理；pass2 纹理整屏放大 */
static int twopass_frame(unsigned w, unsigned h)
{
	unsigned dW, dH, pw, ph;
	double ar_s, ar_d, t0 = now_s();
	int dx, dy;

	if (!g.prog2) {
		g.prog2 = mk_prog(VS2, FS_COPY);
		glGenTextures(1, &g.tex_rgb);
		glGenFramebuffers(1, &g.fbo_rgb);
	}
	/* pass1 只做到"屏幕装得下"的尺寸：4K 源直接按 4K 做色调映射是白烧
	 * 8.3M 片元，缩放后再上屏看不出差别（实测 4K 87ms → 后续测速对比）。
	 */
	{
		/* pass1 只做到 1080p 量级：G31 是逐像素的通用 GPU，
		 * 4K 全尺寸做色调映射要 8.3M 片元（54ms），缩到 1080p 只要
		 * 2M（37ms），再缩放上屏肉眼看不出差别。
		 * 屏幕本身比 1080p 小就按屏幕来。
		 */
		unsigned maxw = 1920, maxh = 1080;
		const char *mx = getenv("GL1MAX");	/* 覆盖 pass1 高度上限 */

		if (g.dw < maxw) maxw = g.dw;
		if (g.dh < maxh) maxh = g.dh;
		if (mx) {
			maxh = (unsigned)atoi(mx);
			if (maxh < 240) maxh = 240;
			if (maxh > g.dh) maxh = g.dh;
			maxw = (unsigned)((uint64_t)g.dw * maxh / g.dh);
		}
		pw = w;
		ph = h;
		if (w > maxw || h > maxh) {
			double k = (double)maxw / w;

			if ((double)maxh / h < k) k = (double)maxh / h;
			pw = ((unsigned)(w * k + 0.5)) & ~1u;
			ph = ((unsigned)(h * k + 0.5)) & ~1u;
		}
	}
	if (pw != g.rw || ph != g.rh) {
		glBindTexture(GL_TEXTURE_2D, g.tex_rgb);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pw, ph, 0, GL_RGBA,
			     GL_UNSIGNED_BYTE, NULL);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		g.rw = pw; g.rh = ph;
	}
	/* pass1 */
	glBindFramebuffer(GL_FRAMEBUFFER, g.fbo_rgb);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
			       GL_TEXTURE_2D, g.tex_rgb, 0);
	glViewport(0, 0, pw, ph);
	glUseProgram(g.prog);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_y);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, g.tex_c);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, g.tex_lut);
	glUniform1i(glGetUniformLocation(g.prog, "uY"), 0);
	glUniform1i(glGetUniformLocation(g.prog, "uC"), 1);
	glUniform1i(glGetUniformLocation(g.prog, "uLut"), 2);
	glUniform1f(glGetUniformLocation(g.prog, "uSat"), (float)tp.sat);
	glUniform1fv(glGetUniformLocation(g.prog, "uPc"), 12, poly_c);
	glUniform1fv(glGetUniformLocation(g.prog, "uPg"), 12, poly_g);
	glBindVertexArray(g.vao);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	/* pass2 */
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glViewport(0, 0, g.dw, g.dh);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	ar_s = (double)w / h;
	ar_d = (double)g.dw / g.dh;
	if (ar_s > ar_d) { dW = g.dw; dH = (unsigned)(g.dw / ar_s + 0.5) & ~1u; }
	else { dH = g.dh; dW = (unsigned)(g.dh * ar_s + 0.5) & ~1u; }
	dx = (g.dw - dW) / 2;
	dy = (g.dh - dH) / 2;
	glViewport(dx, g.dh - dy - dH, dW, dH);
	glUseProgram(g.prog2);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_rgb);
	glUniform1i(glGetUniformLocation(g.prog2, "uTex"), 0);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	if (getenv("GLTIME")) {
		glFinish();
		g.t_sum += now_s() - t0;
	}
	return 0;
}

int glout_frame(int fd_y, int fd_c, unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch)
{
	struct gbm_bo *bo;
	unsigned fbr, dW, dH;
	int dx, dy;
	double ar_s, ar_d;

	if (!g.inited) return -1;
	if (!g.prog) glout_gl_init();
	if (w != g.sw || h != g.sh) {
		drop_tex();
		g.sw = w;
		g.sh = h;
	}
	{
		int i, k = -1;

		/* 逐帧的 dmabuf fd 都不一样（20 个 capture buffer 轮转），
		 * 每块各导一次纹理，之后按 fd 复用。
		 */
		for (i = 0; i < g.ntc; i++)
			if (g.tc[i].fy == fd_y && g.tc[i].fc == fd_c) { k = i; break; }
		if (k < 0) {
			GLuint ty, tc;

			if (g.ntc >= (int)(sizeof(g.tc) / sizeof(g.tc[0]))) drop_tex();
			ty = import_tex(fd_y, w, h, ypitch, DRM_FORMAT_R8);
			tc = import_tex(fd_c, w / 2, h / 2, cpitch, DRM_FORMAT_GR88);
			if (!ty || !tc) return -1;
			k = g.ntc++;
			g.tc[k].fy = fd_y;
			g.tc[k].fc = fd_c;
			g.tc[k].ty = ty;
			g.tc[k].tc = tc;
		}
		g.tex_y = g.tc[k].ty;
		g.tex_c = g.tc[k].tc;
	}
	if (g.twopass) {
		if (twopass_frame(w, h)) return -1;
		goto swap;
	}
	ar_s = (double)w / h;
	ar_d = (double)g.dw / g.dh;
	if (ar_s > ar_d) {
		dW = g.dw;
		dH = (unsigned)(g.dw / ar_s + 0.5) & ~1u;
	} else {
		dH = g.dh;
		dW = (unsigned)(g.dh * ar_s + 0.5) & ~1u;
	}
	dx = (g.dw - dW) / 2;
	dy = (g.dh - dH) / 2;
	glViewport(0, 0, g.dw, g.dh);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glViewport(dx, g.dh - dy - dH, dW, dH);
	glUseProgram(g.prog);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_y);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, g.tex_c);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, g.tex_lut);
	glUniform1i(glGetUniformLocation(g.prog, "uY"), 0);
	glUniform1i(glGetUniformLocation(g.prog, "uC"), 1);
	glUniform1i(glGetUniformLocation(g.prog, "uLut"), 2);
	glUniform1f(glGetUniformLocation(g.prog, "uSat"), (float)tp.sat);
	glUniform1fv(glGetUniformLocation(g.prog, "uPc"), 12, poly_c);
	glUniform1fv(glGetUniformLocation(g.prog, "uPg"), 12, poly_g);
	glBindVertexArray(g.vao);
	{
		double t0 = now_s();

		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		if (getenv("GLTIME")) {
			glFinish();
			g.t_sum += now_s() - t0;
			if (now_s() - t0 > g.t_max) g.t_max = now_s() - t0;
		}
	}

swap:
	dump_frame();
	{
		double ts = now_s();

		if (!eglSwapBuffers(g.dpy, g.surf)) {
			printf("GLOUT: swap 失败 0x%x\n", eglGetError());
			return -1;
		}
		g.tsum += now_s() - ts;
	}
	if (0) {
		printf("GLOUT: swap 失败 0x%x\n", eglGetError());
		return -1;
	}
	bo = gbm_surface_lock_front_buffer(g.gs);
	if (!bo) { printf("GLOUT: lock_front 失败\n"); return -1; }
	fbr = gbm_bo_get_user_data(bo) ? *(uint32_t *)gbm_bo_get_user_data(bo) : 0;
	if (!fbr) {
		uint32_t *slot = calloc(1, sizeof(uint32_t));

		fbr = bo_to_fb(bo);
		if (!fbr) return -1;
		*slot = fbr;
		gbm_bo_set_user_data(bo, slot, NULL);
	}
	if (g.first) {
		if (drmModeSetCrtc(g.dfd, g.crtc_id, fbr, 0, 0, &g.conn_id, 1,
				   &g.mode)) {
			printf("GLOUT: SetCrtc 失败: %s\n", strerror(errno));
			return -1;
		}
		g.first = 0;
	} else {
		if (drmModePageFlip(g.dfd, g.crtc_id, fbr,
				    DRM_MODE_PAGE_FLIP_EVENT, &g.flip_done)) {
			printf("GLOUT: PageFlip 失败: %s\n", strerror(errno));
			return -1;
		}
		wait_flip();
	}
	if (g.prev_bo && g.prev_bo != bo) {
		gbm_surface_release_buffer(g.gs, g.prev_bo);
		g.prev_bo = NULL;
	}
	g.prev_bo = bo;
	g.frames++;
	return 0;
}

/* ---------- 独立测试卡：造一块 PQ 编码的 NV12 ---------- */
static void put_yuv(unsigned char *yp, unsigned char *cp, unsigned ys, unsigned cs,
		    unsigned x, unsigned y, double Yp, double cb, double cr)
{
	double yc = 16.0 + 219.0 * Yp;
	double uc = 128.0 + 224.0 * cb;
	double vc = 128.0 + 224.0 * cr;

	yp[y * ys + x] = (unsigned char)(yc < 0 ? 0 : yc > 255 ? 255 : yc + 0.5);
	if (!(y & 1) && !(x & 1)) {
		cp[(y / 2) * cs + x] = (unsigned char)(uc < 0 ? 0 : uc > 255 ? 255 : uc + 0.5);
		cp[(y / 2) * cs + x + 1] = (unsigned char)(vc < 0 ? 0 : vc > 255 ? 255 : vc + 0.5);
	}
}

/* RGB(0..1 线性, BT.2020 原色) → PQ 编码的 Y'/Cb/Cr */
static void rgb_to_yuv2020(const double rgb[3], double *Yp, double *cb, double *cr)
{
	double r = rgb[0], gg = rgb[1], b = rgb[2];
	double lr = pq_oetf(r), lg = pq_oetf(gg), lb = pq_oetf(b);
	double y = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb;

	*Yp = y;
	*cb = (lb - y) / 1.8814;
	*cr = (lr - y) / 1.4746;
}

static int mk_dumb(unsigned w, unsigned h, int bpp, int *fd_out,
		   void **map, uint32_t *stride_out)
{
	struct drm_mode_create_dumb cd;
	struct drm_mode_map_dumb md;
	uint32_t fb = 0;
	int fd;

	memset(&cd, 0, sizeof(cd));
	cd.width = w; cd.height = h; cd.bpp = bpp;
	if (drmIoctl(g.dfd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
		printf("GLOUT: CREATE_DUMB 失败: %s\n", strerror(errno));
		return -1;
	}
	memset(&md, 0, sizeof(md));
	md.handle = cd.handle;
	if (drmIoctl(g.dfd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
		printf("GLOUT: MAP_DUMB 失败: %s\n", strerror(errno));
		return -1;
	}
	*map = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, g.dfd, md.offset);
	if (*map == MAP_FAILED) {
		printf("GLOUT: dumb mmap 失败: %s\n", strerror(errno));
		return -1;
	}
	if (drmPrimeHandleToFD(g.dfd, cd.handle, DRM_CLOEXEC, fd_out)) {
		printf("GLOUT: prime handle->fd 失败: %s\n", strerror(errno));
		return -1;
	}
	*stride_out = cd.pitch;
	(void)fb;
	fd = *fd_out;
	return fd;
}

static int gen_testcard(unsigned w, unsigned h, int *fy, int *fc,
			unsigned *sy_out, unsigned *sc_out)
{
	void *my = NULL, *mc = NULL;
	uint32_t sy = 0, sc = 0;
	unsigned char *yp, *cp;
	unsigned x, y;
	static const double bars[6][3] = {
		{1, 1, 1}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0, 1, 1}, {1, 0, 1}
	};

	if (mk_dumb(w, h, 8, fy, &my, &sy) < 0) return -1;
	if (mk_dumb(w / 2, h / 2, 16, fc, &mc, &sc) < 0) return -1;
	*sy_out = sy;
	*sc_out = sc;
	yp = my;
	cp = mc;
	for (y = 0; y < h; y++) {
		for (x = 0; x < w; x++) {
			double Yp = 0.0, cb = 0.0, cr = 0.0;
			double rgb[3] = {0, 0, 0};

			if (x < w / 2) {		/* 左：0.05 → 1000 nits 亮度斜坡 */
				double t = (double)x / (w / 2 - 1);
				double nits = 0.05 * pow(1000.0 / 0.05, t);

				rgb[0] = rgb[1] = rgb[2] = nits / 1000.0;
			} else if (y < h / 2) {	/* 右上：彩条（各 300 nits）*/
				int idx = (x - w / 2) * 6 / (w / 2);

				if (idx > 5) idx = 5;
				rgb[0] = bars[idx][0] * 0.3;
				rgb[1] = bars[idx][1] * 0.3;
				rgb[2] = bars[idx][2] * 0.3;
			} else {		/* 右下：灰阶 1/5/20/100/1000 nits */
				static const double g_nt[5] = {1, 5, 20, 100, 1000};
				int idx = (x - w / 2) * 5 / (w / 2);

				if (idx > 4) idx = 4;
				rgb[0] = rgb[1] = rgb[2] = g_nt[idx] / 1000.0;
			}
			rgb_to_yuv2020(rgb, &Yp, &cb, &cr);
			put_yuv(yp, cp, sy, sc, x, y, Yp, cb, cr);
		}
	}
	(void)my; (void)mc;
	return 0;
}

/* ---------- 独立测试程序 ---------- */
#ifndef GLOUT_NO_MAIN
int main(int argc, char **argv)
{
	unsigned w = 1280, h = 720, i, n = 60;
	int fdy = -1, fdc = -1;
	unsigned sy = 0, sc = 0;
	double t0, fps;

	if (argc > 1 && !strcmp(argv[1], "-f")) {	/* 只看 LUT 拟合误差 */
		float lut[256 * 4], c[MAXD + 1], gg[MAXD + 1];
		int d;

		build_lut(lut);
		if (argc > 2 && !strcmp(argv[2], "dump")) {
			for (d = 0; d < 256; d++)
				printf("%d %.6f %.6f %.6f\n", d, lut_n(d),
				       lut[d * 4], lut[d * 4 + 1]);
			return 0;
		}
		for (d = 3; d <= 12; d++) {
			double e1 = fit_poly(lut, 0, c, d);
			double e2 = fit_poly(lut, 1, gg, d);

			printf("deg %2d: code 误差 %.5f (%.2f/255 码)  gain 误差 %.5f\n",
			       d, e1, e1 * 219.0, e2);
		}
		return 0;
	}
	if (argc > 2) w = atoi(argv[2]);
	if (argc > 3) h = atoi(argv[3]);
	if (argc > 1 && !strcmp(argv[1], "-t")) {
		/* 测试卡 */
	} else {
		printf("用法: %s -t [源宽 源高] [帧数]\n", argv[0]);
		return 1;
	}
	if (argc > 4) n = atoi(argv[4]);
	if (glout_init(w, h) < 0) return 1;
	if (gen_testcard(w, h, &fdy, &fdc, &sy, &sc) < 0) return 1;
	t0 = now_s();
	for (i = 0; i < n; i++) {
		if (glout_frame(fdy, fdc, w, h, sy, sc) < 0) {
			printf("第 %u 帧失败\n", i);
			break;
		}
	}
	fps = i / (now_s() - t0);
	if (getenv("GLTIME"))
		printf("GLOUT: 绘制 %.2f ms/帧, swap %.2f ms/帧\n",
		       g.t_sum * 1000 / i, g.tsum * 1000 / i);
	printf("GLOUT: %u 帧, %.1f fps (源 %ux%u → 屏 %ux%u)\n",
	       i, fps, w, h, g.dw, g.dh);
	return 0;
}
#endif /* GLOUT_NO_MAIN */
