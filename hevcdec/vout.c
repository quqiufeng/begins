/* vout.c —— SDR 快速路径：NV12 dma-buf → DRM overlay plane 直出（零拷贝）
 *
 * 链路只有四步：
 *   PRIME_FD_TO_HANDLE ×2 → MODE_ADDFB2 → WAIT_VBLANK(按 pts) → MODE_SETPLANE
 *
 * 三条设计决定，都是有代价的取舍不是疏忽：
 *   1) 用 legacy ioctl 不用 atomic：这颗 SoC 的私有驱动上 atomic 要额外建
 *      property/blob 体系，而我们本来就要自己管节拍（按 pts 算 vblank 槽），
 *      atomic 的"全有或全无提交"在这里买不到东西。代价是没有 flip event，
 *      时序真相只能靠 vblank 序号——见 vout_frame 里的账。
 *   2) primary plane 不收 NV12，且 meson 上 primary 的 zpos **高于** overlay：
 *      所以必须"全透明 ARGB8888 打底 + NV12 挂 overlay 叠下面"。primary 填
 *      不透明色 = 整屏黑但 flips 照涨，这个症状极其误导。
 *   3) fb 按 (yfd,cfd,w,h) 缓存：PRIME_FD_TO_HANDLE 每次都造新 handle，不缓存
 *      就是每帧漏一个 GEM handle；而 fd 号会被复用，所以 flush 必须让旧键
 *      失效（见 struct fbc 的 pinned 语义），否则 seek 后拿到的是上辈子那张 fb。
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
#include "perfstat.h"

#define VOUT_FB_MAX 64
#define VOUT_Q_MAX 8		/* 队列环形缓冲的物理上限，实际深度可配更小 */

struct fbc {			/* fb 缓存项 */
	int yfd, cfd;		/* <-1 = 键已失效（pinned：还在屏上，不能再被命中） */
	uint32_t fb, h0, h1;	/* fb_id 与两个 GEM handle（close 时要还） */
	unsigned w, h, yp, cp;	/* yp/cp：行跨距，vdec 常给对齐过的值 */
};

struct vframe {			/* 在队列里等着上屏的一帧（只存引用，不存数据） */
	uint32_t fb;
	unsigned w, h, yp, cp;
	double pts;
	uint32_t slot;		/* 目标 vblank 绝对序号 */
	int has_slot;		/* 0 = 无 pts，不排队等槽，到点就上 */
	void *owner;		/* 调用方的 buffer 标识，回调原样带回 */
};

struct vout {
	int dfd;
	uint32_t crtc_id, conn_id, plane_id;
	unsigned crtc_idx;	/* WAIT_VBLANK 的 HIGH_CRTC 编码要它 */
	unsigned dw, dh, refresh;
	enum vout_scale scale;

	/* 目标矩形：只跟源尺寸有关，算一次缓存 */
	unsigned rsw, rsh, dW, dH;
	int dx, dy, rect_ok;

	struct fbc fbc[VOUT_FB_MAX];

	/* 屏上正在扫描的那张 fb：seek 重建时不能 RMFB，否则当场黑屏 */
	uint32_t cur_fb;

	/* 帧队列：submit 只入队，pump 负责按槽位翻页。
	 * 队列满时丢最老的（新的赢），落后时先丢够再追，绝不攒延迟。 */
	struct vframe q[VOUT_Q_MAX];
	int qh, qn, qmax;
	int qdepth;		/* 配置值，<=1 = 同步 */

	/* 完成反馈：上一帧的预期 latch 槽，等下一轮 pump 核实 */
	struct vframe prev;
	uint32_t prev_latch;
	int prev_valid, pending;

	vout_displayed_cb cb;
	void *cbctx;
	int in_cb;		/* 回调里只许 submit，pump/flush/close 会重入 */

	/* 节拍 */
	double t_ref;		/* 合成 vblank 序号的时间原点 */
	int t_ref_have;
	uint32_t vbl_base, vbl_first, vbl_last;
	double pts_base;
	int vbl_ok, started;
	unsigned n;

	/* 账 */
	int flips, drops, timeouts, nopts, submitted, stales, late, shown, misses;
	int aborted;
	double t_late_max;
	/* 帧间隔分布：latch 到 latch，不看 fps */
	struct ps_hist h_int;
	struct ps_hist h_late;	/* 迟到分布：晚了几个槽 */
	uint32_t latch_prev;
	int latch_have;
	unsigned sw, sh;
	double t_first, t_last;
};

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void vdie(const char *m)
{
	fprintf(stderr, "VOUT: %s: %s\n", m, strerror(errno));
}

/* ---------- vblank 序号：用单调时钟合成，不靠驱动 ---------- */
/* meson 的 drm_vblank_count() 只在"有人正等 vblank"时才随中断更新：没人等
 * 就冻住不动。而调度逻辑恰恰是"先看当前序号、再决定等不等"——序号不动就永
 * 远判定"还没到点"，于是从不调用 WAIT_VBLANK，计数更不会走，实测卡死在同一
 * 帧上（屏全黑、shown=0、队列每轮只丢不翻）。这里改用 CLOCK_MONOTONIC × 刷新
 * 率合成一个同节奏的序号：行为等价（1 槽 = 1 个刷新周期），且与驱动实现无关。 */
static uint32_t vbl_seq(struct vout *v, int *ok)
{
	double t;

	if (!v->refresh) {
		if (ok) *ok = 0;
		return 0;
	}
	t = now_s();
	if (!v->t_ref_have) {
		v->t_ref = t;
		v->t_ref_have = 1;
	}
	if (ok) *ok = 1;
	return (uint32_t)((t - v->t_ref) * v->refresh);
}

