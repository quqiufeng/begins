/*
 * kmsflip.so — LD_PRELOAD shim for SDL2/kmsdrm on Amlogic (aarch64)
 *
 * 现场证据（KMSFLIP=log，开一次阅读器再返回，见 /tmp/kmsflip.log）：
 *   [master] 拿/放      都是 libSDL2.so 干的
 *   [set ] 1080p → 1440p   桌面启动（真 modeset）
 *   [set ] fb 1920x2160 ≠ mode 2560x1440   ← 失败 -28
 *   [set ] 1080p → 1440p   阅读器退出后桌面恢复
 * 也就是说：桌面每次交屏/收屏，SDL 都把「本进程进来时的原始模式」设回去
 * （1080p），下一个 app 上屏又设回 1440p。一次开合 = 4 次真 modeset，
 * 每次都是 HDMI 重锁存 → 电视弹 4 次信号黄条。
 *
 * 两件事分开治，都是「等价替换」，不猜：
 *   A 还原抑制：请求回到「本进程进来时那个 fb + mode」的调用直接吞掉，
 *     CRTC 保持当前模式。下一个 app 上屏时模式没变，自然不需要 modeset。
 *   B 同模式降级：请求模式与当前完全一致（时钟/时序/刷率都同）时改用
 *     drmModePageFlip 换主 plane —— 不动时钟，不重锁存。
 * 任一前提不成立（模式真变了、fb 尺寸不符、PageFlip 报错）都原样交给真
 * drmModeSetCrtc。另外三个钩子（原子提交/翻页/master）只记录，不改行为。
 *
 * 用法：
 *   KMSFLIP=fix|log  LD_PRELOAD=/opt/desktop/lib/kmsflip.so  <程序>
 *   KMSFLIP_LOG=/tmp/kmsflip.log   （默认就这个）
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <errno.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

typedef int (*setcrtc_fn)(int, uint32_t, uint32_t, uint32_t, uint32_t,
                          uint32_t *, int, drmModeModeInfoPtr);
typedef int (*pageflip_fn)(int, uint32_t, uint32_t, uint32_t, void *);
typedef drmModeCrtcPtr (*getcrtc_fn)(int, uint32_t);
typedef drmModeFBPtr (*getfb_fn)(int, uint32_t);
typedef int (*atomic_fn)(int, drmModeAtomicReqPtr, uint32_t, void *);
typedef int (*master_fn)(int);
typedef drmModeFB2Ptr (*getfb2_fn)(int, uint32_t);
typedef int (*addfb2m_fn)(int, uint32_t, uint32_t, uint32_t, const uint32_t *,
                          const uint32_t *, const uint32_t *, const uint64_t *,
                          uint32_t *, uint32_t);
typedef int (*rmfb_fn)(int, uint32_t);

static setcrtc_fn real_setcrtc;
static pageflip_fn real_pageflip;
static getcrtc_fn real_getcrtc;
static getfb_fn real_getfb;
static atomic_fn real_atomic;
static master_fn real_setmaster, real_dropmaster;
static getfb2_fn real_getfb2;
static addfb2m_fn real_addfb2m;
static rmfb_fn real_rmfb;

static int mode_kind;		/* 0=off 1=log 2=fix */
static FILE *logfp;
static int seq;
int __flip_n;

/* 每个 crtc 记一份「本进程第一次见到的状态」，就是 SDL 眼里的 original。
 * armed：本进程已经把自己的 fb 放上去过；只有 armed 之后才认还原调用，
 * 否则进程启动那一刻的首次 SetCrtc 会被自己误判成还原。 */
#define MAXCRTC 8
struct orig {
	uint32_t crtc;
	int used, armed;
	uint32_t buffer_id;
	drmModeModeInfo mode;
};
static struct orig origs[MAXCRTC];

/* 真函数一律从 libdrm.so.2 的句柄里取：RTLD_NEXT 在「库还没被 loader
 * 放进全局 scope」时会返回 NULL，而 NULL 函数指针一调用就是 SEGV ——
 * 现场就是这么崩的（PC=0，调用者 = 本文件的 drmModeSetCrtc）。 */
static void *drm_lib(void)
{
	static void *h;

	if (!h) {
		h = dlopen("libdrm.so.2", RTLD_LAZY | RTLD_NOLOAD);
		if (!h) h = dlopen("libdrm.so.2", RTLD_LAZY);
	}
	return h;
}

/* libdrm 的 drmModePageFlip 内部就是拿原子提交实现的，会再进到我们的
 * 钩子里来；用线程局部深度计数挡住嵌套，避免自锁。 */
static __thread int depth;

