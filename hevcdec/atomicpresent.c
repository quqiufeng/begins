/* atomicpresent — 上屏能不能走 atomic commit（含 DPU 放大）？
 *
 * 背景（design_player.md §4.1.5）：这块 meson 上 legacy SetCrtc/PageFlip 拿
 * 「比 mode 小的 fb」直接 ENOSPC，所以「渲染目标缩到源分辨率 + DPU 放大」这条
 * 路在 legacy 上根本不成立；而 drmModeSetPlane(dst=整屏) 放大是成功的。
 * 还差一步验收：**atomic commit** 同一件事行不行，以及它比 PageFlip 贵多少。
 *
 * 这个探针只回答四个问题，每个都打印硬数据：
 *   1. atomic modeset 初始化（ACTIVE+MODE_ID+conn CRTC_ID+plane 全套）能不能过
 *   2. 之后只改 FB_ID 的 atomic flip 能不能过；小 fb + CRTC_W/H=整屏 是不是
 *      等价于 DPU 放大（同一张 720p 渐变，屏幕上应该铺满）
 *   3. flip 事件还发不发（glout 的 flip 记账依赖它），一次 commit 的
 *      调用耗时 / 到 flip 事件的时延各多少
 *   4. OUT_FENCE_PTR 拿不拿得到 fence，IN_FENCE_FD 传 -1 是否被接受
 *      （真正"未 signal"的 fence 留给 glout 用 EGL native fence 验）
 *
 * 跑完恢复原 fb + 原 mode，别把屏幕留在测试图上。
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/mman.h>

static int fd;
static uint32_t crtc_id, conn_id, plane_id;
static drmModeModeInfo mode;
static uint32_t save_fb;
static drmModeCrtc *save_crtc;

static uint64_t p_fb_id, p_crtc_id, p_src_x, p_src_y, p_src_w, p_src_h;
static uint64_t p_dst_x, p_dst_y, p_dst_w, p_dst_h, p_in_fence;
static uint64_t c_active, c_mode_id, c_out_fence;
static uint64_t n_crtc_id;
static uint32_t mode_blob;

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name,
			uint64_t *val)
{
	drmModeObjectProperties *op = drmModeObjectGetProperties(fd, obj, type);
	uint32_t k, id = 0;

	if (!op) return 0;
	for (k = 0; k < op->count_props; k++) {
		drmModePropertyRes *pd = drmModeGetProperty(fd, op->props[k]);

		if (!pd) continue;
		if (!strcmp(pd->name, name)) {
			id = pd->prop_id;
			if (val) *val = op->prop_values[k];
		}
		drmModeFreeProperty(pd);
		if (id) break;
	}
	drmModeFreeObjectProperties(op);
	return id;
}

static uint32_t mk_fb(unsigned w, unsigned h, const char *tag)
{
	struct drm_mode_create_dumb cd = {0};
	uint32_t fb = 0;

	cd.width = w; cd.height = h; cd.bpp = 32;
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
		printf("  create_dumb %ux%u 失败: %s\n", w, h, strerror(errno));
		return 0;
	}
	if (drmModeAddFB(fd, w, h, 24, 32, cd.pitch, cd.handle, &fb)) {
		printf("  addfb %ux%u 失败: %s\n", w, h, strerror(errno));
		return 0;
	}
	{
		struct drm_mode_map_dumb md = {0};

		md.handle = cd.handle;
		if (!drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
			void *map = mmap(0, cd.size, PROT_READ | PROT_WRITE,
					 MAP_SHARED, fd, md.offset);

			if (map != MAP_FAILED) {
				uint32_t *p = map;
				unsigned x, y;

				for (y = 0; y < h; y++)
					for (x = 0; x < w; x++)
						p[y * (cd.pitch / 4) + x] =
							(x * 255 / w) |
							((y * 255 / h) << 8) |
							(((x ^ y) & 0x3f) << 16);
				munmap(map, cd.size);
			}
		}
	}
	printf("  fb %ux%u (%s) id=%u pitch=%u\n", w, h, tag, fb, cd.pitch);
	return fb;
}

static int flip_seen;
static drmEventContext g_ev;	/* wait_event 里要用，drmHandleEvent 不接受 NULL */
static void flip_handler(int f, unsigned seq, unsigned sec, unsigned usec,
			 void *data)
{
	flip_seen = 1;
	(void)f; (void)sec; (void)usec; (void)data;
}

static double wait_event(int ms)
{
	double t0 = now_s();
	struct timeval tv = {ms / 1000, (ms % 1000) * 1000};
	fd_set fds;

	FD_ZERO(&fds);
	FD_SET(fd, &fds);
	if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0) return -1;
	drmHandleEvent(fd, &g_ev);	/* 事件全在 drmEventContext 里 */
	return now_s() - t0;
}

/* 填一次单平面 commit 的属性（src 取满 w<<16 x h<<16，dst 铺满 CRTC）；
 * 只填不提交，提交由调用方给 flags（modeset 要多一个 ALLOW_MODESET）。 */
