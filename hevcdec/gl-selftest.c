/* gl-selftest.c —— 把 EGL/GBM/panfrost 这条上屏通路从解码器里剥出来单独验
 *
 * 为什么值得单独测：GL 路径出错时的症状比 vout 那条更容易误诊。
 *   - dmabuf 导不进纹理 → 画面全黑，但 swap 照常成功、fps 照涨（以为在放）
 *   - EGLImage 拿了 dma_buf 引用没销毁 → 下一个 V4L2 会话 EBUSY，报"黑屏重启"
 *   - GPU 跟不上刷新 → 每帧等 flip，fps 掉到 30/20，看着像"解码慢"
 *   - 反过来，片源 24fps 而通路满 60fps → 播快 15%，看着像"音频不同步"
 * 这四条用彩条一次分开一条：三条用帧时间分布就能认出来。
 *
 * 两个阶段：
 *   probe  不碰屏幕。EGL/GL 能力、dmabuf → R8/GR88 纹理导入、LUT 拟合误差。
 *          glout_init 只建 GBM surface 和 context，不 SetCrtc，可以边跑桌面边测。
 *   run    真上屏（接管 CRTC，桌面会黑）。彩条 N 帧，量每帧墙钟时间并
 *          按 vblank 周期量化——落在 1 个周期还是 k 个周期，直接区分
 *          "被刷新率限住" 和 "被 GPU 限住"。
 *
 * 用法：
 *   ./glselftest probe [WxH]
 *   ./glselftest run   [WxH] [帧数]
 *
 * 链接：glout.c 用 -DGLOUT_NO_MAIN 编进来，本文件只用它的公开入口
 *       glout_init() / glout_frame()，不改 glout.c 一行。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

int glout_init(unsigned sw, unsigned sh);
int glout_frame(int fd_y, int fd_c, unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch);
/* glout.c 里的彩条生成器（原本 static，给自检和它自己的 -t 模式共用） */
void glout_stats(double *draw_sum, double *draw_max, double *swap_sum,
		 unsigned *frames);
int gen_testcard(unsigned w, unsigned h, int *fy, int *fc,
		 unsigned *sy_out, unsigned *sc_out);

typedef void (*pfn_image_tex)(GLenum, void *);
typedef EGLImageKHR (*pfn_create_img)(EGLDisplay, EGLContext, EGLenum,
				      EGLClientBuffer, const EGLint *);

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return (x > y) - (x < y);
}

/* ---------- 只读：屏幕模式（不 SetCrtc） ---------- */
static void dump_mode(int dfd)
{
	drmModeRes *res = drmModeGetResources(dfd);
	int i;

	if (!res) { printf("  getResources 失败: %s\n", strerror(errno)); return; }
	{
		drmModePlaneRes *pr = drmModeGetPlaneResources(dfd);

		printf("  connector %d 个 / crtc %d 个 / plane %d 个\n",
		       res->count_connectors, res->count_crtcs,
		       pr ? (int)pr->count_planes : -1);
		if (pr) drmModeFreePlaneResources(pr);
	}
	for (i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(dfd, res->connectors[i]);
		int k;

		if (!c) continue;
		printf("  conn %u: %s", c->connector_id,
		       c->connection == DRM_MODE_CONNECTED ? "connected" : "disconnected");
		if (c->count_modes)
			printf("  首选 %ux%u@%u", c->modes[0].hdisplay,
			       c->modes[0].vdisplay, c->modes[0].vrefresh);
		printf("  模式 %d 个\n", c->count_modes);
		for (k = 1; k < c->count_modes && k < 4; k++)
			printf("      alt %ux%u@%u\n", c->modes[k].hdisplay,
			       c->modes[k].vdisplay, c->modes[k].vrefresh);
		drmModeFreeConnector(c);
	}
	drmModeFreeResources(res);
}

