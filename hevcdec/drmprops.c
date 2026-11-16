/* 枚举 card0 上所有 object 的属性名（找 GAMMA_LUT / CTM / COLOR_* / HDR_*） */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/types.h>
struct drm_mode_object_get_properties {
	uint32_t obj_id, obj_type, count_props, props_ptr, prop_values_ptr;
};
#define DRM_IOCTL_MODE_GETRESOURCES 0xc04064a0
#define DRM_IOCTL_MODE_GETPROPERTY 0xc04064aa
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES 0xc01864b9
#define DRM_IOCTL_MODE_GETPROP 0xc01864b9
struct drm_mode_get_property {
	uint64_t values_ptr, enum_blob_ptr;
	uint32_t prop_id, flags;
	char name[32];
	uint32_t count_values, count_enum_blobs;
};
struct drm_mode_card_res {
	uint64_t fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
	uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
	uint32_t min_width, max_width, min_height, max_height;
	uint32_t count_connectors_r, count_encoders_r, count_crtcs_r;
};
int main(void)
{
	int fd = open("/dev/dri/card0", O_RDWR);
	uint64_t fb[32], crtc[32], conn[32], enc[32];
	struct drm_mode_card_res r; 
	memset(&r, 0, sizeof(r));
	r.fb_id_ptr = (uint64_t)fb; r.crtc_id_ptr = (uint64_t)crtc;
	r.connector_id_ptr = (uint64_t)conn; r.encoder_id_ptr = (uint64_t)enc;
	r.count_fbs = r.count_crtcs = r.count_connectors = r.count_encoders = 32;
	if (fd < 0 || ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &r) < 0) { perror("card0"); return 1; }
	printf("crtcs=%u conns=%u encs=%u planes=?\n", r.count_crtcs, r.count_connectors, r.count_encoders);
	struct { const char *tag; uint32_t n; uint64_t *ids; uint32_t type; } grp[] = {
		{"CRTC", r.count_crtcs, crtc, 0xcccccccc}, {"CONN", r.count_connectors, conn, 0xc0c0c0c0},
	};
	for (unsigned g = 0; g < 2; g++) {
		for (uint32_t i = 0; i < grp[g].n; i++) {
			uint32_t props[64], vals[64];
			struct drm_mode_object_get_properties p;
			memset(&p, 0, sizeof(p));
			p.obj_id = grp[g].ids[i]; p.obj_type = grp[g].type;
			p.props_ptr = (uint64_t)props; p.prop_values_ptr = (uint64_t)vals; p.count_props = 64;
			if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &p) < 0) continue;
			printf("%s %u:", grp[g].tag, p.obj_id);
			for (uint32_t k = 0; k < p.count_props; k++) {
				struct drm_mode_get_property pr; memset(&pr, 0, sizeof(pr));
				pr.prop_id = props[k]; pr.count_values = 64; pr.count_enum_blobs = 64;
				if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &pr) < 0) continue;
				printf(" %s", pr.name);
			}
			printf("\n");
		}
	}
	return 0;
}