/* 等到目标槽的墙钟时刻。pump 已经用预算限制过调用，这里不会再等过头；
 * 最后 2ms 细睡，避免 usleep 的调度粒度把一整帧睡丢。 */
static int vbl_wait_abs(struct vout *v, uint32_t target)
{
	double due;

	if (!v->refresh || !v->t_ref_have) return -1;
	due = v->t_ref + (double)target / v->refresh;
	for (;;) {
		double left = due - now_s();

		if (left <= 0) return 0;
		if (left > 0.002) usleep((useconds_t)((left - 0.002) * 1e6));
		else usleep(200);
	}
}

/* ---------- 完成反馈 ---------- */
/* 每一次 submit 恰好回调一次：上屏、丢弃、中止都算。调用方据此回收 buffer，
 * 所以这里宁可多报一次也不能漏报（漏了=解码器那份 buffer 永远回不来）。 */
static void fire(struct vout *v, const struct vframe *f, int status, uint32_t latch)
{
	if (v->pending > 0) v->pending--;
	if (status == VOUT_SHOWN) v->shown++;
	if (!v->cb) {
		if (status != VOUT_SHOWN)
			printf("VOUT: frame pts=%.3f %s (no cb)\n", f->pts,
			       status == VOUT_ABORTED ? "aborted" : "dropped");
		return;
	}
	v->in_cb = 1;
	v->cb(v->cbctx, f->owner, f->pts, latch, status);
	v->in_cb = 0;
}

/* 队列里有没有这张 fb：pump 还没翻上去的帧，RMFB 了就是花屏 */
static int fb_queued(struct vout *v, uint32_t fb)
{
	int i;

	for (i = 0; i < v->qn; i++)
		if (v->q[(v->qh + i) % VOUT_Q_MAX].fb == fb)
			return 1;
	return v->prev_valid && v->prev.fb == fb;
}

/* 清空队列：逐帧回调中止。flush / close 前必须走一遍，否则调用方那边
 * 永远等不到反馈，buffer 池就枯了。 */
static int q_abort(struct vout *v)
{
	int n = 0;

	while (v->qn) {
		struct vframe *f = &v->q[v->qh];

		fire(v, f, VOUT_ABORTED, 0);
		v->qh = (v->qh + 1) % VOUT_Q_MAX;
		v->qn--;
		n++;
	}
	v->aborted += n;
	v->qh = 0;
	return n;
}

/* ---------- fb 缓存 ---------- */
static void fb_release(struct vout *v, struct fbc *e, int rmfb)
{
	if (!e->fb && !e->h0 && !e->h1) { e->yfd = e->cfd = -1; return; }
	if (rmfb && e->fb)
		ioctl(v->dfd, DRM_IOCTL_MODE_RMFB, &e->fb);
	if (e->h0) { struct drm_gem_close gc = { .handle = e->h0 }; ioctl(v->dfd, DRM_IOCTL_GEM_CLOSE, &gc); }
	if (e->h1) { struct drm_gem_close gc = { .handle = e->h1 }; ioctl(v->dfd, DRM_IOCTL_GEM_CLOSE, &gc); }
	memset(e, 0, sizeof(*e));
	e->yfd = e->cfd = -1;
}

int vout_flush(struct vout *v)
{
	int i, freed = 0;

	if (!v) return -1;
	if (v->in_cb) {
		fprintf(stderr, "VOUT: flush() 不能在完成回调里调\n");
		return -1;
	}
	q_abort(v);			/* 队列里的先退回去，不然 buffer 池枯死 */
	if (v->prev_valid) {
		/* 屏上那一帧等不到"确认"了（它可能还要留到下一帧才被盖掉），
		 * 但回调必须发出去：每一次 submit 恰好一次回调，这条账不能有例外。
		 * 会话重建时那张 dmabuf 本来就要销毁，按中止回报。 */
		v->prev_valid = 0;
		fire(v, &v->prev, VOUT_ABORTED, 0);
	}
	for (i = 0; i < VOUT_FB_MAX; i++) {
		struct fbc *e = &v->fbc[i];

		if (!e->fb) continue;
		if (e->fb == v->cur_fb) {
			/* 屏上那张：留着，但让它的键失效。
			 * 关键：fd 号会被新会话复用，键不失效就会拿错 fb。 */
			e->yfd = e->cfd = -1;
			continue;
		}
		fb_release(v, e, 1);
		freed++;
	}
	v->rect_ok = 0;
	v->started = 0;			/* 时间轴重排：下一帧重新落锚 */
	v->pts_base = 0;
	if (freed)
		printf("VOUT: flush %d fb (keep cur_fb=%u)\n", freed, v->cur_fb);
	return 0;
}

/* 取一个 drm object 上某个属性的值。注意 value 数组必须给：只给 props_ptr
 * 时内核在写第二个数组时就 EFAULT，前面几条属性的值会静默留成 0。 */
static int vout_prop_u64(int dfd, uint32_t obj, uint32_t obj_type,
			 const char *name, uint64_t *val)
{
	static uint32_t ids[64];
	static uint64_t vals[64];
	struct drm_mode_obj_get_properties gp = {0};
	struct drm_mode_get_property pr = {0};
	int i;

	gp.obj_id = obj;
	gp.obj_type = obj_type;
	gp.props_ptr = (uint64_t)(uintptr_t)ids;
	gp.prop_values_ptr = (uint64_t)(uintptr_t)vals;
	gp.count_props = 64;
	if (ioctl(dfd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &gp) < 0) return -1;
	for (i = 0; i < (int)gp.count_props && i < 64; i++) {
		pr.prop_id = ids[i];
		if (ioctl(dfd, DRM_IOCTL_MODE_GETPROPERTY, &pr) < 0) continue;
		if (strcmp(pr.name, name)) continue;
		*val = vals[i];
		return 0;
	}
	return -1;
}

