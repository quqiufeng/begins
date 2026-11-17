/* vout-selftest.c —— 把 DRM overlay 和 vblank 两件事从解码器里剥出来单独验
 *
 * 为什么值得单独测：vout 出错时的症状全都很误导。
 *   - plane 没挂上 → 整屏黑，但 flips 照涨（以为在放，其实黑屏）
 *   - 打底不透明 → 整屏黑，且 flips 也在涨，和上面一模一样
 *   - vblank 等错 crtc → 帧率对但抖动 8-16ms，看起来像"解码跟不上"
 *   - pitch 填成 w → 画面斜切，像色彩格式错
 * 这些用解码器复现要先怀疑三处，用彩条一次定位一处。
 *
 * 两个阶段：
 *   probe  只读。dump connector/plane/zpos/NV12 能力，并试 ADDFB2（不改屏）。
 *          在正跑桌面的机器上安全——不会 SETCRTC/SETPLANE。
 *   run    真实上屏 + 节拍测量。会接管 CRTC，桌面会黑，必须在盒子上跑。
 *   queue  统一队列 / 丢帧 / vblank 槽 / 完成反馈。同上会接管 CRTC，
 *          验的是"每 submit 恰好一次回调"这条底线账。
 *
 * 用法：
 *   ./vout-selftest probe [WxH]
 *   ./vout-selftest run [WxH] [fps]
 *   ./vout-selftest queue [WxH] [fps]
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
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>

#include "vout.h"

/* 内核 uapi 的 drm.h 里没有这三个（只在 libdrm 的 xf86drmMode.h），自己写死 */
#define PT_OVERLAY	0
#define PT_PRIMARY	1
#define PT_CURSOR	2

#define NBUF 3		/* 轮转的 buffer 对数，模拟 vdec 的 DPB */

struct buf {
	struct drm_mode_create_dumb cd_y, cd_c;
	void *map_y, *map_c;
	size_t size_y, size_c;
	int fdy, fdc;
	unsigned w, h, yp, cp;
};

static const char *plane_type_str(uint64_t t)
{
	switch (t) {
	case PT_OVERLAY: return "OVERLAY";
	case PT_PRIMARY: return "PRIMARY";
	case PT_CURSOR:  return "CURSOR";
	}
	return "?";
}

/* 读一个 object 的全部属性：id 和 value 两个数组都要给，只给 props_ptr
 * 时内核写到第二个 put_user 就 EFAULT,前面几条属性的值永远是 0 ——
 * 表现出来就是"所有 plane 的 zpos 都是 0",比读不到还误导。 */
#define NPR 64
static int obj_props(int dfd, uint32_t obj, uint32_t obj_type,
		     uint32_t *ids, uint64_t *vals, int *n)
{
	struct drm_mode_obj_get_properties gp = {0};

	gp.obj_id = obj;
	gp.obj_type = obj_type;
	gp.props_ptr = (uint64_t)(uintptr_t)ids;
	gp.prop_values_ptr = (uint64_t)(uintptr_t)vals;
	gp.count_props = NPR;
	if (ioctl(dfd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &gp) < 0) return -1;
	*n = gp.count_props > NPR ? NPR : (int)gp.count_props;
	return 0;
}

/* 没有这个属性返回 -1；有就是我返回 0，值写进 *val */
static int get_prop_u64(int dfd, uint32_t obj, uint32_t obj_type,
			const char *name, uint64_t *val, int *immutable)
{
	static uint32_t ids[NPR];
	static uint64_t vals[NPR];
	struct drm_mode_get_property pr = {0};
	int i, n;

	if (obj_props(dfd, obj, obj_type, ids, vals, &n) < 0) return -1;
	for (i = 0; i < n; i++) {
		pr.prop_id = ids[i];
		if (ioctl(dfd, DRM_IOCTL_MODE_GETPROPERTY, &pr) < 0) continue;
		if (strcmp(pr.name, name)) continue;
		if (val) *val = vals[i];
		if (immutable) *immutable = (pr.flags & DRM_MODE_PROP_IMMUTABLE) != 0;
		return 0;
	}
	return -1;
}

