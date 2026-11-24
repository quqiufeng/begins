/* grabscreen.c —— 抓 DRM 上屏平面的真实内容（证明"上屏了但黑"到底哪一层）
 * 只读：drmModeGetFB2 + PRIME handle→fd + mmap，不抢 DRM master，能和播放器同时跑。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
	const char *out = argc > 2 ? argv[2] : "/tmp/plane.raw";
	int fd = open(dev, O_RDWR | O_CLOEXEC);
	drmModePlaneRes *pr;
	unsigned i;

	if (fd < 0) { printf("open %s: %s\n", dev, strerror(errno)); return 1; }
	drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
	pr = drmModeGetPlaneResources(fd);
	if (!pr) { printf("plane res: %s\n", strerror(errno)); return 1; }
	for (i = 0; i < pr->count_planes; i++) {
		drmModePlane *p = drmModeGetPlane(fd, pr->planes[i]);
		drmModeFB2 *fb;

		if (!p) continue;
		if (!p->fb_id || !p->crtc_id) { drmModeFreePlane(p); continue; }
		fb = drmModeGetFB2(fd, p->fb_id);
		if (fb) {
			int dfd = -1;
			size_t len = (size_t)fb->pitches[0] * fb->height;

			printf("plane=%u crtc=%u fb=%u %ux%u fmt=%08x pitch=%u\n",
			       p->plane_id, p->crtc_id, p->fb_id, fb->width,
			       fb->height, fb->pixel_format, fb->pitches[0]);
			if (!drmPrimeHandleToFD(fd, fb->handles[0],
						O_RDONLY | O_CLOEXEC, &dfd)) {
				unsigned char *m = mmap(NULL, len, PROT_READ,
							MAP_SHARED, dfd, 0);

				if (m != MAP_FAILED) {
					unsigned long long sum = 0;
					size_t nz = 0, k, n = 0;

					for (k = 0; k < len; k += 997) {
						sum += m[k];
						if (m[k]) nz++;
						n++;
					}
					printf("  采样 %zu 点：非零 %zu 均值 %.2f\n", n, nz,
					       (double)sum / (double)(n ? n : 1));
					{
						FILE *f = fopen(out, "wb");

						if (f) {
							size_t w = len > 20000000 ?
								   20000000 : len;
							fwrite(m, 1, w, f);
							fclose(f);
							printf("  已存 %s (%zu B)\n", out, w);
						}
					}
					munmap(m, len);
				} else {
					printf("  mmap 失败: %s\n", strerror(errno));
				}
				close(dfd);
			} else {
				printf("  PRIME→fd 失败: %s\n", strerror(errno));
			}
			drmModeFreeFB2(fb);
		}
		drmModeFreePlane(p);
	}
	drmModeFreePlaneResources(pr);
	close(fd);
	return 0;
}
