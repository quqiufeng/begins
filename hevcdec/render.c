/* render.c —— Renderer 分发：按名字挑一个后端，播放器只认这个文件
 *
 * 后端表是编译期固定的（都链进同一个二进制），运行期用 RENDER= 选。
 * 这样"换个上屏方式"不需要换二进制、更不需要换一套播放器代码。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "render.h"

extern const struct render_ops render_ops_drm;
extern const struct render_ops render_ops_gl;

static const struct render_ops *const backends[] = {
	&render_ops_drm,
	&render_ops_gl,
	NULL,
};

static const struct render_ops *pick(const char *name)
{
	const struct render_ops *const *p;

	if (name && *name && strcmp(name, "auto")) {
		for (p = backends; *p; p++)
			if (!strcmp((*p)->name, name)) {
				if (!(*p)->probe()) {
					printf("RENDER: 后端 '%s' 没编进这个二进制\n", name);
					return NULL;
				}
				return *p;
			}
		printf("RENDER: 未知后端 '%s'（有：", name);
		for (p = backends; *p; p++)
			if ((*p)->probe())
				printf(" %s", (*p)->name);
		printf("）\n");
		return NULL;
	}
	for (p = backends; *p; p++)
		if ((*p)->probe())
			return *p;
	printf("RENDER: 没有可用后端\n");
	return NULL;
}

struct renderer *render_open(const char *name, unsigned sw, unsigned sh,
			     render_done_cb done, void *done_ctx)
{
	const struct render_ops *ops = pick(name);
	struct renderer *r;

	if (!ops)
		return NULL;
	r = calloc(1, sizeof(*r));
	if (!r)
		return NULL;
	r->ops = ops;
	r->done = done;
	r->done_ctx = done_ctx;
	if (ops->init(r, sw, sh) < 0) {
		printf("RENDER: %s 初始化失败\n", ops->name);
		free(r);
		return NULL;
	}
	printf("RENDER: %s (caps%s%s)\n", ops->name,
	       ops->caps & RENDER_CAP_HDR ? " hdr" : "",
	       ops->caps & RENDER_CAP_HDR ? "" : " sdr-only");
	return r;
}

void render_close(struct renderer *r)
{
	if (!r)
		return;
	if (r->ops->close)
		r->ops->close(r);
	free(r);
}

int render_submit(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		  unsigned ypitch, unsigned cpitch, double pts, void *owner)
{
	if (!r)
		return -1;
	return r->ops->submit(r, fd, w, h, ypitch, cpitch, pts, owner);
}

int render_pump(struct renderer *r, int timeout_ms)
{
	if (!r || !r->ops->pump)
		return 0;
	return r->ops->pump(r, timeout_ms);
}

int render_flush(struct renderer *r)
{
	if (!r || !r->ops->flush)
		return 0;
	return r->ops->flush(r);
}

int render_wait_shown(struct renderer *r, int timeout_ms)
{
	if (!r || !r->ops->wait_shown)
		return 0;
	return r->ops->wait_shown(r, timeout_ms);
}

void render_stats(struct renderer *r, struct render_stats *st)
{
	memset(st, 0, sizeof(*st));
	if (!r)
		return;
	if (r->ops->stats)
		r->ops->stats(r, st);
	st->name = r->ops->name;
	st->caps = r->ops->caps;
}

const char *render_name(const struct renderer *r)
{
	return r ? r->ops->name : "none";
}

int render_has_pace(const struct renderer *r)
{
	return r && (r->ops->caps & RENDER_CAP_PACE);
}

int render_has_hdr(const struct renderer *r)
{
	return r && (r->ops->caps & RENDER_CAP_HDR);
}