/* ---------- 造一对 dumb NV12 buffer，导成 fd（模拟 vdec 的 capture buffer） ---------- */
static int mk_dumb(int dfd, unsigned w, unsigned h, int bpp, uint32_t *handle,
		   uint32_t *pitch, int *fd)
{
	struct drm_mode_create_dumb cd = {0};
	struct drm_mode_map_dumb md = {0};
	void *map;

	cd.width = w;
	cd.height = h;
	cd.bpp = bpp;
	if (ioctl(dfd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) return -1;
	md.handle = cd.handle;
	if (ioctl(dfd, DRM_IOCTL_MODE_MAP_DUMB, &md)) return -1;
	map = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, dfd, md.offset);
	if (map == MAP_FAILED) return -1;
	memset(map, 0x10, cd.size);	/* 有限范围黑：Y=16 */
	munmap(map, cd.size);
	if (drmPrimeHandleToFD(dfd, cd.handle, O_RDWR | O_CLOEXEC, fd)) return -1;
	*handle = cd.handle;
	*pitch = cd.pitch;
	return 0;
}

/* ---------- 导一张纹理（与 glout.c 的 import_tex 同样的属性表） ---------- */
static GLuint import_tex(EGLDisplay dpy, int fd, unsigned w, unsigned h,
			 unsigned pitch, uint32_t fourcc)
{
	pfn_create_img create = (pfn_create_img)eglGetProcAddress("eglCreateImageKHR");
	pfn_image_tex target = (pfn_image_tex)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	EGLint attr[] = {
		EGL_WIDTH, (EGLint)w,
		EGL_HEIGHT, (EGLint)h,
		EGL_LINUX_DRM_FOURCC_EXT, (EGLint)fourcc,
		EGL_DMA_BUF_PLANE0_FD_EXT, fd,
		EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
		EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)pitch,
		EGL_NONE
	};
	EGLImageKHR img;
	GLuint tex = 0;

	if (!create || !target) {
		printf("  缺少入口: create=%p target=%p\n", (void *)create, (void *)target);
		return 0;
	}
	while (glGetError() != GL_NO_ERROR)
		;
	img = create(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
		     (EGLClientBuffer)NULL, attr);
	if (img == EGL_NO_IMAGE_KHR) {
		printf("  eglCreateImageKHR 失败 0x%x (fourcc=%s %ux%u pitch=%u)\n",
		       eglGetError(), fourcc == DRM_FORMAT_R8 ? "R8" : "GR88",
		       w, h, pitch);
		return 0;
	}
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	target(GL_TEXTURE_2D, img);
	if (glGetError() != GL_NO_ERROR) {
		printf("  glEGLImageTargetTexture2DOES 失败\n");
		glDeleteTextures(1, &tex);
		return 0;
	}
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	return tex;
}

