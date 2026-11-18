/* SetCrtc 用小 fb + 大 mode：这条正是播放器第一次上报错的那一步 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
int main(void)
{
	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	drmModeRes *res; drmModeCrtc *c; uint32_t fb720; struct drm_mode_create_dumb cd = {0};

	if (fd < 0) { perror("card0"); return 1; }
	res = drmModeGetResources(fd);
	if (!res) { perror("res"); return 1; }
	c = drmModeGetCrtc(fd, res->crtcs[0]);
	printf("crtc=%u cur_fb=%u mode=%ux%u conn=%u\n", c->crtc_id, c->buffer_id,
	       c->mode.hdisplay, c->mode.vdisplay, res->connectors[0]);
	cd.width = 1280; cd.height = 720; cd.bpp = 32;
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { perror("dumb"); return 1; }
	if (drmModeAddFB(fd, 1280, 720, 24, 32, cd.pitch, cd.handle, &fb720)) { perror("addfb"); return 1; }
	printf("fb720=%u\n", fb720);
	errno = 0;
	printf("SetCrtc(1280x720 fb, 1920x1080 mode): %d %s\n",
	       drmModeSetCrtc(fd, c->crtc_id, fb720, 0, 0, res->connectors, 1, &c->mode),
	       strerror(errno));
	errno = 0;
	{ struct drm_mode_create_dumb c2 = {0}; uint32_t fb1080;
	  c2.width = 1920; c2.height = 1080; c2.bpp = 32;
	  drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &c2);
	  drmModeAddFB(fd, 1920, 1080, 24, 32, c2.pitch, c2.handle, &fb1080);
	  printf("SetCrtc(1920x1080 fb, 1920x1080 mode): %d %s\n",
		 drmModeSetCrtc(fd, c->crtc_id, fb1080, 0, 0, res->connectors, 1, &c->mode),
		 strerror(errno));
	}
	return 0;
}