static void fill_plane(drmModeAtomicReq *req, uint32_t fb, unsigned w,
		       unsigned h, unsigned dw, unsigned dh, int *out_fence_fd)
{
	drmModeAtomicAddProperty(req, plane_id, p_fb_id, fb);
	drmModeAtomicAddProperty(req, plane_id, p_crtc_id, crtc_id);
	drmModeAtomicAddProperty(req, plane_id, p_src_x, 0);
	drmModeAtomicAddProperty(req, plane_id, p_src_y, 0);
	drmModeAtomicAddProperty(req, plane_id, p_src_w, (uint64_t)w << 16);
	drmModeAtomicAddProperty(req, plane_id, p_src_h, (uint64_t)h << 16);
	drmModeAtomicAddProperty(req, plane_id, p_dst_x, 0);
	drmModeAtomicAddProperty(req, plane_id, p_dst_y, 0);
	drmModeAtomicAddProperty(req, plane_id, p_dst_w, dw);
	drmModeAtomicAddProperty(req, plane_id, p_dst_h, dh);
	if (p_in_fence)
		drmModeAtomicAddProperty(req, plane_id, p_in_fence, -1);
	if (c_out_fence && out_fence_fd) {
		*out_fence_fd = -1;
		drmModeAtomicAddProperty(req, crtc_id, c_out_fence,
					 (uint64_t)(uintptr_t)out_fence_fd);
	}
}

