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
#include "perfstat.h"
#include "osd.h"
typedef void (*pfn_image_tex)(GLenum, void *);
int glout_frame(int fd_y, int fd_c, unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch);

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
	int curve, on, gain;
	int tf;			/* HC_TF_*：VUI 传递函数，决定码值→线性光用哪条 EOTF */
	double src_peak, target, sat, knee;
} tp;

/* 色彩数学统一在 hdrcolor.inc（v4l2hevc.c 的软映射吃同一份文本） */
#include "hdrcolor.inc"
/* 内容峰值同样来自码流 SEI；gl-selftest 单独链接时靠里面的弱定义兜住 */
#include "csig.h"

/* 老名字，保持调用点不变 */
#define pq_eotf hc_pq_eotf
#define pq_oetf hc_pq_oetf
#define curve_hable hc_hable

static struct hdrcolor tp_hc(void)
{
	struct hdrcolor c;

	c.on = tp.on;
	c.curve = tp.curve;		/* TM_* 与 HC_* 数值一致 */
	c.src_peak = tp.src_peak;
	c.target = tp.target;
	/* sat 必须进 LUT：和软映射（hc_chroma709 的 1+sat*(nout/n-1)）同一条规则，
	 * 色度增益插值，亮度 Y 守恒。以前这里写死 1.0、把 sat 留给片元的
	 * mix(vec3(lum),o,uSat)，结果暗饱和色被按亮度压暗（col_R 65→43、
	 * col_B 20→3），亮饱和色又给缺失通道灌能量（col_Y 255,255,0→253,253,24），
	 * 同一部片 RENDER=drm / RENDER=gl 颜色对不上。 */
	c.sat = tp.sat;
	c.knee = tp.knee;
	c.full = 0;
	c.enc = hc_enc_env();
	c.gain_mode = tp.gain;
	c.transfer = tp.tf;
	return c;
}

/* 着色器要的是 0..1 的 code，bt709_encode 在 glout 里一直无 16/219 偏移 */
#define bt709_encode hc_bt709_oetf

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
/* 这次 LUT 是按多少 nits 编的；SEI 后到时用来判断要不要重建 */
static double tp_peak_used;
static int tp_tf_used = -1;		/* 编表时的传递函数（VUI 可能后到） */
static int tp_bd_used = -1;		/* 编表时的位深（决定未标时开不开） */
static int tp_peak_env;		/* TM_SRC_PEAK 显式给了，就不跟 SEI */
static int tp_sat_env;		/* TM_SAT 显式给了，就不跟色域 */
static int tp_pri;		/* 编表时用的 colour_primaries */

