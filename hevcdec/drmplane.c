/* drmplane — 枚举 card0 上每个 plane 的格式表 + 全部属性（名和当前值）
 *
 * 为什么单独一个：§4.1.2 的 A/B 两条落地形态，判据是「primary plane 上有没有
 * IN_FENCE_FD」——有才可能不靠 glFinish 做 atomic 直提（B：dumb buffer 轮转 +
 * SetPlane 保留 letterbox）；没有就只能缩小 GBM surface 走 eglSwapBuffers（A：
 * 拿不到任意宽高比的黑边）。drmprops.c 只遍历 CRTC/CONN，看不到 plane。
 *
 * 顺带把 SRC_W/SRC_H/CRTC_W/CRTC_H 的当前值和各 plane 的 possible_crtcs 打出来，
 * 好判断 overlay 到底能不能缩放（能力上限 API 不暴露，只能试）。
 *
 * 裸 ioctl，不链 libdrm —— 和 drmprops.c 一样，盒子上少一份依赖。
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>

struct drm_mode_get_plane_res { uint64_t plane_id_ptr; uint32_t count_planes; };
struct drm_set_client_cap { uint64_t capability, value; };
struct drm_mode_get_plane {
	uint32_t plane_id, crtc_id, fb_id, possible_crtcs, gamma_size;
	uint32_t count_format_types;
	uint64_t format_type_ptr;
};
struct drm_mode_obj_get_props {
	uint32_t obj_id, obj_type, count_props, props_ptr, prop_values_ptr;
};
struct drm_mode_get_property {
	uint64_t values_ptr, enum_blob_ptr;
	uint32_t prop_id, flags;
	char name[32];
	uint32_t count_values, count_enum_blobs;
};

/* ioctl 号按结构体真实大小算，错一个字节就是 EFAULT：
 *   GETPLANERESOURCES = DRM_IOWR(0xb5, {u64,u32})  = 12 字节 → 0xC00C64B5
 *   GETPLANE          = DRM_IOWR(0xb6, {...})      = 32 字节 → 0xC02064B6
 *   drmprops.c 里 GETPROPERTIES 用 0xc01864b9 是对的（那个结构体 24 字节）。
 */
#define DRM_IOCTL_MODE_GETPLANERESOURCES 0xc00c64b5
#define DRM_IOCTL_MODE_GETPLANE          0xc02064b6
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES 0xc01864b9
#define DRM_IOCTL_MODE_GETPROPERTY       0xc01864aa
#define DRM_IOCTL_SET_CLIENT_CAP         0x4010640d
#define CLIENT_CAP_UNIVERSAL_PLANES 1
#define CLIENT_CAP_ATOMIC           3
#define OBJ_PLANE 0xeeeeeeee

static void fourcc(uint32_t f, char out[5])
{
	out[0] = f & 0xff;
	out[1] = (f >> 8) & 0xff;
	out[2] = (f >> 16) & 0xff;
	out[3] = (f >> 24) & 0xff;
	out[4] = 0;
	if (out[0] < 32 || out[1] < 32 || out[2] < 32 || out[3] < 32) {
		snprintf(out, 5, "??");
	}
}

int main(void)
{
	uint32_t ids[64];
	struct drm_mode_get_plane_res pr;
	int fd = open("/dev/dri/card0", O_RDWR);
	unsigned i;

	if (fd < 0) { perror("open card0"); return 1; }
	/* 不设 UNIVERSAL_PLANES，老客户端只能看到自己的 primary/overlay 子集 */
	{
		struct drm_set_client_cap cap;

		cap.capability = CLIENT_CAP_UNIVERSAL_PLANES;
		cap.value = 1;
		if (ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap) < 0)
			printf("WARN: UNIVERSAL_PLANES 设不上: %s\n", strerror(errno));
		cap.capability = CLIENT_CAP_ATOMIC;
		cap.value = 1;
		if (ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap) < 0)
			printf("WARN: ATOMIC 设不上: %s\n", strerror(errno));
		else
			printf("atomic: 支持\n");
	}
	memset(&pr, 0, sizeof(pr));
	pr.plane_id_ptr = (uint64_t)ids;
	pr.count_planes = 64;
	if (ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr) < 0) {
		perror("GETPLANERESOURCES");
		return 1;
	}
	printf("planes=%u\n", pr.count_planes);
	for (i = 0; i < pr.count_planes; i++) {
		struct drm_mode_get_plane p;
		uint32_t fmts[64], props[64];
		uint64_t vals[64];
		struct drm_mode_obj_get_props op;
		uint32_t k;
		char n[5];

		memset(&p, 0, sizeof(p));
		p.plane_id = ids[i];
		p.count_format_types = 64;
		p.format_type_ptr = (uint64_t)(uintptr_t)fmts;
		if (ioctl(fd, DRM_IOCTL_MODE_GETPLANE, &p) < 0) {
			printf("plane %u: GETPLANE 失败 %s\n", ids[i], strerror(errno));
			continue;
		}
		printf("\nplane %u  crtc=%u fb=%u possible_crtcs=0x%x gamma_size=%u\n",
		       p.plane_id, p.crtc_id, p.fb_id, p.possible_crtcs, p.gamma_size);
		printf("  formats:");
		for (k = 0; k < p.count_format_types && k < 64; k++) {
			fourcc(fmts[k], n);
			printf(" %s", n);
		}
		printf("\n");

		memset(&op, 0, sizeof(op));
		op.obj_id = p.plane_id;
		op.obj_type = OBJ_PLANE;
		op.count_props = 64;
		op.props_ptr = (uint32_t)(uintptr_t)props;
		op.prop_values_ptr = (uint32_t)(uintptr_t)vals;
		if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op) < 0) {
			printf("  props 读不到: %s\n", strerror(errno));
			continue;
		}
		for (k = 0; k < op.count_props && k < 64; k++) {
			struct drm_mode_get_property g;

			memset(&g, 0, sizeof(g));
			g.prop_id = props[k];
			if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &g) < 0) continue;
			printf("  %-16s = %llu\n", g.name,
			       (unsigned long long)vals[k]);
		}
	}
	return 0;
}
