/* render_drm.c —— Renderer 后端 A：NV12 dma-buf 直挂 KMS overlay plane
 *
 * 薄适配层，一点策略都不放：策略在 vout.c（提交/队列/节拍/反馈），
 * 这里只负责把 render.h 的接口对上，并把环境变量翻成 vout 的配置。
 *
 * 能力：零拷贝、零运算；有队列（RENDER_DEPTH，默认 3）；异步完成反馈。
 * 短板：meson 的 DRM 没有 GAMMA_LUT/CTM → 不声明 RENDER_CAP_HDR，
 *       HDR 源由播放器先在 CPU 上转 SDR（tm_apply）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "csig.h"
#include "render.h"
#include "vout.h"

struct drm_priv {
	struct vout *v;
	unsigned sw, sh;
	int depth;
};

static void drm_done(void *ctx, void *owner, double pts, uint32_t latch, int status)
{
	struct renderer *r = ctx;

	if (!r->done)
		return;
	r->done(r->done_ctx, owner, pts, latch,
		status == VOUT_SHOWN ? RENDER_SHOWN :
		status == VOUT_DROPPED ? RENDER_DROPPED : RENDER_ABORTED);
}

static int drm_probe(void)
{
	return 1;
}

static int drm_init(struct renderer *r, unsigned sw, unsigned sh)
{
	struct drm_priv *p = calloc(1, sizeof(*p));
	const char *sc;

	if (!p)
		return -1;
	p->sw = sw;
	p->sh = sh;
	p->depth = getenv("RENDER_DEPTH") ? atoi(getenv("RENDER_DEPTH")) : 3;
	if (p->depth < 1)
		p->depth = 1;
	p->v = vout_open(getenv("DRMDEV"));
	if (!p->v) {
		free(p);
		return -1;
	}
	sc = getenv("SCALE");
	if (sc && !strcmp(sc, "fill"))
		vout_set_scale(p->v, VOUT_FILL);
	else if (sc && !strcmp(sc, "crop"))
		vout_set_scale(p->v, VOUT_CROP);
	else
		vout_set_scale(p->v, VOUT_FIT);
	if (getenv("REFRESH"))
		vout_set_refresh(p->v, (unsigned)atoi(getenv("REFRESH")));
	/* 非方形像素的源（720x576 SAR 16:15 那类）不传这个就会横向压扁；
	 * VUI 往往第一帧之后才解析出来，drm_submit 每帧会再同步一次。 */
	vout_set_par(p->v, g_cm.sar_num > 0 ? (unsigned)g_cm.sar_num : 1u,
		     g_cm.sar_den > 0 ? (unsigned)g_cm.sar_den : 1u);
	vout_set_queue(p->v, p->depth);
	vout_set_displayed_cb(p->v, drm_done, r);
	r->priv = p;
	return 0;
}

static int drm_submit(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		      unsigned ypitch, unsigned cpitch, double pts, void *owner)
{
	struct drm_priv *p = r->priv;
	int ret;

	if (w != p->sw || h != p->sh) {
		p->sw = w;
		p->sh = h;
	}
	vout_set_par(p->v, g_cm.sar_num > 0 ? (unsigned)g_cm.sar_num : 1u,
		     g_cm.sar_den > 0 ? (unsigned)g_cm.sar_den : 1u);
	ret = vout_submit(p->v, fd, w, h, ypitch, cpitch, pts, owner);
	return ret;
}

static int drm_pump(struct renderer *r, int timeout_ms)
{
	return vout_pump(((struct drm_priv *)r->priv)->v, timeout_ms);
}

static int drm_flush(struct renderer *r)
{
	return vout_flush(((struct drm_priv *)r->priv)->v);
}

static int drm_wait_shown(struct renderer *r, int timeout_ms)
{
	return vout_wait_shown(((struct drm_priv *)r->priv)->v, timeout_ms);
}

static void drm_close(struct renderer *r)
{
	struct drm_priv *p = r->priv;

	if (!p)
		return;
	vout_close(p->v);
	free(p);
	r->priv = NULL;
}

static void drm_stats(struct renderer *r, struct render_stats *st)
{
	struct drm_priv *p = r->priv;
	struct vout_stats vs = {0};

	vout_get_stats(p->v, &vs);
	st->submitted = vs.submitted;
	st->shown = vs.shown;
	st->dropped = vs.drops;
	st->aborted = vs.aborted;
	st->pending = vs.pending;
	st->misses = vs.misses;
	st->late = vs.late;
	st->late_ms_max = vs.t_late_max;
	st->sw = vs.sw;
	st->sh = vs.sh;
	st->dw = vs.dw;
	st->dh = vs.dh;
	st->refresh = vs.refresh;
	st->t_first = vs.t_first;
	st->t_last = vs.t_last;
}

const struct render_ops render_ops_drm = {
	.name = "drm",
	/* 不声明 PACE：vout_submit 只入队、不阻塞，节拍必须由播放器按 pts 睡
	 * 出来。早先这里声明了 PACE，播放器就撒手不管，帧按 ffmpeg 供流速度灌
	 * 进 3 格队列、每轮都被顶掉，屏上一帧都上不去（shown=0）。 */
	.caps = 0,
	.probe = drm_probe,
	.init = drm_init,
	.submit = drm_submit,
	.pump = drm_pump,
	.flush = drm_flush,
	.wait_shown = drm_wait_shown,
	.close = drm_close,
	.stats = drm_stats,
};