static void build_lut(float *out)
{
	const char *e = getenv("TM");
	int i;

	tp.curve = TM_CURVE;
	if (getenv("TM_SRC_PEAK")) {
		tp.src_peak = atof(getenv("TM_SRC_PEAK"));
		tp_peak_env = 1;
	} else if (csig_peak() > 0.0) {
		tp.src_peak = csig_peak();	/* 码流里的 maxCLL */
	} else {
		tp.src_peak = 1000.0;		/* 兜底：后面 tm_peak_sync() 会补 */
	}
	tp.target = getenv("TM_TARGET") ? atof(getenv("TM_TARGET")) : 200.0;
	/* 和软映射同一条规则（hdrcolor.inc）：2020 源才压，709 源 1.0。
	 * GL 路径的 wide 一直是 0.90，这里保持不变，只补上“看色域”。 */
	if (getenv("TM_SAT")) {
		tp.sat = atof(getenv("TM_SAT"));
		tp_sat_env = 1;
	} else {
		tp.sat = hc_sat_from_primaries(g_cm.primaries, 0.90);
	}
	tp_pri = g_cm.primaries;
	tp.knee = getenv("TM_KNEE") ? atof(getenv("TM_KNEE")) : 0.7;
	tp.tf = g_cm.transfer;	/* 0=未标 → 见 hc_auto_on() */
	/* 开关必须和 v4l2hevc.c 的 tm_build() 用同一杆秤。这里原来无条件
	 * tp.on = 1，于是同一部片：CPU 后端透传（对），GL 后端被当 PQ 压一遍
	 * （发白、高光削平、sat=0.90 去饱和）。 */
	{
		const char *hdr = getenv("HDR");
		int h1 = hdr && (!strcmp(hdr, "1") || !strcmp(hdr, "on"));
		int h0 = hdr && (!strcmp(hdr, "0") || !strcmp(hdr, "off"));

		if (e && (!strcmp(e, "0") || !strcmp(e, "off") || !strcmp(e, "no")))
			tp.on = 0;
		else if (e)
			tp.on = 1;	/* TM=1/clip/curve/... 显式要映射 */
		else if (h1)
			tp.on = 1;
		else if (h0)
			tp.on = 0;
		else
			tp.on = hc_auto_on(tp.tf, g_cm.bit_depth);
	}
	if (e && !strcmp(e, "clip")) tp.curve = TM_CLIP;
	if (e && !strcmp(e, "reinhard")) tp.curve = TM_REINHARD;
	if (e && !strcmp(e, "hable")) tp.curve = TM_HABLE;
	tp.gain = (getenv("TM_GAIN") && (!strcmp(getenv("TM_GAIN"), "lin") ||
		  !strcmp(getenv("TM_GAIN"), "linear"))) ? HC_GAIN_LIN : HC_GAIN_CODE;
	if (tp.src_peak < tp.target) tp.src_peak = tp.target;
	if (tp.knee <= 0.05 || tp.knee >= 1.0) tp.knee = 0.7;
	/* 不映射时 sat 必须回到 1.0：未知色域算出来的 0.90 会进 LUT 的色度增益，
	 * 把 SDR 片凭空去饱和 10%。 */
	if (!tp.on) tp.sat = 1.0;

	{
		struct hdrcolor c = tp_hc();
		unsigned char lut[256];
		unsigned short gain[256];

		hc_build(&c, lut, gain);
		for (i = 0; i < 256; i++) {
			out[i * 4 + 0] = lut[i] / 255.0f;
			out[i * 4 + 1] = gain[i] / 1024.0f;
			out[i * 4 + 2] = 0.0f;
			out[i * 4 + 3] = 1.0f;
		}
	}
	{
		double e1 = fit_poly(out, 0, poly_c, poly_deg);
		double e2 = fit_poly(out, 1, poly_g, poly_deg);

		printf("GLOUT: poly 误差 code=%.4f gain=%.4f\n", e1, e2);
	}
	tp_peak_used = tp.src_peak;
	tp_tf_used = tp.tf;
	tp_bd_used = g_cm.bit_depth;
	printf("GLOUT: TM %s tf=%s curve=%d enc=%s peak=%.0f(%s) target=%.0f sat=%.2f knee=%.2f\n",
	       tp.on ? "on" : "off", hc_tf_name(tp.tf), tp.curve,
	       hc_enc_env() == HC_ENC_709 ? "bt709" : "bt1886", tp.src_peak,
	       tp_peak_env ? "env" : csig_peak() > 0.0 ? "sei" : "默认",
	       tp.target, tp.sat, tp.knee);
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

/* 旧版每像素两次 sin() 生成抖动噪声：Mali-G31 上 sin 是 4~8 周期的超
 * 周期指令，1080p 2M 像素就是 16 个周期/像素级别，实测占 pass1 的
 * 1/3 以上。抖动的目的只是打散 8bit 输出的色带，用一张 64x64 噪声贴图
 * （4KB）查表就够，NEAREST + REPEAT 命中纹理缓存几乎免费。
 */
static const char *FS_SIN =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D uY, uC, uLut;\n"
	"uniform float uSat;\n"
	"uniform mat3 uGm;\n"
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
	"  vec3 o = uGm * rgb;\n"
	"  o = clamp(o, 0.0, 1.0);\n"
	"  float lum = dot(o, vec3(0.2126, 0.7152, 0.0722));\n"
	"  o = mix(vec3(lum), o, uSat);\n"
	"  float d1 = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453);\n"
	"  float d2 = fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345);\n"
	"  o += (d1 + d2 - 1.0) / 255.0;\n"
	"  oCol = vec4(clamp(o, 0.0, 1.0), 1.0);\n"
	"}\n";

/* 默认着色器：和 FS_SIN 逐项等价，只有抖动改成查噪声贴图。 */
static const char *FS =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D uY, uC, uLut, uNoise;\n"
	"uniform float uSat;\n"
	"uniform mat3 uGm;\n"
	"in vec2 vUV;\n"
	"out vec4 oCol;\n"
	"void main(){\n"
	"  float y8 = texture(uY, vUV).r * 255.0;\n"
	"  vec2  c8 = texture(uC, vUV).rg * 255.0;\n"
	"  vec2  l  = texture(uLut, vec2(y8/255.0, 0.5)).rg;\n"
	"  float Y1 = (l.r * 255.0 - 16.0) / 219.0;\n"
	"  float gain = l.g;\n"
	"  float cb = (c8.x - 128.0) / 224.0 * gain;\n"
	"  float cr = (c8.y - 128.0) / 224.0 * gain;\n"
	"  vec3 rgb = vec3(Y1 + 1.47460 * cr,\n"
	"                  Y1 - 0.16455 * cb - 0.57135 * cr,\n"
	"                  Y1 + 1.88140 * cb);\n"
	"  vec3 o = clamp(uGm * rgb, 0.0, 1.0);\n"
	"  float lum = dot(o, vec3(0.2126, 0.7152, 0.0722));\n"
	"  o = mix(vec3(lum), o, uSat);\n"
	"  o += (texture(uNoise, gl_FragCoord.xy * 0.0078125).r - 0.5) / 255.0;\n"
	"  oCol = vec4(clamp(o, 0.0, 1.0), 1.0);\n"
	"}\n";


/* 源色域→709 的 3x3 上到 uGm。系数本身在 hdrcolor.inc（hc_mat），和软映射
 * 是同一组数：以前这里手抄了九个数，P3 片要么走错矩阵要么全无。GLSL 的
 * mat3 构造按列主序收参数，所以上行主序时要转置一次。 */
static void gm_upload(GLuint prog)
{
	/* 不映射就当 709 直通：primaries=0 的兜底是"当 2020"，套在 SDR 片上
	 * 就是额外偏色（正是这次画质问题的第二个来源）。 */
	const double *m = hc_mat(tp.on ? tp_pri : HC_PRI_709);
	float c[9];
	int i, j;

	for (i = 0; i < 3; i++)
		for (j = 0; j < 3; j++)
			c[i * 3 + j] = (float)m[j * 3 + i];
	glUniformMatrix3fv(glGetUniformLocation(prog, "uGm"), 1, GL_FALSE, c);
}

static const char *FSV[12] = {NULL};
static void build_fsv(void)
{
	FSV[0] = FS;			/* 全功能 */
	FSV[1] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ float y = texture(uY,vUV).r; oCol=vec4(y,y,y,1.0); }\n";
	FSV[2] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" oCol=vec4(y,c,1.0); }\n";
	FSV[3] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" vec2 l=texture(uLut,vec2(y,0.5)).rg; oCol=vec4(y,c.r,l.r,1.0); }\n";
	FSV[4] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" float Y=dot(vec3(y,c),vec3(0.21,0.5,0.29));"
		" oCol=vec4(Y, Y*1.3, Y*0.7, 1.0); }\n";
	FSV[5] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){ vec2 c=texture(uC,vUV).rg; float y=texture(uY,vUV).r;"
		" vec2 l=texture(uLut,vec2(y,0.5)).rg;"
		" vec3 o=clamp(vec3(y,c)*(1.0+l.g*0.1),0.0,1.0);"
		" for(int i=0;i<8;i++) o=o*0.99+0.01*l.r; oCol=vec4(o,1.0); }\n";

	FSV[6] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texture(uLut, vec2(y8, 0.5));"
		" float yo = l.r*255.0, gain = l.g*4.0;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = uGm * rgb;"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)"
		"+fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345)-1.0)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";
	FSV[7] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r*255.0;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texelFetch(uLut, ivec2(int(y8+0.5),0), 0);"
		" float yo = l.r*255.0, gain = l.g;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = uGm * rgb;"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)"
		"+fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345)-1.0)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";

	FSV[8] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC;\n"
		"uniform float uPc[8], uPg[8], uSat;\n"
		"uniform mat3 uGm;\n"
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
		" vec3 o = uGm * rgb;"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)+fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345)-1.0)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";



	FSV[9] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC, uLut;\nuniform float uSat;\nuniform mat3 uGm;\n"
		"in vec2 vUV;\nout vec4 oCol;\n"
		"void main(){"
		" float y8 = texture(uY,vUV).r;"
		" vec2 c8 = texture(uC,vUV).rg*255.0;"
		" vec4 l = texture(uLut, vec2(y8, 0.5));"
		" float yo = l.r*255.0, gain = l.g*4.0;"
		" float Y1=(yo-16.0)/219.0;"
		" float cb=(c8.x-128.0)/224.0*gain, cr=(c8.y-128.0)/224.0*gain;"
		" vec3 rgb = vec3(Y1+1.4746*cr, Y1-0.1646*cb-0.5714*cr, Y1+1.8814*cb);"
		" vec3 o = uGm * rgb;"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)+fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345)-1.0)/255.0;"
		" oCol = vec4(clamp(o,0.0,1.0),1.0); }\n";

	FSV[11] = FS_SIN;		/* 旧的两次 sin 抖动，留着 A/B */

	FSV[10] = "#version 300 es\nprecision highp float;\n"
		"uniform sampler2D uY, uC;\n"
		"uniform float uPc[12], uSat;\n"
		"uniform mat3 uGm;\n"
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
		" vec3 o = uGm * rgb;"
		" o = clamp(o,0.0,1.0);"
		" float lum = dot(o, vec3(0.2126,0.7152,0.0722));"
		" o = mix(vec3(lum), o, uSat);"
		" o += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898,78.233)))*43758.5453)+fract(sin(dot(gl_FragCoord.yx+vec2(71.0,13.0), vec2(39.3467,11.1351)))*24634.6345)-1.0)/255.0;"
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
	GLuint prog, tex_y, tex_c, tex_lut, tex_noise, vao, vbo;
	unsigned sw, sh;		/* 源尺寸 */
	double par;		/* 像素宽高比 SAR（默认 1.0）；显示宽高比 =
				 * sw*par/sh，老片源的 720x576/16:15 就靠它 */
	unsigned dw, dh;		/* 屏幕尺寸 */
	/* vw/vh：真正渲染的 target（= GBM surface 尺寸），DPU 负责把它放大到
	 * dw/dh。DPUSCALE=0 时 vw/vh 恒等于屏幕，退回老行为（GL 整屏放大）。
	 * 这就是 design_player.md §4.1 的目标形态 A：片元只在源分辨率上跑。
	 */
	unsigned vw, vh;
	unsigned up;		/* 约定的最大放大倍数（DPU 放大超 4x 糊得明显） */
	int dx, dy;
	unsigned dW, dH;
	uint32_t crtc_id, conn_id, cur_fb;
	drmModeModeInfo mode;
	struct gbm_bo *prev_bo;
	uint32_t prev_fb;
	struct gbm_bo *fly[4];
	int fhead, ftail, nfly;
	double t_sum, t_max, tsum;
	/* 分布账：平均 fps 会把"偶尔 40ms"和"稳定 30ms"算成一样，这里分开记 */
	struct ps_hist h_draw, h_swap, h_flip, h_int;
	long drops;		/* 提交了但没上屏（swap/lock/SetCrtc/PageFlip 失败） */
	long sub;		/* 提交次数（= 上屏 + 掉帧），分母不能只数成功的 */
	long presented;		/* 真被扫描出去的帧数（atomic commit / flip 成功） */
	int master;		/* 自己拿到了 DRM master；拿不到的话一次都上不了屏 */
	int perf;		/* PERF=0 关掉逐帧 glFinish（会改流水线行为） */
	double vbl_ms;		/* 一个刷新周期，判 vblank miss 的基准 */
	double t_latch, t_latch_prev;
	int latch_have;
	/* 上屏分账（GLDBG=1 才逐段计时）：一帧 sub 到底花在哪
	 *   swap    eglSwapBuffers
	 *   lock    gbm_surface_lock_front_buffer（没空闲 bo 会在这里阻塞）
	 *   flip    请求翻页 → flip 完成事件（含 SetCrtc 兜底）
	 */
	double s_swap, s_lock, s_flip, s_in, s_draw;
	unsigned s_n;
	int split;
	/* 每块 dmabuf 一纹理。EGLImage 必须一起存：Mali 上 img 拿着
	 * dma_buf 的引用，只 glDeleteTextures 不销毁 img，旧 buffer 就
	 * 释放不掉，会话重建后新 dmabuf 分配/复用会 EBUSY
	 * （表现为 FAIL glout_frame: Device or resource busy）。
	 */
	struct { int fy, fc; GLuint ty, tc; void *ey, *ec; } tc[40];
	int ntc;
	int first, flip_done, ready;
	int inited, scaled, twopass;
	GLuint prog2, tex_rgb, fbo_rgb;
	unsigned rw, rh;
	unsigned frames;
	double t_gl;
	/* OSD 叠加层：纹理只在内容版本号变了才重传（按键时才变，逐帧重传
	 * 一行字也要一次 glTexImage2D，没必要）。gen 来自 osd_gen()。
	 */
	GLuint prog_osd, tex_osd;
	unsigned osd_gen, osd_w, osd_h;
	/* 上一帧的入参：暂停时没有新帧，但提示条要到点消失/按键要出现，
	 * 得拿同一块 dma-buf 重画一遍（纹理按 fd 复用，不重导入）。
	 */
	int last_fy, last_fc, have_last;
	unsigned last_w, last_h, last_yp, last_cp;
	/* atomic 上屏（ATOMIC=1）。为什么非要它：legacy SetCrtc/PageFlip 交
	 * 「比 mode 小的 fb」一律 ENOSPC，于是「渲染目标缩到源分辨率、放大交给
	 * DPU」这条路在 legacy 上根本不成立（§4.1.5 实测）；atomic 的平面提交
	 * 带上 CRTC_W/H=整屏就等价于 drmModeSetPlane(dst=整屏)，放大成功。
	 * 顺带两件 legacy 拿不到的东西：
	 *   IN_FENCE_FD   —— GPU 画完的 fence 直接交给 KMS，省掉逐帧 glFinish
	 *   OUT_FENCE_PTR —— 扫描完成的 fence，用来判断这块 bo 何时能重用
	 */
	int atomic;
	uint32_t plane_id, mode_blob;
	uint64_t p_fb, p_pcrtc, p_sx, p_sy, p_sw, p_sh, p_dx, p_dy, p_dw, p_dh;
	uint64_t p_in_fence;
	uint64_t c_act, c_mode, c_out_fence, n_crtc;
	/* EGL native fence（EGL_ANDROID_native_fence_sync）；没有就退回 glFinish */
	int nfence;
	PFNEGLCREATESYNCKHRPROC p_eglCreateSync;
	PFNEGLDESTROYSYNCKHRPROC p_eglDestroySync;
	PFNEGLDUPNATIVEFENCEFDANDROIDPROC p_eglDupFenceFd;
	unsigned long n_fence_ok, n_fence_none, n_fence_fail;
	int nowait;		/* ATOMIC_WAIT=0：提交完立刻返回，不等 flip */
	unsigned long n_commit_ebusy;
} g;

