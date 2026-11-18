/* scaletest — 这块 meson 的 primary plane 到底能不能缩放？
 *
 * 背景：把 GL 渲染目标缩到源分辨率、放大交给 DPU（design_player.md §4.1 形态 A）
 * 在播放器里第一次 drmModeSetCrtc 就报 ENOSPC。到底是「这个驱动不做缩放」还是
 * 「legacy SetCrtc 的小 fb 走不通」，必须分开验：
 *
 *   1. plane 40 + 1280x720 fb + dest 1280x720   → 平面本身能不能挂
 *   2. plane 40 + 1280x720 fb + dest 1920x1080  → 能不能放大
 *   3. 同上的缩小方向 640x360 → 1920x1080        → 能不能缩小
 *
 * 测试完把原来那张 fb（SetCrtc 之前的）恢复回去，别把屏幕留在测试图上。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/mman.h>

static int fd;
static uint32_t crtc_id, conn_id, plane_id, save_fb;
static drmModeModeInfo save_mode;
static drmModeCrtc *save_crtc;

static uint32_t mk_fb(unsigned w, unsigned h)
{
	struct drm_mode_create_dumb cd = {0};
	uint32_t fb = 0;
	void *map;

	cd.width = w; cd.height = h; cd.bpp = 32;
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
		printf("  create_dumb %ux%u 失败: %s\n", w, h, strerror(errno));
		return 0;
	}
	if (drmModeAddFB(fd, w, h, 24, 32, cd.pitch, cd.handle, &fb)) {
		printf("  addfb %ux%u 失败: %s\n", w, h, strerror(errno));
		return 0;
	}
	/* 填个渐变，屏幕上能看出是不是真的在缩放 */
	{
		struct drm_mode_map_dumb md = {0};

		md.handle = cd.handle;
		if (!drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
			map = mmap(0, cd.size, PROT_READ | PROT_WRITE,
				   MAP_SHARED, fd, md.offset);
			if (map != MAP_FAILED) {
				unsigned x, y;
				uint32_t *p = map;

				for (y = 0; y < h; y++)
					for (x = 0; x < w; x++)
						p[y * (cd.pitch / 4) + x] =
							(x * 255 / w) |
							((y * 255 / h) << 8) |
							((x ^ y) & 0xff) << 16;
				munmap(map, cd.size);
			}
		}
	}
	printf("  fb %ux%u → id=%u pitch=%u\n", w, h, fb, cd.pitch);
	return fb;
}

/* 一次缩放尝试：src 用整张，dest 给 w2 x h2 */
static void try_scale(uint32_t fb, unsigned w, unsigned h, int x, int y,
		      unsigned w2, unsigned h2, const char *what)
{
	int ret = drmModeSetPlane(fd, plane_id, crtc_id, fb, 0, x, y, w2, h2,
				  0, 0, (uint64_t)w << 16, (uint64_t)h << 16);

	printf("%-28s %ux%u → %ux%u : %s", what, w, h, w2, h2,
	       ret ? strerror(errno) : "成功\n");
	if (ret) printf("\n");
}

int main(void)
{
	drmModePlaneRes *pr;
	drmModeRes *res;
	uint32_t fb720, fb360, fb1080;
	unsigned i, pid = 0;

	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("card0"); return 1; }
	drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);
	res = drmModeGetResources(fd);
	pr = drmModeGetPlaneResources(fd);
	if (!res || !pr) return 1;
	/* 当前 CRTC/connector（正在用的那个） */
	save_crtc = drmModeGetCrtc(fd, res->crtcs[0]);
	if (!save_crtc) return 1;
	crtc_id = save_crtc->crtc_id;
	save_fb = save_crtc->buffer_id;
	save_mode = save_crtc->mode;
	conn_id = res->connectors[0];
	printf("crtc=%u fb=%u mode=%ux%u\n", crtc_id, save_fb,
	       save_mode.hdisplay, save_mode.vdisplay);
	/* primary plane */
	for (i = 0; i < pr->count_planes; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
		drmModeObjectProperties *op;
		uint32_t k;

		if (!p) continue;
		op = drmModeObjectGetProperties(fd, p->plane_id,
						DRM_MODE_OBJECT_PLANE);
		for (k = 0; op && k < op->count_props; k++) {
			drmModePropertyRes *pd = drmModeGetProperty(fd, op->props[k]);

			if (pd && !strcmp(pd->name, "type") &&
			    op->prop_values[k] == DRM_PLANE_TYPE_PRIMARY)
				pid = p->plane_id;
			if (pd) drmModeFreeProperty(pd);
		}
		if (op) drmModeFreeObjectProperties(op);
		drmModeFreePlane(p);
	}
	if (!pid) { printf("找不到 primary plane\n"); return 1; }
	plane_id = pid;
	printf("primary plane=%u\n", plane_id);

	fb720 = mk_fb(1280, 720);
	fb360 = mk_fb(640, 360);
	fb1080 = mk_fb(1920, 1080);
	if (!fb720 || !fb360 || !fb1080) return 1;

	try_scale(fb720, 1280, 720, 0, 0, 1280, 720, "1) 1:1 挂上去");
	try_scale(fb720, 1280, 720, 0, 0, 1920, 1080, "2) 放大 1.5x");
	try_scale(fb720, 1280, 720, 0, 0, 1680, 960, "3) 放大 + 居中偏移");
	try_scale(fb360, 640, 360, 0, 0, 1920, 1080, "4) 放大 3x");
	try_scale(fb1080, 1920, 1080, 0, 0, 1920, 1080, "5) 全屏 1:1（对照）");
	try_scale(fb1080, 1920, 1080, 0, 0, 960, 540, "6) 缩小 0.5x");

	/* 恢复：塞回原来的 fb */
	{
		int ret = drmModeSetCrtc(fd, crtc_id, save_fb, 0, 0, &conn_id, 1,
					 &save_mode);

		printf("\n恢复原 fb: %s\n", ret ? strerror(errno) : "成功");
	}
	return 0;
}
