/* drmprobe2: 摸清 primary plane 的 type / 格式 / modifier，并实测 SETCRTC */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#include <linux/types.h>
#include <stdint.h>
#include <stddef.h>

static int fd;
static const char *fcc(uint32_t f)
{
	static char b[8];
	b[0] = f & 0xff; b[1] = (f >> 8) & 0xff; b[2] = (f >> 16) & 0xff;
	b[3] = (f >> 24) & 0xff; b[4] = 0;
	return b;
}

static int try_setcrtc(uint32_t crtc, uint32_t conn, struct drm_mode_modeinfo *m,
		       uint32_t fb, const char *tag)
{
	struct drm_mode_crtc set = {0};
	int r;

	set.crtc_id = crtc;
	set.fb_id = fb;
	set.mode = *m;
	set.mode_valid = 1;
	set.count_connectors = 1;
	set.set_connectors_ptr = (uint64_t)(uintptr_t)&conn;
	r = ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set);
	printf("  SETCRTC[%s] fb=%u -> %s\n", tag, fb, r ? strerror(errno) : "OK");
	return r;
}

int main(void)
{
	struct drm_mode_card_res res = {0};
	uint32_t crtcs[16], conns[16], encs[16];
	uint32_t planes[32], conn_id = 0, crtc_id = 0;
	struct drm_mode_modeinfo mode = {0};
	int i;

	fd = open("/dev/dri/card0", O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs; res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns; res.count_connectors = 16;
	res.encoder_id_ptr = (uint64_t)(uintptr_t)encs; res.count_encoders = 16;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("RES"); return 1; }

	for (i = 0; i < (int)res.count_connectors && !conn_id; i++) {
		struct drm_mode_get_connector gc = {0};
		static struct drm_mode_modeinfo ms[64];
		uint32_t enc = 0;
		int j;

		gc.connector_id = conns[i];
		gc.modes_ptr = (uint64_t)(uintptr_t)ms; gc.count_modes = 64;
		gc.encoders_ptr = (uint64_t)(uintptr_t)&enc; gc.count_encoders = 1;
		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc)) continue;
		if (gc.connection != 1 || !gc.count_modes) continue;
		conn_id = gc.connector_id;
		for (j = 0; j < (int)gc.count_modes; j++)
			if (ms[j].hdisplay == 2560 && ms[j].vdisplay == 1440)
				mode = ms[j];
		if (gc.encoder_id) {
			struct drm_mode_get_encoder ge = {0};

			ge.encoder_id = gc.encoder_id;
			if (!ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &ge)) crtc_id = ge.crtc_id;
		}
	}
	if (!crtc_id) crtc_id = res.count_crtcs ? crtcs[0] : 0;
	printf("conn=%u crtc=%u mode=%ux%u@%u clock=%u flags=0x%x\n", conn_id, crtc_id,
	       mode.hdisplay, mode.vdisplay, mode.vrefresh, mode.clock, mode.flags);

	{
		struct drm_mode_get_plane_res pr = {0};

		pr.plane_id_ptr = (uint64_t)(uintptr_t)planes; pr.count_planes = 32;
		ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
		printf("PLANES=%u\n", pr.count_planes);

		for (i = 0; i < (int)pr.count_planes; i++) {
			struct drm_mode_get_plane gp = {0};
			static uint32_t fmts[32];
			static uint64_t mods[32];
			struct drm_mode_get_plane_res dummy;
			int k, h;

			gp.plane_id = planes[i];
			ioctl(fd, DRM_IOCTL_MODE_GETPLANE, &gp);
			gp.format_type_ptr = (uint64_t)(uintptr_t)fmts;
			gp.count_format_types = 32;
			ioctl(fd, DRM_IOCTL_MODE_GETPLANE, &gp);
			printf("plane=%u crtc=%u fb=%u possible=0x%x gamma=%u nfmt=%u\n",
			       gp.plane_id, gp.crtc_id, gp.fb_id, gp.possible_crtcs,
			       gp.gamma_size, gp.count_format_types);
			printf("  fmts:");
			for (k = 0; k < (int)gp.count_format_types; k++)
				printf(" %s(0x%x)", fcc(fmts[k]), fmts[k]);
			printf("\n");

			/* 取 propertyset 找 modifier / type */
			{
				uint32_t props[64];
				uint64_t *pv = (uint64_t *)(void *)(props + 32);
				struct drm_mode_obj_get_properties op = {0};

				op.obj_id = gp.plane_id;
				op.obj_type = DRM_MODE_OBJECT_PLANE;
				op.props_ptr = (uint64_t)(uintptr_t)props;
				op.prop_values_ptr = (uint64_t)(uintptr_t)(props + 32);
				op.count_props = 32;
				if (!ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op)) {
					for (k = 0; k < (int)op.count_props; k++) {
						struct drm_mode_get_property pr2 = {0};
						char name[64] = {0};
						uint64_t vals[32];

						pr2.prop_id = props[k];
						pr2.values_ptr = (uint64_t)(uintptr_t)vals;
						pr2.count_values = 32;
						pr2.enum_blob_ptr = (uint64_t)(uintptr_t)name;
						pr2.count_enum_blobs = 64;
						if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &pr2)) continue;
						/* 属性名在 pr2.name 内联字段 */
						printf("  prop %u '%s' val=%llu flags=0x%x enums=%u\n",
						       pr2.prop_id, pr2.name,
						       (unsigned long long)pv[k],
						       pr2.flags, pr2.count_enum_blobs);
						if (!strcmp(pr2.name, "IN_FORMATS")) {
							struct drm_mode_get_blob gb = {0};
							uint8_t buf[2048];
							struct drm_format_modifier_blob *mb =
								(struct drm_format_modifier_blob *)buf;

							gb.blob_id = pv[k];
							gb.length = sizeof buf;
							gb.data = (uint64_t)(uintptr_t)buf;
							if (!ioctl(fd, DRM_IOCTL_MODE_GETPROPBLOB, &gb)) {
								uint32_t *ff = (uint32_t *)(buf + mb->formats_offset);
								struct drm_format_modifier *mm =
									(struct drm_format_modifier *)(buf + mb->modifiers_offset);

								printf("    IN_FORMATS: nfmt=%u nmod=%u\n",
								       mb->count_formats, mb->count_modifiers);
								for (h = 0; h < (int)mb->count_modifiers; h++)
									printf("      mod[%d]=0x%llx fmt_mask=0x%llx\n", h,
									       (unsigned long long)mm[h].modifier,
									       (unsigned long long)mm[h].formats);
								for (h = 0; h < (int)mb->count_formats; h++)
									printf("      fmt[%d]=%s\n", h, fcc(ff[h]));
							}
						}
					}
				}
			}

			/* 实测：NV12 与 YUYV 的 dumb fb 各试一次 SETCRTC */
			{
				struct { uint32_t fourcc; unsigned bpp; const char *tag; } t[] = {
					{ DRM_FORMAT_NV12, 8, "NV12" },
					{ DRM_FORMAT_YUYV, 16, "YUYV" },
				};
				int n;

				for (n = 0; n < 2; n++) {
					struct drm_mode_create_dumb dy = {0}, dc = {0};
					struct drm_mode_fb_cmd2 f2 = {0};
					uint32_t fb = 0;

					dy.width = mode.hdisplay; dy.height = mode.vdisplay;
					dy.bpp = t[n].bpp;
					if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dy)) {
						printf("  dumb %s: %s\n", t[n].tag, strerror(errno));
						continue;
					}
					f2.width = mode.hdisplay; f2.height = mode.vdisplay;
					f2.pixel_format = t[n].fourcc;
					f2.handles[0] = dy.handle; f2.pitches[0] = dy.pitch;
					if (t[n].fourcc == DRM_FORMAT_NV12) {
						dc.width = mode.hdisplay; dc.height = mode.vdisplay / 2;
						dc.bpp = 8;
						ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dc);
						f2.handles[1] = dc.handle; f2.pitches[1] = dc.pitch;
					}
					if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &f2)) {
						printf("  addfb %s: %s\n", t[n].tag, strerror(errno));
						continue;
					}
					fb = f2.fb_id;
					try_setcrtc(crtc_id, conn_id, &mode, fb, t[n].tag);
				}
			}
		}
	}
	return 0;
}