/* 收一次 GPU 完成时间。perf 开时 glFinish 把它变成真实耗时——不加 glFinish
 * 拿到的只是"命令塞进队列"的时间，和 GPU 实际干完差了整整一帧，这种数看着
 * 漂亮但会漏掉所有掉帧。关掉（PERF=0）则退回旧行为，可对比 glFinish 本身的
 * 代价。 */
static void gpu_done(double t0)
{
	double dt;

	if (!g.perf) return;
	glFinish();
	dt = now_s() - t0;
	g.t_sum += dt;
	if (dt > g.t_max) g.t_max = dt;
	ps_add(&g.h_draw, dt * 1000.0);
}

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
	/* 刷新周期按 mode 算，不用 vrefresh：后者常被驱动凑整，2560x1440@60
	 * 实际是 59.95，阈值差 1% 就会把正常帧判成 miss。 */
	g.vbl_ms = g.mode.htotal && g.mode.vtotal && g.mode.clock
		   ? (double)g.mode.htotal * g.mode.vtotal / g.mode.clock
		   : 1000.0 / (g.mode.vrefresh ? g.mode.vrefresh : 60);
	{
		const char *e = getenv("PERF");

		g.perf = e ? atoi(e) : 1;
		ps_init(&g.h_draw, "draw", "ms", g.vbl_ms);
		ps_init(&g.h_swap, "swap", "ms", g.vbl_ms);
		ps_init(&g.h_flip, "flip", "ms", g.vbl_ms * 1.5);
		ps_init(&g.h_int,  "intv", "ms", g.vbl_ms * 1.5);
		g.h_flip.slot_unit = g.vbl_ms;	/* flip 迟到几个周期 */
		g.h_int.slot_unit = g.vbl_ms;	/* 上屏间隔几个周期 */
		if (!g.perf)
			printf("GLOUT: PERF=0，不做逐帧 glFinish，draw 只反映建命令时间\n");
		g.split = getenv("GLDBG") ? atoi(getenv("GLDBG")) : 0;
	}
	return 0;
}

/* ---------- atomic 上屏：属性 id 解析 + 平面提交 ----------
 * 属性 id 只在 init 里查一次（每次 commit 去查属性表是最常见的性能坑：
 * drmModeObjectGetProperties + GetProperty 每帧几十微秒，还带分配）。
 */
static uint32_t aprop(uint32_t obj, uint32_t type, const char *name)
{
	drmModeObjectProperties *op = drmModeObjectGetProperties(g.dfd, obj, type);
	uint32_t k, id = 0;

	if (!op) return 0;
	for (k = 0; k < op->count_props; k++) {
		drmModePropertyRes *pd = drmModeGetProperty(g.dfd, op->props[k]);

		if (pd && !strcmp(pd->name, name)) id = pd->prop_id;
		if (pd) drmModeFreeProperty(pd);
		if (id) break;
	}
	drmModeFreeObjectProperties(op);
	return id;
}

static int atomic_init(void)
{
	drmModeRes *res;
	drmModePlaneRes *pr;
	uint32_t crtc_idx = 32, i;

	if (drmSetClientCap(g.dfd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)) {
		printf("GLOUT: 不支持 UNIVERSAL_PLANES: %s\n", strerror(errno));
		return -1;
	}
	if (drmSetClientCap(g.dfd, DRM_CLIENT_CAP_ATOMIC, 1)) {
		printf("GLOUT: 驱动不支持 atomic: %s\n", strerror(errno));
		return -1;
	}
	res = drmModeGetResources(g.dfd);
	pr = drmModeGetPlaneResources(g.dfd);
	if (!res || !pr) {
		printf("GLOUT: atomic 取资源失败: %s\n", strerror(errno));
		if (res) drmModeFreeResources(res);
		return -1;
	}
	for (i = 0; i < (uint32_t)res->count_crtcs; i++)
		if (res->crtcs[i] == g.crtc_id) crtc_idx = i;
	/* connector 必须取「接在 g.crtc_id 上」的那个：res->connectors[0]
	 * 可能是没插线的口，把它的 CRTC_ID 写进请求会让整个 commit EINVAL
	 * （atomicms 探针就是在这里空转了半小时）。
	 */
	for (i = 0; i < (uint32_t)res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(g.dfd, res->connectors[i]);

		if (!c) continue;
		if (c->encoder_id) {
			drmModeEncoder *e = drmModeGetEncoder(g.dfd, c->encoder_id);

			if (e) {
				if (e->crtc_id == g.crtc_id)
					g.conn_id = c->connector_id;
				drmModeFreeEncoder(e);
			}
		}
		drmModeFreeConnector(c);
	}
	for (i = 0; i < pr->count_planes && !g.plane_id; i++) {
		drmModePlane *p = drmModeGetPlane(g.dfd, pr->planes[i]);
		uint64_t ty;
		uint32_t id;

		if (!p) continue;
		if (!(p->possible_crtcs & (1u << crtc_idx))) {
			drmModeFreePlane(p);
			continue;
		}
		id = aprop(p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
		ty = 0;
		if (id) {
			drmModeObjectProperties *op =
				drmModeObjectGetProperties(g.dfd, p->plane_id,
							   DRM_MODE_OBJECT_PLANE);
			uint32_t k;

			for (k = 0; op && k < op->count_props; k++)
				if (op->props[k] == id) ty = op->prop_values[k];
			if (op) drmModeFreeObjectProperties(op);
		}
		if (ty == DRM_PLANE_TYPE_PRIMARY) g.plane_id = p->plane_id;
		drmModeFreePlane(p);
	}
	drmModeFreePlaneResources(pr);
	drmModeFreeResources(res);
	if (!g.plane_id) { printf("GLOUT: 找不到 primary plane\n"); return -1; }

	g.p_fb = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID");
	g.p_pcrtc = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
	g.p_sx = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X");
	g.p_sy = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y");
	g.p_sw = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W");
	g.p_sh = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H");
	g.p_dx = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X");
	g.p_dy = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
	g.p_dw = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W");
	g.p_dh = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H");
	g.p_in_fence = aprop(g.plane_id, DRM_MODE_OBJECT_PLANE, "IN_FENCE_FD");
	g.c_act = aprop(g.crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
	g.c_mode = aprop(g.crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
	g.c_out_fence = aprop(g.crtc_id, DRM_MODE_OBJECT_CRTC, "OUT_FENCE_PTR");
	g.n_crtc = aprop(g.conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
	if (!g.p_fb || !g.p_sw || !g.p_dw || !g.c_mode || !g.n_crtc) {
		printf("GLOUT: atomic 属性不全 fb=%u sw=%u dw=%u mode=%u conn=%u\n",
		       (unsigned)g.p_fb, (unsigned)g.p_sw, (unsigned)g.p_dw,
		       (unsigned)g.c_mode, (unsigned)g.n_crtc);
		return -1;
	}
	if (drmModeCreatePropertyBlob(g.dfd, &g.mode, sizeof(g.mode),
				      &g.mode_blob)) {
		printf("GLOUT: mode blob 失败: %s\n", strerror(errno));
		return -1;
	}
	g.atomic = 1;
	g.nowait = getenv("ATOMIC_WAIT") && !atoi(getenv("ATOMIC_WAIT"));
	printf("GLOUT: atomic 上屏 plane=%u conn=%u in_fence=%s out_fence=%s%s\n",
	       g.plane_id, g.conn_id, g.p_in_fence ? "有" : "无",
	       g.c_out_fence ? "有" : "无", g.nowait ? " (不等 flip)" : "");
	return 0;
}

/* GPU 画完的 fence：glout 不再 glFinish，让 KMS 等 GPU。
 * eglDupNativeFenceFDANDROID 返回 -1 表示「没有未完成的活」（工作已经
 * 做完），这时按 -1 属性提交，等价于「立刻可用」。
 */
static int make_fence(void)
{
	EGLSyncKHR s;
	int fd;

	if (!g.nfence) return -1;
	s = g.p_eglCreateSync(g.dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
	if (s == EGL_NO_SYNC_KHR) {
		g.n_fence_fail++;
		return -1;
	}
	fd = g.p_eglDupFenceFd(g.dpy, s);
	g.p_eglDestroySync(g.dpy, s);
	if (fd < 0) g.n_fence_none++;
	else g.n_fence_ok++;
	return fd;
}

/* 前向声明：这一段在 flip 记账函数之前（它们贴着 legacy 上屏路径） */
static void wait_flip_to(int ms);
static void wait_flip(void);
static void record_flip(double t_req);

/* 一次平面提交。首帧要带全套 modeset（让 CRTC 上有模式），之后只改
 * FB_ID（+ 尺寸），这在本驱动上实测 43µs/次，比 legacy PageFlip 还快。
 * 返回 0 表示已提交（fence fd 归内核），-1 表示失败。
 */
/* 每帧都失败时别刷屏：同一条错误只喊前 3 次，之后每 60 次喊一次。
 * 屏幕不动的时候日志里 80 行一样的字，看不出是哪个错在先。
 */
static void err_ratelimit(const char *what, int e)
{
	static int last = -1;
	static long n;

	n = (e == last) ? n + 1 : 1;
	last = e;
	if (n > 3 && (n % 60)) return;
	printf("GLOUT: %s 失败: %s%s\n", what, strerror(e),
	       n > 3 ? "（同错持续，之后每 60 次喊一次）" : "");
}

static int present_atomic(uint32_t fbr, int fence_fd)
{
	drmModeAtomicReq *req = drmModeAtomicAlloc();
	int ofd = -1, ret = -1, tries = 0;
	double t_req = now_s();

	if (!req) {
		if (fence_fd >= 0) close(fence_fd);
		return -1;
	}
	drmModeAtomicAddProperty(req, g.plane_id, g.p_fb, fbr);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_pcrtc, g.crtc_id);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_sx, 0);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_sy, 0);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_sw, (uint64_t)g.vw << 16);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_sh, (uint64_t)g.vh << 16);
	/* dst 恒等于整屏：给子矩形 atomic 也回 EINVAL（见 glout_init 里的实测） */
	drmModeAtomicAddProperty(req, g.plane_id, g.p_dx, 0);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_dy, 0);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_dw, g.dw);
	drmModeAtomicAddProperty(req, g.plane_id, g.p_dh, g.dh);
	if (g.p_in_fence)
		drmModeAtomicAddProperty(req, g.plane_id, g.p_in_fence, fence_fd);
	if (g.c_out_fence) {
		ofd = -1;
		drmModeAtomicAddProperty(req, g.crtc_id, g.c_out_fence,
					 (uint64_t)(uintptr_t)&ofd);
	}
	if (g.first) {
		drmModeAtomicAddProperty(req, g.conn_id, g.n_crtc, g.crtc_id);
		drmModeAtomicAddProperty(req, g.crtc_id, g.c_act, 1);
		drmModeAtomicAddProperty(req, g.crtc_id, g.c_mode, g.mode_blob);
		ret = drmModeAtomicCommit(g.dfd, req,
					  DRM_MODE_ATOMIC_ALLOW_MODESET,
					  &g.flip_done);
		if (ret && errno == EBUSY) {
			wait_flip_to(20);
			ret = drmModeAtomicCommit(g.dfd, req,
						  DRM_MODE_ATOMIC_ALLOW_MODESET,
						  &g.flip_done);
		}
		if (!ret) g.first = 0;
	} else {
		/* EBUSY = 上一次提交还挂在 CRTC 上（内核同一时刻只允许一个
		 * pending flip）。收掉挂起事件再重试，和 legacy 路径同策略。
		 */
		while (tries++ < 60) {
			ret = drmModeAtomicCommit(g.dfd, req,
						  DRM_MODE_ATOMIC_NONBLOCK |
						  DRM_MODE_PAGE_FLIP_EVENT,
						  &g.flip_done);
			if (!ret) break;
			if (errno != EBUSY) break;
			g.n_commit_ebusy++;
			wait_flip_to(20);
			usleep(1000);
		}
	}
	drmModeAtomicFree(req);
	/* IN_FENCE_FD 的 fd 归内核（commit 成功后内核 sync_file_get 走了引用，
	 * fd 本身也由内核在 ioctl 里关掉）；失败时是我们自己负责关。
	 * 关两次最多 EBADF，不会误伤——但为了不带病上线，这里只在失败时关。
	 */
	if (ret && fence_fd >= 0) close(fence_fd);
	if (ret) {
		err_ratelimit("atomic commit", errno);
		g.drops++;
		return -1;
	}
	if (ofd >= 0) close(ofd);
	if (g.nowait) {
		record_flip(t_req);	/* 只记请求时刻，不等事件 */
	} else {
		wait_flip();
		record_flip(t_req);
	}
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

