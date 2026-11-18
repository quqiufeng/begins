#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <sys/mman.h>

// 用法: drmcap [card] [out.raw]   card 省略时自动找第一个有 active crtc 的卡
static const char *cards[] = {"/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card2", "/dev/dri/card3"};

static int dump(const char *dev, const char *out);

int main(int argc, char **argv) {
	if (argc > 1)
		return dump(argv[1], argc > 2 ? argv[2] : "/tmp/drmcap.raw");
	for (unsigned i = 0; i < sizeof(cards) / sizeof(*cards); i++)
		if (access(cards[i], R_OK) == 0 && dump(cards[i], "/tmp/drmcap.raw") == 0)
			return 0;
	fprintf(stderr, "no active framebuffer on any card\n");
	return 9;
}

static int dump(const char *dev, const char *outpath) {
	int fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) return 1;
	drmModeRes *res = drmModeGetResources(fd);
	if (!res) { close(fd); return 2; }
	unsigned fb_id = 0, cw = 0, ch = 0;
	for (int i = 0; i < res->count_crtcs; i++) {
		drmModeCrtc *c = drmModeGetCrtc(fd, res->crtcs[i]);
		if (!c) continue;
		if (c->buffer_id && c->mode_valid && !fb_id) { fb_id = c->buffer_id; cw = c->width; ch = c->height; }
		drmModeFreeCrtc(c);
	}
	if (!fb_id) { drmModeFreeResources(res); return 3; }
	drmModeFB *fb = drmModeGetFB(fd, fb_id);
	if (!fb) { return 4; }
	struct drm_mode_map_dumb mp; memset(&mp, 0, sizeof(mp)); mp.handle = fb->handle;
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mp)) return 5;
	size_t sz = (size_t)fb->pitch * fb->height;
	void *p = mmap(NULL, sz, PROT_READ, MAP_SHARED, fd, mp.offset);
	if (p == MAP_FAILED) return 6;
	FILE *o = fopen(outpath, "wb");
	if (!o) return 7;
	fwrite(p, 1, sz, o); fclose(o);
	printf("WROTE %s %u %u %u\n", outpath, fb->width, fb->height, fb->pitch);
	munmap(p, sz);
	return 0;
}
