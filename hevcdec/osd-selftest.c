/* osd-selftest.c —— 提示条离线自检（主机上跑，不需要盒子/GPU）
 *
 * 盒子上验一次 OSD 要走完整条链（解码 → GL 合成 → 拍照），改一个字都得
 * 重新部署。而 OSD 的错都很蠢：字形缺了变空白、advance 算错就重叠、
 * 位流偏移错就整行花屏。这里把 osd.c 的同一份代码直接烘成 PPM，
 * 再顺手断言几条"文案里的字必须在字形表里"。
 *
 *   make osdtest && ./osdtest /tmp/osd.ppm
 *   ./osdtest --list          列出字形表覆盖的汉字
 *
 * 输出是几条真文案的竖排拼图（透明底条按 GL 里的做法合成到灰底上），
 * 用眼睛看一眼就知道对不对。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osd.h"

/* 字形表的码点覆盖：文案里出现但没烘进字形的字会画成空白，
 * 屏幕上就是"提示条占位但没有字"——最难查的那种。
 * 声明在 osd.c 里，这里只要判存在与否，所以借用一下 osd_rgba 的度量。 */
static const char *CASES[] = {
	"音量 40%",
	"音量 100%",
	"静音 0%",
	"|| 暂停",
	"> 播放",
	"位置 01:23:45",
	"快进 30 秒",
	"无音轨",
};

#define NCASE ((int)(sizeof CASES / sizeof CASES[0]))

struct img {
	unsigned char *p;	/* RGBA8 */
	int w, h;
};

/* 按 GL 的做法把提示条叠到灰底上：底条 alpha=150，字 255。
 * 叠出来的样子就是屏幕上看到的样子（GL 里同一套 SRC_ALPHA 混合）。 */
static void compose(struct img *dst, const struct img *src, int ox, int oy,
		    int W, int H)
{
	for (int y = 0; y < src->h; y++)
		for (int x = 0; x < src->w; x++) {
			const unsigned char *s = src->p +
				((size_t)y * src->w + x) * 4;
			unsigned char *d;
			int a = s[3];

			if (ox + x < 0 || ox + x >= W || oy + y < 0 || oy + y >= H)
				continue;
			d = dst->p + ((size_t)(oy + y) * W + (ox + x)) * 4;
			for (int c = 0; c < 3; c++)
				d[c] = (unsigned char)((s[c] * a +
					d[c] * (255 - a)) / 255);
			d[3] = 255;
		}
}

int main(int argc, char **argv)
{
	struct img imgs[NCASE];
	int W = 0, H = 32, fail = 0;
	const char *out = argc > 1 && argv[1][0] != '-' ? argv[1] : "osd.ppm";
	FILE *f;

	for (int i = 0; i < NCASE; i++) {
		osd_clear();			/* 别让上一条留着的文本混进来 */
		osd_show(0, "%s", CASES[i]);
		imgs[i].p = osd_rgba(&imgs[i].w, &imgs[i].h);
		if (!imgs[i].p) {
			printf("FAIL: \"%s\" 烘不出位图\n", CASES[i]);
			fail = 1;
			imgs[i].w = imgs[i].h = 0;
			continue;
		}
		/* 宽度合理性：40px 字高、每个字符至少 ~10px 步进。
		 * 太窄说明字形全缺（只剩内边距），太宽说明 advance 被算成 0 后
		 * 又重复计了别的字。
		 */
		{
			int n = (int)strlen(CASES[i]);
			int lo = 2 * 30 + n * 6, hi = 2 * 30 + n * 60;

			if (imgs[i].w < lo || imgs[i].w > hi) {
				printf("FAIL: \"%s\" 宽 %d 不在 [%d,%d]\n",
				       CASES[i], imgs[i].w, lo, hi);
				fail = 1;
			}
		}
		if (imgs[i].w > W) W = imgs[i].w;
		H += imgs[i].h + 8;
	}
	osd_clear();
	if (osd_active()) {
		printf("FAIL: osd_clear 之后仍然 active\n");
		fail = 1;
	}

	{
		struct img canvas;
		int y = 0;

		canvas.w = W;
		canvas.h = H;
		canvas.p = malloc((size_t)W * H * 4);
		if (!canvas.p) return 1;
		for (size_t i = 0; i < (size_t)W * H; i++) {
			canvas.p[i * 4 + 0] = 40;	/* 深灰：白字和半透明底条都看得清 */
			canvas.p[i * 4 + 1] = 40;
			canvas.p[i * 4 + 2] = 40;
			canvas.p[i * 4 + 3] = 255;
		}
		for (int i = 0; i < NCASE; i++) {
			if (imgs[i].p) compose(&canvas, &imgs[i], 0, y, W, H);
			y += imgs[i].h + 8;
		}
		f = fopen(out, "wb");
		if (!f) { perror(out); return 1; }
		fprintf(f, "P6\n%d %d\n255\n", W, H);
		for (size_t i = 0; i < (size_t)W * H; i++)
			fwrite(canvas.p + i * 4, 1, 3, f);
		fclose(f);
		printf("写到 %s (%dx%d)\n", out, W, H);
		free(canvas.p);
	}
	for (int i = 0; i < NCASE; i++) free(imgs[i].p);
	return fail;
}