/* OSD：一行提示的 RGBA 位图（真 alpha，底条半透明），按 src_alpha 混上去。
 * 和画面 pass 分开编一个程序：片元里不做色彩变换，提示条不该跟着 HDR 走。
 */
static const char *FS_OSD =
	"#version 300 es\n"
	"precision mediump float;\n"
	"uniform sampler2D uTex;\n"
	"in vec2 vUV;\n"
	"out vec4 oCol;\n"
	"void main(){ oCol = texture(uTex, vUV); }\n";

/* 复用调用方已打开的 DRM fd（master 只能有一个，另开 fd 会 SetCrtc EACCES） */
void glout_set_drm_fd(int fd)
{
	g.fd_in = fd;
}

/* ---------- 初始化：DRM + GBM + EGL + GL ---------- */
/* 像素宽高比：必须在 glout_init 之前调用（比例守卫在 init 里定 target 尺寸）。
 * 非方形像素的老片源（如 720x576 SAR 16:15）如果按容器宽高算比例，
 * 会选错 target 并把黑边算歪。VUI 没写就保持默认 1.0。
 */
void glout_set_par(unsigned num, unsigned den)
{
	if (num && den && num < 4096 && den < 4096) {
		g.par = (double)num / den;
	} else {
		g.par = 1.0;
	}
}