/* ============================ probe ============================ */
static int do_probe(unsigned w, unsigned h)
{
	int dfd, fdy, fdc, ret = 0;
	uint32_t hy = 0, hc = 0, py = 0, pc = 0;
	EGLDisplay dpy;
	EGLContext ctx;
	EGLConfig cfg;
	EGLint ncfg = 0, ver = 0;
	EGLint cfgattr[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8, EGL_NONE
	};
	EGLint cattr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";
	GLuint ty, tc;

	printf("== probe %ux%u ==\n", w, h);
	dfd = open(dev, O_RDWR | O_CLOEXEC);
	if (dfd < 0) { printf("open %s: %s\n", dev, strerror(errno)); return 1; }
	dump_mode(dfd);

	/* 这里不走 glout_init：它要建全屏 GBM surface（屏 2560x1440 的 scanout bo），
	 * probe 只需要 context，不需要 surface，免得占显存。
	 */
	{
		struct gbm_device *gbm = gbm_create_device(dfd);
		EGLint pmajor = -1;

		if (!gbm) { printf("gbm_create_device 失败\n"); return 1; }
		dpy = eglGetDisplay((EGLNativeDisplayType)gbm);
		if (!eglInitialize(dpy, &pmajor, &ver)) {
			printf("eglInitialize 失败 0x%x\n", eglGetError());
			return 1;
		}
		printf("  EGL %d.%d client-apis=%s\n", pmajor, ver, eglQueryString(dpy, EGL_CLIENT_APIS));
		printf("  EGL_VENDOR=%s\n", eglQueryString(dpy, EGL_VENDOR));
		{
			const char *e = eglQueryString(dpy, EGL_EXTENSIONS);
			int has_dma = e && strstr(e, "EGL_EXT_image_dma_buf_import");
			int has_mod = e && strstr(e, "EGL_EXT_image_dma_buf_import_modifiers");

			printf("  dma_buf_import=%s modifiers=%s\n",
			       has_dma ? "有" : "缺", has_mod ? "有" : "缺");
		}
		if (!eglBindAPI(EGL_OPENGL_ES_API)) { printf("  bindAPI 失败\n"); return 1; }
		ncfg = 0;
		eglChooseConfig(dpy, cfgattr, &cfg, 1, &ncfg);
		printf("  chooseConfig n=%d\n", ncfg);
		ctx = eglCreateContext(dpy, ncfg ? cfg : NULL, EGL_NO_CONTEXT, cattr);
		if (ctx == EGL_NO_CONTEXT) {
			printf("  eglCreateContext 失败 0x%x\n", eglGetError());
			return 1;
		}
		/* surfaceless：panfrost 支持 EGL_KHR_surfaceless_context；
		 * 不支持时退回一个 1x1 pbuffer。
		 */
		if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
			EGLint pb[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
			EGLSurface s = eglCreatePbufferSurface(dpy, cfg, pb);

			if (s == EGL_NO_SURFACE ||
			    !eglMakeCurrent(dpy, s, s, ctx)) {
				printf("  makeCurrent 失败（surfaceless 和 pbuffer 都不行）0x%x\n",
				       eglGetError());
				return 1;
			}
			printf("  用 1x1 pbuffer 当 current\n");
		}
		printf("  GL_VERSION=%s\n", glGetString(GL_VERSION));
		printf("  GL_RENDERER=%s\n  GL_VENDOR=%s\n", glGetString(GL_RENDERER),
		       glGetString(GL_VENDOR));
		printf("  GLSL=%s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));
		{
			GLint mx = 0, l2 = 0;
			char rb[256] = {0};

			glGetIntegerv(GL_MAX_TEXTURE_SIZE, &mx);
			glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &l2);
			printf("  MAX_TEXTURE_SIZE=%d  纹理单元=%d\n", mx, l2);
			{
				const char *e = (const char *)glGetString(GL_EXTENSIONS);
				int oes = e && strstr(e, "GL_OES_EGL_image");
				int nv12 = e && strstr(e, "GL_EXT_texture_nv12");

				printf("  GL_OES_EGL_image=%s GL_EXT_texture_nv12=%s\n",
				       oes ? "有" : "缺", nv12 ? "有" : "缺");
			}
			(void)rb;
		}

		/* ---- dmabuf 导入：R8(Y) + GR88(CbCr)，各导一次，量耗时 ---- */
		if (mk_dumb(dfd, w, h, 8, &hy, &py, &fdy) < 0 ||
		    mk_dumb(dfd, w / 2, h / 2, 16, &hc, &pc, &fdc) < 0) {
			printf("  造 dumb buffer 失败: %s\n", strerror(errno));
			return 1;
		}
		{
			double t0 = now_s();

			ty = import_tex(dpy, fdy, w, h, py, DRM_FORMAT_R8);
			tc = import_tex(dpy, fdc, w / 2, h / 2, pc, DRM_FORMAT_GR88);
			printf("  导入 Y=%u C=%u  %.2f ms (pitch %u/%u)\n",
			       ty, tc, (now_s() - t0) * 1000, py, pc);
		}
		if (!ty || !tc) ret = 1;
		/* 采样一次，确认这张纹理真能读（panfrost 上 import 成功但采样
		 * 出全 0 是可能的：比如 modifier 不匹配）
		 */
		if (ty && tc) {
			GLuint fb, rb8, prog, vs, fs;
			static const char *vsrc =
				"#version 300 es\n"
				"in vec2 p; out vec2 uv;\n"
				"void main(){ uv = p*0.5+0.5; gl_Position = vec4(p,0,1); }\n";
			static const char *fsrc =
				"#version 300 es\n"
				"precision highp float;\n"
				"uniform sampler2D uY; in vec2 uv; out vec4 o;\n"
				"void main(){ o = vec4(texture(uY, uv).rrr, 1.0); }\n";

			#define MK(T, S) ({ GLuint s_ = glCreateShader(T); \
				glShaderSource(s_, 1, &(S), NULL); glCompileShader(s_); \
				{ GLint ok_ = 0; glGetShaderiv(s_, GL_COMPILE_STATUS, &ok_); \
				  if (!ok_) { char lg[512]; glGetShaderInfoLog(s_, 512, NULL, lg); \
					printf("  着色器编译失败: %s\n", lg); } } s_; })
			vs = MK(GL_VERTEX_SHADER, vsrc);
			fs = MK(GL_FRAGMENT_SHADER, fsrc);
			prog = glCreateProgram();
			glAttachShader(prog, vs);
			glAttachShader(prog, fs);
			glBindAttribLocation(prog, 0, "p");
			glLinkProgram(prog);
			glGenTextures(1, &rb8);
			glBindTexture(GL_TEXTURE_2D, rb8);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 8, 8, 0, GL_RGBA,
				     GL_UNSIGNED_BYTE, NULL);
			glGenFramebuffers(1, &fb);
			glBindFramebuffer(GL_FRAMEBUFFER, fb);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
					       GL_TEXTURE_2D, rb8, 0);
			if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
				printf("  FBO 不完整，跳过采样验证\n");
			} else {
				unsigned char px[4] = {0, 0, 0, 0};
				/* ES3 里裸 glDrawArrays 是无效的：必须有绑定的
				 * VAO，且属主数组要 enable。第一版漏了这个，
				 * 画的是空 FBO，读回 0 —— 差点误判成
				 * "dmabuf 导入成功但采样不到"。
				 */
				static const float quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
				GLuint vao, vbo;

				glGenVertexArrays(1, &vao);
				glBindVertexArray(vao);
				glGenBuffers(1, &vbo);
				glBindBuffer(GL_ARRAY_BUFFER, vbo);
				glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
				glEnableVertexAttribArray(0);
				glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float),
						      (void *)0);
				glViewport(0, 0, 8, 8);
				glUseProgram(prog);
				glActiveTexture(GL_TEXTURE0);
				glBindTexture(GL_TEXTURE_2D, ty);
				glUniform1i(glGetUniformLocation(prog, "uY"), 0);
				glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
				glFinish();
				{
					GLenum e = glGetError();

					if (e != GL_NO_ERROR) printf("  绘制期 GL 错误 0x%x\n", e);
				}
				glReadPixels(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
				/* dumb 里填的是 Y=16（有限范围黑）→ 采样应 ~16 */
				printf("  采样 Y=%d (期望 16，0 表示纹理读不到)\n", px[0]);
				if (px[0] == 0) ret = 1;
			}
		}
	}
	printf("== probe %s ==\n", ret ? "失败" : "通过");
	(void)w; (void)hy; (void)hc;
	return ret;
}

