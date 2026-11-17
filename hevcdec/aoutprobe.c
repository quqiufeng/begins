/*
 * aoutprobe — ALSA PCM 裸 ioctl 能力探测（不依 libasound）
 *
 * 目的：验证 §1.12 翻案条件的第一条 —— 这块板子的 hw:0,0 到底能不能开大 buffer，
 *       以及大 buffer 能不能把 docs/playback.md:182 记的「8 s 内 15 次 xrun」压掉。
 *
 * 交叉编译：aarch64-linux-gnu-gcc -O2 -static -o aoutprobe-aarch64 aoutprobe.c
 * 用法：   ./aoutprobe [/dev/snd/pcmC0D0p] [秒数]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sound/asound.h>

static const char *fmt_name(unsigned int f)
{
	switch (f) {
	case SNDRV_PCM_FORMAT_S16_LE: return "S16_LE";
	case SNDRV_PCM_FORMAT_S16_BE: return "S16_BE";
	case SNDRV_PCM_FORMAT_S24_LE: return "S24_LE";
	case SNDRV_PCM_FORMAT_S24_3LE: return "S24_3LE";
	case SNDRV_PCM_FORMAT_S32_LE: return "S32_LE";
	case SNDRV_PCM_FORMAT_FLOAT_LE: return "FLOAT_LE";
	case SNDRV_PCM_FORMAT_U8: return "U8";
	case SNDRV_PCM_FORMAT_S8: return "S8";
	case SNDRV_PCM_FORMAT_IEC958_SUBFRAME_LE: return "IEC958_SUBFRAME";
	default: return "?";
	}
}

static void ph(const char *k, unsigned int lo, unsigned int hi)
{
	printf("  %-14s %u .. %u\n", k, lo, hi);
}

static int refine_open(int fd, struct snd_pcm_hw_params *p)
{
	int i;
	memset(p, 0, sizeof(*p));
	/* 所有 mask 全开 */
	for (i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++)
		memset(&p->masks[i], 0xff, sizeof(p->masks[i]));
	/* 所有 interval 全开 */
	for (i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++) {
		p->intervals[i].min = 0;
		p->intervals[i].max = ~0u;
	}
	p->rmask = ~0u;
	p->cmask = ~0u;
	return ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, p);
}

static void dump_constraints(struct snd_pcm_hw_params *p)
{
#define IV(id) p->intervals[(id) - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL]
	unsigned int i, n;
	printf("  格式:");
	n = 0;
	for (i = 0; i < SNDRV_PCM_FORMAT_LAST; i++)
		if (p->masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[i / 32] & (1u << (i % 32))) {
			printf(" %s", fmt_name(i));
			if (++n > 8) { printf(" ..."); break; }
		}
	printf("\n");
	ph("channels", IV(SNDRV_PCM_HW_PARAM_CHANNELS).min,     IV(SNDRV_PCM_HW_PARAM_CHANNELS).max);
	ph("rate",     IV(SNDRV_PCM_HW_PARAM_RATE).min,        IV(SNDRV_PCM_HW_PARAM_RATE).max);
	ph("buffer",   IV(SNDRV_PCM_HW_PARAM_BUFFER_SIZE).min, IV(SNDRV_PCM_HW_PARAM_BUFFER_SIZE).max);
	ph("period",   IV(SNDRV_PCM_HW_PARAM_PERIOD_SIZE).min, IV(SNDRV_PCM_HW_PARAM_PERIOD_SIZE).max);
	ph("periods",  IV(SNDRV_PCM_HW_PARAM_PERIODS).min,     IV(SNDRV_PCM_HW_PARAM_PERIODS).max);
}

/* 设一组具体参数；max 步长策略由 big_buf 控制 */
static int set_params(int fd, unsigned int fmt, unsigned int rate, unsigned int ch,
		      unsigned int buf_frames, unsigned int period_frames,
		      struct snd_pcm_hw_params *out)
{
	struct snd_pcm_hw_params p;
	int r;

	r = refine_open(fd, &p);
	if (r < 0) return r;
	/* 同 aout.c：ACCESS 必须收敛成 RW_INTERLEAVED，否则 channels>1 的 writei 返回 EINVAL */
	memset(&p.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0, sizeof(struct snd_mask));
	p.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK]
		.bits[SNDRV_PCM_ACCESS_RW_INTERLEAVED / 32] |= 1u << (SNDRV_PCM_ACCESS_RW_INTERLEAVED % 32);
	memset(&p.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0, sizeof(struct snd_mask));
	p.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK].bits[fmt / 32] |= 1u << (fmt % 32);