/* 源在屏幕上的显示宽高比 */
static double src_ar(unsigned w, unsigned h)
{
	double par = g.par > 0.0 ? g.par : 1.0;

	return (double)w * par / (double)h;
}

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
	if (g.par <= 0.0) g.par = 1.0;
	g.sw = sw;
	g.sh = sh;
	if (g.fd_in > 0) {
		g.dfd = g.fd_in;
	} else {
		g.dfd = open(dev, O_RDWR | O_CLOEXEC);
		if (g.dfd < 0) gdie("open card0");
	}
	/* 拿 master 是「能不能上屏」的前提：别人（kinfo/desktop 之类）拿着
	 * master 时，SetCrtc/PageFlip 一律 EACCES，GBM 那边 eglSwapBuffers
	 * 也随之 EGL_BAD_ALLOC——每帧都失败，但解码循环照跑，fps 看着还挺好。
	 * 所以这里显式要一次，失败就喊出来，别让"解码正常"冒充"在放"。
	 */
	if (drmSetMaster(g.dfd) == 0) {
		g.master = 1;
	} else {
		printf("GLOUT: 拿不到 DRM master (%s)：显示被别的进程占着，"
		       "画面会一帧都上不去\n", strerror(errno));
	}
	if (kms_pick() < 0) return -1;
	/* ATOMIC=1：上屏改走平面提交，这样「渲染 1280x720、由 DPU 放大到整屏」
	 * 才成立（legacy SetCrtc/PageFlip 对小 fb 一律 ENOSPC）。初始化失败不算
	 * 致命：退回 legacy 继续跑，只是不能开 DPUSCALE。
	 */
	if (getenv("ATOMIC") && atoi(getenv("ATOMIC")))
		if (atomic_init() < 0)
			printf("GLOUT: atomic 初始化失败，退回 legacy 上屏\n");
	g.gbm = gbm_create_device(g.dfd);
	if (!g.gbm) gdie("gbm_create_device");
	/* 渲染目标取「源尺寸」，由 DPU 硬件放大到屏幕（§4.1 形态 A）：
	 * 片元数从 dw*dh 降到 vw*vh，放大是 DPU 的免费能力。
	 * 上限 4x：再往上 DPU 的单次放大插值会明显发虚，且 720p 以下源
	 * 本来就是少数情况，退回屏幕尺寸做 GPU 放大更稳。
	 */
	/* 渲染目标取「源尺寸」，由 DPU 硬件放大到屏幕（§4.1 形态 A）：
	 * 片元数从 dw*dh 降到 vw*vh，放大是 DPU 的免费能力。
	 *
	 * 两个死结都是实测的，别绕：
	 *  1. legacy SetCrtc 不收「fb 比 mode 小」（ENOSPC）→ 只有 atomic 平面
	 *     提交下这条路才成立，所以默认值跟着 atomic 走（ATOMIC=1 → 4x）。
	 *  2. plane 的 dst 只能是整屏：给子矩形照样进 commit，但 atomic 回
	 *     EINVAL —— 实测 192 帧帧帧失败、全靠 legacy 兜底才上屏
	 *     （`DSTFIT` 那个实验就是这么否掉的）。所以黑边不能靠 dst 偏移，
	 *     只能画进 target。
	 * 两条合起来就是：**target 必须与屏幕同比例**。比例对不上还硬放，
	 * DPU 会把整张拉成全屏 —— 2.35:1 的片子就是纵向 1.35 倍的变形。
	 * 所以比例差超过 0.5% 就退回整屏 target，让 GL 自己画黑边。
	 * 上限 4x：再往上 DPU 的单次放大插值明显发虚。
	 */
	/* 默认 0（不放大）。曾经默认跟着 atomic 走 4x，实测站不住：
	 * target 就是源尺寸，所以 DPU 放大只会发生在「源比屏小」的场合，
	 * 而那正是填充最便宜的时候 —— 720p 源 target 1280x720 的 draw 只有
	 * 0.01ms，1080p 源 target 1920x1080 是 0.02ms（开不开 tonemap 都一样），
	 * Mali-G31 在这个量级上根本不是瓶颈。反过来 DPU 路径要 atomic 提交，
	 * 720p 源上实测 55.5 fps，整屏 target 是 58.9 fps —— 放大不赚还略亏，
	 * 却要多一层插值。留着当手动旋钮（DPUSCALE=2/4 + ATOMIC=1 能跑通、
	 * 300/300 上屏），但不该是默认行为。 */
	g.up = getenv("DPUSCALE") ? (unsigned)atoi(getenv("DPUSCALE")) : 0;
	/* 死结 1 的后果：没有 atomic 就只有 legacy SetCrtc/PageFlip，而这两条
	 * 对小 fb 一律 ENOSPC —— 显式要了 DPUSCALE 却忘了 ATOMIC=1，实测就是
	 * 全程黑屏（submit 300 / shown 0，日志只有一行 SetCrtc 失败）。
	 * 与其让人对着黑屏猜，这里直接否掉并说清原因。 */
	if (g.up && !g.atomic) {
		printf("GLOUT: DPUSCALE=%u 需要 ATOMIC=1（legacy 不收小 fb，"
		       "会全程黑屏）；本次按 0 处理\n", g.up);
		g.up = 0;
	}
	g.vw = sw ? sw : g.dw;
	g.vh = sh ? sh : g.dh;
	if (g.vw > g.dw) g.vw = g.dw;
	if (g.vh > g.dh) g.vh = g.dh;
	g.vw &= ~1u;
	g.vh &= ~1u;
	if (!g.vw || !g.vh) { g.vw = g.dw; g.vh = g.dh; }
	{
		double asp_t = (double)g.vw / g.vh;
		double asp_s = (double)g.dw / g.dh;

		if (!g.up || g.vw * g.up < g.dw || g.vh * g.up < g.dh ||
		    fabs(asp_t - asp_s) > asp_s * 0.005) {
			g.vw = g.dw;
			g.vh = g.dh;
		}
	}
	printf("GLOUT: target %ux%u -> 屏 %ux%u（DPU %ux 放大）\n",
	       g.vw, g.vh, g.dw, g.dh, g.up);
	g.gs = gbm_surface_create(g.gbm, g.vw, g.vh, GBM_FORMAT_XRGB8888,
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
	/* EGL native fence：有它才能把「GPU 还没画完」交给 KMS 等，
	 * 省掉逐帧 glFinish（实测 720p pass1 的 glFinish 要 8.3ms，
	 * 其中大部分是等 GPU，本来可以流水到下一帧）。没有就退回 glFinish。
	 */
	{
		const char *e = eglQueryString(g.dpy, EGL_EXTENSIONS);

		if (e && strstr(e, "EGL_ANDROID_native_fence_sync")) {
			g.p_eglCreateSync = (PFNEGLCREATESYNCKHRPROC)
				eglGetProcAddress("eglCreateSyncKHR");
			g.p_eglDestroySync = (PFNEGLDESTROYSYNCKHRPROC)
				eglGetProcAddress("eglDestroySyncKHR");
			g.p_eglDupFenceFd = (PFNEGLDUPNATIVEFENCEFDANDROIDPROC)
				eglGetProcAddress("eglDupNativeFenceFDANDROID");
			if (g.p_eglCreateSync && g.p_eglDestroySync &&
			    g.p_eglDupFenceFd)
				g.nfence = 1;
		}
		printf("GLOUT: EGL native fence %s\n",
		       g.nfence ? "可用（不 glFinish，交给 KMS 等）"
				: "不可用（退回逐帧 glFinish）");
	}
	g.twopass = getenv("GL1PASS") ? 0 : 1;
	g.inited = 1;
	g.first = 1;
	printf("GLOUT: GL %s / 屏 %ux%u 渲染 %ux%u (%s)\n",
	       glGetString(GL_VERSION), g.dw, g.dh, g.vw, g.vh,
	       (g.vw == g.dw && g.vh == g.dh) ? "GPU 放大" : "DPU 放大");
	printf("GLOUT: 渲染器 %s (%s)\n", glGetString(GL_RENDERER),
	       glGetString(GL_VENDOR));
	return 0;
}

/* 源尺寸变了就把渲染 target 跟着改（换片、自适应分辨率）。
 * GBM surface 换尺寸只能重建：gbm_surface_destroy 会释放全部 bo，
 * 上面挂的 fb_id 必须一起删，否则内核对已释放的 GEM 还留着 fb 引用。
 */
static int ensure_surface(unsigned w, unsigned h)
{
	unsigned nw = w ? w : g.dw, nh = h ? h : g.dh;

	if (!g.up) return 0;
	if (nw > g.dw) nw = g.dw;
	if (nh > g.dh) nh = g.dh;
	if (!g.up || nw * g.up < g.dw || nh * g.up < g.dh) { nw = g.dw; nh = g.dh; }
	nw &= ~1u;
	nh &= ~1u;
	if (!nw || !nh) { nw = g.dw; nh = g.dh; }
	if (nw == g.vw && nh == g.vh) return 0;
	/* 差距 10% 以内不值得重建：recreate 要丢两帧 */
	if (abs((int)nw - (int)g.vw) * 10 < (int)g.vw &&
	    abs((int)nh - (int)g.vh) * 10 < (int)g.vh)
		return 0;
	{
		int i;

		for (i = 0; i < g.nfly; i++) {
			uint32_t *slot = gbm_bo_get_user_data(g.fly[i]);

			if (slot && *slot) { drmModeRmFB(g.dfd, *slot); *slot = 0; }
		}
	}
	eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroySurface(g.dpy, g.surf);
	gbm_surface_destroy(g.gs);
	g.gs = gbm_surface_create(g.gbm, nw, nh, GBM_FORMAT_XRGB8888,
				  GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	if (!g.gs) { printf("GLOUT: 重建 gbm_surface 失败\n"); return -1; }
	g.surf = eglCreateWindowSurface(g.dpy, g.cfg,
					(EGLNativeWindowType)g.gs, NULL);
	if (g.surf == EGL_NO_SURFACE) {
		printf("GLOUT: 重建 egl surface 失败 0x%x\n", eglGetError());
		return -1;
	}
	if (!eglMakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) {
		printf("GLOUT: 重建后 makeCurrent 失败 0x%x\n", eglGetError());
		return -1;
	}
	g.vw = nw;
	g.vh = nh;
	g.first = 1;	/* 老 fb 都删了，下一帧必须 SetCrtc 重新点名 */
	printf("GLOUT: 渲染 target 改为 %ux%u（源 %ux%u → 屏 %ux%u）\n",
	       nw, nh, w, h, g.dw, g.dh);
	return 0;
}

/* LUT 纹理上传 + 采样参数（初始化一次；SEI 峰值后到时重建也走这条） */
/* 抖动噪声贴图：128x128 R8，NEAREST+REPEAT，命中纹理缓存基本免费。
 * 内容用 LCG 生成成"蓝噪声近似"（打散 + 固定种子），不做逐帧变化——
 * 抖动只为了打散 8bit 色带，逐帧变化反而会闪。
 */
static void noise_upload(void)
{
	unsigned char n[128 * 128];
	unsigned i, x = 12345;

	for (i = 0; i < sizeof(n); i++) {
		x = x * 1103515245u + 12345u;
		/* 三角分布：两个均匀相加，均值 0.5，比纯均匀少一半的抖动能量 */
		unsigned a = (x >> 16) & 0xff, b = (x >> 8) & 0xff;

		n[i] = (unsigned char)((a + b) >> 1);
	}
	glGenTextures(1, &g.tex_noise);
	glBindTexture(GL_TEXTURE_2D, g.tex_noise);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 128, 128, 0, GL_RED,
		     GL_UNSIGNED_BYTE, n);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
}

static void lut_upload(const float *lut)
{
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
}

/* GL 这条路径在开流前就把 LUT 建好了，而 maxCLL 往往跟着第一帧的 SEI 才到。
 * 峰值一变就重建表 + 重拟多项式（uPc/uPg 每帧都上传，不用另外处理），
 * 否则整片都在按兜底的 1000 压。每帧两次比较的代价。
 */