static int dumb_alloc(int dfd, unsigned w, unsigned h, unsigned bpp,
		      struct drm_mode_create_dumb *cd, void **map)
{
	struct drm_mode_map_dumb md = {0};
	struct drm_prime_handle ph = {0};

	memset(cd, 0, sizeof(*cd));
	cd->width = w;
	cd->height = h;
	cd->bpp = bpp;
	if (ioctl(dfd, DRM_IOCTL_MODE_CREATE_DUMB, cd) < 0) {
		fprintf(stderr, "  CREATE_DUMB %ux%u bpp=%u: %s\n", w, h, bpp, strerror(errno));
		return -1;
	}
	md.handle = cd->handle;
	if (ioctl(dfd, DRM_IOCTL_MODE_MAP_DUMB, &md) < 0) {
		fprintf(stderr, "  MAP_DUMB: %s\n", strerror(errno));
		return -1;
	}
	*map = mmap(NULL, cd->size, PROT_READ | PROT_WRITE, MAP_SHARED, dfd, md.offset);
	if (*map == MAP_FAILED) {
		fprintf(stderr, "  mmap: %s\n", strerror(errno));
		*map = NULL;
		return -1;
	}
	ph.handle = cd->handle;
	if (ioctl(dfd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph) < 0) {
		fprintf(stderr, "  HANDLE_TO_FD: %s\n", strerror(errno));
		return -1;
	}
	return ph.fd;
}