/* ============================ run ============================ */
/* 彩条 N 帧，量每帧墙钟（含 eglSwapBuffers + 等 flip），按刷新周期量化。
 * 判据：
 *   时间 ≈ k * 1/refresh  → 被 vblank 限住（k=1 满速，k>1 GPU 掉了 k-1 个周期）
 *   时间 远小于 1/refresh → 通路没等 flip（不该出现，出现就是 flip 没挂上）
 */
static int do_run(unsigned w, unsigned h, int n)
{
	int ret = 0;
	unsigned sy = 0, sc = 0;
	int fdy = -1, fdc = -1;
	double t0, *dt, *srt;
	int i, refresh = 60, k1 = 0, k2 = 0, k3 = 0;
	double sum = 0;

	printf("== run %ux%u x %d 帧 ==\n", w, h, n);
	if (glout_init(w, h) < 0) { printf("glout_init 失败\n"); return 1; }
	if (gen_testcard(w, h, &fdy, &fdc, &sy, &sc) < 0) {
		printf("测试卡生成失败\n");
		return 1;
	}
	/* 第一帧含 SetCrtc + 编译着色器 + 建 LUT，单独算 */
	t0 = now_s();
	if (glout_frame(fdy, fdc, w, h, sy, sc) < 0) {
		printf("首帧失败\n");
		return 1;
	}
	printf("  首帧（含 SetCrtc/编译/LUT）%.1f ms\n", (now_s() - t0) * 1000);

	dt = calloc(n, sizeof(double));
	srt = calloc(n, sizeof(double));
	for (i = 0; i < n; i++) {
		double a = now_s();

		if (glout_frame(fdy, fdc, w, h, sy, sc) < 0) {
			printf("  第 %d 帧失败\n", i);
			ret = 1;
			break;
		}
		dt[i] = now_s() - a;
		sum += dt[i];
	}
	if (i < 2) { printf("  帧太少\n"); return 1; }
	memcpy(srt, dt, i * sizeof(double));
	qsort(srt, i, sizeof(double), cmp_d);
	{
		double period = 1.0 / refresh;

		for (int k = 0; k < i; k++) {
			double c = dt[k] / period;

			if (c < 0.5) k1++;
			else if (c < 1.5) k2++;
			else k3++;
		}
		printf("  稳定帧 %d 帧: 平均 %.2f ms (%.1f fps)  p50 %.2f  p95 %.2f  max %.2f ms\n",
		       i, sum / i * 1000, i / sum, srt[i / 2] * 1000,
		       srt[(int)(i * 0.95)] * 1000, srt[i - 1] * 1000);
		printf("  按 %dHz 量化: <0.5 周期 %d 帧 / ≈1 周期 %d 帧 / >1.5 周期 %d 帧\n",
		       refresh, k1, k2, k3);
		printf("  判读: ");
		if (k2 > i * 0.8)
			printf("被刷新率限住（每帧等一个 vblank，通路满速）\n");
		else if (k3 > i * 0.5)
			printf("被 GPU 限住（每帧 >1.5 个周期 → 实际帧率只有刷新的 1/k）\n");
		else if (k1 > i * 0.5)
			printf("没等 flip（帧快于 vblank）→ 检查 PageFlip 是否真的挂上了\n");
		else
			printf("混合，抖动大 → 看 p95 与 max 的差\n");
	}
	{
		double ds = 0, dm = 0, ss = 0;
		unsigned fr = 0;

		glout_stats(&ds, &dm, &ss, &fr);
		if (fr && ds > 0)
			printf("  GPU 绘制 %.2f ms/帧 (峰值 %.2f)  swap %.2f ms/帧 [GLTIME=1 才有]\n",
			       ds * 1000 / fr, dm * 1000, ss * 1000 / fr);
	}
	printf("== run %s ==\n", ret ? "失败" : "通过");
	return ret;
}

int main(int argc, char **argv)
{
	unsigned w = 1280, h = 720;
	int n = 120;

	if (argc < 2) {
		printf("用法:\n  %s probe [WxH]       只读，不接管屏幕\n"
		       "  %s run   [WxH] [帧数]  真上屏，接管 CRTC\n",
		       argv[0], argv[0]);
		return 1;
	}
	if (argc > 2) sscanf(argv[2], "%ux%u", &w, &h);
	if (!strcmp(argv[1], "probe")) return do_probe(w, h);
	if (!strcmp(argv[1], "run")) {
		if (argc > 3) n = atoi(argv[3]);
		if (n <= 0 || n > 4000) n = 120;
		return do_run(w, h, n);
	}
	printf("未知阶段: %s\n", argv[1]);
	return 1;
}