static void tm_peak_sync(void)
{
	float lut[256 * 4];
	double p;

	if (!tp_sat_env && g_cm.primaries != tp_pri) {
		double s;

		tp_pri = g_cm.primaries;
		s = tp.on ? hc_sat_from_primaries(tp_pri, 0.90) : 1.0;
		if (fabs(s - tp.sat) > 0.001) {
			tp.sat = s;
			build_lut(lut);
			lut_upload(lut);
			printf("GLOUT: 色域 -> %s，sat=%.2f，LUT 重建\n",
			       cm_gamut(), tp.sat);
		}
	}
	/* VUI/位深后到（GL 在开流前就建好表）：SDR↔HDR 判定可能整片翻过来，
	 * 不重建就会一直按错的开关跑。 */
	if (g_cm.transfer != tp_tf_used || g_cm.bit_depth != tp_bd_used) {
		struct hdrcolor c;

		build_lut(lut);
		lut_upload(lut);
		c = tp_hc();
		printf("GLOUT: VUI 后到 tf=%d bd=%d → TM %s，LUT 重建\n",
		       g_cm.transfer, g_cm.bit_depth, c.on ? "on" : "off");
	}
	if (tp_peak_env)
		return;
	p = csig_peak();
	if (p <= 0.0 || fabs(p - tp_peak_used) <= 0.5)
		return;
	build_lut(lut);
	lut_upload(lut);
	printf("GLOUT: 内容峰值 -> %.0fnits(sei)，LUT 重建\n", tp.src_peak);
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

		if (k < 0 || k > 11) k = 0;
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
	lut_upload(lut);
	noise_upload();
	g.tex_y = 0;
	g.tex_c = 0;
	return 0;
}

/* dmabuf → EGLImage → 纹理 */
static GLuint import_tex(int fd, unsigned w, unsigned h, unsigned pitch,
			 uint32_t fourcc, void **oimg)
{
	PFNEGLCREATEIMAGEKHRPROC create_image =
		(PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	pfn_image_tex target_tex = (pfn_image_tex)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	EGLint attr[16];
	int n = 0;
	EGLImageKHR img;
	GLuint tex;

	if (!create_image || !target_tex) {
		printf("GLOUT: eglGetProcAddress 缺函数 create_image=%p target_tex=%p\n",
		       (void *)create_image, (void *)target_tex);
		return 0;
	}
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
	if (oimg) *oimg = (void *)img;
	return tex;
}

/* 换分辨率/缓存满：扔掉所有导入的纹理 */
static void drop_tex(void)
{
	int i;

	PFNEGLDESTROYIMAGEKHRPROC destroy_image =
		(PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");

	for (i = 0; i < g.ntc; i++) {
		if (g.tc[i].ty) glDeleteTextures(1, &g.tc[i].ty);
		if (g.tc[i].tc) glDeleteTextures(1, &g.tc[i].tc);
		/* 关键：先删纹理再销毁 img，dma_buf 引用才会真正释放 */
		if (destroy_image) {
			if (g.tc[i].ey) destroy_image(g.dpy, (EGLImageKHR)g.tc[i].ey);
			if (g.tc[i].ec) destroy_image(g.dpy, (EGLImageKHR)g.tc[i].ec);
		}
		g.tc[i].ey = g.tc[i].ec = NULL;
	}
	g.ntc = 0;
	g.tex_y = g.tex_c = 0;
}

/* seek 后 dmabuf fd 全换了一批：把旧纹理扔掉，按新 fd 重新导入。
 * GL 上下文/EGLDisplay/DRM 都不动，所以屏幕不会黑。
 */
/* 给自检/上层看的统计：片元（含 glFinish 的绘制）累计与峰值、swap 累计 */
void glout_stats(double *draw_sum, double *draw_max, double *swap_sum,
		 unsigned *frames)
{
	if (draw_sum) *draw_sum = g.t_sum;
	if (draw_max) *draw_max = g.t_max;
	if (swap_sum) *swap_sum = g.tsum;
	if (frames) *frames = g.frames;
}

/* 上屏质量：提交了多少次、真上屏多少帧、是不是 master。
 * 调用方（播放器的 PERF 行）必须两者都报：只报成功次数时，
 * 「一帧都没上屏」和「上屏很慢」在数字上长得一模一样。
 */
void glout_present_stats(long *sub, unsigned *shown, long *drops, int *master)
{
	if (sub) *sub = g.sub;
	if (shown) *shown = (unsigned)g.presented;
	if (drops) *drops = g.drops;
	if (master) *master = g.master;
}

void glout_reset(void)
{
	if (!g.inited) return;
	drop_tex();
}

/* 帧级性能结论。故意不打印 fps：fps 是下面四个量的商，看商看不出病因。 */
void glout_perf_print(void)
{
	if (!g.frames) return;
	printf("--- GLOUT 性能（%u 帧, 周期 %.3f ms）---\n", g.frames, g.vbl_ms);
	ps_print(&g.h_draw);
	ps_print(&g.h_swap);
	ps_print(&g.h_flip);
	if (g.h_flip.n) {
		long miss = (long)g.h_flip.over;

		printf("PERF flip  vblank miss %ld 次 / %ld 次翻页 (%.1f%%)"
		       "，最大迟到 %.2f ms = %.2f 个周期\n",
		       miss, g.h_flip.n, 100.0 * miss / g.h_flip.n,
		       g.h_flip.maxv, g.vbl_ms > 0 ? g.h_flip.maxv / g.vbl_ms : 0);
	}
	ps_print(&g.h_int);
	printf("PERF 上屏 %ld 帧 / 提交 %ld 帧（丢弃 %ld）%s\n",
	       g.presented, g.sub, g.drops,
	       g.presented ? "" : "  ← 一帧都没上屏，屏幕不会变！");
	if (!g.presented && g.sub)
		printf("GLOUT: 全部帧丢弃%s\n",
		       g.master ? "" : "（本进程不是 DRM master，见上面那行）");
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
	buf = malloc((size_t)g.vw * g.vh * 4);
	if (!buf) return;
	glReadPixels(0, 0, g.vw, g.vh, GL_RGBA, GL_UNSIGNED_BYTE, buf);
	f = fopen(p, "wb");
	if (!f) { free(buf); return; }
	fprintf(f, "P6\n%u %u\n255\n", g.vw, g.vh);
	for (y = 0; y < g.vh; y++) {
		unsigned char *r = buf + (size_t)(g.vh - 1 - y) * g.vw * 4;

		for (x = 0; x < g.vw; x++) fwrite(r + x * 4, 1, 3, f);
	}
	fclose(f);
	free(buf);
	printf("GLOUT: 抓帧 → %s (%ux%u)\n", p, g.vw, g.vh);
}

static void flip_handler(int fd, unsigned seq, unsigned sec, unsigned usec, void *data)
{
	(void)fd; (void)seq; (void)sec; (void)usec;
	/* atomic 提交的 user_data 是 commit 时给的指针；万一没给（NULL），
	 * 这里绝不能写 —— 一写就是段错误，整链重启闪屏。
	 */
	if (data) *(int *)data = 1;
}

static void wait_flip_to(int ms)
{
	drmEventContext ev;

	memset(&ev, 0, sizeof(ev));
	ev.version = DRM_EVENT_CONTEXT_VERSION;
	ev.page_flip_handler = flip_handler;
	g.flip_done = 0;
	/* 硬截止：原来只看 poll 的返回值，一旦 DRM fd 永久可读（事件被暂停/
	 * 冻住时丢掉、或 CRTC 上挂着一条不属于本进程的 flip），poll 立刻返回
	 * >0、drmHandleEvent 又拿不到 flip 事件，这里就死转不出来了 ——
	 * 实测 resume 后卡死在这，画面冻住而进程 CPU 才 3%。
	 * 现在按墙钟限总等待，出错立即返回，由调用方走 SetCrtc 兜底。
	 */
	{
		double t0 = now_s();

		while (!g.flip_done) {
			struct pollfd p = {g.dfd, POLLIN, 0};
			double left = ms - (now_s() - t0) * 1000.0;
			int pr;

			if (left <= 0) break;
			pr = poll(&p, 1, (int)left);
			if (pr <= 0) break;
			if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
			if (drmHandleEvent(g.dfd, &ev) != 0) break;
		}
	}
}

static void wait_flip(void)
{
	wait_flip_to(200);
}

/* 一次上屏的两笔账：
 *   flip 延迟 = 请求翻页 → flip 完成事件。翻页只会落在某个 vblank 边界上，
 *     所以正常值 ≤ 1 个周期；超过 1.5 周期说明这一帧没赶上最近那个 vblank，
 *     也就是真正意义上的 vblank miss（不是"fps 低"，是"交晚了"）。
 *   intv = 两次真正上屏的间隔。24fps@60 应该只有 33.3/50.0 两个峰；出现
 *     16.7 说明某些帧被重复扫了，出现 66.7 说明漏了一个槽。
 */
static void record_flip(double t_req)
{
	double now = now_s(), ms = (now - t_req) * 1000.0;

	ps_add(&g.h_flip, ms);
	if (g.latch_have) ps_add(&g.h_int, (now - g.t_latch_prev) * 1000.0);
	g.t_latch_prev = now;
	g.latch_have = 1;
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
	/* fb 尺寸 = bo 尺寸 = 渲染 target。比 CRTC 小就是 DPU 硬件放大，
	 * 比它大就是硬件缩小（源比屏大时老路径也在用），两种都免费。
	 */
	ret = drmModeAddFB2WithModifiers(g.dfd, g.vw, g.vh,
					 DRM_FORMAT_XRGB8888, handles, pitches,
					 offsets, mods, &fb, flags);
	if (ret && !(flags & DRM_MODE_FB_MODIFIERS))
		ret = drmModeAddFB2(g.dfd, g.vw, g.vh, DRM_FORMAT_XRGB8888,
				    handles, pitches, offsets, &fb, 0);
	if (ret) {
		printf("GLOUT: AddFB2 失败: %s\n", strerror(errno));
		return 0;
	}
	return fb;
}

/* ---------- 画一帧 ---------- */

/* 两遍渲染：pass1 源分辨率全功能色调映射 → 纹理；pass2 纹理整屏放大 */
/* 画提示条：底部居中再往左偏一点（电视过扫描不留边）。
 * 位置按屏幕高度缩放，1080p 上就是烘出来的原尺寸。
 */
static void osd_draw(void)
{
	int W, H, m;
	unsigned qw, qh, qx, qy;
	double k;
	unsigned char *px;

	if (!osd_active())
		return;
	if (!g.prog_osd) {
		g.prog_osd = mk_prog(VS, FS_OSD);
		if (!g.prog_osd)
			return;
		glGenTextures(1, &g.tex_osd);
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, g.tex_osd);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		g.osd_gen = 0;
	}
	if (osd_gen() != g.osd_gen) {
		px = osd_rgba(&W, &H);
		if (!px)
			return;
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, g.tex_osd);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA,
			     GL_UNSIGNED_BYTE, px);
		free(px);
		g.osd_w = (unsigned)W;
		g.osd_h = (unsigned)H;
		g.osd_gen = osd_gen();
		/* 一行日志：屏幕上有没有提示条，只有这里能看出来（fb0 是死图，
		 * 取画面要读 plane 的 GBM buffer，盒子上一时半会儿拿不到） */
		printf("OSD: 上屏 %dx%d\n", W, H);
		fflush(stdout);
	}
	if (!g.osd_w || !g.osd_h)
		return;
	/* 提示条画在渲染 target 的坐标系里（DPU 会把它一起放大），
	 * 缩放基准因此是 vh，不是屏幕的 dh。
	 */
	k = (double)g.vh / 1080.0;
	qw = (unsigned)(g.osd_w * k + 0.5);
	qh = (unsigned)(g.osd_h * k + 0.5);
	m = (int)(40.0 * k);
	qx = (unsigned)m;
	qy = (unsigned)m;
	glViewport((int)qx, (int)qy, qw, qh);
	glUseProgram(g.prog_osd);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_osd);
	glUniform1i(glGetUniformLocation(g.prog_osd, "uTex"), 0);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glBindVertexArray(g.vao);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glDisable(GL_BLEND);
}

