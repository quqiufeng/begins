/* atomicms — atomic modeset 到底能不能做？（承 atomicpresent 的 §1 失败）
 *
 * atomicpresent 的结论：只改平面属性的 atomic commit 完全可用（720p fb →
 * 整屏放大成功、flip 事件有、commit 43µs）；但凡是带 ALLOW_MODESET 的
 * commit（初始化 + 恢复）一律 EINVAL。差别只有 flags，所以要么是
 * 「meson-drm 不支持 atomic modeset」，要么是「我们的 modeset 请求写漏了」。
 *
 * 逐个变量试，每次都打印 errno：
 *   0. 弄清这个 crtc 真正接的是哪个 connector（不能瞎用 connectors[0]）
 *   1. TEST_ONLY + ALLOW_MODESET       → 只校验，不改屏，最快暴露 EINVAL 来源
 *   2. TEST_ONLY 全套（含 MODE_ID/ACTIVE/conn CRTC_ID）
 *   3. 真 modeset（阻塞、ALLOW_MODESET）
 *   4. ACTIVE=0 关屏，再 ACTIVE=1 + MODE_ID 开回来
 *   5. 最后恢复原 fb / 原 mode
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static int fd;
static uint32_t crtc_id, conn_id, plane_id, mode_blob;
static drmModeModeInfo mode;
static uint32_t save_fb;
static uint64_t p_fb, p_crtc, p_sx, p_sy, p_sw, p_sh, p_dx, p_dy, p_dw, p_dh;
static uint64_t c_active, c_mode, n_crtc;

static uint32_t prop_id(uint32_t obj, uint32_t type, const char *name)
{
	drmModeObjectProperties *op = drmModeObjectGetProperties(fd, obj, type);
	uint32_t k, id = 0;

	if (!op) return 0;
	for (k = 0; k < op->count_props; k++) {
		drmModePropertyRes *pd = drmModeGetProperty(fd, op->props[k]);

		if (pd && !strcmp(pd->name, name)) id = pd->prop_id;
		if (pd) drmModeFreeProperty(pd);
		if (id) break;
	}
	drmModeFreeObjectProperties(op);
	return id;
}

static void fill(drmModeAtomicReq *r, uint32_t fb, unsigned w, unsigned h,
		 unsigned dw, unsigned dh, int full)
{
	if (full) {
		drmModeAtomicAddProperty(r, conn_id, n_crtc, crtc_id);
		drmModeAtomicAddProperty(r, crtc_id, c_active, 1);
		drmModeAtomicAddProperty(r, crtc_id, c_mode, mode_blob);
	}
	drmModeAtomicAddProperty(r, plane_id, p_fb, fb);
	drmModeAtomicAddProperty(r, plane_id, p_crtc, crtc_id);
	drmModeAtomicAddProperty(r, plane_id, p_sx, 0);
	drmModeAtomicAddProperty(r, plane_id, p_sy, 0);
	drmModeAtomicAddProperty(r, plane_id, p_sw, (uint64_t)w << 16);
	drmModeAtomicAddProperty(r, plane_id, p_sh, (uint64_t)h << 16);
	drmModeAtomicAddProperty(r, plane_id, p_dx, 0);
	drmModeAtomicAddProperty(r, plane_id, p_dy, 0);
	drmModeAtomicAddProperty(r, plane_id, p_dw, dw);
	drmModeAtomicAddProperty(r, plane_id, p_dh, dh);
}

static uint32_t mk_fb(unsigned w, unsigned h)
{
	struct drm_mode_create_dumb cd = {0};
	uint32_t fb = 0;

	cd.width = w; cd.height = h; cd.bpp = 32;
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) return 0;
	if (drmModeAddFB(fd, w, h, 24, 32, cd.pitch, cd.handle, &fb)) return 0;
	return fb;
}

static void try(const char *what, uint32_t fb, unsigned w, unsigned h,
		int full, uint32_t flags)
{
	drmModeAtomicReq *r = drmModeAtomicAlloc();
	int ret;

	fill(r, fb, w, h, 1920, 1080, full);
	errno = 0;
	ret = drmModeAtomicCommit(fd, r, flags, NULL);
	printf("%-52s %s\n", what, ret ? strerror(errno) : "成功");
	drmModeAtomicFree(r);
}

int main(void)
{
	drmModeRes *res;
	drmModePlaneRes *pr;
	uint32_t fb1080, fb720, i;

	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("card0"); return 1; }
	drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
		perror("atomic cap");
		return 1;
	}
	res = drmModeGetResources(fd);
	pr = drmModeGetPlaneResources(fd);
	if (!res || !pr) { perror("res"); return 1; }
	{
		drmModeCrtc *c = drmModeGetCrtc(fd, res->crtcs[0]);

		if (!c) { perror("getcrtc"); return 1; }
		crtc_id = c->crtc_id;
		save_fb = c->buffer_id;
		mode = c->mode;
		drmModeFreeCrtc(c);
	}

	/* 0. 这个 crtc 上挂着哪个 connector？ */
	for (i = 0; i < (uint32_t)res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
		uint32_t crtc = 0;

		if (!c) continue;
		if (c->encoder_id) {
			drmModeEncoder *e = drmModeGetEncoder(fd, c->encoder_id);

			if (e) { crtc = e->crtc_id; drmModeFreeEncoder(e); }
		}
		printf("connector %u type=%u 连接=%s encoder=%u crtc=%u modes=%d%s\n",
		       c->connector_id, c->connector_type,
		       c->connection == DRM_MODE_CONNECTED ? "是" : "否",
		       c->encoder_id, crtc, c->count_modes,
		       crtc == crtc_id ? "  ← 就是它" : "");
		if (crtc == crtc_id) conn_id = c->connector_id;
		drmModeFreeConnector(c);
	}
	if (!conn_id) { printf("没找到接在 crtc %u 上的 connector\n", crtc_id); return 1; }
	printf("用 crtc=%u conn=%u fb=%u mode=%ux%u\n", crtc_id, conn_id, save_fb,
	       mode.hdisplay, mode.vdisplay);

	for (i = 0; i < pr->count_planes && !plane_id; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
		uint64_t ty = 0;
		uint32_t id;

		if (!p) continue;
		id = prop_id(p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
		if (id) {
			drmModeObjectProperties *op =
				drmModeObjectGetProperties(fd, p->plane_id,
							   DRM_MODE_OBJECT_PLANE);
			uint32_t k;

			for (k = 0; op && k < op->count_props; k++)
				if (op->props[k] == id)
					ty = op->prop_values[k];
			if (op) drmModeFreeObjectProperties(op);
		}
		if (ty == DRM_PLANE_TYPE_PRIMARY) plane_id = p->plane_id;
		drmModeFreePlane(p);
	}
	if (!plane_id) { printf("没有 primary plane\n"); return 1; }

	p_fb = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID");
	p_crtc = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID");
	p_sx = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_X");
	p_sy = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_Y");
	p_sw = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_W");
	p_sh = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "SRC_H");
	p_dx = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X");
	p_dy = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y");
	p_dw = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_W");
	p_dh = prop_id(plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_H");
	c_active = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE");
	c_mode = prop_id(crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID");
	n_crtc = prop_id(conn_id, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID");
	printf("plane=%u props fb=%u src=%u/%u dst=%u/%u | crtc act=%u mode=%u | "
	       "conn crtc=%u\n", plane_id, (unsigned)p_fb, (unsigned)p_sw,
	       (unsigned)p_sh, (unsigned)p_dw, (unsigned)p_dh,
	       (unsigned)c_active, (unsigned)c_mode, (unsigned)n_crtc);
	if (!p_fb || !c_mode || !n_crtc) { printf("属性不全\n"); return 1; }

	mode_blob = 0;
	if (drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &mode_blob)) {
		perror("mode blob");
		return 1;
	}
	fb1080 = mk_fb(1920, 1080);
	fb720 = mk_fb(1280, 720);
	if (!fb1080 || !fb720) return 1;

	/* 1/2. TEST_ONLY 只校验 */
	try("1) TEST_ONLY 平面属性（不 modeset）", fb720, 1280, 720, 0,
	    DRM_MODE_ATOMIC_TEST_ONLY);
	try("2) TEST_ONLY 全套 + ALLOW_MODESET", fb1080, 1920, 1080, 1,
	    DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET);
	try("3) TEST_ONLY 全套，不给 ALLOW_MODESET", fb1080, 1920, 1080, 1,
	    DRM_MODE_ATOMIC_TEST_ONLY);
	/* 4. 真 modeset */
	try("4) 真 modeset（阻塞 ALLOW_MODESET）", fb1080, 1920, 1080, 1,
	    DRM_MODE_ATOMIC_ALLOW_MODESET);
	/* 5. 关屏再开 */
	{
		drmModeAtomicReq *r = drmModeAtomicAlloc();
		int ret;

		drmModeAtomicAddProperty(r, crtc_id, c_active, 0);
		ret = drmModeAtomicCommit(fd, r, DRM_MODE_ATOMIC_ALLOW_MODESET, NULL);
		printf("%-52s %s\n", "5) ACTIVE=0 关屏", ret ? strerror(errno) : "成功");
		drmModeAtomicFree(r);
		usleep(300000);
	}
	try("6) 关屏后再 modeset 开回来", fb1080, 1920, 1080, 1,
	    DRM_MODE_ATOMIC_ALLOW_MODESET);
	/* 7. 恢复成原来的 fb（平面属性即可，mode 已经对了） */
	try("7) 平面属性恢复原 fb", save_fb, mode.hdisplay, mode.vdisplay, 0, 0);
	drmModeDestroyPropertyBlob(fd, mode_blob);
	drmModeFreePlaneResources(pr);
	drmModeFreeResources(res);
	return 0;
}
