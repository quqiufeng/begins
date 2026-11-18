/*
 * aout — 独立音频输出模块（裸 ALSA ioctl，不依 libasound / mpv / ffmpeg）
 *
 *   ffmpeg ... -map 0:a:0 -ac 2 -ar 48000 -f s16le pipe:4 | aout
 *
 * 职责单一：把 stdin 上的 PCM 灌进 /dev/snd/pcmC0D0p，并对外提供
 * 音量/暂停/位置，让播放器不再为了音量跟 mpv 的 IPC 打来回（见 design_player.md §1.12）。
 *
 * 为什么不用 mpv --ao=alsa（§1.12 那一节的病根）：
 *   1. mpv 的 ao_alsa 只用 snd_pcm_set_params() 收 200ms 默认 buffer，
 *      docs/playback.md:182 记的「8 s 内 15 次 xrun」就是它 + 浅 period 来的；
 *      这里 buffer/period 由 AOUT_BUFFER/AOUT_PERIOD 直接指定，能放到硬件上限。
 *   2. 音量走本地整数增益，没有 get/set 两次 IPC 往返（mpvctl vol +5 会读旧值写新值，
 *      连按时丢帧）。
 *   3. 位置由 hw_ptr 算（written - delay），不是推算——视频侧要拿它当从时钟（§1.11 B）。
 *
 * 时钟：写 ring 是阻塞的，内核按采样率节流，所以"喂到第 N 帧"= "播到第 N 帧 - delay"。
 *
 * 控制口（AF_UNIX，一行一条，应答一行 JSON）：
 *   status | pause | resume | toggle | vol <0..100> | vol +N | vol -N | quit
 *
 * 环境变量：
 *   AOUT_DEV     默认 /dev/snd/pcmC0D0p
 *   AOUT_RATE    默认 48000          AOUT_CH  默认 2
 *   AOUT_FMT     s16le|s32le|s24le   AOUT_BUFFER 默认 8192 帧
 *   AOUT_PERIOD  默认 2048 帧        AOUT_SOCK 默认 /tmp/aout.sock
 *   AOUT_VOL     默认 100
 *   AOUT_QUIET   1 = 不打 stderr 统计
 *
 * 编译：aarch64-linux-gnu-gcc -O2 -static -pthread -o aout-aarch64 aout.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sound/asound.h>

/* ALSA uapi 只给了 SNDRV_PCM_IOCTL_PAUSE 这个 ioctl，参数语义在 pcm_native 里：
 * 1 = 暂停，0 = 恢复（老 soundcard.h 里的 AOUT_PAUSE_ON/RESUME）。 */
#define AOUT_PAUSE_ON   1
#define AOUT_PAUSE_OFF  0

static int   pcmfd = -1;
static unsigned int g_rate = 48000, g_ch = 2, g_fmt = SNDRV_PCM_FORMAT_S16_LE;
static unsigned int g_frame_bytes = 4;
static snd_pcm_uframes_t g_buf = 8192, g_period = 2048;
static const char *g_dev = "/dev/snd/pcmC0D0p";
#ifndef AOUT_EMBED
static const char *g_sock = "/tmp/aout.sock";	/* 只有独立模式有控制口 */
#endif
static int g_quiet;
static int g_in_fd = STDIN_FILENO;      /* PCM 来源：独立模式是 stdin，内嵌时由播放器给 */

static volatile sig_atomic_t g_quit;
static volatile int  g_paused;          /* 1 = 逻辑暂停 */
static int           g_pause_mode;      /* 0 未生效 / 1 硬件 PAUSE / 2 写静音兜底 */
static long          g_written;         /* 已写进 ring 的帧（累计） */
static long          g_frozen_ms = -1;  /* 暂停时冻结的播放位置 */
static int           g_xrun, g_vol = 100;
static volatile int  g_listen = -1;   /* 控制口 listen fd：上游 EOF 时要能把它踢醒 */
static int           g_underruns_recovered;
static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

#ifdef AOUT_EMBED
/* 内嵌进播放器（player）时不能 exit()：音频出错只该没有声音，画面必须继续。
 * 从播放线程里 pthread_exit 就是"这条线程收工"，主循环完全不受影响。 */