/* 暂停补画：没有新帧，但提示条要出现/到点消失。
 * 拿上一帧的同一块 dma-buf 重走一遍（纹理按 fd 命中，不重导入），
 * 所以只花一次绘制，不碰解码器也不动时间轴。
 */
int glout_repaint(void)
{
	if (!g.inited || !g.have_last)
		return -1;
	return glout_frame(g.last_fy, g.last_fc, g.last_w, g.last_h,
			   g.last_yp, g.last_cp);
}

static int twopass_frame(unsigned w, unsigned h)
{
	unsigned dW, dH, pw, ph;
	double ar_s, ar_d, t0 = now_s();
	double tA = t0, tB = t0, tC = t0, tD = t0, tE = t0;
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
	glActiveTexture(GL_TEXTURE3);
	glBindTexture(GL_TEXTURE_2D, g.tex_noise);
	glActiveTexture(GL_TEXTURE0);
	glUniform1i(glGetUniformLocation(g.prog, "uY"), 0);
	glUniform1i(glGetUniformLocation(g.prog, "uC"), 1);
	glUniform1i(glGetUniformLocation(g.prog, "uLut"), 2);
	glUniform1i(glGetUniformLocation(g.prog, "uNoise"), 3);
	/* sat 已在 LUT 的色度增益里，片元里那次 mix 保持恒等，避免算两遍。 */
	glUniform1f(glGetUniformLocation(g.prog, "uSat"), 1.0f);
	gm_upload(g.prog);
	glUniform1fv(glGetUniformLocation(g.prog, "uPc"), 12, poly_c);
	glUniform1fv(glGetUniformLocation(g.prog, "uPg"), 12, poly_g);
	glBindVertexArray(g.vao);
	tB = now_s();
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	tC = now_s();
	/* pass2：目标是渲染 target（vw x vh），不是屏幕 —— 放大交给 DPU。
	 * 片元数因此从 dw*dh 降到 vw*vh（720p 源在 1080p 屏上是 25%）。
	 * 等比黑边在 target 坐标系里算：DPU 把整张 target 一起放大，
	 * 黑边比例不变，所以在任意宽高比的源上依然是对的。
	 */
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	ar_s = src_ar(w, h);
	ar_d = (double)g.vw / g.vh;
	if (ar_s > ar_d) { dW = g.vw; dH = (unsigned)(g.vw / ar_s + 0.5) & ~1u; }
	else { dH = g.vh; dW = (unsigned)(g.vh * ar_s + 0.5) & ~1u; }
	dx = (g.vw - dW) / 2;
	dy = (g.vh - dH) / 2;
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glViewport(dx, g.vh - dy - dH, dW, dH);
	glUseProgram(g.prog2);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_rgb);
	glUniform1i(glGetUniformLocation(g.prog2, "uTex"), 0);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	tD = now_s();
	osd_draw();		/* 提示条在屏幕坐标里，两 pass 之后再合成 */
	tE = now_s();
	gpu_done(t0);		/* twopass 也要记，别只记单 pass */
	{
		static long n;
		static double ab, bc, cd, de, ef;
		static int on = -1;

		if (on < 0) on = getenv("GLOUT_T") ? 1 : 0;
		if (on) {
			double te = now_s();

			ab += tB - tA; bc += tC - tB; cd += tD - tC;
			de += tE - tD; ef += te - tE;
			if (++n % 60 == 0)
				printf("GLIN setup=%.1f p1=%.1f p2=%.1f osd=%.1f "
				       "fin=%.1f ms/帧\n", ab / n * 1000,
				       bc / n * 1000, cd / n * 1000,
				       de / n * 1000, ef / n * 1000);
		}
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
	double tg0 = 0, tg1 = 0, tg2 = 0;	/* swap/lock/flip 各自累计进 g.s_*，不需要再打点 */

	if (!g.inited) {
		printf("GLOUT: glout_frame 但未 inited (errno=%d %s)\n",
		       errno, strerror(errno));
		return -1;
	}
	if (!g.prog) {
		glout_gl_init();
		if (!g.prog) {
			printf("GLOUT: glout_gl_init 未产出 prog (errno=%d %s)\n",
			       errno, strerror(errno));
			return -1;
		}
	}
	tg0 = now_s();
	tm_peak_sync();	/* 峰值后到就重建 LUT（每帧两次比较） */
	if (w != g.sw || h != g.sh) {
		drop_tex();
		g.sw = w;
		g.sh = h;
		/* 渲染 target 跟着源走（DPUSCALE=0 时 ensure_surface 直接返回） */
		if (ensure_surface(w, h)) return -1;
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
			void *iy = NULL, *ic = NULL;

			ty = import_tex(fd_y, w, h, ypitch, DRM_FORMAT_R8, &iy);
			tc = import_tex(fd_c, w / 2, h / 2, cpitch, DRM_FORMAT_GR88, &ic);
			if (!ty || !tc) {
				printf("GLOUT: import_tex 返回空 ty=%u tc=%u (errno=%d %s)\n",
				       ty, tc, errno, strerror(errno));
				/* 导入失败的那半张也销毁，别漏 dma_buf 引用 */
				glDeleteTextures(1, &ty);
				glDeleteTextures(1, &tc);
				if (iy) {
					PFNEGLDESTROYIMAGEKHRPROC di =
						(PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
					if (di) di(g.dpy, (EGLImageKHR)iy);
				}
				if (ic) {
					PFNEGLDESTROYIMAGEKHRPROC di =
						(PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
					if (di) di(g.dpy, (EGLImageKHR)ic);
				}
				return -1;
			}
			k = g.ntc++;
			g.tc[k].fy = fd_y;
			g.tc[k].fc = fd_c;
			g.tc[k].ty = ty;
			g.tc[k].tc = tc;
			g.tc[k].ey = iy;
			g.tc[k].ec = ic;
		}
		g.tex_y = g.tc[k].ty;
		g.tex_c = g.tc[k].tc;
	}
	tg1 = now_s();
	if (g.twopass) {
		g.last_fy = fd_y;
		g.last_fc = fd_c;
		g.last_w = w;
		g.last_h = h;
		g.last_yp = ypitch;
		g.last_cp = cpitch;
		g.have_last = 1;
		if (twopass_frame(w, h)) return -1;
		goto swap;
	}
	ar_s = src_ar(w, h);
	ar_d = (double)g.vw / g.vh;
	if (ar_s > ar_d) {
		dW = g.vw;
		dH = (unsigned)(g.vw / ar_s + 0.5) & ~1u;
	} else {
		dH = g.vh;
		dW = (unsigned)(g.vh * ar_s + 0.5) & ~1u;
	}
	dx = (g.vw - dW) / 2;
	dy = (g.vh - dH) / 2;
	glViewport(0, 0, g.vw, g.vh);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glViewport(dx, g.vh - dy - dH, dW, dH);
	glUseProgram(g.prog);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, g.tex_y);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, g.tex_c);
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, g.tex_lut);
	glActiveTexture(GL_TEXTURE3);
	glBindTexture(GL_TEXTURE_2D, g.tex_noise);
	glActiveTexture(GL_TEXTURE0);
	glUniform1i(glGetUniformLocation(g.prog, "uY"), 0);
	glUniform1i(glGetUniformLocation(g.prog, "uC"), 1);
	glUniform1i(glGetUniformLocation(g.prog, "uLut"), 2);
	glUniform1i(glGetUniformLocation(g.prog, "uNoise"), 3);
	/* sat 已在 LUT 的色度增益里，片元里那次 mix 保持恒等，避免算两遍。 */
	glUniform1f(glGetUniformLocation(g.prog, "uSat"), 1.0f);
	gm_upload(g.prog);
	glUniform1fv(glGetUniformLocation(g.prog, "uPc"), 12, poly_c);
	glUniform1fv(glGetUniformLocation(g.prog, "uPg"), 12, poly_g);
	glBindVertexArray(g.vao);
	{
		double t0 = now_s();

		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		gpu_done(t0);
	}
	g.last_fy = fd_y;
	g.last_fc = fd_c;
	g.last_w = w;
	g.last_h = h;
	g.last_yp = ypitch;
	g.last_cp = cpitch;
	g.have_last = 1;
	osd_draw();