static void buf_free(int dfd, struct buf *b)
{
	struct drm_mode_destroy_dumb dd = {0};

	if (b->map_y) munmap(b->map_y, b->size_y);
	if (b->map_c) munmap(b->map_c, b->size_c);
	if (b->fdy >= 0) close(b->fdy);
	if (b->fdc >= 0) close(b->fdc);
	/* 导出过得 handle 自己的引用已经还给 fd，这里只销毁 kernel 侧对象 */
	dd.handle = b->cd_y.handle;
	if (dd.handle) ioctl(dfd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
	dd.handle = b->cd_c.handle;
	if (dd.handle) ioctl(dfd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
}

/* 填彩条：8 条竖直亮度带 + 一个滚动白块（一眼看出有没有翻页、有没有斜切） */
static void fill_nv12(struct buf *b, int frame)
{
	static const unsigned char bars[8] = { 235, 210, 170, 145, 110, 81, 41, 16 };
	unsigned x, y;

	for (y = 0; y < b->h; y++) {
		unsigned char *row = (unsigned char *)b->map_y + (size_t)y * b->yp;

		for (x = 0; x < b->w; x++)
			row[x] = bars[(x * 8) / b->w];
	}
	/* 滚动块：横向走，纵向固定 1/4 高，纯白 */
	{
		unsigned bw = b->w / 8, bx = (unsigned)((frame * 13) % (b->w - bw));
		unsigned y0 = b->h / 4, y1 = y0 + b->h / 4;

		for (y = y0; y < y1; y++) {
			unsigned char *row = (unsigned char *)b->map_y + (size_t)y * b->yp;

			memset(row + bx, 235, bw);
		}
	}
	/* 色度恒为 128 = 无色。想验色彩可以改成按带写入 */
	if (b->map_c)
		memset(b->map_c, 128, b->size_c);
}

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* ---------------- probe：只读 ---------------- */
static int phase_probe(int dfd, unsigned pw, unsigned ph)
{
	static uint32_t crtcs[16], conns[16], pids[64];
	struct drm_mode_card_res res = {0};
	int i, n_nv12_plane = 0;

	res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs; res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns; res.count_connectors = 16;
	if (ioctl(dfd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		fprintf(stderr, "GETRESOURCES: %s\n", strerror(errno));
		return 1;
	}
	printf("== card: %u crtc, %u connector, %u encoder\n",
	       res.count_crtcs, res.count_connectors, res.count_encoders);

	for (i = 0; i < (int)res.count_connectors; i++) {
		static struct drm_mode_modeinfo modes[64];
		struct drm_mode_get_connector gc = {0};
		int j, n;

		gc.connector_id = conns[i];
		gc.modes_ptr = (uint64_t)(uintptr_t)modes;
		gc.count_modes = 64;
		if (ioctl(dfd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0) continue;
		n = gc.count_modes > 64 ? 64 : (int)gc.count_modes;
		printf("  conn %u: %s, %u mode%s", conns[i],
		       gc.connection == 1 ? "connected" : "disconnected", n,
		       n == 1 ? "" : "s");
		if (n) {
			const struct drm_mode_modeinfo *best = &modes[0];

			for (j = 1; j < n; j++)
				if (modes[j].hdisplay * modes[j].vdisplay >
				    best->hdisplay * best->vdisplay)
					best = &modes[j];
			printf(" max=%ux%u@%u (enc %u)", best->hdisplay,
			       best->vdisplay, best->vrefresh, gc.encoder_id);
		}
		printf("\n");
	}

	if (ioctl(dfd, DRM_IOCTL_MODE_GETPLANERESOURCES,
		  &(struct drm_mode_get_plane_res){
			  .plane_id_ptr = (uint64_t)(uintptr_t)pids,
			  .count_planes = 64 }) < 0) {
		fprintf(stderr, "GETPLANERESOURCES: %s\n", strerror(errno));
		return 1;
	}
	printf("== planes（zpos 是 meson 上黑屏的元凶，primary 大于 overlay）\n");
	{
		struct drm_mode_get_plane_res pr = {0};

		pr.plane_id_ptr = (uint64_t)(uintptr_t)pids;
		pr.count_planes = 64;
		ioctl(dfd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
		for (i = 0; i < (int)pr.count_planes; i++) {
			static uint32_t fmts[64];
			struct drm_mode_get_plane gp = {0};
			uint64_t type = 99, zpos = 0, alpha = 0;
			int imm = 0, j, has12 = 0;

			gp.plane_id = pids[i];
			gp.format_type_ptr = (uint64_t)(uintptr_t)fmts;
			gp.count_format_types = 64;
			if (ioctl(dfd, DRM_IOCTL_MODE_GETPLANE, &gp) < 0) continue;
			for (j = 0; j < (int)gp.count_format_types; j++)
				if (fmts[j] == DRM_FORMAT_NV12) has12 = 1;
			get_prop_u64(dfd, pids[i], DRM_MODE_OBJECT_PLANE, "type", &type, NULL);
			get_prop_u64(dfd, pids[i], DRM_MODE_OBJECT_PLANE, "zpos", &zpos, &imm);
			get_prop_u64(dfd, pids[i], DRM_MODE_OBJECT_PLANE, "alpha", &alpha, NULL);
			printf("  plane %u: %-8s zpos=%llu%s crtc_mask=0x%x nfmt=%u%s\n",
			       pids[i], plane_type_str(type),
			       (unsigned long long)zpos, imm ? "(imm)" : "",
			       gp.possible_crtcs, gp.count_format_types,
			       has12 ? " [NV12]" : "");
			if (has12) n_nv12_plane++;
		}
	}

	/* 试 ADDFB2：只建 fb 不改屏，安全。验的是"格式+pitch 能不能被收" */
	printf("== ADDFB2 NV12 %ux%u（只建 fb，不动屏）\n", pw, ph);
	{
		struct buf *b = calloc(1, sizeof(*b));
		struct drm_prime_handle phy = {0}, phc = {0};
		struct drm_mode_fb_cmd2 fb = {0};
		struct drm_mode_destroy_dumb dd = {0};

		b->fdy = b->fdc = -1;
		b->w = pw; b->h = ph;
		b->fdy = dumb_alloc(dfd, pw, ph, 8, &b->cd_y, &b->map_y);
		if (b->fdy < 0) { free(b); return 1; }
		b->size_y = b->cd_y.size; b->yp = b->cd_y.pitch;
		b->fdc = dumb_alloc(dfd, pw, ph / 2, 8, &b->cd_c, &b->map_c);
		if (b->fdc < 0) { buf_free(dfd, b); free(b); return 1; }
		b->size_c = b->cd_c.size; b->cp = b->cd_c.pitch;
		printf("  dumb: Y pitch=%u C pitch=%u", b->yp, b->cp);
		printf("%s\n", b->yp == b->cp ? "" : "  <-- 不等，NV12 上多半要被拒");

		phy.handle = b->cd_y.handle;
		phc.handle = b->cd_c.handle;
		if (ioctl(dfd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &phy) < 0 ||
		    ioctl(dfd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &phc) < 0) {
			fprintf(stderr, "  HANDLE_TO_FD: %s\n", strerror(errno));
		} else {
			fb.width = pw; fb.height = ph;
			fb.pixel_format = DRM_FORMAT_NV12;
			fb.handles[0] = phy.handle; fb.handles[1] = phc.handle;
			fb.pitches[0] = b->yp;      fb.pitches[1] = b->cp;
			if (ioctl(dfd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0)
				printf("  ADDFB2: %s（dumb 可能不是这个 plane 要吃的东西）\n",
				       strerror(errno));
			else {
				printf("  ADDFB2 ok: fb_id=%u\n", fb.fb_id);
				ioctl(dfd, DRM_IOCTL_MODE_RMFB, &fb.fb_id);
			}
			close(phy.fd);
			close(phc.fd);
		}
		dd.handle = b->cd_y.handle; ioctl(dfd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
		dd.handle = b->cd_c.handle; ioctl(dfd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
		munmap(b->map_y, b->size_y);
		munmap(b->map_c, b->size_c);
		free(b);
	}
	printf("== 结论: %s\n", n_nv12_plane ? "有 NV12 plane，可跑 run 阶段"
					     : "没有 NV12 plane —— vout 这条路走不通");
	return 0;
}

/* ---------------- run：真上屏 ---------------- */
#define NFRAME 240

static int phase_run(unsigned w, unsigned h, unsigned fps)
{
	int dfd, fd[2], i, f, ret;
	struct vout *v;
	struct buf b[NBUF];
	struct vout_stats st;
	static double t[NFRAME];
	double base, sum = 0, dmin = 1e9, dmax = 0, exp = 1.0 / fps;
	double vs, t0, t1;
	uint32_t s0, s1;

	dfd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (dfd < 0) { perror("/dev/dri/card0"); return 1; }

	memset(b, 0, sizeof(b));
	for (i = 0; i < NBUF; i++) {
		b[i].fdy = b[i].fdc = -1;
		b[i].w = w; b[i].h = h;
		b[i].fdy = dumb_alloc(dfd, w, h, 8, &b[i].cd_y, &b[i].map_y);
		if (b[i].fdy < 0) goto out;
		b[i].size_y = b[i].cd_y.size; b[i].yp = b[i].cd_y.pitch;
		b[i].fdc = dumb_alloc(dfd, w, h / 2, 8, &b[i].cd_c, &b[i].map_c);
		if (b[i].fdc < 0) goto out;
		b[i].size_c = b[i].cd_c.size; b[i].cp = b[i].cd_c.pitch;
		fill_nv12(&b[i], i);
		printf("  buf%d: %dx%d Y pitch=%u C pitch=%u\n", i, w, h, b[i].yp, b[i].cp);
	}

	printf("== 接管 CRTC（桌面会黑）\n");
	v = vout_open(NULL);
	if (!v) goto out;
	vout_set_scale(v, VOUT_FIT);

	/* A. 第一帧：验 plane 到底挂上没有 */
	fd[0] = b[0].fdy; fd[1] = b[0].fdc;
	ret = vout_frame_ex(v, fd, w, h, b[0].yp, b[0].cp, 0);
	vout_get_stats(v, &st);
	printf("== A. 首帧 ret=%d  plane=%ux%u  refresh=%uHz  vbl_ok=%d\n",
	       ret, st.dw, st.dh, st.refresh, st.vbl_ok);
	if (ret != 1)
		printf("   <-- 没上屏。黑屏时先查这里，不要先怀疑解码\n");

	/* B. 节拍：按 fps 喂 pts，看落点和 vblank 消费量 */
	printf("== B. 节拍 %u fps / %u vblank 每帧（%.3f）\n",
	       fps, st.refresh, (double)st.refresh / fps);
	vout_get_stats(v, &st);
	s0 = st.vbl_last;
	base = now_s() + 0.20;
	for (f = 0; f < NFRAME; f++) {
		fd[0] = b[f % NBUF].fdy; fd[1] = b[f % NBUF].fdc;
		fill_nv12(&b[f % NBUF], f);
		vout_frame_ex(v, fd, w, h, b[f % NBUF].yp, b[f % NBUF].cp,
			      base + (double)f / fps);
		t[f] = now_s();
	}
	vout_get_stats(v, &st);
	s1 = st.vbl_last;
	for (f = 1; f < NFRAME; f++) {
		double d = t[f] - t[f - 1];

		sum += d; if (d < dmin) dmin = d; if (d > dmax) dmax = d;
	}
	{
		int late = 0, early = 0;
		double half = 0.5 * exp;

		for (f = 1; f < NFRAME; f++) {
			double d = t[f] - t[f - 1];

			if (d > exp + half) late++;
			if (d < exp - half) early++;
		}
		printf("   间隔: avg=%.3fms min=%.3f max=%.3f（理想 %.3f）\n",
		       sum / (NFRAME - 1) * 1e3, dmin * 1e3, dmax * 1e3, exp * 1e3);
		printf("   偏晚 %d 帧 / 偏早 %d 帧，共 %d 帧\n", late, early, NFRAME - 1);
		vs = (double)(s1 - s0) / (NFRAME - 1);
		printf("   vblank 消费 %.3f/帧（应为 %.3f）%s\n", vs,
		       (double)st.refresh / fps,
		       fabs(vs - (double)st.refresh / fps) > 0.15 ? "  <-- 节拍没落在槽上" : "");
		printf("   flips=%d drops=%d timeouts=%d\n", st.flips, st.drops, st.timeouts);
	}

	/* C. 无 pts：这条路径一次 memcpy 都没有，应当是几十微秒 */
	printf("== C. 无 pts 吞吐（pts<=0 不等待）\n");
	t0 = now_s();
	for (f = 0; f < 200; f++) {
		fd[0] = b[f % NBUF].fdy; fd[1] = b[f % NBUF].fdc;
		vout_frame_ex(v, fd, w, h, b[f % NBUF].yp, b[f % NBUF].cp, 0);
	}
	t1 = now_s();
	printf("   200 帧 %.1fms，平均 %.1fus/帧 %s\n", (t1 - t0) * 1e3,
	       (t1 - t0) / 200 * 1e6,
	       (t1 - t0) / 200 > 0.002 ? "  <-- 慢了，八成在等 vblank" : "");

	/* D. 会话重建：连做 5 次 flush，验不泄漏 */
	for (i = 0; i < 5; i++) vout_flush(v);
	printf("== D. flush x5 完成（不泄漏则这里不该有错误日志）\n");

	vout_close(v);
	for (i = 0; i < NBUF; i++) buf_free(dfd, &b[i]);
	close(dfd);
	return 0;
out:
	for (i = 0; i < NBUF; i++) buf_free(dfd, &b[i]);
	close(dfd);
	return 1;
}

/* ---------------- queue：统一队列 / 丢帧 / 完成反馈 ----------------
 * 要验的三条不变量：
 *   每 submit 恰好一次回调（上屏/丢弃/中止各算一种），否则 buffer 池会枯；
 *   submit 不等 vblank（微秒级），排队与上屏真的解耦了；
 *   同一 vblank 里挤两次 SETPLANE 必须被算成 miss（前帧从未被扫过）。
 */
struct qcb {
	int shown, dropped, aborted, bad_latch, bad_order, total, last_idx;
};

static void cb_displayed(void *ctx, void *owner, double pts, uint32_t latch, int status)
{
	struct qcb *q = ctx;
	int idx = (int)(intptr_t)owner;

	q->total++;
	if (status == VOUT_SHOWN) {
		q->shown++;
		if (!latch) q->bad_latch++;	/* 上屏了却报不出槽位 = 反馈不可信 */
	} else if (status == VOUT_DROPPED) {
		q->dropped++;
	} else {
		q->aborted++;
	}
	if (idx < q->last_idx) q->bad_order++;	/* 回调乱序 = 回收顺序错，会串画面 */
	q->last_idx = idx;
	(void)pts;
}

static int phase_queue(unsigned w, unsigned h, unsigned fps)
{
	int dfd, fd[2], i, f, ret, bad = 0, maxq = 0;
	struct vout *v;
	struct buf b[NBUF];
	struct vout_stats st;
	struct qcb q;
	double base, t0, t1, tmax = 0;
	unsigned depth = 2;

	dfd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (dfd < 0) { perror("/dev/dri/card0"); return 1; }
	memset(b, 0, sizeof(b));
	for (i = 0; i < NBUF; i++) {
		b[i].fdy = b[i].fdc = -1;
		b[i].fdy = dumb_alloc(dfd, w, h, 8, &b[i].cd_y, &b[i].map_y);
		if (b[i].fdy < 0) goto out;
		b[i].size_y = b[i].cd_y.size; b[i].yp = b[i].cd_y.pitch;
		b[i].fdc = dumb_alloc(dfd, w, h / 2, 8, &b[i].cd_c, &b[i].map_c);
		if (b[i].fdc < 0) goto out;
		b[i].size_c = b[i].cd_c.size; b[i].cp = b[i].cd_c.pitch;
		b[i].w = w; b[i].h = h;
		fill_nv12(&b[i], i);
	}

	v = vout_open(NULL);
	if (!v) goto out;
	vout_set_scale(v, VOUT_FIT);
	memset(&q, 0, sizeof(q));
	vout_set_displayed_cb(v, cb_displayed, &q);
	ret = vout_set_queue(v, depth);
	printf("== E0. 队列深度 %d（ret=%d）\n", depth, ret);

	/* A. 正常喂帧：submit 必须立刻返回，pump(0) 只翻到点的 */
	printf("== E1. 队列喂帧 %u fps，submit 不得等 vblank\n", fps);
	base = now_s() + 0.20;
	for (f = 0; f < 90; f++) {
		fd[0] = b[f % NBUF].fdy; fd[1] = b[f % NBUF].fdc;
		t0 = now_s();
		vout_submit(v, fd, w, h, b[f % NBUF].yp, b[f % NBUF].cp,
			    base + (double)f / fps, (void *)(intptr_t)f);
		t1 = now_s();
		if (t1 - t0 > tmax) tmax = t1 - t0;
		vout_pump(v, 0);		/* 非阻塞钩子：该翻的全翻，不等 */
		vout_get_stats(v, &st);
		if (st.queued > maxq) maxq = st.queued;
	}
	vout_wait_shown(v, 500);
	vout_get_stats(v, &st);
	printf("   submit 最大 %.0fus（不该接近 %.1fms 的帧间隔）\n",
	       tmax * 1e6, 1e3 / fps);
	printf("   队列峰值 %d/%d  submitted=%d shown=%d dropped=%d late=%d max %.1fms\n",
	       maxq, st.qdepth, st.submitted, st.shown, st.drops, st.late, st.t_late_max);
	printf("   回调 shown=%d dropped=%d aborted=%d 乱序=%d 无槽位=%d\n",
	       q.shown, q.dropped, q.aborted, q.bad_order, q.bad_latch);
	if (tmax > 0.5 / 1000.0 * 100) {	/* 50ms 量级的等待才算出问题 */
		printf("   <-- submit 在等 vblank，队列没起作用\n");
		bad++;
	}
	if (q.bad_order || q.bad_latch) { printf("   <-- 反馈不可信\n"); bad++; }
	if (maxq > (int)depth) { printf("   <-- 队列超深\n"); bad++; }

	/* B. 故意迟到：pts 跳着给 + 生产端拖 120ms，必须判丢而不是硬补 */
	printf("== E2. 迟到帧必须丢\n");
	{
		int d0 = st.drops;

		vout_pump(v, 0);
		for (f = 0; f < 6; f++) {
			unsigned idx = (f + 90) % NBUF;

			fd[0] = b[idx].fdy; fd[1] = b[idx].fdc;
			vout_submit(v, fd, w, h, b[idx].yp, b[idx].cp,
				    base + (90 + f * 3) / (double)fps,
				    (void *)(intptr_t)(90 + f));
			if (f == 1) usleep(120000);	/* 假装解码卡了一下 */
			vout_pump(v, 0);
		}
		vout_wait_shown(v, 500);
		vout_get_stats(v, &st);
		printf("   这次丢掉 %d 帧（累计 drops=%d stales=%d）\n",
		       st.drops - d0, st.drops, st.stales);
		if (st.drops == d0) printf("   <-- 一帧都没丢，节拍判定没生效\n");
	}

	/* C. 同一个 vblank 里连翻两帧：第二帧盖掉第一帧，必须算 miss */
	printf("== E3. 同槽双翻必须报 miss\n");
	{
		int m0;

		vout_get_stats(v, &st);
		m0 = st.misses;
		for (i = 0; i < 2; i++) {
			unsigned idx = (i + 1) % NBUF;

			fd[0] = b[idx].fdy; fd[1] = b[idx].fdc;
			vout_submit(v, fd, w, h, b[idx].yp, b[idx].cp,
				    base + 10.0, (void *)(intptr_t)(200 + i));
			vout_pump(v, -1);	/* 阻塞：两帧都挤在这一轮里翻 */
		}
		vout_wait_shown(v, 500);
		vout_get_stats(v, &st);
		printf("   miss %d（应为 1：第一帧被第二帧盖掉）\n", st.misses - m0);
		if (st.misses == m0) printf("   <-- miss 没抓到，完成反馈是瞎的\n");
	}

	/* D. 账要对得上：submit 过的每一帧都恰好收到一次回调 */
	vout_get_stats(v, &st);
	printf("== E4. 回调对账 submitted=%d total(cb)=%d pending=%d\n",
	       st.submitted, q.total, st.pending);
	if (st.submitted != q.total + st.pending) {
		printf("   <-- 有帧的回调丢了，buffer 池会枯\n");
		bad++;
	}

	vout_flush(v);
	vout_close(v);
	for (i = 0; i < NBUF; i++) buf_free(dfd, &b[i]);
	close(dfd);
	printf("== 结论: %s\n", bad ? "队列/反馈有硬伤" : "队列、丢帧、节拍、反馈一致");
	return bad ? 1 : 0;
out:
	for (i = 0; i < NBUF; i++) buf_free(dfd, &b[i]);
	close(dfd);
	return 1;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "probe";
	unsigned w = 1920, h = 1080, fps = 24;
	int dfd;

	if (argc > 2) sscanf(argv[2], "%ux%u", &w, &h);
	if (argc > 3) fps = (unsigned)atoi(argv[3]);
	if (!fps) fps = 24;

	dfd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (dfd < 0) {
		fprintf(stderr, "/dev/dri/card0: %s（要在 video 组里，或 sudo）\n",
			strerror(errno));
		return 1;
	}
	if (!strcmp(mode, "probe")) {
		int r = phase_probe(dfd, w, h);

		close(dfd);
		return r;
	}
	if (!strcmp(mode, "run")) {
		close(dfd);
		return phase_run(w, h, fps);
	}
	if (!strcmp(mode, "queue")) {
		close(dfd);
		return phase_queue(w, h, fps);
	}
	fprintf(stderr, "用法: %s probe|run|queue [WxH] [fps]\n", argv[0]);
	close(dfd);
	return 2;
}
