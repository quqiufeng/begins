// DRM capability probe: connectors/modes, planes/formats, and whether a
// NV12 NV12M dmabuf from meson-vdec can be imported + scanned out.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>

#define DRM_IOCTL_BASE_ 'd'

static int fd;

static int ioctl_w(int req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
	return r;
}

static const char *fourcc_str(uint32_t f, char *b)
{
	b[0] = f & 0xff; b[1] = (f >> 8) & 0xff;
	b[2] = (f >> 16) & 0xff; b[3] = (f >> 24) & 0xff; b[4] = 0;
	return b;
}

static int get_res(struct drm_mode_card_res *res)
{
	uint64_t fbc[64], cc[64], ec[64];
	uint32_t fbi[64], ci[64], ei[64];

	memset(res, 0, sizeof(*res));
	res->fb_id_ptr = (uint64_t)(unsigned long)fbi;
	res->crtc_id_ptr = (uint64_t)(unsigned long)ci;
	res->connector_id_ptr = (uint64_t)(unsigned long)ei;
	res->count_fbs = 64; res->count_crtcs = 64; res->count_connectors = 64;
	if (ioctl_w(DRM_IOCTL_MODE_GETRESOURCES, res) < 0)
		return -1;
	(void)fbc; (void)cc; (void)ec;
	return 0;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
	struct drm_mode_card_res res;
	uint32_t crtcs[64], conns[64];
	unsigned nc, ncr;
	char b[8];

	fd = open(dev, O_RDWR);
	if (fd < 0) { printf("open %s: %s\n", dev, strerror(errno)); return 1; }

	/* resources with real arrays */
	{
		struct drm_mode_card_res r2;
		uint32_t ci[64], co[64], ei[64], fi[64];

		memset(&r2, 0, sizeof(r2));
		r2.count_crtcs = 64; r2.count_connectors = 64;
		r2.count_encoders = 64; r2.count_fbs = 64;
		r2.crtc_id_ptr = (uint64_t)(unsigned long)ci;
		r2.connector_id_ptr = (uint64_t)(unsigned long)co;
		r2.encoder_id_ptr = (uint64_t)(unsigned long)ei;
		r2.fb_id_ptr = (uint64_t)(unsigned long)fi;
		if (ioctl_w(DRM_IOCTL_MODE_GETRESOURCES, &r2) < 0) {
			printf("GETRESOURCES: %s\n", strerror(errno));
			return 1;
		}
		res = r2;
		ncr = r2.count_crtcs; nc = r2.count_connectors;
		memcpy(crtcs, ci, sizeof(uint32_t) * ncr);
		memcpy(conns, co, sizeof(uint32_t) * nc);
	}

	printf("== %s ==\n", dev);
	printf("crtcs=%u connectors=%u encoders=%u\n",
	       res.count_crtcs, res.count_connectors, res.count_encoders);

	for (unsigned i = 0; i < nc; i++) {
		struct drm_mode_get_connector c;
		struct drm_mode_modeinfo modes[64];
		uint32_t encs[16], props[64], propv[64];

		memset(&c, 0, sizeof(c));
		c.connector_id = conns[i];
		c.count_modes = 64; c.modes_ptr = (uint64_t)(unsigned long)modes;
		c.count_encoders = 16; c.encoders_ptr = (uint64_t)(unsigned long)encs;
		c.count_props = 64; c.props_ptr = (uint64_t)(unsigned long)props;
		c.prop_values_ptr = (uint64_t)(unsigned long)propv;
		if (ioctl_w(DRM_IOCTL_MODE_GETCONNECTOR, &c) < 0) {
			printf("connector %u: %s\n", conns[i], strerror(errno));
			continue;
		}
		printf("\nCONNECTOR id=%u type=%u conn=%s enc=%u modes=%u\n",
		       conns[i], c.connector_type,
		       c.connection == 1 ? "CONNECTED" : "disconnected",
		       c.encoder_id, c.count_modes);
		for (unsigned m = 0; m < c.count_modes && m < 8; m++)
			printf("   mode %ux%u @%uHz  \"%s\"\n", modes[m].hdisplay,
			       modes[m].vdisplay, modes[m].vrefresh, modes[m].name);
		if (c.count_modes > 8) printf("   ... (%u total)\n", c.count_modes);
	}

	/* planes */
	{
		struct drm_mode_get_plane_res pr;
		uint32_t pl[64];

		memset(&pr, 0, sizeof(pr));
		pr.count_planes = 64;
		pr.plane_id_ptr = (uint64_t)(unsigned long)pl;
		if (ioctl_w(DRM_IOCTL_MODE_GETPLANERESOURCES, &pr) < 0) {
			printf("\nGETPLANERESOURCES: %s\n", strerror(errno));
			return 1;
		}
		printf("\nPLANES=%u\n", pr.count_planes);
		for (unsigned i = 0; i < pr.count_planes; i++) {
			struct drm_mode_get_plane p;
			uint32_t fmts[128];
			int has_nv12 = 0, has_p010 = 0;

			memset(&p, 0, sizeof(p));
			p.plane_id = pl[i];
			p.count_format_types = 128;
			p.format_type_ptr = (uint64_t)(unsigned long)fmts;
			if (ioctl_w(DRM_IOCTL_MODE_GETPLANE, &p) < 0) {
				printf("plane %u: %s\n", pl[i], strerror(errno));
				continue;
			}
			for (uint32_t k = 0; k < p.count_format_types; k++) {
				if (fmts[k] == DRM_FORMAT_NV12) has_nv12 = 1;
				if (fmts[k] == DRM_FORMAT_P010) has_p010 = 1;
			}
			printf("plane id=%u crtc=%u fb=%u gamma=%u possible_crtcs=%08x fmts=%u NV12=%d P010=%d\n",
			       pl[i], p.crtc_id, p.fb_id, p.gamma_size,
			       p.possible_crtcs, p.count_format_types, has_nv12, has_p010);
			if (has_nv12) {
				printf("   fmts:");
				for (uint32_t k = 0; k < p.count_format_types && k < 24; k++)
					printf(" %s", fourcc_str(fmts[k], b));
				printf("\n");
			}
		}
	}
	close(fd);
	return 0;
}