#define SETIV(id, v) do { \
		p.intervals[(id) - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].min = (v); \
		p.intervals[(id) - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max = (v); \
	} while (0)
	SETIV(SNDRV_PCM_HW_PARAM_RATE, rate);
	SETIV(SNDRV_PCM_HW_PARAM_CHANNELS, ch);
	SETIV(SNDRV_PCM_HW_PARAM_BUFFER_SIZE, buf_frames);
	SETIV(SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period_frames);
	SETIV(SNDRV_PCM_HW_PARAM_PERIODS, buf_frames / period_frames);
	p.rmask = ~0u;
	p.cmask = ~0u;

	r = ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &p);
	if (r < 0) return r;
	r = ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &p);
	if (r < 0) return r;
	if (out) *out = p;
	return 0;
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* 播 n 秒静音，返回 (xrun 次数, 实际耗时) */
static int play_silence(int fd, unsigned int rate, unsigned int ch,
			unsigned int period_frames, int secs, int chunk, double *elapsed)
{
	static short sil[65536];
	struct snd_xferi xf;
	unsigned int frames = (unsigned long)rate * secs;
	int xrun = 0;
	double t0 = now_s();

	while (frames) {
		unsigned int n = frames > (unsigned)chunk ? (unsigned)chunk : frames;
		memset(sil, 0, n * ch * sizeof(short));
		xf.buf = sil;
		xf.frames = n;
		xf.result = 0;
		if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf) < 0) {
			int e = errno;
			if (e == EPIPE) { xrun++; ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0); continue; }
			fprintf(stderr, "  writei 失败: %s\n", strerror(e));
			break;
		}
		frames -= n;
	}
	*elapsed = now_s() - t0;
	return xrun;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/snd/pcmC0D0p";
	int secs = argc > 2 ? atoi(argv[2]) : 3;
	struct snd_pcm_info info;
	struct snd_pcm_hw_params p;
	struct snd_pcm_status st;
	int fd, r, xrun, big;
	double el;
	unsigned int buf, per;

	fd = open(dev, O_RDWR);
	if (fd < 0) { fprintf(stderr, "open %s: %s\n", dev, strerror(errno)); return 1; }

	memset(&info, 0, sizeof(info));
	if (ioctl(fd, SNDRV_PCM_IOCTL_INFO, &info) == 0)
		printf("%s: card=%u device=%u subdevices=%u/%u\n", dev,
		       info.card, info.device, info.subdevices_avail, info.subdevices_count);

	printf("\n== 硬件约束（HW_REFINE 全开）==\n");
	if (refine_open(fd, &p) < 0) { fprintf(stderr, "HW_REFINE: %s\n", strerror(errno)); return 1; }
	dump_constraints(&p);

	/* 三种 buffer 规模，各播一次，比 xrun */
	unsigned int cases[][2] = {
		/* buffer,  period  */
		{  2048,  512 },   /* mpv/ffmpeg 的默认量级 */
		{  8192, 2048 },   /* 64 KB @48k/2ch */
		{ 32768, 8192 },   /* 256 KB，看硬件给不给 */
	};
	const char *name[] = { "小(2048/512)", "中(8192/2048)", "大(32768/8192)" };

	for (big = 0; big < 3; big++) {
		buf = cases[big][0]; per = cases[big][1];
		r = set_params(fd, SNDRV_PCM_FORMAT_S16_LE, 48000, 2, buf, per, &p);
		if (r < 0) {
			printf("\n== %s == HW_PARAMS 失败: %s\n", name[big], strerror(errno));
			continue;
		}
		{
			unsigned int gb = p.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max;
			unsigned int gp = p.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max;
			printf("\n== %s == 实际 buffer=%u 帧(%.1f ms) period=%u 帧(%.1f ms)\n",
			       name[big], gb, gb * 1000.0 / 48000, gp, gp * 1000.0 / 48000);
			buf = gb; per = gp;
		}
		if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0) < 0)
			printf("  PREPARE 失败: %s\n", strerror(errno));

		/* 先用最大 buffer 灌满，模拟"一直喂满"的稳态 */
		xrun = play_silence(fd, 48000, 2, per, secs, 1024, &el);
		memset(&st, 0, sizeof(st));
		ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st);
		printf("  播 %ds: xrun=%d 耗时=%.2fs(差 %+.1f%%) 末态=%s\n",
		       secs, xrun, el, (el - secs) / secs * 100.0,
		       st.state == SNDRV_PCM_STATE_RUNNING ? "RUNNING" :
		       st.state == SNDRV_PCM_STATE_XRUN ? "XRUN" : "其他");
		ioctl(fd, SNDRV_PCM_IOCTL_DROP, 0);
	}
	close(fd);
	return 0;
}
