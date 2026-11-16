/* GL 可行性探针：EGL(GBM 平台) + panfrost 起不起得来；dmabuf 能不能当 R8/GR88 纹理导入。
 * 板上编译： gcc -O2 -o glprobe glprobe.c -I include -l:libEGL.so.1 -l:libGL.so.1 \
 *              -l:libgbm.so.1 -l:libdrm.so.2
 */
#define EGL_EGLEXT_PROTOTYPES 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
typedef void (*pfnEGLImageTargetTexture2DOES)(GLenum, void *);

static void *gp(const char *n)
{
	void *p = (void *)eglGetProcAddress(n);

	if (!p) printf("  缺少 GL 入口: %s\n", n);
	return p;
}

int main(int argc, char **argv)
{
	int fd = open("/dev/dri/card0", O_RDWR);
	struct gbm_device *gbm;
	EGLDisplay dpy;
	EGLConfig cfg;
	EGLint ncfg = 0;
	EGLint cfgattr[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 8, EGL_NONE
	};
	EGLContext ctx;
	EGLSurface surf;
	EGLint ver[2];
	struct gbm_surface *gs;
	const char *e;

	if (fd < 0 || argc < 2) { printf("用法: glprobe WxH [w h]\n"); return 1; }
	gbm = gbm_create_device(fd);
	if (!gbm) { printf("gbm_create_device 失败\n"); return 1; }
	printf("GBM backend=%s\n", gbm_device_get_backend_name(gbm));
	gs = gbm_surface_create(gbm, 640, 480, GBM_FORMAT_XRGB8888,
				GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
	printf("gbm_surface: %s\n", gs ? "ok" : "失败");

	dpy = eglGetDisplay((EGLNativeDisplayType)gbm);
	if (dpy == EGL_NO_DISPLAY) { printf("eglGetDisplay 失败\n"); return 1; }
	if (!eglInitialize(dpy, &ver[0], &ver[1])) {
		printf("eglInitialize 失败: 0x%x\n", eglGetError());
		return 1;
	}
	printf("EGL %d.%d vendor=%s\n", ver[0], ver[1], eglQueryString(dpy, EGL_VENDOR));
	e = eglQueryString(dpy, EGL_EXTENSIONS);
	printf("EGL ext 有 dma_buf_import: %s\n", (e && strstr(e, "EGL_EXT_image_dma_buf_import")) ? "是" : "否");
	if (e && strstr(e, "EGL_EXT_image_dma_buf_import_modifiers"))
		printf("EGL ext 有 import_modifiers: 是\n");
	if (e && strstr(e, "EGL_KHR_no_config_context"))
		printf("EGL ext 有 no_config_context: 是\n");

	{
		EGLConfig all[64];
		EGLint n = 0, i;

		eglGetConfigs(dpy, all, 64, &n);
		printf("总共 %d 个 config\n", n);
		for (i = 0; i < n && i < 6; i++) {
			EGLint rt = 0, st = 0, id = 0, rs = 0;

			eglGetConfigAttrib(dpy, all[i], EGL_RENDERABLE_TYPE, &rt);
			eglGetConfigAttrib(dpy, all[i], EGL_SURFACE_TYPE, &st);
			eglGetConfigAttrib(dpy, all[i], EGL_CONFIG_ID, &id);
			eglGetConfigAttrib(dpy, all[i], EGL_RED_SIZE, &rs);
			printf("  cfg#%d id=%d renderable=0x%x surface=0x%x r=%d\n", i, id, rt, st, rs);
		}
	}
	if (!eglChooseConfig(dpy, cfgattr, &cfg, 1, &ncfg) || ncfg < 1) {
		printf("eglChooseConfig(OPENGL_BIT) 失败 n=%d\n", ncfg);
		return 1;
	}
	{
		EGLint rt = 0, id = 0;

		eglGetConfigAttrib(dpy, cfg, EGL_RENDERABLE_TYPE, &rt);
		eglGetConfigAttrib(dpy, cfg, EGL_CONFIG_ID, &id);
		printf("选中 id=%d renderable=0x%x\n", id, rt);
	}
	{
		EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};

		ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ca);
		if (ctx == EGL_NO_CONTEXT) {
			printf("GL3.0 context 失败 0x%x，退回默认\n", eglGetError());
			ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
		}
	}
	if (ctx == EGL_NO_CONTEXT) {
		printf("GL context 失败 0x%x\n", eglGetError());
		return 1;
	}
	surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)gs, NULL);
	if (surf == EGL_NO_SURFACE) { printf("EGLSurface 失败 0x%x\n", eglGetError()); return 1; }
	if (!eglMakeCurrent(dpy, surf, surf, ctx)) { printf("MakeCurrent 失败\n"); return 1; }
	printf("GL vendor=%s renderer=%s\n  version=%s\n  glsl=%s\n",
	       glGetString(GL_VENDOR), glGetString(GL_RENDERER),
	       glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));

	/* 造一块线性 dmabuf（R8 / GR88），走 EGL image 导入，验证 panfrost 纹理导入链路 */
	{
		unsigned w = 64, h = 64;
		struct gbm_bo *bo = gbm_bo_create(gbm, w, h, GBM_FORMAT_R8,
						  GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
		int bfd;
		EGLImageKHR img;
		GLuint tex = 0;
		unsigned char px[8 * 8 * 4] = {0};
		PFNGLTEXTUREPARAMETERIPROC tp;
		int attr[32], n = 0;
		uint64_t mod = 0;

		if (!bo) { printf("gbm_bo_create(R8) 失败\n"); return 1; }
		mod = gbm_bo_get_modifier(bo);
		printf("R8 bo stride=%u modifier=0x%llx\n", gbm_bo_get_stride(bo),
		       (unsigned long long)mod);
		/* 填点图案 */
		{
			void *map = NULL;
			uint32_t st = gbm_bo_get_stride(bo);
			unsigned char *m;

			if (gbm_bo_map(bo, 0, 0, w, h, GBM_BO_TRANSFER_WRITE, &st, &map) == 0) {
				m = map;
				for (unsigned y2 = 0; y2 < h; y2++)
					memset(m + y2 * st, y2 < h / 2 ? 200 : 40, w);
				gbm_bo_unmap(bo, map);
			}
		}
		attr[n++] = EGL_WIDTH; attr[n++] = w;
		attr[n++] = EGL_HEIGHT; attr[n++] = h;
		attr[n++] = EGL_LINUX_DRM_FOURCC_EXT; attr[n++] = 0x20203852; /* DRM_FORMAT_R8 */
		attr[n++] = EGL_DMA_BUF_PLANE0_FD_EXT; attr[n++] = (int)gbm_bo_get_fd(bo);
		attr[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT; attr[n++] = 0;
		attr[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT; attr[n++] = (int)gbm_bo_get_stride(bo);
		if (mod != 0x00ffffffffffffffULL && mod != 0) {
			attr[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT; attr[n++] = (int)(mod & 0xffffffff);
			attr[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT; attr[n++] = (int)(mod >> 32);
		}
		attr[n++] = EGL_NONE;
		{
			PFNEGLCREATEIMAGEKHRPROC create_img =
				(PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");

			if (!create_img) { printf("没有 eglCreateImageKHR 入口\n"); return 1; }
			img = create_img(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
					 NULL, (EGLint *)attr);
		}
		if (img == EGL_NO_IMAGE_KHR) {
			printf("eglCreateImageKHR(dmabuf R8) 失败 0x%x\n", eglGetError());
		} else {
			GLint ok;

			glGenTextures(1, &tex);
			glBindTexture(GL_TEXTURE_2D, tex);
			((pfnEGLImageTargetTexture2DOES)gp("glEGLImageTargetTexture2DOES"))(GL_TEXTURE_2D, (void *)img);
			tp = (PFNGLTEXTUREPARAMETERIPROC)gp("glTexParameteri");
			if (tp) { tp(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
				  tp(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST); }
			ok = glGetError();
			printf("dmabuf -> 纹理: %s (glGetError=0x%x)\n",
			       ok == GL_NO_ERROR ? "OK" : "报错", ok);

			/* 着色器链路留到 glplay；这里只确认导入 + 绑定不报错 */
			glViewport(0, 0, 8, 8);
			glClearColor(0, 0, 0, 1);
			glClear(GL_COLOR_BUFFER_BIT);
			glFlush();
			(void)px;
		}
		close(gbm_bo_get_fd(bo));
	}
	eglSwapBuffers(dpy, surf);
	printf("probe done\n");
	return 0;
}