static void die(const char *what)
{
	fprintf(stderr, "aout: %s: %s（内嵌模式：音频停，画面继续）\n",
		what, strerror(errno));
	pthread_exit(NULL);
}
#else
static void die(const char *what)
{
	fprintf(stderr, "aout: %s: %s\n", what, strerror(errno));
	exit(1);
}
#endif

#ifndef AOUT_EMBED
static void on_sig(int s)
{
	(void)s;
	g_quit = 1;
}
#endif

/* 只为了打断 DRAIN：不带 SA_RESTART，让 ioctl 返回 EINTR 而不是被信号杀掉 */
static void on_alarm(int s) { (void)s; }

/* ---------- ALSA：只建一次参数，拒绝任何插件/转换层 ---------- */

static void iv_set(struct snd_pcm_hw_params *p, int id, unsigned int lo, unsigned int hi)
{
	struct snd_interval *i = &p->intervals[id - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
	i->min = lo;
	i->max = hi;
}

static int hw_setup(void)
{
	struct snd_pcm_hw_params p;
	int i, r;

	pcmfd = open(g_dev, O_RDWR);
	if (pcmfd < 0) return -1;	/* 声卡被占用/不存在：由调用方决定是"没声音"还是"退出" */

	memset(&p, 0, sizeof p);
	for (i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++)
		memset(&p.masks[i], 0xff, sizeof p.masks[i]);
	for (i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++)
		iv_set(&p, SNDRV_PCM_HW_PARAM_FIRST_INTERVAL + i, 0, ~0u);
	p.rmask = ~0u;
	p.cmask = ~0u;

	/* 关键：ACCESS 必须显式收敛成 RW_INTERLEAVED。
	 * 裸 ioctl 不像 libasound 那样替你置这个位，全开的默认值是 MMAP_INTERLEAVED，
	 * 而内核 snd_pcm_lib_write() 里写着：
	 *   if (runtime->access != RW_INTERLEAVED && runtime->channels > 1) return -EINVAL;
	 * 所以立体声 writei 会莫名 EINVAL（x86 上验过，aarch64 同理）。 */
	memset(&p.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0,
	       sizeof(struct snd_mask));
	p.masks[SNDRV_PCM_HW_PARAM_ACCESS - SNDRV_PCM_HW_PARAM_FIRST_MASK]
		.bits[SNDRV_PCM_ACCESS_RW_INTERLEAVED / 32] |= 1u << (SNDRV_PCM_ACCESS_RW_INTERLEAVED % 32);

	/* 缩到我们要的格式/采样率/声道 */
	memset(&p.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0,
	       sizeof(struct snd_mask));
	p.masks[SNDRV_PCM_HW_PARAM_FORMAT - SNDRV_PCM_HW_PARAM_FIRST_MASK]
		.bits[g_fmt / 32] |= 1u << (g_fmt % 32);
	iv_set(&p, SNDRV_PCM_HW_PARAM_RATE, g_rate, g_rate);
	iv_set(&p, SNDRV_PCM_HW_PARAM_CHANNELS, g_ch, g_ch);
	iv_set(&p, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, g_buf, g_buf);
	iv_set(&p, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, g_period, g_period);
	iv_set(&p, SNDRV_PCM_HW_PARAM_PERIODS, g_buf / g_period, g_buf / g_period);

	r = ioctl(pcmfd, SNDRV_PCM_IOCTL_HW_REFINE, &p);
	if (r < 0) return -1;
	r = ioctl(pcmfd, SNDRV_PCM_IOCTL_HW_PARAMS, &p);
	if (r < 0) return -1;

	/* 回读硬件真正给的尺寸 */
	g_buf = p.intervals[SNDRV_PCM_HW_PARAM_BUFFER_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max;
	g_period = p.intervals[SNDRV_PCM_HW_PARAM_PERIOD_SIZE - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL].max;
	if (ioctl(pcmfd, SNDRV_PCM_IOCTL_PREPARE, 0) < 0) return -1;
	return 0;
}

/* 已写但还没播出去的帧。
 * SNDRV_PCM_IOCTL_DELAY 是 _IOR（内核 put_user 到你给的指针），arg 传 NULL 会 -EFAULT，
 * 于是 delay 恒 0、played_ms 虚高——x86 上就是这么暴露的。 */
static long pcm_delay(void)
{
	snd_pcm_sframes_t d = 0;
	ioctl(pcmfd, SNDRV_PCM_IOCTL_HWSYNC, 0);
	if (ioctl(pcmfd, SNDRV_PCM_IOCTL_DELAY, &d) < 0)
		return 0;
	return d < 0 ? 0 : (long)d;
}

static long played_frames(void)
{
	long w, d;
	pthread_mutex_lock(&lk);
	w = g_written;
	pthread_mutex_unlock(&lk);
	d = pcm_delay();
	return w - d < 0 ? 0 : w - d;
}

/* ---------- 音量：本地整数增益，0..100 ---------- */

static void scale_s16(short *s, unsigned int frames, int vol)
{
	unsigned int i, n = frames * g_ch;
	for (i = 0; i < n; i++) {
		int v = (int)s[i] * vol / 100;
		s[i] = v > 32767 ? 32767 : v < -32768 ? -32768 : v;
	}
}

static void scale_s32(int *s, unsigned int frames, int vol)
{
	unsigned int i, n = frames * g_ch;
	for (i = 0; i < n; i++) {
		long long v = (long long)s[i] * vol / 100;
		s[i] = v > 2147483647LL ? 2147483647 : v < -2147483648LL ? -2147483648 : (int)v;
	}
}

/* ---------- 播放线程：阻塞写，内核按采样率节流 ---------- */

static int write_all_frames(const void *buf, unsigned int frames)
{
	struct snd_xferi xf;
	unsigned int done = 0;

	while (done < frames && !g_quit) {
		xf.buf = (void *)((char *)buf + (size_t)done * g_frame_bytes);
		xf.frames = frames - done;
		xf.result = 0;
		if (ioctl(pcmfd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xf) < 0) {
			if (errno == EINTR) continue;
			if (errno == EPIPE) {          /* xrun：补一次 prepare 继续，别退出 */
				pthread_mutex_lock(&lk);
				g_xrun++;
				g_underruns_recovered++;
				pthread_mutex_unlock(&lk);
				ioctl(pcmfd, SNDRV_PCM_IOCTL_PREPARE, 0);
				if (!g_quiet)
					fprintf(stderr, "aout: xrun #%d，已 prepare 恢复\n", g_xrun);
				continue;
			}
			if (errno == EINVAL || errno == ENODEV) {
				/* 参数被硬件拒了：把现场打出来，别静默退出 */
				struct snd_pcm_status st;
				memset(&st, 0, sizeof st);
				ioctl(pcmfd, SNDRV_PCM_IOCTL_STATUS, &st);
				fprintf(stderr, "aout: writei EINVAL: 要写 %u 帧(period=%lu buffer=%lu "
					"fmt=%u rate=%u ch=%u) 状态=%d result=%ld\n",
					frames - done, (unsigned long)g_period,
					(unsigned long)g_buf, g_fmt, g_rate, g_ch,
					st.state, (long)xf.result);
				return -1;
			}
			if (errno == ESTRPIPE || errno == EBADFD) {
				ioctl(pcmfd, SNDRV_PCM_IOCTL_PREPARE, 0);
				continue;
			}
			return -1;
		}
		done += xf.result;
		pthread_mutex_lock(&lk);
		g_written += xf.result;
		pthread_mutex_unlock(&lk);
	}
	return 0;
}

static void *play_thread(void *arg)
{
	unsigned int chunk = g_period;                 /* 一次一个 period，够大够省 */
	size_t chunk_bytes = (size_t)chunk * g_frame_bytes;
	char *buf = malloc(chunk_bytes);
	size_t have = 0;
	double t0 = now_s();

	(void)arg;
	if (!buf) die("malloc");

	while (!g_quit) {
		ssize_t n;

		if (g_paused) {
			pthread_mutex_lock(&lk);
			if (g_pause_mode == 2) {              /* 兜底：写静音占住 dma */
				pthread_mutex_unlock(&lk);
				memset(buf, 0, chunk_bytes);
				write_all_frames(buf, chunk);
				continue;
			}
			while (g_paused && !g_quit)
				pthread_cond_wait(&cv, &lk);
			pthread_mutex_unlock(&lk);
			continue;
		}

		n = read(g_in_fd, buf + have, chunk_bytes - have);
		if (n == 0) {                                 /* 上游 EOF = 播完 */
			if (have >= g_frame_bytes) {          /* 尾巴不满一个 period 也要放出去 */
				unsigned int tail = (unsigned int)(have / g_frame_bytes);
				int vol;
				pthread_mutex_lock(&lk);
				vol = g_vol;
				pthread_mutex_unlock(&lk);
				if (vol != 100) {
					if (g_fmt == SNDRV_PCM_FORMAT_S16_LE)
						scale_s16((short *)buf, tail, vol);
					else
						scale_s32((int *)buf, tail, vol);
				}
				write_all_frames(buf, tail);
			}
			g_quit = 1;
			if (g_listen >= 0) shutdown(g_listen, SHUT_RDWR);
			break;
		}
		if (n < 0) {
			if (errno == EINTR) continue;
			fprintf(stderr, "aout: 输入: %s\n", strerror(errno));
			break;
		}
		have += (size_t)n;
		if (have < chunk_bytes) continue;

		/* 满一个 period 才写，帧对齐 */
		{
			unsigned int frames = chunk;
			int vol;
			pthread_mutex_lock(&lk);
			vol = g_vol;
			pthread_mutex_unlock(&lk);
			if (vol != 100) {
				if (g_fmt == SNDRV_PCM_FORMAT_S16_LE)
					scale_s16((short *)buf, frames, vol);
				else
					scale_s32((int *)buf, frames, vol);
			}
		}
		have = 0;
		if (write_all_frames(buf, chunk) < 0) {
			fprintf(stderr, "aout: writei: %s\n", strerror(errno));
			break;
		}
	}
	free(buf);

	if (!g_quiet) {
		double dt = now_s() - t0;
		double wd = g_written * 1000.0 / g_rate / 1000.0;
		fprintf(stderr, "aout: 退出 wall=%.2fs 写入=%.2fs 差=%+.0f ms(≈buffer 深度) xrun=%d\n",
			dt, wd, (wd - dt) * 1000.0, g_xrun);
	}
	return NULL;
}

/* ---------- 控制口（只有独立模式有：内嵌时由播放器直接调本模块的 API） ---------- */

#ifndef AOUT_EMBED
struct cmd_ctx { int fd; };

static void reply(int fd, const char *json)
{
	size_t n = strlen(json);
	while (n) {
		ssize_t w = write(fd, json, n);
		if (w <= 0) return;
		json += w;
		n -= (size_t)w;
	}
}

static void do_status(int fd)
{
	char b[512];
	long played = g_frozen_ms >= 0 ? g_frozen_ms * g_rate / 1000 : played_frames();
	long d = pcm_delay();
	int paused, vol, xrun;
	struct snd_pcm_status st;

	memset(&st, 0, sizeof st);
	ioctl(pcmfd, SNDRV_PCM_IOCTL_STATUS, &st);
	pthread_mutex_lock(&lk);
	paused = g_paused;
	vol = g_vol;
	xrun = g_xrun;
	pthread_mutex_unlock(&lk);

	snprintf(b, sizeof b,
		 "{\"state\":\"%s\",\"pause\":%d,\"played_ms\":%ld,\"delay_ms\":%ld,"
		 "\"buffer_ms\":%.1f,\"period_ms\":%.1f,\"vol\":%d,\"xrun\":%d,"
		 "\"rate\":%u,\"ch\":%u,\"written\":%ld}\n",
		 st.state == SNDRV_PCM_STATE_RUNNING ? "RUNNING" :
		 st.state == SNDRV_PCM_STATE_PAUSED  ? "PAUSED"  :
		 st.state == SNDRV_PCM_STATE_XRUN    ? "XRUN"    :
		 st.state == SNDRV_PCM_STATE_PREPARED? "PREPARED": "OTHER",
		 paused, played * 1000 / g_rate, d * 1000 / g_rate,
		 g_buf * 1000.0 / g_rate, g_period * 1000.0 / g_rate,
		 vol, xrun, g_rate, g_ch, g_written);
	reply(fd, b);
}
#endif /* !AOUT_EMBED */

/* 注意：不能在持 lk 的情况下调 played_frames()——它自己会锁 lk（非递归互斥），
 * 板上第一次测就死在这：pause 一条命令直接把进程锁死。位置先算，再动状态。 */
static void set_pause(int on)
{
	int mode;
	long frozen;

	pthread_mutex_lock(&lk);
	if (on && g_paused) { pthread_mutex_unlock(&lk); return; }
	if (!on && !g_paused) { pthread_mutex_unlock(&lk); return; }
	pthread_mutex_unlock(&lk);

	if (on) {
		frozen = played_frames() * 1000 / g_rate;
		/* 先试硬件暂停：dma 停住、ring 不动，resume 后是连续的 */
		if (ioctl(pcmfd, SNDRV_PCM_IOCTL_PAUSE, AOUT_PAUSE_ON) == 0)
			mode = 1;
		else
			mode = 2;   /* dai 不认 pause：退化成写静音，保住 dma 不欠载 */
		pthread_mutex_lock(&lk);
		g_pause_mode = mode;
		g_paused = 1;
		g_frozen_ms = frozen;
		pthread_mutex_unlock(&lk);
		if (!g_quiet && mode == 2)
			fprintf(stderr, "aout: 硬件 PAUSE 不支持(%s)，用静音兜底\n", strerror(errno));
	} else {
		pthread_mutex_lock(&lk);
		mode = g_pause_mode;
		g_paused = 0;
		g_frozen_ms = -1;
		g_pause_mode = 0;
		pthread_cond_broadcast(&cv);
		pthread_mutex_unlock(&lk);
		if (mode == 1)
			ioctl(pcmfd, SNDRV_PCM_IOCTL_PAUSE, AOUT_PAUSE_OFF);
	}
}

static void set_vol(int v)
{
	if (v < 0) v = 0;
	if (v > 100) v = 100;
	pthread_mutex_lock(&lk);
	g_vol = v;
	pthread_mutex_unlock(&lk);
}

#ifndef AOUT_EMBED
/* 返回 1 = 要退出 */
static int handle_line(int fd, char *line)
{
	char *a = strtok(line, " \t\r\n");
	char *b = strtok(NULL, " \t\r\n");

	if (!a) return 0;
	if (!strcmp(a, "status")) { do_status(fd); return 0; }
	if (!strcmp(a, "pause"))  { set_pause(1); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "resume")) { set_pause(0); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "toggle")) {
		int p;
		pthread_mutex_lock(&lk); p = g_paused; pthread_mutex_unlock(&lk);
		set_pause(!p);
		reply(fd, "{\"ok\":1}\n");
		return 0;
	}
	if (!strcmp(a, "vol") && b) {
		int cur, nv;
		pthread_mutex_lock(&lk); cur = g_vol; pthread_mutex_unlock(&lk);
		if (b[0] == '+' || b[0] == '-')
			nv = cur + atoi(b);       /* 相对：算在模块内部，调用方不做读改写 */
		else
			nv = atoi(b);
		set_vol(nv);
		pthread_mutex_lock(&lk); nv = g_vol; pthread_mutex_unlock(&lk);
		{
			char r[64];
			snprintf(r, sizeof r, "{\"ok\":1,\"vol\":%d}\n", nv);
			reply(fd, r);
		}
		return 0;
	}
	if (!strcmp(a, "quit")) { g_quit = 1; reply(fd, "{\"ok\":1}\n"); return 1; }
	reply(fd, "{\"error\":\"unknown\"}\n");
	return 0;
}