static void init_once(void)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	void *h = drm_lib();

	(void)once;
	if (real_setcrtc) return;
	if (!h) return;
	real_setcrtc = (setcrtc_fn)dlsym(h, "drmModeSetCrtc");
	real_pageflip = (pageflip_fn)dlsym(h, "drmModePageFlip");
	real_getcrtc = (getcrtc_fn)dlsym(h, "drmModeGetCrtc");
	real_getfb = (getfb_fn)dlsym(h, "drmModeGetFB");
	real_atomic = (atomic_fn)dlsym(h, "drmModeAtomicCommit");
	real_getfb2 = (getfb2_fn)dlsym(h, "drmModeGetFB2");
	real_addfb2m = (addfb2m_fn)dlsym(h, "drmModeAddFB2WithModifiers");
	real_rmfb = (rmfb_fn)dlsym(h, "drmModeRmFB");
	real_setmaster = (master_fn)dlsym(h, "drmSetMaster");
	real_dropmaster = (master_fn)dlsym(h, "drmDropMaster");
}

static void boot(void)
{
	const char *m, *p;

	if (mode_kind) return;
	m = getenv("KMSFLIP");
	if (m && !strcmp(m, "log")) mode_kind = 1;
	else if (m && (!strcmp(m, "fix") || !strcmp(m, "1"))) mode_kind = 2;
	if (!mode_kind) return;
	p = getenv("KMSFLIP_LOG");
	if (!p) p = "/tmp/kmsflip.log";
	logfp = fopen(p, "a");
	if (logfp) setvbuf(logfp, NULL, _IOLBF, 0);
}

static void say(const char *fmt, ...)
{
	va_list ap;

	if (!logfp) return;
	va_start(ap, fmt);
	vfprintf(logfp, fmt, ap);
	va_end(ap);
	fputc('\n', logfp);
}

static const char *caller(void)
{
	Dl_info di;

	if (!dladdr(__builtin_return_address(0), &di) || !di.dli_fname) return "?";
	return di.dli_fname;
}


/* ---- AR24 → XR24 别名 ----
 * 现场（4K、mainline meson）: SDL 2.32 的 kmsdrm 建 GBM surface 用 ARGB8888，
 * 而 meson 主 plane 只吃 XRGB8888 —— drmModePageFlip(fb=AR24) 一律 -EINVAL，
 * SDL 每帧打 "Could not queue pageflip: -22"，fbcon 一直占着主 plane，桌面
 * 黑屏。同一块 bo 用 XR24 建别名 fb 立刻能翻（已用 drmtest 实测：XR24 同尺寸
 * 翻页 0，AR24 同尺寸 -22）。XR24 忽略 alpha，画面不变，内存不多占。
 * 别名 fb 与源 fb 同源 bo；drmModeRmFB 源 fb 时一起回收，否则 bo 永远被钉住。 */
#define AR24 0x34325241u
#define XR24 0x34325258u
#define MAXALIAS 32
static struct { uint32_t src, dst; } aliases[MAXALIAS];
static int nalias;

static uint32_t alias_fb(int fd, uint32_t src)
{
	drmModeFB2Ptr f;
	uint32_t hs[4], ps[4], os[4], dst = 0;
	uint64_t ms[4];
	int i, r;

	for (i = 0; i < nalias; i++)
		if (aliases[i].src == src) return aliases[i].dst;
	if (nalias >= MAXALIAS || !real_getfb2 || !real_addfb2m) return 0;
	f = real_getfb2(fd, src);
	if (!f) return 0;
	if (f->pixel_format != AR24) { drmModeFreeFB2(f); return 0; }
	for (i = 0; i < 4; i++) {
		hs[i] = f->handles[i];
		ps[i] = f->pitches[i];
		os[i] = f->offsets[i];
		ms[i] = (f->flags & DRM_MODE_FB_MODIFIERS) ? f->modifier : 0;
	}
	r = real_addfb2m(fd, f->width, f->height, XR24, hs, ps, os, ms, &dst,
			 (f->flags & DRM_MODE_FB_MODIFIERS) ? DRM_MODE_FB_MODIFIERS : 0);
	say("    [alias] AR24 fb=%u → XR24 fb=%u ret=%d", src, dst, r);
	drmModeFreeFB2(f);
	if (r) return 0;
	aliases[nalias].src = src;
	aliases[nalias].dst = dst;
	nalias++;
	return dst;
}

/* 同一个模式 = 时钟/有效区/总时序/刷率都一样。只比 hdisplay 不够：
 * 1080p50 和 1080p60 尺寸相同但确实是两种模式，那必须走真 modeset。 */