static struct fbc *fb_lookup(struct vout *v, int yfd, int cfd, unsigned w, unsigned h,
			     unsigned yp, unsigned cp)
{
	int i, free_slot = -1, victim = -1;

	for (i = 0; i < VOUT_FB_MAX; i++) {
		struct fbc *e = &v->fbc[i];

		if (!e->fb) { if (free_slot < 0) free_slot = i; continue; }
		if (e->yfd == yfd && e->cfd == cfd && e->w == w && e->h == h &&
		    e->yp == yp && e->cp == cp)
			return e;	/* 命中：这次一帧都不碰 ioctl */
	}
	if (free_slot >= 0) return &v->fbc[free_slot];

	/* 满：牺牲第一张不在屏上、也不在队列里的。屏上那张 RMFB 会当场黑屏，
	 * 队列里那张 RMFB 会让下一轮 pump 翻出一张野 fb。 */
	for (i = 0; i < VOUT_FB_MAX; i++)
		if (v->fbc[i].fb && v->fbc[i].fb != v->cur_fb &&
		    !fb_queued(v, v->fbc[i].fb)) { victim = i; break; }
	if (victim < 0) return NULL;
	fb_release(v, &v->fbc[victim], 1);
	return &v->fbc[victim];
}

static struct fbc *fb_get(struct vout *v, int yfd, int cfd, unsigned w, unsigned h,
			  unsigned yp, unsigned cp)
{
	struct drm_mode_fb_cmd2 fb = {0};
	struct drm_prime_handle ph;
	struct fbc *e = fb_lookup(v, yfd, cfd, w, h, yp, cp);

	if (!e) return NULL;
	if (e->fb) return e;

	/* 新 fb：同一个 dma-buf 的两个 plane 各导一次，handle 必须分开存 */
	ph.fd = yfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(v->dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		vdie("PRIME_FD_TO_HANDLE(Y)"); return NULL;
	}
	e->h0 = ph.handle;
	ph.fd = cfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(v->dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		vdie("PRIME_FD_TO_HANDLE(C)"); fb_release(v, e, 0); return NULL;
	}
	e->h1 = ph.handle;

	/* NV12 是交织单平面格式，DRM 侧靠两个 handle 表达；
	 * pitch = w（不是 w*2，也不是 len/height），modifier 不设 = LINEAR。 */
	fb.width = w;
	fb.height = h;
	fb.pixel_format = DRM_FORMAT_NV12;
	fb.handles[0] = e->h0;
	fb.handles[1] = e->h1;
	fb.pitches[0] = yp;
	fb.pitches[1] = cp;
	fb.offsets[0] = 0;
	fb.offsets[1] = 0;
	if (ioctl(v->dfd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
		vdie("ADDFB2 NV12"); fb_release(v, e, 0); return NULL;
	}
	e->fb = fb.fb_id;
	e->yfd = yfd; e->cfd = cfd; e->w = w; e->h = h; e->yp = yp; e->cp = cp;
	return e;
}

/* ---------- 目标矩形 ---------- */
static void rect_calc(struct vout *v, unsigned sw, unsigned sh)
{
	if (v->rect_ok && v->rsw == sw && v->rsh == sh) return;
	v->rsw = sw; v->rsh = sh;

	if (v->scale != VOUT_FIT) {
		v->dx = 0; v->dy = 0; v->dW = v->dw; v->dH = v->dh;
	} else {
		double s = (double)v->dw / sw, sv = (double)v->dh / sh;

		if (sv < s) s = sv;
		v->dW = (unsigned)(sw * s + 0.5);
		v->dH = (unsigned)(sh * s + 0.5);
		if (v->dW > v->dw) v->dW = v->dw;
		if (v->dH > v->dh) v->dH = v->dh;
		v->dx = (int)(v->dw - v->dW) / 2;
		v->dy = (int)(v->dh - v->dH) / 2;
	}
	v->rect_ok = 1;
	printf("VOUT: scale=%s src=%ux%u -> %ux%u @ +%d+%d (screen %ux%u)\n",
	       v->scale == VOUT_CROP ? "crop" : v->scale == VOUT_FILL ? "fill" : "fit",
	       sw, sh, v->dW, v->dH, v->dx, v->dy, v->dw, v->dh);
}

/* ---------- 建 CRTC：全透明 ARGB 打底 ---------- */
static int primary_bring_up(struct vout *v, const struct drm_mode_modeinfo *m)
{
	struct drm_mode_create_dumb cd = {0};
	struct drm_mode_destroy_dumb dd = {0};
	struct drm_mode_map_dumb md = {0};
	struct drm_mode_fb_cmd fb = {0};
	struct drm_mode_crtc set = {0};
	void *map;

	cd.width = m->hdisplay;
	cd.height = m->vdisplay;
	cd.bpp = 32;
	if (ioctl(v->dfd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) < 0) {
		vdie("CREATE_DUMB"); return -1;
	}
	/* legacy ADDFB 按 (bpp=32, depth=24) 推出的是 **XRGB8888**：alpha 位被
	 * 驱动忽略 → 全 0 的缓冲照样是不透明黑，正好盖在 overlay 上面（meson
	 * primary 的 normalized-zpos=1，overlay 是 0）。必须用 ADDFB2 明确要
	 * ARGB8888，alpha=0 才是真透明。 */
	{
		struct drm_mode_fb_cmd2 f2 = {0};

		f2.width = cd.width; f2.height = cd.height;
		f2.pixel_format = DRM_FORMAT_ARGB8888;
		f2.handles[0] = cd.handle;
		f2.pitches[0] = cd.pitch;
		f2.offsets[0] = 0;
		if (ioctl(v->dfd, DRM_IOCTL_MODE_ADDFB2, &f2) < 0) {
			vdie("ADDFB2(primary ARGB8888)");
			fb.width = cd.width; fb.height = cd.height;
			fb.bpp = 32; fb.depth = 24; fb.pitch = cd.pitch;
			fb.handle = cd.handle;
			if (ioctl(v->dfd, DRM_IOCTL_MODE_ADDFB, &fb) < 0) {
				vdie("ADDFB(primary)"); goto bad;
			}
		} else {
			fb.fb_id = f2.fb_id;
		}
	}

	/* 内容未定义，必须显式清零；alpha=0 让 overlay 透上来 */
	md.handle = cd.handle;
	if (ioctl(v->dfd, DRM_IOCTL_MODE_MAP_DUMB, &md) == 0) {
		map = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED,
			   v->dfd, md.offset);
		if (map != MAP_FAILED) {
			memset(map, 0, cd.size);
			munmap(map, cd.size);
		} else {
			fprintf(stderr, "VOUT: primary mmap 失败，透明底可能不干净\n");
		}
	}

	set.crtc_id = v->crtc_id;
	set.fb_id = fb.fb_id;
	set.set_connectors_ptr = (uint64_t)(uintptr_t)&v->conn_id;
	set.count_connectors = 1;
	set.mode = *m;
	set.mode_valid = 1;	/* 少这行内核 mode=NULL → SETCRTC EINVAL */
	if (ioctl(v->dfd, DRM_IOCTL_MODE_SETCRTC, &set) < 0) {
		vdie("SETCRTC"); goto bad;
	}
	/* dumb 留在内核里跟着 CRTC 用到底，只还内存句柄会黑屏，所以不 destroy */
	(void)dd;
	return (int)fb.fb_id;
bad:
	dd.handle = cd.handle;
	ioctl(v->dfd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
	return -1;
}

struct vout *vout_open(const char *drmdev)
{
	struct vout *v;
	struct drm_mode_card_res res = {0};
	static uint32_t crtcs[16], conns[16], encs[16];
	static struct drm_mode_modeinfo modes[64];
	const char *dev = drmdev ? drmdev : "/dev/dri/card0";
	uint32_t enc_id = 0;
	struct drm_mode_modeinfo mode = {0};
	struct drm_mode_modeinfo want = {0};	/* 2560x1440@60 目标 */
	int i;

	v = calloc(1, sizeof(*v));
	if (!v) return NULL;
	for (i = 0; i < VOUT_FB_MAX; i++) v->fbc[i].yfd = v->fbc[i].cfd = -1;
	v->scale = VOUT_FIT;
	v->refresh = 60;
	ps_init(&v->h_int, "intv", "ms", 1500.0 / 60);
	ps_init(&v->h_late, "late", "ms", 0);
	/* 默认深度 1：老语义（submit 当场推平），要队列请 vout_set_queue()。
	 * 队列是给"解码线程想领先几帧"的场景用的，默认不开——多一帧队列就多
	 * 一帧显示延迟，24fps 下那是 41ms 的唇音误差，不该由库替调用方决定。 */
	v->qmax = v->qdepth = 1;

	v->dfd = open(dev, O_RDWR | O_CLOEXEC);
	if (v->dfd < 0) { vdie(dev); goto fail; }

	res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs; res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns; res.count_connectors = 16;
	res.encoder_id_ptr = (uint64_t)(uintptr_t)encs; res.count_encoders = 16;
	if (ioctl(v->dfd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) { vdie("GETRESOURCES"); goto fail; }

	/* 找一个已连接、有 mode 的 connector；优先它当前绑的 CRTC */
	for (i = 0; i < (int)res.count_connectors && !v->conn_id; i++) {
		struct drm_mode_get_connector gc = {0};
		uint32_t myenc = 0;
		int j, nmode;

		gc.connector_id = conns[i];
		gc.modes_ptr = (uint64_t)(uintptr_t)modes;
		gc.count_modes = 64;
		gc.encoders_ptr = (uint64_t)(uintptr_t)&myenc;
		gc.count_encoders = 1;
		if (ioctl(v->dfd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0) continue;
		/* 必须只认 connected 的 connector：X96 上 card0 同时挂着
		 * Composite-1（CVBS，status=unknown）和 HDMI-A-1，前者排在
		 * 前面且带 720x576i/720x480i 模式。只看 count_modes 会选中
		 * CVBS → 输出 720x576@50、HDMI 上什么也没有、vout 队列瞬间
		 * 堵死（"queue full, drop"）。 */
		if (gc.connection != 1 /* DRM_MODE_CONNECTED */)
			continue;
		if (!gc.count_modes) continue;
		nmode = gc.count_modes > 64 ? 64 : (int)gc.count_modes;

		v->conn_id = conns[i];
		/* 目标模式写死 2560x1440@60：这台显示器只有这一个模式，屏幕
		 * 是固定的，选别的分辨率要么黑屏要么走 scaler。先按 (宽,高,刷新)
		 * 精确找；找不到再退化为"取最大面积（<=4096 宽）"，最后兜底
		 * modes[0]，别让 EDID 顺序决定结果。
		 */
		for (j = 0; j < nmode; j++) {
			if (modes[j].hdisplay != 2560 || modes[j].vdisplay != 1440)
				continue;
			if (!want.hdisplay ||
			    abs((int)modes[j].vrefresh - 60) <
			    abs((int)want.vrefresh - 60))
				want = modes[j];
		}
		if (want.hdisplay) {
			mode = want;
		} else {
			for (j = 0; j < nmode; j++) {
				if (modes[j].hdisplay > 4096) continue;
				if (modes[j].hdisplay * modes[j].vdisplay >
				    mode.hdisplay * mode.vdisplay)
					mode = modes[j];
			}
			if (!mode.hdisplay) mode = modes[0];
			fprintf(stderr, "VOUT: 没有 2560x1440@60，退化为 %ux%u@%u\n",
				mode.hdisplay, mode.vdisplay, mode.vrefresh);
		}
		enc_id = gc.encoder_id ? gc.encoder_id : myenc;
	}
	if (!v->conn_id) { fprintf(stderr, "VOUT: 没有已连接的 connector\n"); goto fail; }
	if (!mode.hdisplay) { fprintf(stderr, "VOUT: 没有可用 mode\n"); goto fail; }

	v->dw = mode.hdisplay;
	v->dh = mode.vdisplay;
	v->refresh = mode.vrefresh ? mode.vrefresh : 60;
	/* latch 间隔超过 1.5 个刷新周期就是掉槽，阈值随实际刷新率走 */
	v->h_int.budget = 1500.0 / v->refresh;
	v->h_int.slot_unit = 1000.0 / v->refresh;	/* 间隔按 vblank 槽记账 */
	v->h_late.slot_unit = 1000.0 / v->refresh;

	/* encoder → crtc */
	if (enc_id) {
		struct drm_mode_get_encoder ge = {0};

		ge.encoder_id = enc_id;
		if (ioctl(v->dfd, DRM_IOCTL_MODE_GETENCODER, &ge) == 0)
			v->crtc_id = ge.crtc_id;
	}
	if (!v->crtc_id && res.count_crtcs) v->crtc_id = crtcs[0];
	if (!v->crtc_id) { fprintf(stderr, "VOUT: 没有 CRTC\n"); goto fail; }
	for (i = 0; i < (int)res.count_crtcs; i++)
		if (crtcs[i] == v->crtc_id) v->crtc_idx = i;

	if (primary_bring_up(v, &mode) < 0) goto fail;

	/* 扫 plane：要的是 overlay。不能只撞第一个支持 NV12 的——有的驱动把
	 * primary 也报 NV12（nvidia-drm 四个 plane 全报 type=0），一旦选中
	 * primary，SETPLANE 会和上面那层打底 fb 抢同一个 plane，打底就白费了。 */
	{
		struct drm_mode_get_plane_res pr = {0};
		static uint32_t pids[64];

		pr.plane_id_ptr = (uint64_t)(uintptr_t)pids;
		pr.count_planes = 64;
		if (ioctl(v->dfd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr) < 0) {
			vdie("GETPLANERESOURCES"); goto fail;
		}
		uint32_t fallback = 0;

		for (i = 0; i < (int)pr.count_planes; i++) {
			struct drm_mode_get_plane gp = {0};
			static uint32_t fmts[64];
			int j, has_nv12 = 0, ptype = -1;
			uint64_t tv = 0;

			gp.plane_id = pids[i];
			gp.format_type_ptr = (uint64_t)(uintptr_t)fmts;
			gp.count_format_types = 64;
			if (ioctl(v->dfd, DRM_IOCTL_MODE_GETPLANE, &gp) < 0) continue;
			for (j = 0; j < (int)gp.count_format_types; j++)
				if (fmts[j] == DRM_FORMAT_NV12) has_nv12 = 1;
			if (!has_nv12) continue;
			if (!(gp.possible_crtcs & (1u << v->crtc_idx))) continue;
			if (vout_prop_u64(v->dfd, pids[i], DRM_MODE_OBJECT_PLANE,
					  "type", &tv) == 0)
				ptype = (int)tv;
			if (ptype == 2) continue;	/* CURSOR：尺寸和格式都不对 */
			if (ptype == 1) {		/* PRIMARY：留作兜底 */
				if (!fallback) fallback = pids[i];
				continue;
			}
			v->plane_id = pids[i];
			break;
		}
		if (!v->plane_id) v->plane_id = fallback;
	}
	if (!v->plane_id) {
		fprintf(stderr, "VOUT: 找不到支持 NV12 的 plane\n"); goto fail;
	}

	printf("VOUT: %ux%u@%u crtc=%u plane=%u conn=%u\n",
	       v->dw, v->dh, v->refresh, v->crtc_id, v->plane_id, v->conn_id);
	return v;
fail:
	if (v->dfd >= 0) close(v->dfd);
	free(v);
	return NULL;
}

/* ---------- 上屏：一次 SETPLANE ---------- */
/* 只做一件事：把队列里的 fb 挂到 plane 上。src/dst 矩形按这一帧自己的源尺寸
 * 算——队列里可能同时躺着改分辨率前后的两种帧，用全局 v->sw/sh 会算错。 */
static int plane_commit(struct vout *v, const struct vframe *f)
{
	struct drm_mode_set_plane sp = {0};
	unsigned w = f->w, h = f->h;

	rect_calc(v, w, h);
	sp.plane_id = v->plane_id;
	sp.crtc_id = v->crtc_id;
	sp.fb_id = f->fb;
	/* src 是 16.16 定点 */
	if (v->scale == VOUT_CROP) {
		unsigned cw = w, ch = h;
		double sa = (double)w / h, da = (double)v->dw / v->dh;

		if (sa > da) cw = (unsigned)(h * da + 0.5);
		else if (sa < da) ch = (unsigned)(w / da + 0.5);
		sp.src_x = ((w - cw) / 2) << 16;
		sp.src_y = ((h - ch) / 2) << 16;
		sp.src_w = cw << 16;
		sp.src_h = ch << 16;
	} else {
		sp.src_w = w << 16;
		sp.src_h = h << 16;
	}
	sp.crtc_x = v->dx;
	sp.crtc_y = v->dy;
	sp.crtc_w = v->dW;
	sp.crtc_h = v->dH;

	if (ioctl(v->dfd, DRM_IOCTL_MODE_SETPLANE, &sp) < 0) {
		vdie("SETPLANE");
		return -1;
	}
	v->cur_fb = f->fb;
	v->flips++;
	v->n++;
	v->t_last = now_s();
	return 0;
}

/* 显示完成反馈：SETPLANE 要等到下一个 vblank 才接管扫描，所以目标槽 T 的
 * 那一帧，真正开始扫描是 T+1。下一轮 pump 拿当前序号去核：
 *   cur >= prev_latch   上一帧确实吃到了 vblank → SHOWN，把真序号交回去
 *   cur <  prev_latch   两次 SETPLANE 挤进同一个 vblank，后一次盖掉前一次，
 *                       前帧一帧都没被扫过 → 记 miss，按丢弃回报
 * legacy ioctl 没有 flip event，这是能拿到的最准的完成反馈；粒度一帧，
 * 用来回收 buffer 足够（回收只要"不在扫描"这个结论，不要精确到行）。 */
static void confirm_prev(struct vout *v, uint32_t cur, int okv)
{
	if (!v->prev_valid) return;
	v->prev_valid = 0;
	if (!okv || (int32_t)(cur - v->prev_latch) >= 0) {
		if (okv) {
			/* 真正上屏的两个 latch 之间的间隔：节拍真相在这，
			 * fps 只是它的调和平均，抖动全被抹平 */
			if (v->latch_have) {
				double ms = (double)(uint32_t)(v->prev_latch - v->latch_prev)
					    * 1000.0 / v->refresh;

				ps_add(&v->h_int, ms);
			}
			v->latch_prev = v->prev_latch;
			v->latch_have = 1;
		}
		fire(v, &v->prev, VOUT_SHOWN, okv ? v->prev_latch : 0);
	} else {
		v->misses++;
		fire(v, &v->prev, VOUT_DROPPED, 0);
	}
}

/* pts → 目标 vblank 槽。锚点在首帧（和 seek 回跳）时种下，之后纯靠绝对时间
 * 换算：迟到就迟到，下一帧自己回到槽上，不需要追帧式重锚。
 * 32 位序号在 60Hz 下 2 年多才回绕，用有符号差值比较就够。 */
static uint32_t pts_slot(struct vout *v, double pts, uint32_t cur)
{
	long long slot;

	if (pts < v->pts_base - 0.5) {	/* seek：时间轴跳到过去，重锚 */
		v->pts_base = pts;
		v->vbl_base = cur;
	}
	slot = (long long)((pts - v->pts_base) * v->refresh + 0.5);
	if (slot < 0) slot = 0;
	return v->vbl_base + (uint32_t)slot;
}

/* ---------- 提交：只入队，不等 vblank ---------- */
int vout_submit(struct vout *v, const int fd[2], unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch, double pts, void *owner)
{
	struct vframe f = {0};
	struct fbc *e;
	int okv = 0, tail;
	uint32_t cur;

	if (!v) return -1;
	if (!fd || !w || !h) return 0;

	/* 分辨率变了：旧尺寸的 fb 全部作废（显存不能靠重启进程回收）。
	 * flush 会连队列一起中止 —— 这里是对的，改尺寸时旧帧已经无处可上。 */
	if (v->started && (w != v->sw || h != v->sh))
		vout_flush(v);
	v->sw = w; v->sh = h;

	if (!ypitch) ypitch = w;
	if (!cpitch) cpitch = ypitch;
	/* 关键：fd→handle→fb 一次做完，几十微秒。做完之后 fd 归调用方，
	 * vout 只留 GEM handle，所以"排队"不会把解码器堵在这里等 vblank。 */
	e = fb_get(v, fd[0], fd[1], w, h, ypitch, cpitch);
	if (!e) return -1;

	f.fb = e->fb; f.w = w; f.h = h; f.yp = ypitch; f.cp = cpitch;
	f.pts = pts; f.owner = owner;

	cur = vbl_seq(v, &okv);
	if (!v->started) {
		v->vbl_ok = okv;
		v->vbl_first = cur;
		v->vbl_base = cur;
		v->pts_base = pts > 0 ? pts : 0;
		v->t_first = now_s();
		v->started = 1;
	} else if (!okv) {
		v->vbl_ok = 0;
	} else if (!v->pts_base && pts > 0) {
		/* 首帧没时间戳（B 帧还没排出来）：等第一帧带 pts 的再落锚，
		 * 否则 pts_base 永远是 0，整场都走不到 vblank 节拍。 */
		v->pts_base = pts;
		v->vbl_base = cur;
	}

	v->submitted++;
	v->pending++;			/* 这一帧欠一次回调 */
	if (v->vbl_ok && pts > 0 && v->pts_base > 0) {
		long long d;

		f.slot = pts_slot(v, pts, cur);
		f.has_slot = 1;
		if (getenv("VOUTDBG")) {
			static int c;
			if (c < 6 || (c % 50) == 0)
				fprintf(stderr, "[sub] #%d pts=%.3f base=%.3f cur=%u slot=%u d=%ld t_first_ago=%.3f\n",
					c, pts, v->pts_base, cur, f.slot,
					(long)((long long)f.slot - (long long)cur), now_s() - v->t_first);
			c++;
		}
		if ((long long)f.slot - (long long)cur > 2LL * v->refresh) {
			/* 槽位远得离谱（pts 起点不是 0 之类）：重锚，否则队列
			 * 会卡在这一张上等到天荒，后面的帧全被它堵死。 */
			v->vbl_base = cur;
			v->pts_base = pts;
			f.slot = cur;
		}
		d = (long long)f.slot - (long long)cur;
		/* 丢帧：晚两个 vblank 以上的不再上屏。24fps@60 每帧只吃 2~3 槽，
		 * 补这一帧就得连累后面一串；H.265 的短 P 链少一帧很耐看。 */
		if (d <= -2) {
			v->drops++;
			v->stales++;
			printf("VOUT: drop pts=%.3f (%lld vblank late)\n", pts, -d);
			fire(v, &f, VOUT_DROPPED, 0);
			return 2;
		}
	} else if (pts <= 0) {
		v->nopts++;
	}

	/* 入队。满了丢最老的：显示队列永远"新的赢"，落后时跳帧去追，
	 * 而不是把最新帧也堵在外面——那等于让延迟越攒越大。 */
	if (v->qn >= v->qmax) {
		struct vframe *old = &v->q[v->qh];

		printf("VOUT: queue full, drop pts=%.3f\n", old->pts);
		fire(v, old, VOUT_DROPPED, 0);
		v->qh = (v->qh + 1) % VOUT_Q_MAX;
		v->qn--;
		v->drops++;
		v->stales++;
	}
	tail = (v->qh + v->qn) % VOUT_Q_MAX;
	v->q[tail] = f;
	v->qn++;
	return 0;
}

/* ---------- 推队列：按槽位翻页 ---------- */
int vout_pump(struct vout *v, int timeout_ms)
{
	int flipped = 0;
	double deadline = timeout_ms >= 0 ? now_s() + timeout_ms / 1000.0 : 0.0;

	if (!v) return -1;
	if (v->in_cb) {			/* 重入会翻同一张 fb 两次，直接拒 */
		fprintf(stderr, "VOUT: pump() 不能在完成回调里调\n");
		return -1;
	}
	while (v->qn > 0) {
		struct vframe *f = &v->q[v->qh];
		int okv = 0;
		uint32_t cur = vbl_seq(v, &okv);

		confirm_prev(v, cur, okv);	/* 顺手核掉上一帧的完成反馈 */
		/* 回调里允许 submit（见 vout.h），而队列满时 submit 会丢最老的、
		 * 把 qh 推走——所以 confirm 之后必须重取队首，别拿旧指针去 commit。 */
		f = &v->q[v->qh];
		if (f->has_slot && okv) {
			long long d = (long long)f->slot - (long long)cur;

			if (d > 0) {
				int need = (int)(d * 1000.0 / v->refresh + 0.5);

				if (timeout_ms >= 0) {
					double left = (deadline - now_s()) * 1000.0;

					/* 还没到点且不许等：停在这，交给下一次 pump。
					 * 队首槽位最小（FIFO），停它就是停全部。 */
					if (need > (int)left) {
						if (getenv("VOUTDBG")) {
							static int c;
							if ((c++ % 30) == 0)
								fprintf(stderr, "[pump] break qn=%d cur=%u slot=%u need=%d left=%.1f okv=%d\n",
									v->qn, cur, f->slot, need, left, okv);
						}
						break;
					}
				}
				if (vbl_wait_abs(v, f->slot) < 0) {
					v->timeouts++;
					v->vbl_ok = 0;
					f->has_slot = 0;
				}
			} else if (d < 0) {
				double ms = -d * 1000.0 / v->refresh;

				v->late++;
				if (ms > v->t_late_max) v->t_late_max = ms;
				/* 迟到不是"晚一点"，是整整晚 n 个槽：记分布才知道
				 * 是偶尔差一槽（相邻帧补回来）还是系统性晚一堆 */
				ps_add(&v->h_late, ms);
			}
		}
		if (plane_commit(v, f) < 0) {
			fire(v, f, VOUT_DROPPED, 0);	/* 翻不上去也得把 buffer 还了 */
		} else {
			cur = vbl_seq(v, &okv);
			if (okv) v->vbl_last = cur;
			v->prev = *f;
			v->prev_latch = cur + 1;	/* 下一 vblank 接管扫描 */
			v->prev_valid = 1;
		}
		v->qh = (v->qh + 1) % VOUT_Q_MAX;
		v->qn--;
		flipped++;
	}
	return flipped;
}

/* 队列剩下的全部立刻翻上去，不看槽位。只用在 seek/切源前追平——
 * 同一个 vblank 里连翻多张，中间的帧等于白翻（硬件只认最后那张）。 */
int vout_drain(struct vout *v)
{
	int n = 0;

	if (!v) return -1;
	while (v->qn > 0) {
		struct vframe *f = &v->q[v->qh];
		int okv = 0;
		uint32_t cur;

		/* 同一个 vblank 里连翻，中间那几张其实没被扫过：诚实地按 miss
		 * 回报，别把"翻过"当"显示过"——否则调用方会以为画面完整。 */
		confirm_prev(v, vbl_seq(v, &okv), okv);
		f = &v->q[v->qh];
		f->has_slot = 0;
		if (plane_commit(v, f) < 0) {
			fire(v, f, VOUT_DROPPED, 0);
		} else {
			cur = vbl_seq(v, &okv);
			if (okv) v->vbl_last = cur;
			v->prev = *f;
			v->prev_latch = cur + 1;
			v->prev_valid = 1;
		}
		v->qh = (v->qh + 1) % VOUT_Q_MAX;
		v->qn--;
		n++;
	}
	return n;
}

/* 等到"最后一帧已确认上屏"。暂停、收流、切分辨率之前用它把画面钉住。 */
int vout_wait_shown(struct vout *v, int timeout_ms)
{
	double deadline = timeout_ms < 0 ? 1e18 : now_s() + timeout_ms / 1000.0;

	if (!v) return -1;
	vout_pump(v, timeout_ms);	/* 先把队列推平，可能刚好花光预算 */
	if (!v->prev_valid) return 1;	/* 没有在途帧 = 最后那张已经在屏上 */
	if (!v->vbl_ok) { confirm_prev(v, 0, 0); return 1; }

	for (;;) {
		int okv = 0;
		uint32_t cur = vbl_seq(v, &okv);
		double left;

		if (okv && (int32_t)(cur - v->prev_latch) >= 0) {
			confirm_prev(v, cur, okv);
			return 1;
		}
		left = (deadline - now_s()) * 1000.0;
		if (left <= 0) return 0;
		if (left > 5) left = 5;	/* 5ms 一批，别一觉睡过头 */
		{
			int nb = (int)(left * v->refresh / 1000.0 + 0.5);

			if (nb > 0 && vbl_wait_abs(v, cur + (uint32_t)nb) < 0) {
				v->timeouts++;
				return 0;
			}
		}
	}
}

int vout_set_queue(struct vout *v, int depth)
{
	if (!v) return -1;
	if (depth < 1) depth = 1;
	if (depth > VOUT_Q_MAX) depth = VOUT_Q_MAX;
	v->qdepth = depth;
	v->qmax = depth;
	/* 缩容：多出来的从老的那头丢，回调照发，绝不吞掉别人的 buffer */
	while (v->qn > v->qmax) {
		struct vframe *old = &v->q[v->qh];

		fire(v, old, VOUT_DROPPED, 0);
		v->qh = (v->qh + 1) % VOUT_Q_MAX;
		v->qn--;
		v->drops++;
	}
	return v->qmax;
}

void vout_set_displayed_cb(struct vout *v, vout_displayed_cb cb, void *ctx)
{
	if (!v) return;
	v->cb = cb;
	v->cbctx = ctx;
}

/* ---------- 同步接口：深度 1 的老语义 ---------- */
int vout_frame(struct vout *v, const int fd[2], unsigned w, unsigned h, double pts)
{
	return vout_frame_ex(v, fd, w, h, w, w, pts);
}

int vout_frame_ex(struct vout *v, const int fd[2], unsigned w, unsigned h,
		  unsigned ypitch, unsigned cpitch, double pts)
{
	int ret, f0;

	if (!v) return -1;
	ret = vout_submit(v, fd, w, h, ypitch, cpitch, pts, NULL);
	if (ret < 0) return -1;
	if (ret == 2) return 0;		/* 节拍判定丢弃 */
	f0 = v->flips;
	vout_pump(v, -1);		/* 同步语义：排空即为已上屏 */
	/* 到这里 dmabuf 已经可以被调用方还给 vdec：vout 只留 GEM handle 引用。
	 * （深度 1 时不需要等回调；深度 >1 时请改用 submit + 回调回收。） */
	return v->flips > f0 ? 1 : 0;
}

void vout_set_scale(struct vout *v, enum vout_scale m)
{
	if (!v) return;
	if (v->scale != m) v->rect_ok = 0;
	v->scale = m;
}

void vout_set_refresh(struct vout *v, unsigned hz)
{
	if (v && hz) {
		v->refresh = hz;
		/* 超过 1.5 个刷新周期 = 这一帧至少错过一个 vblank */
		v->h_int.budget = 1500.0 / hz;
		v->h_int.slot_unit = 1000.0 / hz;
	}
}

void vout_get_stats(struct vout *v, struct vout_stats *st)
{
	if (!v || !st) return;
	st->flips = v->flips;
	st->drops = v->drops;
	st->timeouts = v->timeouts;
	st->sw = v->sw;
	st->sh = v->sh;
	st->dw = v->dw;
	st->dh = v->dh;
	st->refresh = v->refresh;
	st->t_first = v->t_first;
	st->t_last = v->t_last;
	st->vbl_first = v->vbl_first;
	st->vbl_last = v->vbl_last;
	st->vbl_ok = v->vbl_ok;

	st->queued = v->qn;
	st->qdepth = v->qdepth;
	st->submitted = v->submitted;
	st->stales = v->stales;
	st->late = v->late;
	st->t_late_max = v->t_late_max;
	st->shown = v->shown;
	st->misses = v->misses;
	st->iv_n = (int)v->h_int.n;
	st->iv_p50 = ps_pct(&v->h_int, 0.50);
	st->iv_p90 = ps_pct(&v->h_int, 0.90);
	st->iv_p99 = ps_pct(&v->h_int, 0.99);
	st->iv_max = v->h_int.maxv;
	st->iv_over = (int)v->h_int.over;
	st->aborted = v->aborted;
	st->pending = v->pending;
}

void vout_close(struct vout *v)
{
	int i;

	if (!v) return;
	q_abort(v);			/* 队列里没上屏的，逐帧回调中止 */
	if (v->prev_valid) {
		v->prev_valid = 0;
		fire(v, &v->prev, VOUT_ABORTED, 0);
	}
	if (v->flips) {
		double dt = v->t_last - v->t_first;

		printf("VOUT: %d flips, %d drops, %d timeouts, %d no-pts, %.2fs = %.2f fps\n",
		       v->flips, v->drops, v->timeouts, v->nopts, dt,
		       dt > 0 ? (v->flips - 1) / dt : 0.0);
		printf("VOUT: queue depth=%d submit=%d shown=%d late=%d(max %.1fms) "
		       "stale=%d miss=%d aborted=%d pending=%d\n",
		       v->qdepth, v->submitted, v->shown, v->late, v->t_late_max,
		       v->stales, v->misses, v->aborted, v->pending);
		/* 间隔的槽位分布就是节拍真相：24fps@60Hz 只该出现在 2/3 槽，
		 * 1 槽 = 有帧被重复扫，>=4 槽 = 漏了槽 */
		ps_print(&v->h_int);
		ps_print(&v->h_late);
	}
	/* 屏上那张不 RMFB：画面停在最后一帧，不闪黑 */
	for (i = 0; i < VOUT_FB_MAX; i++) {
		struct fbc *e = &v->fbc[i];

		if (!e->fb) continue;
		fb_release(v, e, e->fb != v->cur_fb);
	}
	if (v->dfd >= 0) close(v->dfd);
	free(v);
}