static int ctl_serve(void)
{
	struct sockaddr_un sa;
	int lfd, cfd;
	char line[256];

	unlink(g_sock);
	lfd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (lfd < 0) die("socket");
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", g_sock);
	if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) < 0) die("bind");
	chmod(g_sock, 0666);
	if (listen(lfd, 8) < 0) die("listen");
	g_listen = lfd;

	while (!g_quit) {
		cfd = accept(lfd, NULL, NULL);
		if (cfd < 0) { if (errno == EINTR) continue; break; }
		for (;;) {                       /* 一个连接多条命令，短连接也行 */
			ssize_t n = read(cfd, line, sizeof line - 1);
			if (n <= 0) break;
			line[n] = 0;
			if (handle_line(cfd, line)) break;
		}
		close(cfd);
	}
	close(lfd);
	unlink(g_sock);
	return 0;
}

#endif /* !AOUT_EMBED */

#ifndef AOUT_EMBED
int main(int argc, char **argv)
{
	const char *e;
	pthread_t th;

	if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
		fprintf(stderr,
			"aout: 从 stdin 读 PCM 直接喂 ALSA 硬件，控制口 %s\n"
			"  AOUT_DEV/RATE/CH/FMT/BUFFER/PERIOD/VOL/SOCK/QUIET\n"
			"  命令: status pause resume toggle vol N|+N|-N quit\n", g_sock);
		return 0;
	}
	if ((e = getenv("AOUT_DEV")))    g_dev = e;
	if ((e = getenv("AOUT_SOCK")))   g_sock = e;
	if ((e = getenv("AOUT_RATE")))   g_rate = (unsigned)atoi(e);
	if ((e = getenv("AOUT_CH")))     g_ch = (unsigned)atoi(e);
	if ((e = getenv("AOUT_BUFFER"))) g_buf = (snd_pcm_uframes_t)atoi(e);
	if ((e = getenv("AOUT_PERIOD"))) g_period = (snd_pcm_uframes_t)atoi(e);
	if ((e = getenv("AOUT_VOL")))    g_vol = atoi(e);
	if ((e = getenv("AOUT_QUIET")))  g_quiet = atoi(e);
	if ((e = getenv("AOUT_FMT"))) {
		if (!strcmp(e, "s16le")) g_fmt = SNDRV_PCM_FORMAT_S16_LE;
		else if (!strcmp(e, "s32le")) g_fmt = SNDRV_PCM_FORMAT_S32_LE;
		else if (!strcmp(e, "s24le")) g_fmt = SNDRV_PCM_FORMAT_S24_LE;
		else { fprintf(stderr, "aout: 不认识的 AOUT_FMT=%s\n", e); return 1; }
	}
	g_frame_bytes = g_ch * (g_fmt == SNDRV_PCM_FORMAT_S16_LE ? 2 : 4);
	if (g_period == 0) g_period = g_buf / 4;
	if (g_buf < g_period * 2) g_buf = g_period * 2;

	if (hw_setup() < 0)
		die("hw_params（声卡被占用？拼 AOUT_BUFFER/AOUT_PERIOD 太大？）");

	if (!g_quiet)
		fprintf(stderr, "aout: %s %u Hz %uch %s buffer=%.0f ms(%lu 帧) period=%.0f ms(%lu 帧)\n",
			g_dev, g_rate, g_ch,
			g_fmt == SNDRV_PCM_FORMAT_S16_LE ? "s16le" : "s32le",
			g_buf * 1000.0 / g_rate, (unsigned long)g_buf,
			g_period * 1000.0 / g_rate, (unsigned long)g_period);

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGPIPE, SIG_IGN);
	{
		struct sigaction sa;
		memset(&sa, 0, sizeof sa);
		sa.sa_handler = on_alarm;
		sa.sa_flags = 0;              /* 关键：不设 SA_RESTART */
		sigaction(SIGALRM, &sa, NULL);
	}

	if (pthread_create(&th, NULL, play_thread, NULL) != 0) die("pthread_create");
	ctl_serve();

	g_quit = 1;
	pthread_cond_broadcast(&cv);
	/* 退出：默认 DROP，不等。axg 上 DRAIN 会永久挂住（实测：进程打完退出统计后卡死在
	 * SNDRV_PCM_IOCTL_DRAIN，连接它上游的脚本一起卡住）。要收尾那 170 ms 才开 AOUT_DRAIN=1。 */
	if (getenv("AOUT_DRAIN")) {
		alarm(2);                        /* 兜底：2 s 后 EINTR 打断 */
		if (ioctl(pcmfd, SNDRV_PCM_IOCTL_DRAIN, 0) < 0 && errno == EINTR)
			fprintf(stderr, "aout: DRAIN 超时，改 DROP\n");
		alarm(0);
	} else {
		ioctl(pcmfd, SNDRV_PCM_IOCTL_DROP, 0);
	}
	pthread_join(th, NULL);
	close(pcmfd);
	return 0;
}
#endif /* !AOUT_EMBED —— 独立模式到此为止 */