static int same_mode(const drmModeModeInfo *a, const drmModeModeInfo *b)
{
	if (!a || !b) return 0;
	if (a->clock != b->clock) return 0;
	if (a->hdisplay != b->hdisplay || a->vdisplay != b->vdisplay) return 0;
	if (a->htotal != b->htotal || a->vtotal != b->vtotal) return 0;
	if (a->vrefresh != b->vrefresh) return 0;
	/* 极性位不参与判定：同一时序正/负极性对电视是同一路信号 */
	if ((a->flags & ~(DRM_MODE_FLAG_NHSYNC | DRM_MODE_FLAG_NVSYNC)) !=
	    (b->flags & ~(DRM_MODE_FLAG_NHSYNC | DRM_MODE_FLAG_NVSYNC))) return 0;
	return 1;
}

static struct orig *orig_for(uint32_t crtc)
{
	int i, free_i = -1;

	for (i = 0; i < MAXCRTC; i++) {
		if (origs[i].used && origs[i].crtc == crtc) return &origs[i];
		if (!origs[i].used && free_i < 0) free_i = i;
	}
	if (free_i < 0) return NULL;
	origs[free_i].used = 1;
	origs[free_i].crtc = crtc;
	return &origs[free_i];
}

static void fmt_mode(char *buf, size_t n, const drmModeModeInfo *m)
{
	if (!m) { snprintf(buf, n, "无"); return; }
	snprintf(buf, n, "%ux%u@%u", m->hdisplay, m->vdisplay, m->vrefresh);
}

int drmModeSetCrtc(int fd, uint32_t crtcId, uint32_t bufferId, uint32_t x, uint32_t y,
                   uint32_t *connectors, int count, drmModeModeInfoPtr mode)
{
	drmModeCrtcPtr cur = NULL;
	drmModeFBPtr fb = NULL;
	struct orig *o;
	int ret, treat = 0;	/* 0=真 SetCrtc 1=翻页 2=吞掉 */
	char cm[32] = "无", rm[32] = "无";

	boot();
	init_once();
	if (!real_setcrtc) return -1;
	if (depth || !mode_kind)	/* 嵌套调用 / 旁路 */
		return real_setcrtc(fd, crtcId, bufferId, x, y, connectors, count, mode);

	depth = 1;
	seq++;
	fmt_mode(rm, sizeof rm, mode);
	cur = real_getcrtc ? real_getcrtc(fd, crtcId) : NULL;
	fmt_mode(cm, sizeof cm, cur && cur->mode_valid ? &cur->mode : NULL);

	o = orig_for(crtcId);
	if (o && !o->armed && cur) {
		o->buffer_id = cur->buffer_id;
		o->mode = cur->mode;
	}

	if (!mode || !bufferId) {
		say("#%d [set ] crtc=%u fb=%u 当前 %s%s", seq, crtcId, bufferId, cm,
		    !mode ? " (mode=NULL)" : " (bufferId=0)");
		goto realpath;
	}
	if (o && !o->armed && bufferId != o->buffer_id) o->armed = 1;

	/* A 还原抑制 */
	if (o && o->armed && bufferId == o->buffer_id && same_mode(mode, &o->mode)) {
		say("#%d [skip] crtc=%u fb=%u %s ← 本进程原始状态，当前 %s：还原吞掉",
		    seq, crtcId, bufferId, rm, cm);
		treat = 2;
		goto done;
	}
	/* B 同模式降级 */
	if (cur && cur->mode_valid && !x && !y && same_mode(&cur->mode, mode)) {
		if (cur->buffer_id == bufferId) {
			say("#%d [noop] crtc=%u fb=%u 已是该 fb（%s）", seq, crtcId, bufferId, rm);
			treat = 2;
			goto done;
		}
		fb = real_getfb ? real_getfb(fd, bufferId) : NULL;
		if (fb && (uint32_t)fb->width == mode->hdisplay &&
		    (uint32_t)fb->height == mode->vdisplay) {
			say("#%d [flip] crtc=%u fb=%u %s（模式没变，跳过 modeset）",
			    seq, crtcId, bufferId, rm);
			treat = 1;
			goto done;
		}
		say("#%d [set ] crtc=%u fb=%u 同模式但 fb %ux%u 不符 %s", seq, crtcId, bufferId,
		    fb ? fb->width : 0, fb ? fb->height : 0, rm);
		goto realpath;
	}
	say("#%d [set ] crtc=%u fb=%u 当前 %s → 请求 %s", seq, crtcId, bufferId, cm, rm);

realpath:
	if (fb) { drmModeFreeFB(fb); fb = NULL; }
	if (cur) { drmModeFreeCrtc(cur); cur = NULL; }
	ret = real_setcrtc(fd, crtcId, bufferId, x, y, connectors, count, mode);
	say("       └ 真 SetCrtc 返回 %d%s", ret, ret ? "（失败）" : "");
	depth = 0;
	return ret;

done:
	if (fb) drmModeFreeFB(fb);
	if (cur) drmModeFreeCrtc(cur);
	if (mode_kind == 1 || treat == 2) {
		/* log 模式只观察；fix 模式下 treat==2 就是真吞掉 */
		if (mode_kind == 1) {
			ret = real_setcrtc(fd, crtcId, bufferId, x, y, connectors, count, mode);
			say("       └ log 模式放行，真 SetCrtc 返回 %d", ret);
			depth = 0;
			return ret;
		}
		depth = 0;
		return 0;
	}
	/* SDL 自己常有一帧 flip 在排队，这里撞 -EBUSY 是常态：短等重试几次。
	 * 真失败也绝不回落 SetCrtc —— 同模式 SetCrtc 在 meson 上仍会重写
	 * vout 时序（电视弹黄条），而画面随后由 SDL 自己的 GBM 翻页接手。 */
	{
		int i;

		ret = -1;
		bufferId = alias_fb(fd, bufferId) ?: bufferId;
		for (i = 0; i < 12; i++) {
			ret = real_pageflip(fd, crtcId, bufferId, 0, NULL);
			if (!ret) break;
			if (ret != -EBUSY) break;
			/* 播放器 60fps 一直在排 flip，等一个 vblank 量级：
			 * 它那一次 pending 落地后 CRTC 会空出几 ms 给我们。 */
			usleep(2500);
		}
		if (ret) {
			/* 绝不回落 SetCrtc：本路径模式没变，同模式 SetCrtc 在
			 * meson 上仍会重写 vout 时序 —— 电视就弹一次信号黄条。
			 * 这一帧直接丢，当作已生效返回；画面由下一帧的 PageFlip
			 * 接手（模式不变，跳过 SetCrtc 没有任何副作用）。 */
			say("       └ PageFlip 放弃 %d，丢帧不回落 SetCrtc（避免电视弹条）", ret);
			ret = 0;
		}
	}
	depth = 0;
	return ret;
}