int main(void)
{
	drmModeRes *res;
	drmModePlaneRes *pr;
	uint32_t fb720, fb1080, i;
	double t0, t1;
	int dret = 0;

	g_ev.version = 2;
	g_ev.page_flip_handler = flip_handler;

	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("card0"); return 1; }
	drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
		printf("atomic 不可用: %s\n", strerror(errno));
		return 1;
	}
	res = drmModeGetResources(fd);
	pr = drmModeGetPlaneResources(fd);
	if (!res || !pr) { perror("resources"); return 1; }

	save_crtc = drmModeGetCrtc(fd, res->crtcs[0]);
	if (!save_crtc) { perror("getcrtc"); return 1; }
	crtc_id = save_crtc->crtc_id;
	save_fb = save_crtc->buffer_id;
	mode = save_crtc->mode;
	conn_id = res->connectors[0];
	printf("crtc=%u conn=%u fb=%u mode=%ux%u@%u\n", crtc_id, conn_id,
	       save_fb, mode.hdisplay, mode.vdisplay, mode.vrefresh);

	/* primary plane：possible_crtcs 得覆盖这个 crtc */
	for (i = 0; i < pr->count_planes && !plane_id; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
		uint64_t ty = 0;
		uint32_t id;

		if (!p) continue;
		id = prop_id(p->plane_id, DRM_MODE_OBJECT_PLANE, "type", &ty);
		if (id && ty == DRM_PLANE_TYPE_PRIMARY)
			plane_id = p->plane_id;
		drmModeFreePlane(p);
	}
	if (!plane_id) { printf("找不到 primary plane\n"); return 1; }

	p_fb_id   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", NULL);
	p_crtc_id = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", NULL);
	p_src_x   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X", NULL);
	p_src_y   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y", NULL);
	p_src_w   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W", NULL);
	p_src_h   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H", NULL);
	p_dst_x   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X", NULL);
	p_dst_y   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y", NULL);
	p_dst_w   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W", NULL);
	p_dst_h   = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H", NULL);
	p_in_fence = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "IN_FENCE_FD", NULL);
	c_active  = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE", NULL);
	c_mode_id = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID", NULL);
	c_out_fence = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "OUT_FENCE_PTR", NULL);
	n_crtc_id = prop_id(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", NULL);
	printf("primary=%u  props: fb=%u crtc=%u src_w=%u dst_w=%u in_fence=%u "
	       "| crtc active=%u mode=%u outfence=%u | conn crtc=%u\n",
	       plane_id, (unsigned)p_fb_id, (unsigned)p_crtc_id,
	       (unsigned)p_src_w, (unsigned)p_dst_w, (unsigned)p_in_fence,
	       (unsigned)c_active, (unsigned)c_mode_id,
	       (unsigned)c_out_fence, (unsigned)n_crtc_id);
	if (!p_fb_id || !c_mode_id || !n_crtc_id) {
		printf("属性不全，atomic 这条走不通\n");
		return 1;
	}

	fb1080 = mk_fb(mode.hdisplay, mode.vdisplay, "整屏");
	fb720 = mk_fb(1280, 720, "720p");
	if (!fb720 || !fb1080) return 1;

	/* 1) atomic modeset 初始化：ACTIVE + MODE_ID + conn CRTC_ID + plane 全套 */
	if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &mode_blob)) {
		perror("mode blob");
		return 1;
	}
	{
		drmModeAtomicReq *req = drmModeAtomicAlloc();
		int ofd = -1;

		drmModeAtomicAddProperty(req, conn_id, n_crtc_id, crtc_id);
		drmModeAtomicAddProperty(req, crtc_id, c_active, 1);
		drmModeAtomicAddProperty(req, crtc_id, c_mode_id, mode_blob);
		fill_plane(req, fb1080, mode.hdisplay, mode.vdisplay,
			   mode.hdisplay, mode.vdisplay, &ofd);
		flip_seen = 0;
		t0 = now_s();
		dret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET |
					  DRM_MODE_PAGE_FLIP_EVENT |
					  DRM_MODE_ATOMIC_NONBLOCK, NULL);
		t1 = now_s();
		printf("1) atomic modeset 1080p : %s  commit=%.3fms",
		       dret ? strerror(errno) : "成功", (t1 - t0) * 1000.0);
		if (!dret) {
			double w = wait_event(200);

			printf("  flip事件=%s%s", flip_seen ? "有" : "无",
			       w >= 0 ? "" : "(超时)");
			printf("  等待=%.2fms  out_fence=%d\n",
			       w >= 0 ? w * 1000.0 : -1, ofd);
			if (ofd >= 0) close(ofd);
			sleep(1);
		} else {
			printf("\n");
		}
		drmModeAtomicFree(req);
	}

	/* 2) 只改 FB_ID 的 flip；顺便试 720p→整屏放大 */
	{
		struct { uint32_t fb; unsigned w, h; const char *what; } seq[] = {
			{ fb720, 1280, 720,  "720p fb → 整屏(放大 1.5x)" },
			{ fb1080, 1920, 1080, "1080p fb → 整屏(1:1)" },
		};
		unsigned s;

		for (s = 0; s < 2; s++) {
			drmModeAtomicReq *req = drmModeAtomicAlloc();
			int ofd = -1;
			double tw;

			fill_plane(req, seq[s].fb, seq[s].w, seq[s].h,
				     mode.hdisplay, mode.vdisplay, &ofd);
			flip_seen = 0;
			t0 = now_s();
			dret = drmModeAtomicCommit(fd, req,
						   DRM_MODE_ATOMIC_NONBLOCK |
						   DRM_MODE_PAGE_FLIP_EVENT, NULL);
			t1 = now_s();
			printf("2.%u) %s : %s commit=%.3fms",
			       s + 1, seq[s].what,
			       dret ? strerror(errno) : "成功", (t1 - t0) * 1000.0);
			if (!dret) {
				tw = wait_event(200);
				printf("  flip=%s 时延=%.2fms out_fence=%d\n",
				       flip_seen ? "有" : "无", tw * 1000.0, ofd);
				if (ofd >= 0) close(ofd);
			} else {
				printf("\n");
			}
			drmModeAtomicFree(req);
			usleep(500000);
		}
	}

	/* 3) 连打 120 帧（720p fb 放大），量提交节拍与掉帧 */
	{
		int n = 120, miss = 0, err = 0, k;
		double t_start = now_s(), t_sum = 0, t_max = 0;

		for (k = 0; k < n; k++) {
			drmModeAtomicReq *req = drmModeAtomicAlloc();
			double c0, c1;
			int ofd = -1;

			fill_plane(req, fb720, 1280, 720, mode.hdisplay,
				     mode.vdisplay, &ofd);
			flip_seen = 0;
			c0 = now_s();
			dret = drmModeAtomicCommit(fd, req,
						   DRM_MODE_ATOMIC_NONBLOCK |
						   DRM_MODE_PAGE_FLIP_EVENT, NULL);
			c1 = now_s();
			drmModeAtomicFree(req);
			if (dret) { err++; usleep(2000); continue; }
			if (ofd >= 0) close(ofd);
			if (wait_event(200) < 0 || !flip_seen) miss++;
			t_sum += c1 - c0;
			if (c1 - c0 > t_max) t_max = c1 - c0;
			/* 按 60Hz 节拍走，模拟播放器的提交节奏 */
			{
				double want = t_start + (k + 1) / 60.0;
				double rest = want - now_s();

				if (rest > 0) usleep((useconds_t)(rest * 1e6));
			}
		}
		printf("3) 连打 %d 帧: 失败 %d / 无 flip 事件 %d / commit 均 %.3fms "
		       "峰 %.3fms / 实际 %.2f fps\n",
		       n, err, miss, t_sum / (n ? n : 1) * 1000.0, t_max * 1000.0,
		       n / (now_s() - t_start));
	}

	/* 恢复 */
	{
		drmModeAtomicReq *req = drmModeAtomicAlloc();

		drmModeAtomicAddProperty(req, conn_id, n_crtc_id, crtc_id);
		drmModeAtomicAddProperty(req, crtc_id, c_active, 1);
		drmModeAtomicAddProperty(req, crtc_id, c_mode_id, mode_blob);
		fill_plane(req, save_fb, mode.hdisplay, mode.vdisplay,
			     mode.hdisplay, mode.vdisplay, NULL);
		dret = drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET,
					   NULL);
		printf("恢复原 fb: %s\n", dret ? strerror(errno) : "成功");
		drmModeAtomicFree(req);
	}
	drmModeDestroyPropertyBlob(fd, mode_blob);
	drmModeFreePlaneResources(pr);
	drmModeFreeResources(res);
	return 0;
}