/* ---------- 内嵌 API：播放器内建音频，盒上不再单独一个音频二进制 ----------
 *
 * 与独立模式的区别只有三点：PCM 从调用方给的 fd 来（不是 stdin）、
 * 不自带控制口（播放器的 /tmp/play.sock 统一转发命令）、出错 pthread_exit
 * 而不是 exit（没有声音也不能把画面带走）。
 */
#ifdef AOUT_EMBED
static pthread_t g_th;
static int g_th_on;

int aout_open(int rate, int ch, const char *fmt, int buf, int period,
	      int vol, int quiet)
{
	if (rate > 0)   g_rate = (unsigned)rate;
	if (ch > 0)     g_ch = (unsigned)ch;
	if (buf > 0)    g_buf = (snd_pcm_uframes_t)buf;
	if (period > 0) g_period = (snd_pcm_uframes_t)period;
	if (vol >= 0)   g_vol = vol;
	g_quiet = quiet;

	if (fmt) {
		if (!strcmp(fmt, "s16le"))      g_fmt = SNDRV_PCM_FORMAT_S16_LE;
		else if (!strcmp(fmt, "s32le")) g_fmt = SNDRV_PCM_FORMAT_S32_LE;
		else if (!strcmp(fmt, "s24le")) g_fmt = SNDRV_PCM_FORMAT_S24_LE;
		else return -2;
	}
	g_frame_bytes = g_ch * (g_fmt == SNDRV_PCM_FORMAT_S16_LE ? 2 : 4);
	if (g_period == 0) g_period = g_buf / 4;
	if (g_buf < g_period * 2) g_buf = g_period * 2;

	/* 暂停要能打断 ioctl，得让 SIGALRM 不带 SA_RESTART */
	{
		struct sigaction sa;

		memset(&sa, 0, sizeof sa);
		sa.sa_handler = on_alarm;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sigaction(SIGALRM, &sa, NULL);
	}
	signal(SIGPIPE, SIG_IGN);

	if (hw_setup() < 0) {
		if (pcmfd >= 0) { close(pcmfd); pcmfd = -1; }
		return -1;
	}
	if (!g_quiet)
		fprintf(stderr, "aout: 内嵌 %s %u Hz %uch buffer=%.0f ms(%lu 帧) period=%.0f ms\n",
			g_dev, g_rate, g_ch, g_buf * 1000.0 / g_rate,
			(unsigned long)g_buf, g_period * 1000.0 / g_rate);
	return 0;
}

