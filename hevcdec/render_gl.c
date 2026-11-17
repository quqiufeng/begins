/* render_gl.c —— Renderer 后端 B：EGL/GBM + GLES3（dmabuf 当纹理，shader 里做色调映射）
 *
 * 也是薄适配层：绘制全在 glout.c。这个后端的性格和 drm 后端不同，接口下面
 * 如实体现，不做假同步：
 *   同步 —— glout_frame 返回时已经 eglSwapBuffers，帧确实交给显示了，
 *           所以完成反馈就地触发（owner 立刻可回收），pump/wait_shown 空转。
 *   有运算 —— HDR→SDR 在片元里做，因此声明 RENDER_CAP_HDR，播放器不再
 *           在 CPU 上跑 tm_apply。
 *
 * 没编 GL（-DHAVE_GLOUT 缺席）时 probe() 返回 0：这个后端只是"不存在"，
 * 不影响二进制里另一个后端可用。
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "render.h"

#ifdef HAVE_GLOUT
void glout_set_drm_fd(int fd);
int  glout_init(unsigned sw, unsigned sh);
int  glout_frame(int fd_y, int fd_c, unsigned w, unsigned h,
		 unsigned ypitch, unsigned cpitch);
void glout_reset(void);
void glout_perf_print(void);
void glout_stats(double *draw_sum, double *draw_max, double *swap_sum,
		 unsigned *frames);
#endif

struct gl_priv {
	int dfd;
	unsigned sw, sh;
	unsigned frames, latch;
	double draw_sum, draw_max, swap_sum;
	double t_first, t_last;
};

#ifdef HAVE_GLOUT

static int gl_probe(void)
{
	return 1;
}

static int gl_init(struct renderer *r, unsigned sw, unsigned sh)
{
	struct gl_priv *p = calloc(1, sizeof(*p));
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";

	if (!p)
		return -1;
	p->dfd = open(dev, O_RDWR | O_CLOEXEC);
	if (p->dfd < 0) {
		printf("RENDER gl: open %s: %s\n", dev, strerror(errno));
		free(p);
		return -1;
	}
	glout_set_drm_fd(p->dfd);
	if (glout_init(sw, sh) < 0) {
		close(p->dfd);
		free(p);
		return -1;
	}
	p->sw = sw;
	p->sh = sh;
	r->priv = p;
	return 0;
}

static int gl_submit(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		     unsigned ypitch, unsigned cpitch, double pts, void *owner)
{
	struct gl_priv *p = r->priv;

	(void)pts;
	if (glout_frame(fd[0], fd[1], w, h, ypitch, cpitch) < 0)
		return -1;		/* 没画上去：owner 留在调用方，它自己回收 */
	if (!p->frames)
		p->t_first = 0;
	p->frames++;
	p->latch++;
	if (r->done)
		r->done(r->done_ctx, owner, pts, p->latch, RENDER_SHOWN);
	return 1;			/* 同步：返回即已上屏 */
}

static int gl_pump(struct renderer *r, int timeout_ms)
{
	(void)r;
	(void)timeout_ms;
	return 0;			/* 同步后端没有队列可推 */
}

static int gl_flush(struct renderer *r)
{
	(void)r;
	glout_reset();			/* seek 后 fd 全换了，旧纹理丢掉 */
	return 0;
}

static int gl_wait_shown(struct renderer *r, int timeout_ms)
{
	(void)r;
	(void)timeout_ms;
	return 1;			/* 每帧都同步上完了，没有在飞的帧 */
}

static void gl_close(struct renderer *r)
{
	struct gl_priv *p = r->priv;

	if (!p)
		return;
	/* 收尾前把 GPU 完成时间/vblank miss/帧间隔/掉帧的分布打出来：
	 * 平均 fps 在这里毫无用处，卡顿和稳定低帧率是同一个平均数。 */
	glout_perf_print();
	/* GL/EGL 上下文留到进程退出：拆一遍在盒子上会闪一下黑屏 */
	if (p->dfd >= 0)
		close(p->dfd);
	free(p);
	r->priv = NULL;
}

static void gl_get_stats(struct renderer *r, struct render_stats *st)
{
	struct gl_priv *p = r->priv;
	unsigned frames = 0;

	glout_stats(&p->draw_sum, &p->draw_max, &p->swap_sum, &frames);
	st->submitted = p->frames;
	st->shown = p->frames;
	st->sw = p->sw;
	st->sh = p->sh;
	st->draw_ms_sum = p->draw_sum;
	st->draw_ms_max = p->draw_max;
	st->swap_ms_sum = p->swap_sum;
}

const struct render_ops render_ops_gl = {
	.name = "gl",
	.caps = RENDER_CAP_HDR,
	.probe = gl_probe,
	.init = gl_init,
	.submit = gl_submit,
	.pump = gl_pump,
	.flush = gl_flush,
	.wait_shown = gl_wait_shown,
	.close = gl_close,
	.stats = gl_get_stats,
};

#else /* !HAVE_GLOUT —— 后端不存在，但符号要在，auto 选择时直接跳过 */

static int gl_probe(void) { return 0; }
static int gl_init(struct renderer *r, unsigned sw, unsigned sh)
{
	(void)r; (void)sw; (void)sh;
	printf("RENDER gl: 这个二进制没编 GL 后端\n");
	return -1;
}
static int gl_submit(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		     unsigned ypitch, unsigned cpitch, double pts, void *owner)
{
	(void)r; (void)fd; (void)w; (void)h; (void)ypitch; (void)cpitch;
	(void)pts; (void)owner;
	return -1;
}
static int gl_pump(struct renderer *r, int timeout_ms) { (void)r; (void)timeout_ms; return 0; }
static int gl_flush(struct renderer *r) { (void)r; return 0; }
static int gl_wait_shown(struct renderer *r, int timeout_ms) { (void)r; (void)timeout_ms; return 1; }
static void gl_close(struct renderer *r) { (void)r; }
static void gl_get_stats(struct renderer *r, struct render_stats *st) { (void)r; (void)st; }

const struct render_ops render_ops_gl = {
	.name = "gl",
	.caps = RENDER_CAP_HDR,
	.probe = gl_probe,
	.init = gl_init,
	.submit = gl_submit,
	.pump = gl_pump,
	.flush = gl_flush,
	.wait_shown = gl_wait_shown,
	.close = gl_close,
	.stats = gl_get_stats,
};

#endif /* HAVE_GLOUT */