swap:
	g.sub++;
	tg2 = now_s();
	dump_frame();
	{
		double ts = now_s(), dt;

		if (!eglSwapBuffers(g.dpy, g.surf)) {
			{
				static int en;
				unsigned e = eglGetError();

				/* 0x3003 = EGL_BAD_ALLOC：GBM 分不出新 back buffer，
				 * 常见于「不是 DRM master」或 surface 尺寸被改过。
				 */
				if (en++ < 3 || !(en % 60))
					printf("GLOUT: eglSwapBuffers 失败 0x%x%s\n",
					       e, e == 0x3003 ?
					       " (EGL_BAD_ALLOC：分不出 back buffer)" : "");
			}
			g.drops++;
			return -1;
		}
		dt = now_s() - ts;
		g.tsum += dt;
		g.s_swap += dt;
		ps_add(&g.h_swap, dt * 1000.0);
	}
	if (0) {
		printf("GLOUT: swap 失败 0x%x\n", eglGetError());
		return -1;
	}
	{
		double tl = now_s();

		bo = gbm_surface_lock_front_buffer(g.gs);
		g.s_lock += now_s() - tl;
	}
	if (!bo) { printf("GLOUT: lock_front 失败\n"); g.drops++; return -1; }
	fbr = gbm_bo_get_user_data(bo) ? *(uint32_t *)gbm_bo_get_user_data(bo) : 0;
	if (!fbr) {
		uint32_t *slot = calloc(1, sizeof(uint32_t));

		fbr = bo_to_fb(bo);
		if (!fbr) { g.drops++; return -1; }
		*slot = fbr;
		gbm_bo_set_user_data(bo, slot, NULL);
	}
	if (g.atomic) {
		int ff = -1;
		double tf;

		if (g.nfence) ff = make_fence();
		else glFinish();	/* 没有 in-fence，只能自己等 GPU 画完 */
		tf = now_s();
		if (present_atomic(fbr, ff) == 0)
			g.presented++;
		else if (g.drops == 1)
			/* 第一次就失败：一次性说清「解码还在跑但屏幕不会变」 */
			printf("GLOUT: 上屏被拒——解码和渲染继续，但这帧没上屏\n");
		g.s_flip += now_s() - tf;
	} else {
	double tf = now_s();

	if (g.first) {
		int tries = 0;

		while (drmModeSetCrtc(g.dfd, g.crtc_id, fbr, 0, 0, &g.conn_id, 1,
				      &g.mode)) {
			if (errno != EBUSY || ++tries > 20) {
				err_ratelimit("SetCrtc", errno);
				return -1;
			}
			wait_flip_to(20);
			usleep(1000);
		}
		g.first = 0;
	} else {
		int tries = 0, ok = 0;
		double t_req = now_s();

		/* EBUSY = 上一个 flip 还挂在 CRTC 上没完成（内核同一时刻
		 * 只允许一个 pending flip）。以前这里直接放弃 → 进程 die →
		 * 上层整链重启闪屏。现在先把挂起的事件收掉再重试。
		 *
		 * 但真机上这个 pending flip 能一直收不掉（桌面 suspend 时留下
		 * 的那笔事后没人再收），于是每帧空转 60×(20+1)ms ≈ 1.26s，
		 * 把一帧的时间预算吃光 → 解码器下游堵住 → 整链掉到 1fps，
		 * 音频线程跟着饿出 xrun（听感就是「没声音」）。所以重试预算
		 * 砍到 3 次；连续失败就记住这台机器 legacy flip 不可用，之后
		 * 直接走 SetCrtc 直切，每 120 帧再探一次 flip，能通了就回退。
		 */
		static int dead, dead_n;

		if (dead && (dead_n = (dead_n + 1) % 120)) {
			errno = EBUSY;		/* 已知不可用：直通兜底 */
		} else {
			while (tries++ < 3) {
				if (!drmModePageFlip(g.dfd, g.crtc_id, fbr,
						     DRM_MODE_PAGE_FLIP_EVENT,
						     &g.flip_done)) {
					ok = 1;
					break;
				}
				if (errno != EBUSY) break;
				wait_flip_to(20);	/* 收掉旧的 flip 完成事件 */
				usleep(1000);
			}
		}
		if (ok) {
			dead = 0;
			dead_n = 0;
			wait_flip();
			record_flip(t_req);
		} else {
			/* 兜底：SetCrtc 会同步等旧 flip 收尾，代价是一次
			 * 直切（可能轻微闪），但比整链重启强得多。
			 */
			if (!dead)
				printf("GLOUT: PageFlip 连续失败(%s)，改走 SetCrtc 直切"
				       "（之后每 120 帧再试一次 flip）\n",
				       strerror(errno));
			dead = 1;
			if (drmModeSetCrtc(g.dfd, g.crtc_id, fbr, 0, 0,
					   &g.conn_id, 1, &g.mode)) {
				printf("GLOUT: SetCrtc 兜底也失败: %s\n",
				       strerror(errno));
				g.drops++;
				return -1;
			}
			record_flip(t_req);	/* 直切也算一次上屏，别漏样本 */
		}
	}
	g.s_flip += now_s() - tf;
	}
	if (g.prev_bo && g.prev_bo != bo) {
		gbm_surface_release_buffer(g.gs, g.prev_bo);
		g.prev_bo = NULL;
	}
	g.prev_bo = bo;
	g.frames++;		/* 画完并交出去了（= 提交，未必上屏） */
	if (!g.atomic) g.presented++;	/* legacy 走到这里是真的 flip 成功了 */
	if (g.split) {
		g.s_in += tg1 - tg0;
		g.s_draw += tg2 - tg1;
	} else {
		g.s_in = g.s_draw = 0;
	}
	if (g.split && ++g.s_n >= 60) {
		printf("GLSPLIT in=%.1f draw=%.1f swap=%.1f lock=%.1f flip=%.1f "
		       "sum=%.1f ms/帧 (n=%u)\n",
		       g.s_in / g.s_n * 1000.0, g.s_draw / g.s_n * 1000.0,
		       g.s_swap / g.s_n * 1000.0, g.s_lock / g.s_n * 1000.0,
		       g.s_flip / g.s_n * 1000.0,
		       (g.s_in + g.s_draw + g.s_swap + g.s_lock + g.s_flip) /
		       g.s_n * 1000.0, g.frames);
		g.s_swap = g.s_lock = g.s_flip = g.s_in = g.s_draw = 0;
		g.s_n = 0;
	}
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

int gen_testcard(unsigned w, unsigned h, int *fy, int *fc,
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
	if (getenv("PAR")) {		/* PAR=16:15 模拟非方形像素，看黑边对不对 */
		unsigned a = 1, b = 1;

		sscanf(getenv("PAR"), "%u:%u", &a, &b);
		glout_set_par(a, b);
	}
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
	glout_perf_print();
	printf("GLOUT: %u 帧, %.1f fps (源 %ux%u → 屏 %ux%u)\n",
	       i, fps, w, h, g.dw, g.dh);
	return 0;
}
#endif /* GLOUT_NO_MAIN */