/* 起播放线程：从 infd 读 PCM。返回 0 成功。 */
int aout_start(int infd)
{
	g_in_fd = infd;
	if (!pcmfd) return -1;
	if (g_th_on) return 0;
	if (pthread_create(&g_th, NULL, play_thread, NULL) != 0) return -1;
	g_th_on = 1;
	return 0;
}

void aout_set_paused(int on) { set_pause(on); }
int  aout_paused(void)
{
	int p;

	pthread_mutex_lock(&lk);
	p = g_paused;
	pthread_mutex_unlock(&lk);
	return p;
}

void aout_set_vol_abs(int v) { set_vol(v); }
int  aout_vol(void)
{
	int v;

	pthread_mutex_lock(&lk);
	v = g_vol;
	pthread_mutex_unlock(&lk);
	return v;
}

/* 已播毫秒（hw_ptr 折算，不是推算）：视频侧可以拿它当从时钟 */
long aout_played_ms(void)
{
	if (pcmfd < 0) return -1;
	if (g_frozen_ms >= 0) return g_frozen_ms;
	return played_frames() * 1000L / (long)g_rate;
}

int aout_xrun(void)
{
	int x;

	pthread_mutex_lock(&lk);
	x = g_xrun;
	pthread_mutex_unlock(&lk);
	return x;
}

int aout_running(void) { return pcmfd >= 0; }

void aout_stop(void)
{
	if (pcmfd < 0) return;
	g_quit = 1;
	pthread_cond_broadcast(&cv);
	if (g_th_on) { pthread_join(g_th, NULL); g_th_on = 0; }
	ioctl(pcmfd, SNDRV_PCM_IOCTL_DROP, 0);
	close(pcmfd);
	pcmfd = -1;
}
#endif /* AOUT_EMBED */
