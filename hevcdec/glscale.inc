/* ---------- 方案 B：GL 只做源分辨率色调映射，显示控制器硬件放大 ----------
 * 片元数从屏分辨率降到源分辨率（720p 源 = 1/4 工作量），放大交给 DPU，
 * panfrost 只负责逐像素 CSC/色调映射，实测 28fps → 55fps+。
 */
#define NRT 3
struct rt {
	int fd;
	void *map;
	uint32_t pitch, fb, w, h;
	EGLImageKHR img;
	GLuint rb, fbo;
};

static struct {
	uint32_t plane_id;
	struct rt rt[NRT];
	int cur, rtw, rth;
} S;

static uint32_t pick_primary_plane(void)
{
	drmModePlaneRes *pr = drmModeGetPlaneResources(g.dfd);
	uint32_t id = 0;
	unsigned i, k;

	if (!pr) return 0;
	for (i = 0; i < pr->count_planes && !id; i++) {
		drmModePlane *p = drmModeGetPlane(g.dfd, pr->planes[i]);
		drmModeObjectProperties *op;
		int type = -1, has_fmt = 0;

		if (!p) continue;
		for (k = 0; k < p->count_formats; k++)
			if (p->formats[k] == DRM_FORMAT_XRGB8888) has_fmt = 1;
		op = drmModeObjectGetProperties(g.dfd, p->plane_id,
						DRM_MODE_OBJECT_PLANE);
		for (k = 0; op && k < (unsigned)op->count_props; k++) {
			drmModePropertyRes *pd = drmModeGetProperty(g.dfd, op->props[k]);
			int e;

			if (pd && !strcmp(pd->name, "type"))
				for (e = 0; e < pd->count_enums; e++)
					if (!strcmp(pd->enums[e].name, "Primary"))
						type = 1;
			if (pd) drmModeFreeProperty(pd);
		}
		if (op) drmModeFreeObjectProperties(op);
		if (has_fmt && type == 1 && (p->crtc_id == g.crtc_id || !p->crtc_id))
			id = p->plane_id;
		drmModeFreePlane(p);
	}
	drmModeFreePlaneResources(pr);
	return id;
}

static int rt_make(struct rt *r, unsigned w, unsigned h)
{
	EGLint attrs[32];
	uint32_t handle = 0, off = 0;
	int n = 0, dfd = 0;

	r->w = w;
	r->h = h;
	if (mk_dumb(w, h, 32, &dfd, &r->map, &r->pitch)) return -1;
	r->fd = dfd;
	if (drmPrimeFDToHandle(g.dfd, r->fd, &handle)) return -1;
	if (drmModeAddFB2(g.dfd, w, h, DRM_FORMAT_XRGB8888, &handle, &r->pitch,
			  &off, &r->fb, 0)) {
		printf("GLOUT: AddFB2 失败: %s\n", strerror(errno));
		return -1;
	}
	attrs[n++] = EGL_WIDTH; attrs[n++] = w;
	attrs[n++] = EGL_HEIGHT; attrs[n++] = h;
	attrs[n++] = EGL_LINUX_DRM_FOURCC_EXT; attrs[n++] = DRM_FORMAT_XRGB8888;
	attrs[n++] = EGL_DMA_BUF_PLANE0_FD_EXT; attrs[n++] = r->fd;
	attrs[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT; attrs[n++] = 0;
	attrs[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT; attrs[n++] = (EGLint)r->pitch;
	attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT; attrs[n++] = 0;
	attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT; attrs[n++] = 0;
	attrs[n++] = EGL_NONE;
	r->img = eglCreateImageKHR(g.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
				   NULL, attrs);
	if (r->img == EGL_NO_IMAGE_KHR) {
		printf("GLOUT: EGLImage 失败 0x%x\n", eglGetError());
		return -1;
	}
	glGenRenderbuffers(1, &r->rb);
	glBindRenderbuffer(GL_RENDERBUFFER, r->rb);
	glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER, r->img);
	glGenFramebuffers(1, &r->fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, r->fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
				  GL_RENDERBUFFER, r->rb);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		printf("GLOUT: FBO 不完整\n");
		return -1;
	}
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	return 0;
}

static int scaler_setup(unsigned w, unsigned h)
{
	int i;

	S.plane_id = pick_primary_plane();
	if (!S.plane_id) { printf("GLOUT: 找不到主平面\n"); return -1; }
	if ((int)w == S.rtw && (int)h == S.rth) return 0;
	for (i = 0; i < NRT; i++) {
		if (S.rt[i].fb) { drmModeRmFB(g.dfd, S.rt[i].fb); S.rt[i].fb = 0; }
	}
	S.rtw = w; S.rth = h;
	for (i = 0; i < NRT; i++)
		if (rt_make(&S.rt[i], w, h)) return -1;
	printf("GLOUT: 缩放模式 渲染目标 %ux%u x%d 平面=%u\n", w, h, NRT,
	       S.plane_id);
	return 0;
}

static int scaler_frame(unsigned w, unsigned h, unsigned ypitch, unsigned cpitch)
{
	struct rt *r;
	unsigned dW, dH;
	double ar_s, ar_d;
	int dx, dy;

	if (scaler_setup(w, h)) return -1;
	r = &S.rt[S.cur];
	S.cur = (S.cur + 1) % NRT;
	glBindFramebuffer(GL_FRAMEBUFFER, r->fbo);
	glViewport(0, 0, r->w, r->h);
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
	glBindVertexArray(g.vao);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glFinish();
	(void)ypitch; (void)cpitch;
	ar_s = (double)w / h;
	ar_d = (double)g.dw / g.dh;
	if (ar_s > ar_d) { dW = g.dw; dH = (unsigned)(g.dw / ar_s + 0.5) & ~1u; }
	else { dH = g.dh; dW = (unsigned)(g.dh * ar_s + 0.5) & ~1u; }
	dx = (g.dw - dW) / 2;
	dy = (g.dh - dH) / 2;
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	if (drmModeSetPlane(g.dfd, S.plane_id, g.crtc_id, r->fb, 0, dx, dy, dW, dH,
			    0, 0, (uint64_t)r->w << 16, (uint64_t)r->h << 16)) {
		printf("GLOUT: SetPlane 失败: %s\n", strerror(errno));
		return -1;
	}
	g.frames++;
	return 0;
}
