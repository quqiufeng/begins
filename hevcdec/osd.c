/* osd.c —— 一行屏幕提示：状态 + 位图字体烘焙
 *
 * 字体是编译期烘进二进制的 1bpp 位图（osd_font.inc，见 gen-osd-font.py）：
 * 盒子上没有 freetype，也不值得为一行提示加运行期依赖。
 */
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "osd.h"

struct osd_glyph {
	unsigned int cp;	/* Unicode 码点 */
	unsigned short adv;	/* 步进宽度 */
	unsigned short h;	/* 位图行数（所有字形同高） */
	unsigned int off;	/* 位偏移（字节对齐） */
};

#include "osd_font.inc"

#define PAD_X	30		/* 底条内边距 */
#define PAD_Y	14
#define TEXT_MAX 96

static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static char text[TEXT_MAX];
static double until;		/* 到期时刻（CLOCK_MONOTONIC） */
static unsigned gen;
static int dirty;		/* 有内容变化，等渲染方取走 */
static int was_active;

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

void osd_show(double dur, const char *fmt, ...)
{
	va_list ap;
	char buf[TEXT_MAX];

	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);

	pthread_mutex_lock(&lk);
	if (strcmp(text, buf)) {
		snprintf(text, sizeof text, "%s", buf);
		gen++;
	}
	until = dur > 0 ? now_s() + dur : 1e18;
	dirty = 1;
	pthread_mutex_unlock(&lk);
}

void osd_clear(void)
{
	pthread_mutex_lock(&lk);
	if (text[0]) {
		text[0] = 0;
		gen++;
		dirty = 1;
	}
	pthread_mutex_unlock(&lk);
}

int osd_active(void)
{
	int a;

	pthread_mutex_lock(&lk);
	a = text[0] && now_s() < until;
	pthread_mutex_unlock(&lk);
	return a;
}

unsigned osd_gen(void)
{
	unsigned g;

	pthread_mutex_lock(&lk);
	g = gen;
	pthread_mutex_unlock(&lk);
	return g;
}

/* 出现一次、到期一次，各让屏幕重画一遍（暂停时没有新帧，就靠这个把提示
 * 画上去/擦掉，否则冻住的那帧会把提示永远挂在屏幕上） */
int osd_poll_dirty(void)
{
	int d = 0;

	pthread_mutex_lock(&lk);
	if (dirty) {
		dirty = 0;
		d = 1;
	} else if (was_active && !(text[0] && now_s() < until)) {
		d = 1;
	}
	was_active = text[0] && now_s() < until;
	pthread_mutex_unlock(&lk);
	return d;
}

/* UTF-8 → 码点，返回字节数（坏字节按 1 跳） */
static int utf8_next(const unsigned char *s, unsigned int *cp)
{
	if (s[0] < 0x80) { *cp = s[0]; return 1; }
	if ((s[0] & 0xE0) == 0xC0 && s[1]) {
		*cp = ((unsigned)s[0] & 0x1F) << 6 | (s[1] & 0x3F);
		return 2;
	}
	if ((s[0] & 0xF0) == 0xE0 && s[1] && s[2]) {
		*cp = ((unsigned)s[0] & 0x0F) << 12 |
		      ((unsigned)s[1] & 0x3F) << 6 | (s[2] & 0x3F);
		return 3;
	}
	*cp = '?';
	return 1;
}

static const struct osd_glyph *find(unsigned int cp)
{
	int lo = 0, hi = (int)OSD_NGLYPH - 1;

	while (lo <= hi) {		/* 表按码点升序，二分 */
		int mid = (lo + hi) / 2;

		if (osd_glyphs[mid].cp == cp) return &osd_glyphs[mid];
		if (osd_glyphs[mid].cp < cp) lo = mid + 1;
		else hi = mid - 1;
	}
	return NULL;
}

static int bit(unsigned int off)
{
	return (osd_bits[off >> 3] >> (7 - (off & 7))) & 1;
}

unsigned char *osd_rgba(int *w, int *h)
{
	char buf[TEXT_MAX];
	unsigned char *px;
	const unsigned char *s;
	int tw = 0, W, H, n;
	struct { const struct osd_glyph *g; } gl[TEXT_MAX];

	pthread_mutex_lock(&lk);
	snprintf(buf, sizeof buf, "%s", text);
	pthread_mutex_unlock(&lk);
	if (!buf[0])
		return NULL;

	/* 先量宽度：字宽不同（数字窄、汉字满格），不能按字符数算 */
	s = (const unsigned char *)buf;
	for (n = 0; *s && n < TEXT_MAX - 1; n++) {
		unsigned int cp;
		int len = utf8_next(s, &cp);

		s += len;
		gl[n].g = find(cp);
		if (gl[n].g)
			tw += gl[n].g->adv;
	}
	if (tw <= 0)
		return NULL;

	W = tw + 2 * PAD_X;
	H = OSD_FONT_H + 2 * PAD_Y;
	px = calloc(1, (size_t)W * H * 4);
	if (!px)
		return NULL;

	/* 底条 + 白字。1bpp 烘焙，边缘没有灰度：40px 字在 1080p 上是清楚的，
	 * 花更多字节换抗锯齿是下一版的事。 */
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			unsigned char *p = px + ((size_t)y * W + x) * 4;

			p[0] = p[1] = p[2] = 0;
			p[3] = 150;
		}

	{
		int cx = PAD_X;

		for (int i = 0; i < n; i++) {
			const struct osd_glyph *g = gl[i].g;

			if (!g) continue;
			for (int y = 0; y < OSD_FONT_H; y++) {
				int py = PAD_Y + y;

				if (py >= H) break;
				for (int x = 0; x < g->adv; x++) {
					unsigned char *p;
					int pxx = cx + x;

					if (pxx >= W) break;
					if (!bit(g->off + (unsigned)y * g->adv + x))
						continue;
					p = px + ((size_t)py * W + pxx) * 4;
					p[0] = p[1] = p[2] = 255;
					p[3] = 255;
				}
			}
			cx += g->adv;
		}
	}

	*w = W;
	*h = H;
	return px;
}
