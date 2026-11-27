/* fbwall — 把一张原始 BGRA 图铺到 framebuffer 上（居中、等比缩放留黑边）
 *
 * 用途：桌面/外部 app 释放 DRM master 的空档，屏幕停在最后一帧或开局命令行文本上。
 * 这里直接写 /dev/fb0，让"没人画"的时候看到的是壁纸。
 *
 * 用法： fbwall <raw.bgra> <src_w> <src_h>
 *       fbwall /root/mecha.bgra 2560 1440
 * 退出码：0 成功，1 打开/ioctl 失败，2 读图失败
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>

#define FB "/dev/fb0"

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s raw.bgra src_w src_h\n", argv[0]);
		return 1;
	}
	const char *path = argv[1];
	long sw = atol(argv[2]), sh = atol(argv[3]);
	if (sw <= 0 || sh <= 0) return 1;

	size_t need = (size_t)sw * (size_t)sh * 4;
	unsigned char *src = malloc(need);
	if (!src) return 2;
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); free(src); return 2; }
	if (fread(src, 1, need, f) != need) { fclose(f); free(src); return 2; }
	fclose(f);

	int fd = open(FB, O_RDWR);
	if (fd < 0) { perror(FB); free(src); return 1; }
	struct fb_var_screeninfo vi;
	struct fb_fix_screeninfo fi;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) < 0 ||
	    ioctl(fd, FBIOGET_FSCREENINFO, &fi) < 0) {
		perror("ioctl"); close(fd); free(src); return 1;
	}
	/* 只认可见分辨率：yres_virtual 通常是 3 倍（fbcon 三页滚动），
	   往 yres_virtual 里算把画面写到第二页，扫描出去的还是黑的第一页 */
	long fw = vi.xres;
	long fh = vi.yres;
	long stride = (long)fi.line_length;
	if (stride <= 0) stride = fw * 4;
	size_t vis = (size_t)stride * (size_t)fh;
	size_t map = (size_t)stride * (size_t)(vi.yres_virtual ? vi.yres_virtual : fh);

	unsigned char *fb = mmap(NULL, map, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) { perror("mmap"); close(fd); free(src); return 1; }

	/* 32bpp 且源分辨率一致：整块直拷（最快，也最不容易糊） */
	if (vi.bits_per_pixel == 32 && sw == fw && sh == fh && stride == sw * 4) {
		memcpy(fb, src, vis);
	} else {
		/* 等比缩放 + 居中（最近邻，够用且不依赖任何库） */
		double sx = (double)fw / (double)sw, sy = (double)fh / (double)sh;
		double s = sx < sy ? sx : sy;
		long dw = (long)(sw * s), dh = (long)(sh * s);
		if (dw < 1) dw = 1;
		if (dh < 1) dh = 1;
		long ox = (fw - dw) / 2, oy = (fh - dh) / 2;
		memset(fb, 0, vis);
		for (long y = 0; y < dh; y++) {
			long syy = (long)((double)y * sh / dh);
			if (syy >= sh) syy = sh - 1;
			unsigned char *dst = fb + (size_t)(oy + y) * stride + (size_t)ox * 4;
			const unsigned char *srow = src + (size_t)syy * sw * 4;
			if (dw == fw) {
				memcpy(dst, srow, (size_t)fw * 4);
			} else {
				for (long x = 0; x < dw; x++) {
					long sxx = (long)((double)x * sw / dw);
					if (sxx >= sw) sxx = sw - 1;
					memcpy(dst + (size_t)x * 4, srow + (size_t)sxx * 4, 4);
				}
			}
		}
	}
	msync(fb, vis, MS_SYNC);
	munmap(fb, map);
	close(fd);
	free(src);
	return 0;
}
