// grabplane.c —— 抓当前 CRTC scanout 平面内容（DRM PRIME mmap），支持任意分辨率
// 用法: grabplane [card] [out.raw]  输出 BGRA/pitch 布局的原始数据
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    const char *out = argc > 2 ? argv[2] : "/tmp/plane.raw";
    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open"); return 1; }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getresources"); return 1; }
    uint32_t nc = res.count_crtcs;
    uint32_t *crtcs = calloc(nc ? nc : 1, sizeof(uint32_t));
    memset(&res, 0, sizeof res);
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.count_crtcs = nc;   /* 入参=数组容量，出参=实际个数 */
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getresources2"); return 1; }
    nc = res.count_crtcs;

    uint32_t fb_id = 0;
    for (uint32_t i = 0; i < nc; i++) {
        struct drm_mode_crtc c;
        memset(&c, 0, sizeof c);
        c.crtc_id = crtcs[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &c)) continue;
        if (c.mode_valid && c.fb_id) {
            printf("crtc=%u fb=%u %ux%u@%u\n", c.crtc_id, c.fb_id, c.mode.hdisplay, c.mode.vdisplay, c.mode.vrefresh);
            fb_id = c.fb_id;
            break;
        }
    }
    if (!fb_id) { fprintf(stderr, "没有活动 CRTC/fb\n"); return 1; }

    struct drm_mode_fb_cmd fb;
    memset(&fb, 0, sizeof fb);
    fb.fb_id = fb_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETFB, &fb)) { perror("getfb"); return 1; }
    printf("fb %ux%u pitch=%u bpp=%u handle=%u\n", fb.width, fb.height, fb.pitch, fb.bpp, fb.handle);

    struct drm_prime_handle ph;
    memset(&ph, 0, sizeof ph);
    ph.handle = fb.handle;
    ph.flags = DRM_CLOEXEC | DRM_RDWR;
    if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph)) { perror("prime"); return 1; }

    size_t sz = (size_t)fb.pitch * fb.height;
    void *p = mmap(NULL, sz, PROT_READ, MAP_SHARED, ph.fd, 0);
    if (p == MAP_FAILED) {
        // 退回只读不带 RDWR 的导入
        perror("mmap");
        return 1;
    }
    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); return 1; }
    if (fwrite(p, 1, sz, f) != sz) { perror("fwrite"); return 1; }
    fclose(f);
    printf("已存 %s (%zu B)\n", out, sz);
    return 0;
}
