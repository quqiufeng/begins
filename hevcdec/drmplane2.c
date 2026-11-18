/* drmplane — plane 属性探针（libdrm 版）
 *
 * 判据来自 design_player.md §4.1.2：A（缩小 GBM surface + eglSwapBuffers）还是
 * B（dumb buffer 轮转 + SetPlane，能 letterbox），取决于 **primary plane 上有没有
 * IN_FENCE_FD**。裸 ioctl 版的 struct 打包一路 EFAULT/ENOENT，改用 libdrm ——
 * glout.c 的 pick_primary_plane() 早就用 drmModeGetPlaneResources/GetPlane/
 * ObjectGetProperties 跑通了，没理由在这上面重新踩坑。
 *
 * 输出每个 plane：类型、格式表、以及全部属性名=当前值。
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(void)
{
	drmModePlaneRes *pr;
	drmModeRes *res;
	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	unsigned i;

	if (fd < 0) { perror("open card0"); return 1; }
	drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	printf("atomic 能力: %s\n",
	       drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1) == 0 ? "有" : "无");

	res = drmModeGetResources(fd);
	pr = drmModeGetPlaneResources(fd);
	if (!pr) { perror("planes"); return 1; }
	printf("crtcs=%d conns=%d planes=%u\n", res ? res->count_crtcs : -1,
	       res ? res->count_connectors : -1, pr->count_planes);

	for (i = 0; i < pr->count_planes; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
		drmModeObjectProperties *op;
		uint32_t k;
		const char *type = "?";

		if (!p) continue;
		op = drmModeObjectGetProperties(fd, p->plane_id,
						DRM_MODE_OBJECT_PLANE);
		printf("\nplane %u  crtc=%u fb=%u possible_crtcs=0x%x\n",
		       p->plane_id, p->crtc_id, p->fb_id, p->possible_crtcs);
		printf("  formats:");
		for (k = 0; k < p->count_formats; k++) {
			uint32_t f = p->formats[k];
			printf(" %c%c%c%c", f & 0xff, (f >> 8) & 0xff,
			       (f >> 16) & 0xff, (f >> 24) & 0xff);
		}
		printf("\n");
		for (k = 0; op && k < op->count_props; k++) {
			drmModePropertyRes *pd =
				drmModeGetProperty(fd, op->props[k]);
			if (!pd) continue;
			printf("  %-20s = %llu", pd->name,
			       (unsigned long long)op->prop_values[k]);
			if (!strcmp(pd->name, "type") && pd->count_enums == 0) {
			}
			/* type 是枚举属性：值要翻成 Primary/Overlay/Cursor */
			if (!strcmp(pd->name, "type"))
				for (unsigned e = 0; e < pd->count_enums; e++)
					if ((uint64_t)pd->enums[e].value ==
					    op->prop_values[k])
						type = pd->enums[e].name;
			drmModeFreeProperty(pd);
		}
		printf("\n  → 类型=%s\n", strdup(type));
		if (op) drmModeFreeObjectProperties(op);
		drmModeFreePlane(p);
	}
	drmModeFreePlaneResources(pr);
	drmModeFreeResources(res);
	return 0;
}