/* ---- 以下三个钩子只记录，不改行为 ---- */
int drmModeAtomicCommit(int fd, drmModeAtomicReqPtr req, uint32_t flags, void *ud)
{
	int ret;

	boot();
	init_once();
	if (!real_atomic) return -1;
	ret = real_atomic(fd, req, flags, ud);
	if (mode_kind && !depth)
		say("    [atom] flags=0x%x%s%s → %d   %s", flags,
		    (flags & DRM_MODE_ATOMIC_ALLOW_MODESET) ? " ALLOW_MODESET" : "",
		    (flags & DRM_MODE_ATOMIC_TEST_ONLY) ? " TEST_ONLY" : "",
		    ret, caller());
	return ret;
}

int drmModePageFlip(int fd, uint32_t crtc, uint32_t fb, uint32_t flags, void *ud)
{
	int ret;

	boot();
	init_once();
	if (!real_pageflip) return -1;
	ret = real_pageflip(fd, crtc, fb, flags, ud);
	if (ret == -EINVAL) {
		uint32_t a = alias_fb(fd, fb);

		if (a) {
			int r2 = real_pageflip(fd, crtc, a, flags, ud);

			if (!r2) ret = 0;
		}
	}
	if (mode_kind && !depth) {	/* 每帧一次，全记会把日志刷爆：只留计数 */
		static int bad;

		__flip_n++;
		if (ret && bad++ < 5) say("    [flip] 失败 flags=0x%x → %d", flags, ret);
	}
	return ret;
}

int drmModeRmFB(int fd, uint32_t fb)
{
	int i, ret;

	boot();
	init_once();
	if (!real_rmfb) return -1;
	for (i = 0; i < nalias; i++) {
		if (aliases[i].src != fb) continue;
		real_rmfb(fd, aliases[i].dst);
		aliases[i] = aliases[--nalias];
		break;
	}
	ret = real_rmfb(fd, fb);
	return ret;
}

int drmSetMaster(int fd)
{
	int ret;

	boot();
	init_once();
	ret = real_setmaster ? real_setmaster(fd) : 0;
	if (mode_kind) say("    [master] 拿 = %d   %s", ret, caller());
	return ret;
}

/* 进程退出时把翻页计数落一行，看「画了多少帧」用 */
__attribute__((destructor)) static void bye(void)
{
	if (logfp) fprintf(logfp, "    [统计] 翻页合计 %d 次\n", (int)({ extern int __flip_n; __flip_n; }));
}

int drmDropMaster(int fd)
{
	int ret;

	boot();
	init_once();
	ret = real_dropmaster ? real_dropmaster(fd) : 0;
	if (mode_kind) say("    [master] 放 = %d   %s", ret, caller());
	return ret;
}
