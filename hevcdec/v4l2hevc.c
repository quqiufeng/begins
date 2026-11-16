// V4L2 M2M HEVC decode smoke test for meson-vdec
// - feeds one access unit (AU) per OUTPUT buffer (driver matches frames by
//   vififo offset in sess->timestamps)
// - allocates >= DPB (16) capture buffers so amvdec_src_change() just resumes
// - handles V4L2_EVENT_SOURCE_CHANGE (real resolution change)
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <linux/videodev2.h>
#ifdef USE_DRM
#include <stdint.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#endif

#ifdef USE_GLOUT
/* glout.c：NV12 dmabuf → panfrost GLES3 上屏（HDR10→SDR tone map） */
void glout_set_drm_fd(int fd);
int glout_init(unsigned sw, unsigned sh);
int glout_frame(int fd_y, int fd_c, unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch);
void glout_reset(void);
#endif

#define DEV "/dev/video0"
#define NBUF_CAP_MAX 32
#define NBUF_CAP() (getenv("CAPBUF") ? atoi(getenv("CAPBUF")) : 20)
#define NBUF_OUT 32
#define OUT_DEPTH() (getenv("NBUF_OUT") ? atoi(getenv("NBUF_OUT")) : 8)
#define CAP_T V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
#define OUT_T V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE

static volatile sig_atomic_t g_reinit;	/* 定义在下方，xioctl 要先看到 */

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	for (;;) {
		r = ioctl(fd, req, arg);
		if (r != -1 || errno != EINTR)
			break;
		/* seek 打断：阻塞型 ioctl（DQBUF/DQEVENT）被 SIGUSR1 打断后
		 * 若继续重试，要等下一帧才返回——实测把 seek 拖满 3s 超时。
		 * 直接返回 EINTR，调用方 break 回主循环处理 g_reinit。
		 */
		if (g_reinit)
			return -1;
	}
	return r;
}

static void die(const char *m)
{
	fprintf(stderr, "FAIL %s: %s\n", m, strerror(errno));
	exit(1);
}

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static struct {
	void *mem[VIDEO_MAX_PLANES];
	size_t len[VIDEO_MAX_PLANES];
	int dmabuf[VIDEO_MAX_PLANES];	/* EXPBUF=1 时有效 */
	void *mem2[VIDEO_MAX_PLANES];	/* dmabuf fd 另开的映射（测访问属性用） */
} capbuf[NBUF_CAP_MAX];
static unsigned cap_count;

static struct { void *mem; size_t len; } outbuf[NBUF_OUT];
static int out_free[NBUF_OUT], out_nfree, n_out;

static unsigned char *stream;
static size_t stream_size;
static struct { size_t off, len; int key; } au[4096];
static int n_au;

static int fd;
/* seek 时驱动没法在同一个 V4L2 会话里接新码流（meson-vdec 直接
 * "Unrecognized dec_status 0000000F / Aborting decoding session"），
 * 必须重开 /dev/video0。DRM/GL 那一路不碰，所以屏幕不黑。
 */
static void on_usr1(int sig) { (void)sig; g_reinit = 1; }
#ifdef USE_GLOUT
static int g_gl_ready;
#endif
static unsigned g_w = 640, g_h = 360;
static int got, resets, g_refeed;
static int g_mark_first;	/* reinit 后等待首帧，打一行供脚本同步 */
/* 计时：把"纯解码吞吐"从启动/收尾/写盘里剥出来 */
static int got_queued;
static double t_first_q, t_last_q, t_first_rx, t_last_rx, t_write_acc, t_tm_acc;

static int nal_type(const unsigned char *p)
{
	return (p[0] >> 1) & 0x3f;
}

/* Split Annex-B stream into access units. */
static void parse_au(void)
{
	size_t i = 0;
	int cur_vcl = 0;
	size_t au_start = (size_t)-1;

	while (i + 4 < stream_size) {
		size_t sc, pl;
		int t, vcl, iru;

		if (!(stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1)) {
			i++;
			continue;
		}
		sc = (i >= 1 && stream[i-1] == 0) ? i - 1 : i;
		pl = i + 3;
		t = nal_type(&stream[pl]);
		vcl = (t <= 31);
		iru = (t == 32 || t == 33 || t == 34 || t == 35 ||
		       t == 39 || t == 41);

		if (au_start == (size_t)-1) {
			au_start = sc;
			cur_vcl = 0;
		} else if ((vcl && cur_vcl) || (iru && cur_vcl)) {
			if (n_au < 4096) {
				au[n_au].off = au_start;
				au[n_au].len = sc - au_start;
				au[n_au].key = 0;
				n_au++;
			}
			au_start = sc;
			cur_vcl = 0;
		}
		if (vcl)
			cur_vcl = 1;
		i = pl + 1;
	}
	if (au_start != (size_t)-1 && n_au < 4096 && stream_size > au_start) {
		au[n_au].off = au_start;
		au[n_au].len = stream_size - au_start;
		au[n_au].key = 0;
		n_au++;
	}
	if (n_au > 0)
		au[0].key = 1;
}

static void s_fmt_cap(unsigned w, unsigned h)
{
	struct v4l2_format f = {0};

	f.type = CAP_T;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M;
	f.fmt.pix_mp.num_planes = 2;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = w * h;
	f.fmt.pix_mp.plane_fmt[1].sizeimage = w * h / 2;
	f.fmt.pix_mp.plane_fmt[1].bytesperline = w / 2;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) die("S_FMT cap");
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	printf("S_FMT CAP : %ux%u pf=%08x sizeimage=%u\n", g_w, g_h,
	       f.fmt.pix_mp.pixelformat, f.fmt.pix_mp.plane_fmt[0].sizeimage);
}

static void g_fmt_cap(void)
{
	struct v4l2_format f = {0};

	f.type = CAP_T;
	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) return;
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	printf("G_FMT CAP : %ux%u\n", g_w, g_h);
}

static void cap_release(void)
{
	struct v4l2_requestbuffers rb = {0};
	unsigned i;
	int p;

	for (i = 0; i < cap_count; i++)
		for (p = 0; p < VIDEO_MAX_PLANES; p++)
			if (capbuf[i].mem[p]) {
				munmap(capbuf[i].mem[p], capbuf[i].len[p]);
				capbuf[i].mem[p] = NULL;
			}
	cap_count = 0;
	rb.type = CAP_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 0;
	xioctl(fd, VIDIOC_REQBUFS, &rb);
}

static void cap_setup(void)
{
	struct v4l2_requestbuffers rb = {0};
	unsigned i;
	int p;

	unsigned want = NBUF_CAP_MAX;

	cap_release();
	if (getenv("CAPBUF")) {
		int v = atoi(getenv("CAPBUF"));
		if (v > 0) want = v > NBUF_CAP_MAX ? NBUF_CAP_MAX : (unsigned)v;
	} else {
		want = NBUF_CAP();
	}
	rb.type = CAP_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = want;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) < 0) die("REQBUFS cap");
	cap_count = rb.count > want ? want : rb.count;
	printf("cap buffers=%u\n", cap_count);

	for (i = 0; i < cap_count; i++) {
		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[2] = {{0}};

		b.type = CAP_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 2;
		b.m.planes = pl;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) die("QUERYBUF cap");
		for (p = 0; p < 2; p++) {
			capbuf[i].len[p] = pl[p].length;
			capbuf[i].dmabuf[p] = -1;
			if (getenv("NOMAP")) {		/* 零拷贝：不 mmap，只导出 */
				capbuf[i].mem[p] = NULL;
				continue;
			}
			capbuf[i].mem[p] = mmap(NULL, pl[p].length,
						PROT_READ | PROT_WRITE, MAP_SHARED,
						fd, pl[p].m.mem_offset);
			if (capbuf[i].mem[p] == MAP_FAILED) die("mmap cap");
		}
		if (getenv("EXPBUF") || getenv("PLAY")) {
			for (p = 0; p < 2; p++) {
				struct v4l2_exportbuffer eb = {0};

				eb.type = CAP_T;
				eb.index = i;
				eb.plane = p;
				eb.flags = O_CLOEXEC;
				if (xioctl(fd, VIDIOC_EXPBUF, &eb) < 0)
					die("EXPBUF cap");
				capbuf[i].dmabuf[p] = eb.fd;
			}
			if (i == 0)
				printf("dmabuf: buf0 Y=%d C=%d\n",
				       capbuf[0].dmabuf[0], capbuf[0].dmabuf[1]);
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0) die("QBUF cap");
	}
}

static void out_setup(void)
{
	struct v4l2_requestbuffers rb = {0};
	int i;

	out_nfree = 0;		/* 重开设备时会被二次调用，不清就会重复入队 */
	for (i = 0; i < NBUF_OUT; i++)
		if (outbuf[i].mem) {
			munmap(outbuf[i].mem, outbuf[i].len);
			outbuf[i].mem = NULL;
		}
	rb.type = OUT_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 0;
	xioctl(fd, VIDIOC_REQBUFS, &rb);

	rb.count = OUT_DEPTH();
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) < 0) die("REQBUFS out");
	n_out = rb.count;
	printf("out buffers=%u\n", rb.count);
	for (i = 0; i < (int)rb.count; i++) {
		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[1] = {{0}};

		b.type = OUT_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 1;
		b.m.planes = pl;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) die("QUERYBUF out");
		outbuf[i].len = pl[0].length;
		outbuf[i].mem = mmap(NULL, outbuf[i].len, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, pl[0].m.mem_offset);
		if (outbuf[i].mem == MAP_FAILED) die("mmap out");
		out_free[out_nfree++] = i;
	}
}

static void start_stream(void)
{
	int t = CAP_T;

	if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) die("STREAMON cap");
	t = OUT_T;
	if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) die("STREAMON out");
}

static void stop_stream(void)
{
	int t = OUT_T;

	xioctl(fd, VIDIOC_STREAMOFF, &t);
	t = CAP_T;
	xioctl(fd, VIDIOC_STREAMOFF, &t);
}

/* 喂一个 AU（流式：数据来自缓冲区，调用方保证本函数返回前有效） */
static unsigned g_au_seq;

static void qbuf_au(const unsigned char *data, size_t len, int key)
{
	int oi = out_free[--out_nfree];
	struct v4l2_buffer b = {0};
	struct v4l2_plane pl[1] = {{0}};

	if (len > outbuf[oi].len)
		die("AU 大于 OUTPUT 缓冲（调大 MAXAU）");
	memcpy(outbuf[oi].mem, data, len);
	pl[0].bytesused = len;
	pl[0].data_offset = 0;
	pl[0].length = outbuf[oi].len;
	b.type = OUT_T;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = oi;
	b.length = 1;
	b.m.planes = pl;
	b.bytesused = len;
	b.field = V4L2_FIELD_NONE;
	b.flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	if (key)
		b.flags |= V4L2_BUF_FLAG_KEYFRAME;
	b.timestamp.tv_sec = g_au_seq / 25;
	b.timestamp.tv_usec = (g_au_seq % 25) * 40000;
	g_au_seq++;
	if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
		fprintf(stderr, "QBUF out: idx=%d n_out=%d nfree=%d len=%zu/%zu\n",
			oi, n_out, out_nfree, len, outbuf[oi].len);
		die("QBUF out");
	}
	if (!got_queued)
		t_first_q = now_s();
	t_last_q = now_s();
	got_queued++;
}

static int eos_seen, g_verbose;
static int handle_event(void)
{
	struct v4l2_event ev;

	memset(&ev, 0, sizeof(ev));
	if (xioctl(fd, VIDIOC_DQEVENT, &ev) < 0)
		return 0;
	if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
		unsigned ow = g_w, oh = g_h, nw, nh;

		g_fmt_cap();
		nw = g_w;
		nh = g_h;
		printf("EVENT SOURCE_CHANGE %ux%u (was %ux%u, frames=%d)\n",
		       nw, nh, ow, oh, got);
		if (nw == ow && nh == oh) {
			printf("(same resolution, driver resumed)\n");
			return 0;   /* amvdec_src_change() already resumed */
		}
		if (++resets > 3) {
			printf("too many resets\n");
			exit(1);
		}
		stop_stream();
		s_fmt_cap(nw, nh);
		cap_setup();
		out_nfree = 0;
		out_setup();
		start_stream();
		g_refeed = 1;     /* main() 从 AU 0 重喂 */
		return 0;
	}
	if (ev.type == V4L2_EVENT_EOS) {
		if (g_verbose) printf("EVENT EOS\n");
		eos_seen = 1;
	}
	return 0;
}

static unsigned capw, caph;
static FILE *out;

/* plane0 常按 64 行对齐（如 720->768），必须按 stride 逐行取，不能整块 blob 写 */
static void write_nv12(unsigned idx, unsigned w, unsigned h)
{
	unsigned ph = (h + 63) & ~63u, stride = w, y;
	unsigned char *p0 = capbuf[idx].mem[0], *p1 = capbuf[idx].mem[1];

	if (capbuf[idx].len[0] % ph == 0 && capbuf[idx].len[0] / ph >= w)
		stride = capbuf[idx].len[0] / ph;
	for (y = 0; y < h; y++)
		fwrite(p0 + (size_t)y * stride, 1, w, out);
	for (y = 0; y < h / 2; y++)
		fwrite(p1 + (size_t)y * stride, 1, w, out);
}

static void dump_frame(unsigned idx, struct v4l2_plane *pl)
{
	static unsigned char pat[64];
	unsigned i, n = capbuf[idx].len[0];
	unsigned char *y = capbuf[idx].mem[0];

	if (got == 0) {
		memcpy(pat, y, 64);
		printf("first pixels:");
		for (i = 0; i < 16; i++)
			printf(" %02x", y[i]);
		printf("\n");
	} else if (g_verbose) {
		int same = !memcmp(pat, y, 64);
		printf("  plane0 same-as-first=%d\n", same);
	}
	if (g_verbose) {
		unsigned long sum = 0;

		for (i = 0; i < n; i += 97)
			sum += y[i];
		printf("  bytes=%u/%u ysum=%lu\n", pl[0].bytesused,
		       pl[1].bytesused, sum);
	}
}

/* ---- minimal HEVC SPS parser: get coded width/height before REQBUFS ----
 * Needed because the meson-vdec driver sizes CAPTURE buffers from the
 * format set at S_FMT time; with the wrong size no frame ever completes,
 * and since vb2_fop_poll() does not wake on V4L2 events the
 * SOURCE_CHANGE event would only be noticed on the next POLLIN -> deadlock.
 */
struct bitrd { const unsigned char *p; size_t bits, pos; };

static unsigned br_bits(struct bitrd *b, int n)
{
	unsigned v = 0;

	while (n-- > 0) {
		size_t byte = b->pos >> 3;

		if (byte >= b->bits)
			return 0;
		v = (v << 1) | ((b->p[byte] >> (7 - (b->pos & 7))) & 1);
		b->pos++;
	}
	return v;
}

static unsigned br_ue(struct bitrd *b)
{
	int lz = 0;

	while (br_bits(b, 1) == 0) {
		if (++lz > 31)
			return 0;
	}
	if (!lz)
		return 0;
	return ((1u << lz) - 1) + br_bits(b, lz);
}

/* 解析一个 SPS RBSP：ptl 为 profile_tier_level 的位数（多数编码器 88，
 * 但见过写 96 的），返回 1 表示字段自洽。
 */
static int sps_try(const unsigned char *d, size_t nbytes, int ptl,
		   unsigned *ow, unsigned *oh)
{
	struct bitrd b = { d, nbytes * 8, 8 + (size_t)ptl };
	unsigned sid, chroma, w, h, conf, bdl, bdc, poc;

	sid = br_ue(&b);
	chroma = br_ue(&b);
	if (chroma > 3)
		return 0;
	if (chroma == 3)
		br_bits(&b, 1);
	w = br_ue(&b);
	h = br_ue(&b);
	conf = br_bits(&b, 1);

	/* conformance window（色度单位）紧跟 conf flag，顺序不能挪 */
	{
		unsigned l = 0, r = 0, t = 0, bo = 0;

		if (conf) {
			l = br_ue(&b);
			r = br_ue(&b);
			t = br_ue(&b);
			bo = br_ue(&b);
		}
		bdl = br_ue(&b);
		bdc = br_ue(&b);
		poc = br_ue(&b);
		if (bdl > 8 || bdc > 8 || poc > 12)
			return 0;
		if (getenv("SPSDBG"))
			printf("SPSDBG raw id=%u chroma=%u %ux%u conf=%u crop=%u,%u,%u,%u bd_luma=%u bd_chroma=%u poc=%u\n",
			       sid, chroma, w, h, conf, l, r, t, bo, bdl, bdc, poc);
		if (conf) {
			unsigned sub = (chroma == 1 || chroma == 2) ? 2 : 1;

			if (l + r >= w || t + bo >= h)
				return 0;
			w -= (l + r) * sub;
			h -= (t + bo) * sub;
		}
	}
	if (w < 64 || h < 64 || w > 8192 || h > 8192)
		return 0;
	if ((w & 7) || (h & 7))
		return 0;
	*ow = w;
	*oh = h;
	return 1;
}

/* ------------------------------------------------------------------
 * 流式 AU 读取：不整片读入内存，支持 stdin/管道，可播任意长片源。
 * 只保留"当前 AU + 未扫完的尾巴"，窗口因此很小（几 MB）。
 * ------------------------------------------------------------------ */
static int s_fd = -1;		/* 码流 fd（文件或 STDIN） */
static unsigned char *s_buf;
static size_t s_cap, s_len;	/* 缓冲区容量 / 有效字节 */
static size_t s_pos;		/* 扫描位置 */
static size_t s_au_start;	/* 当前 AU 起点 */
static int s_au_open, s_cur_vcl, s_eof, s_release, s_au_irap;
static size_t g_stream_bytes;	/* 已消费字节，用于码率统计 */
static int g_stream_au;		/* 已产出 AU 数 */

static void s_fill(size_t want)
{
	if (s_eof)
		return;
	if (s_len + want > s_cap) {
		size_t nc = s_cap ? s_cap : (4u << 20);

		while (nc < s_len + want)
			nc *= 2;
		{
			unsigned char *nb = realloc(s_buf, nc);

			if (!nb)
				die("realloc stream");
			s_buf = nb;
			s_cap = nc;
		}
	}
	for (;;) {
		ssize_t r = read(s_fd, s_buf + s_len, s_cap - s_len);

		if (r < 0) {
			if (errno == EINTR) {
				/* 阻塞在 read() 等 ffmpeg 供流时收到 seek 信号：
				 * 别重新阻塞回去，交给主循环重建会话。
				 */
				if (g_reinit)
					return;
				continue;
			}
			die("read stream");
		}
		if (r == 0) {
			s_eof = 1;
			return;
		}
		s_len += r;
		return;
	}
}

/* 上一轮交出的 AU 已被调用方 memcpy 走，这里可以丢弃前缀 */
static void s_compact(void)
{
	if (!s_release)
		return;
	if (s_au_start) {
		memmove(s_buf, s_buf + s_au_start, s_len - s_au_start);
		s_len -= s_au_start;
		s_pos -= s_au_start;
		s_au_start = 0;
	}
	s_release = 0;
}

/* 取出下一个 AU：1=有，0=结束。*out 在下一次调用前有效。 */
static int stream_next_au(const unsigned char **out, size_t *outlen)
{
	s_compact();
	for (;;) {
		while (s_pos + 4 <= s_len) {
			unsigned char *p = s_buf + s_pos;
			size_t sc, pl;
			int t, vcl, iru;

			if (!(p[0] == 0 && p[1] == 0 && p[2] == 1)) {
				s_pos++;
				continue;
			}
			sc = (s_pos >= 1 && s_buf[s_pos - 1] == 0) ? s_pos - 1 : s_pos;
			pl = s_pos + 3;
			t = nal_type(&s_buf[pl]);
			vcl = (t <= 31);
			iru = (t == 32 || t == 33 || t == 34 || t == 35 ||
			       t == 39 || t == 41);

			if (!s_au_open) {
				s_au_start = sc;
				s_au_open = 1;
				s_cur_vcl = 0;
				s_au_irap = 0;
			} else if ((vcl && s_cur_vcl) || (iru && s_cur_vcl)) {
				size_t len = sc - s_au_start;

				if (!len) {	/* 空 AU，跳过 */
					s_pos = sc;
					continue;
				}
				*out = s_buf + s_au_start;
				*outlen = len;
				g_stream_bytes += len;
				g_stream_au++;
				s_pos = sc;
				s_au_start = sc;
				s_cur_vcl = 0;
				s_release = 1;
				{
					int k = s_au_irap;

					s_au_irap = 0;
					return k ? 2 : 1;	/* 2 = 关键帧 */
				}
			}
			if (vcl) {
				s_cur_vcl = 1;
				if (t >= 16 && t <= 21)
					s_au_irap = 1;
			}
			s_pos = pl + 1;
		}
		if (s_eof) {
			if (s_au_open && s_len > s_au_start) {
				size_t len = s_len - s_au_start;
				int k = s_au_irap;

				*out = s_buf + s_au_start;
				*outlen = len;
				g_stream_bytes += len;
				g_stream_au++;
				s_au_start = s_len;
				s_au_open = 0;
				s_au_irap = 0;
				s_release = 1;
				return k ? 2 : 1;
			}
			return 0;
		}
		s_fill(1u << 20);
		if (g_reinit)
			return -1;	/* 被打断：既不是有 AU 也不是 EOS */
	}
}

static int sps_size(unsigned *ow, unsigned *oh)
{
	static unsigned char buf[8192];
	size_t i = 0;

	while (i + 6 < stream_size) {
		size_t pl;

		if (!(stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1)) {
			i++;
			continue;
		}
		pl = i + 3;                    /* NAL header */
		if (nal_type(&stream[pl]) == 33) {
			size_t n = 0, j = pl + 2;  /* skip 2-byte NAL header */
			static const int ptls[] = { 88, 96, 92, 100, 104 };
			unsigned k;

			/* 去防竞争字节，遇到下一个起始码停止 */
			for (; j < stream_size && n < sizeof(buf); j++) {
				if (n >= 2 && buf[n-1] == 0 && buf[n-2] == 0 &&
				    stream[j] == 3) {
					if (j + 1 >= stream_size ||
					    stream[j+1] > 3)
						break;
					continue;
				}
				if (j + 2 < stream_size && stream[j] == 0 &&
				    stream[j+1] == 0 && stream[j+2] == 1)
					break;
				buf[n++] = stream[j];
			}
			if (getenv("SPSDBG"))
				printf("SPSDBG nal=%zu n=%zu\n", i, n);
			if (n < 12)
				return 0;
			for (k = 0; k < sizeof(ptls) / sizeof(ptls[0]); k++) {
				if (sps_try(buf, n, ptls[k], ow, oh)) {
					if (getenv("SPSDBG"))
						printf("SPSDBG ptl=%d -> %ux%u\n",
						       ptls[k], *ow, *oh);
					return 1;
				}
			}
			return 0;
		}
		i = pl + 2;
	}
	return 0;
}

#ifdef USE_DRM
/* 零拷贝验证：vdec 导出的 NV12M 两块 dmabuf 能否被 card0 直接当成 NV12 fb */
static void drm_import_test(int yfd, int cfd, unsigned w, unsigned h)
{
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";
	struct drm_mode_fb_cmd2 fb = {0};
	struct drm_prime_handle ph;
	int dfd = open(dev, O_RDWR | O_CLOEXEC);
	uint32_t handles[2];

	if (dfd < 0) {
		printf("DRM: open %s failed: %s\n", dev, strerror(errno));
		return;
	}

	ph.fd = yfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("DRM: FD_TO_HANDLE(Y) failed: %s\n", strerror(errno));
		goto out;
	}
	handles[0] = ph.handle;

	ph.fd = cfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("DRM: FD_TO_HANDLE(C) failed: %s\n", strerror(errno));
		goto out;
	}
	handles[1] = ph.handle;
	printf("DRM: handles Y=%u C=%u\n", handles[0], handles[1]);

	fb.width = w;
	fb.height = h;
	fb.pixel_format = DRM_FORMAT_NV12;
	fb.handles[0] = handles[0];
	fb.handles[1] = handles[1];
	fb.pitches[0] = w;
	fb.pitches[1] = w;
	fb.offsets[0] = 0;
	fb.offsets[1] = 0;
	if (ioctl(dfd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0)
		printf("DRM: ADDFB2 NV12 %ux%u FAILED: %s\n", w, h, strerror(errno));
	else
		printf("DRM: ADDFB2 NV12 %ux%u OK fb_id=%u\n", w, h, fb.fb_id);
out:
	close(dfd);
}

/* ---------- HDR10 → SDR tone mapping（软件，就地改写 NV12） ----------
 * 输入：vdec 出来的是 8bit NV12，但内容是 PQ(SMPTE2084) + BT.2020，
 *       即"码值是 HDR 的，容器是 8bit 的" —— 直接上屏就是灰蒙蒙低对比。
 * 做法：Y 走一张 256 项 LUT（PQ 码 → 线性光 → 压缩 → BT.709 OETF 编码），
 *       Cb/Cr 按同点 Y 的码值增益等比缩放（保持色相/饱和度）再乘色域压缩系数。
 * 全部在已 mmap 的采集缓冲上原地做，不解码后拷内存、不加中间帧。
 *
 * 环境变量：
 *   TM=0|1|off|on|clip|curve|reinhard|hable   （默认：HDR=1 时开，curve 曲线）
 *   TM_SRC_PEAK=1000   内容峰值亮度 nits（HDR10 常见 1000，MasteringDisplay 可 4000）
 *   TM_TARGET=200      SDR 屏峰值/参考白 nits（面板亮就把这个调大）
 *   TM_SAT=0.85        BT.2020 → BT.709 色域压缩系数（1=不压，偏艳）
 *   TM_KNEE=0.7        拐点位置（0..1，越小越早压缩、越"电影感"）
 *   TMDIAG=1           打印映射前后 Y 的 min/max/mean
 */
#define TM_CLIP 0
#define TM_CURVE 1
#define TM_REINHARD 2
#define TM_HABLE 3

struct tmctx {
	int on, curve, diag, built, full, noop, time_it;
	double src_peak, target, sat, knee;
	unsigned char lut[256];		/* Y 单通道码值映射 */
	unsigned short gain[256];	/* Q10 增益：1024 = 1.0，给 Cb/Cr 用 */
	unsigned calls;
	double t_acc;
};
static struct tmctx tm;

/* ST 2084 (PQ) EOTF：码值 n∈[0,1] → 绝对亮度 nits */
static double pq_eotf(double n)
{
	const double m1 = 0.1593017578125, m2 = 78.84375;
	const double c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
	double np = pow(n, 1.0 / m2), num = np - c1, den = c2 - c3 * np;

	if (num <= 0.0) return 0.0;
	return 10000.0 * pow(num / den, 1.0 / m1);
}

/* 线性光 d∈[0,1]（1.0 = 屏幕白）→ BT.709 OETF → 有限范围码值 */
static double bt709_encode(double d)
{
	double e;

	if (d <= 0.0) return 16.0;
	if (d >= 1.0) return 235.0;
	e = (d < 0.018) ? 4.5 * d : 1.099 * pow(d, 0.45) - 0.099;
	return 16.0 + 219.0 * e;
}

static double tm_hable(double x)
{
	const double A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
	double f1 = (x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F);
	double fw = (1.0 * (A * 1.0 + C * B) + D * E) / (1.0 * (A * 1.0 + B) + D * F);

	return f1 / fw;
}

/* 归一化亮度 x（1.0 = 目标白）→ 屏上线性光 d∈[0,1] */
static double tm_curve(double x)
{
	switch (tm.curve) {
	case TM_CLIP:
		return x > 1.0 ? 1.0 : x;
	case TM_REINHARD:
		return 2.0 * x / (1.0 + x);
	case TM_HABLE:
		return tm_hable(x);
	default: {			/* 拐点以上指数软膝，以下不动 */
		double k = tm.knee, t;

		if (x <= k) return x;
		t = (x - k) / (1.0 - k);
		return k + (1.0 - k) * (1.0 - exp(-t));
	}
	}
}

static void tm_build(void)
{
	const char *e = getenv("TM");
	const char *hdr = getenv("HDR");
	int v;

	memset(&tm, 0, sizeof(tm));
	tm.curve = TM_CURVE;
	tm.src_peak = getenv("TM_SRC_PEAK") ? atof(getenv("TM_SRC_PEAK")) : 1000.0;
	tm.target = getenv("TM_TARGET") ? atof(getenv("TM_TARGET")) : 200.0;
	tm.sat = getenv("TM_SAT") ? atof(getenv("TM_SAT")) : 0.85;
	tm.knee = getenv("TM_KNEE") ? atof(getenv("TM_KNEE")) : 0.7;
	tm.diag = getenv("TMDIAG") != NULL;
	tm.noop = getenv("TMNOOP") != NULL;	/* 只读写不做变换：量带宽上限 */
	tm.time_it = getenv("TMTIME") != NULL;
	tm.full = getenv("TM_FULL") != NULL;	/* 源是全范围（少见） */
	if (tm.src_peak < tm.target) tm.src_peak = tm.target;
	if (tm.knee <= 0.05 || tm.knee >= 1.0) tm.knee = 0.7;
	if (tm.sat <= 0.0 || tm.sat > 2.0) tm.sat = 0.85;

	/* 开关：显式 TM= 优先，否则看 HDR=1（play.sh 用 ffprobe 判出来） */
	if (e && (!strcmp(e, "0") || !strcmp(e, "off") || !strcmp(e, "no"))) {
		tm.on = 0;
		return;
	}
	if (e && (!strcmp(e, "clip"))) tm.curve = TM_CLIP;
	else if (e && (!strcmp(e, "reinhard"))) tm.curve = TM_REINHARD;
	else if (e && (!strcmp(e, "hable"))) tm.curve = TM_HABLE;
	else if (e && (!strcmp(e, "curve") || !strcmp(e, "soft"))) tm.curve = TM_CURVE;
	if (e && (!strcmp(e, "1") || !strcmp(e, "on") || !strcmp(e, "yes") ||
		  !strcmp(e, "clip") || !strcmp(e, "curve") || !strcmp(e, "soft") ||
		  !strcmp(e, "reinhard") || !strcmp(e, "hable")))
		tm.on = 1;
	else
		tm.on = (hdr && (!strcmp(hdr, "1") || !strcmp(hdr, "on")));

	if (!tm.on) return;

	for (v = 0; v < 256; v++) {
		/* 源是 tv range（HDR10 都是），PQ 码值归一化 */
		double n = tm.full ? v / 255.0 : (v - 16) / 219.0;
		double L, x, d, out;
		double nin;

		if (n < 0.0) n = 0.0;
		if (n > 1.0) n = 1.0;
		L = pq_eotf(n);				/* nits */
		x = L / tm.target;			/* 归一化到目标白 */
		d = tm_curve(x);			/* 屏幕上线性光 0..1 */
		out = bt709_encode(d);
		tm.lut[v] = (unsigned char)(out + 0.5);

		/* 色度增益：码值域输出/输入（保持饱和度），再压色域 */
		nin = tm.full ? v / 255.0 : (v - 16) / 219.0;
		if (nin > 0.002) {
			double nout = (out - 16.0) / 219.0;
			double g = (nout / nin) * tm.sat;

			if (g < 0.0) g = 0.0;
			if (g > 3.9) g = 3.9;
			tm.gain[v] = (unsigned short)(g * 1024.0 + 0.5);
		} else {
			tm.gain[v] = 0;
		}
	}
	tm.built = 1;
	printf("TM: on curve=%s src_peak=%.0fnits target=%.0fnits sat=%.2f knee=%.2f\n",
	       tm.curve == TM_CLIP ? "clip" : tm.curve == TM_REINHARD ? "reinhard" :
	       tm.curve == TM_HABLE ? "hable" : "curve",
	       tm.src_peak, tm.target, tm.sat, tm.knee);
}

/* 就地映射一块 NV12（NV12M 两块 plane） */
static void tm_apply(int idx, unsigned w, unsigned h)
{
	unsigned char *yp, *cp;
	unsigned ystride, cstride, y, x;
	unsigned ymin = 255, ymax = 0;
	unsigned long ysum = 0;
	double t0;

	if (!tm.built) tm_build();
	if (!tm.on || !capbuf[idx].mem[0]) return;
	yp = capbuf[idx].mem2[0] ? capbuf[idx].mem2[0] : capbuf[idx].mem[0];
	cp = capbuf[idx].mem2[0] ? capbuf[idx].mem2[1] : capbuf[idx].mem[1];
	if (capbuf[idx].mem2[0] && tm.calls == 0)
		printf("TM: Y 走 dmabuf 映射 (mem2)\n");
	ystride = (capbuf[idx].len[0] % h == 0 && capbuf[idx].len[0] / h >= w) ?
		  capbuf[idx].len[0] / h : w;
	cstride = (cp && (h / 2) && capbuf[idx].len[1] % (h / 2) == 0) ?
		  capbuf[idx].len[1] / (h / 2) : w;
	t0 = (tm.diag || tm.time_it || tm.noop) ? now_s() : 0;

#ifdef HAVE_NEON
	/* Y 平面：ARMv8 TBL 一次查 64 字节表，4 条 TBL + 4 条 select 处理 16 像��。
	 * 采集缓冲是 Normal-NC 映射，ALU 几乎不占时间，瓶颈只在访存。
	 */
	if (!tm.diag && !tm.noop) {
		uint8x16_t t0 = vld1q_u8(tm.lut + 0);
		uint8x16_t t1 = vld1q_u8(tm.lut + 16);
		uint8x16_t t2 = vld1q_u8(tm.lut + 32);
		uint8x16_t t3 = vld1q_u8(tm.lut + 48);
		uint8x16_t t4 = vld1q_u8(tm.lut + 64);
		uint8x16_t t5 = vld1q_u8(tm.lut + 80);
		uint8x16_t t6 = vld1q_u8(tm.lut + 96);
		uint8x16_t t7 = vld1q_u8(tm.lut + 112);
		uint8x16_t t8 = vld1q_u8(tm.lut + 128);
		uint8x16_t t9 = vld1q_u8(tm.lut + 144);
		uint8x16_t ta = vld1q_u8(tm.lut + 160);
		uint8x16_t tb = vld1q_u8(tm.lut + 176);
		uint8x16_t tc = vld1q_u8(tm.lut + 192);
		uint8x16_t td = vld1q_u8(tm.lut + 208);
		uint8x16_t te = vld1q_u8(tm.lut + 224);
		uint8x16_t tf = vld1q_u8(tm.lut + 240);
		uint8x16x4_t q0 = {{t0, t1, t2, t3}};
		uint8x16x4_t q1 = {{t4, t5, t6, t7}};
		uint8x16x4_t q2 = {{t8, t9, ta, tb}};
		uint8x16x4_t q3 = {{tc, td, te, tf}};
		const uint8x16_t c0 = vdupq_n_u8(0), c1 = vdupq_n_u8(1);
		const uint8x16_t c2 = vdupq_n_u8(2), c3 = vdupq_n_u8(3);
		const uint8x16_t m63 = vdupq_n_u8(63);

		for (y = 0; y < h; y++) {
			unsigned char *r = yp + (size_t)y * ystride;

			for (x = 0; x + 16 <= w; x += 16) {
				uint8x16_t v = vld1q_u8(r + x);
				uint8x16_t idx = vandq_u8(v, m63);
				uint8x16_t hi = vshrq_n_u8(v, 6);
				uint8x16_t o;

				if (tm.noop) {
					o = v;
				} else {
					uint8x16_t a = vqtbl4q_u8(q0, idx);
					uint8x16_t b = vqtbl4q_u8(q1, idx);
					uint8x16_t c = vqtbl4q_u8(q2, idx);
					uint8x16_t d = vqtbl4q_u8(q3, idx);

					a = vbslq_u8(vceqq_u8(hi, c1), b, a);
					c = vbslq_u8(vceqq_u8(hi, c3), d, c);
					o = vbslq_u8(vceqq_u8(hi, c2), c, a);
					o = vbslq_u8(vceqq_u8(hi, c0), vqtbl4q_u8(q0, idx), o);
				}
				vst1q_u8(r + x, o);
			}
			for (; x < w; x++) r[x] = tm.noop ? r[x] : tm.lut[r[x]];
		}
	} else
#endif
	{
		for (y = 0; y < h; y++) {
			unsigned char *r = yp + (size_t)y * ystride;

			for (x = 0; x < w; x++) {
				unsigned char v = r[x];

				if (tm.diag) {
					if (v < ymin) ymin = v;
					if (v > ymax) ymax = v;
					ysum += v;
				}
				r[x] = tm.lut[v];
			}
		}
	}
	/* 色度：2x2 一块，用左上角 Y 的增益（够准，省一半查表） */
	if (cp) {
		for (y = 0; y + 1 < h; y += 2) {
			unsigned char *cr = cp + (size_t)(y / 2) * cstride;
			unsigned char *ry = yp + (size_t)y * ystride;

			for (x = 0; x + 1 < w; x += 2) {
				unsigned g = tm.gain[ry[x]];
				int u = cr[x], v = cr[x + 1];

				u = 128 + (((u - 128) * (int)g) >> 10);
				v = 128 + (((v - 128) * (int)g) >> 10);
				cr[x] = (unsigned char)(u < 0 ? 0 : u > 255 ? 255 : u);
				cr[x + 1] = (unsigned char)(v < 0 ? 0 : v > 255 ? 255 : v);
			}
		}
	}
	if (tm.diag && (tm.calls < 3 || tm.calls % 96 == 0))
		printf("TM: %ux%u stride=%u/%u Y in[%u..%u] mean=%.1f -> LUT out %.1fms\n",
		       w, h, ystride, cstride, ymin, ymax,
		       (double)ysum / ((double)w * h), (now_s() - t0) * 1000.0);
	tm.calls++;
	tm.t_acc += now_s() - t0;
	if (tm.time_it || tm.noop) {
		if (tm.calls < 4 || tm.calls % 24 == 0)
			printf("TM: frame %u %ux%u noop=%d cost=%.1fms (%.2f GB/s)\n",
			       tm.calls, w, h, tm.noop, (now_s() - t0) * 1000.0,
			       (double)w * h * 1.5 / (now_s() - t0) / 1e9);
	}
}

/* ---------- 播放：NV12 dmabuf → plane 缩放 → pageflip ---------- */
struct playctx {
	int dfd, ev_pending;
	uint32_t crtc_id, plane_id;
	unsigned dw, dh;		/* 屏幕模式尺寸 */
	uint32_t fb[NBUF_CAP_MAX];
	/* 屏上正在扫描的那个 fb：seek 重建时不能删，否则当场黑屏 */
	uint32_t cur_fb, prev_fb;
	double t0;			/* 首帧节拍基准 */
	int n;				/* 已翻页数 */
	int flips, timeouts, drops;
	double t_start;
	unsigned refresh;	/* 屏幕刷新率，节拍基准 */
	/* 目标矩形：按源宽高比算出的居中区域，两侧/上下留黑边 */
	int dx, dy; unsigned dW, dH; int rect_ok;
	unsigned rsw, rsh;
	uint32_t vbl_base;	/* 首帧时的 vblank 序列号 */
	int vbl_ok;		/* vblank 可用（否则退回 usleep） */
	uint32_t vbl_now;
};
static struct playctx pc;

static uint32_t play_addfb(int yfd, int cfd, unsigned sw, unsigned sh)
{
	struct drm_mode_fb_cmd2 fb = {0};
	struct drm_prime_handle ph;

	ph.fd = yfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(pc.dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("PLAY: PRIME_FD_TO_HANDLE(Y fd=%d): %s\n", yfd, strerror(errno));
		return 0;
	}
	fb.handles[0] = ph.handle;
	ph.fd = cfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(pc.dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("PLAY: PRIME_FD_TO_HANDLE(C fd=%d): %s\n", cfd, strerror(errno));
		return 0;
	}
	fb.handles[1] = ph.handle;

	fb.width = sw; fb.height = sh;
	fb.pixel_format = DRM_FORMAT_NV12;
	fb.pitches[0] = sw; fb.pitches[1] = sw;
	if (ioctl(pc.dfd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0) {
		printf("PLAY: ADDFB2 NV12 %ux%u pitch=%u/%u: %s\n", sw, sh,
		       fb.pitches[0], fb.pitches[1], strerror(errno));
		return 0;
	}
	return fb.fb_id;
}

static int play_setup(unsigned sw, unsigned sh)
{
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";
	struct drm_mode_card_res res = {0};
	uint32_t crtcs[16], conns[16], encs[16];
	uint32_t conn_id = 0, crtc_id = 0;
	struct drm_mode_modeinfo mode = {0};
	struct drm_mode_crtc set = {0};
	int i, j;

	pc.dfd = open(dev, O_RDWR | O_CLOEXEC);
	if (pc.dfd < 0) { printf("PLAY: open %s: %s\n", dev, strerror(errno)); return -1; }

	res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs; res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns; res.count_connectors = 16;
	res.encoder_id_ptr = (uint64_t)(uintptr_t)encs; res.count_encoders = 16;
	if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) return -1;

	for (i = 0; i < (int)res.count_connectors && !conn_id; i++) {
		struct drm_mode_get_connector gc = {0};
		static struct drm_mode_modeinfo modes[64];
		uint32_t enc = 0;

		gc.connector_id = conns[i];
		gc.modes_ptr = (uint64_t)(uintptr_t)modes;
		gc.count_modes = 64;
		gc.encoders_ptr = (uint64_t)(uintptr_t)&enc;
		gc.count_encoders = 1;
		if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0) continue;
		if (gc.connection != 1 || !gc.count_modes) continue;
		conn_id = gc.connector_id;
		enc = gc.encoder_id;
		/* 选能装下的最大模式，源更小时取等比最大不超过屏幕 */
		for (j = 0; j < (int)gc.count_modes; j++) {
			unsigned mw = modes[j].hdisplay, mh = modes[j].vdisplay;

			if (mw > 4096 || mh > 4096) continue;
			if (mw * (uint64_t)mh > (uint64_t)mode.hdisplay * mode.vdisplay)
				mode = modes[j];
		}
		if (gc.encoder_id) {
			struct drm_mode_get_encoder ge = {0};

			ge.encoder_id = gc.encoder_id;
			if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETENCODER, &ge) == 0 && ge.crtc_id)
				crtc_id = ge.crtc_id;
		}
	}
	if (!conn_id || !mode.hdisplay) { printf("PLAY: no connected connector\n"); return -1; }
	if (!crtc_id && res.count_crtcs) crtc_id = crtcs[0];
	pc.crtc_id = crtc_id; pc.dw = mode.hdisplay; pc.dh = mode.vdisplay;
	pc.refresh = mode.vrefresh ? mode.vrefresh : 60;
	printf("PLAY: conn=%u crtc=%u mode=%ux%u@%u  src=%ux%u\n", conn_id, crtc_id,
	       pc.dw, pc.dh, mode.vrefresh, sw, sh);

	/* primary plane 只认 RGB（ARGB/ABGR/XRGB/XBGR/RGB888/RGB565），不收 NV12。
	 * 所以点屏用一张全透明 ARGB8888：CRTC 起来、OSD 完全透明，
	 * 视频画面由 overlay plane 的 SETPLANE 叠加到下层。
	 */
	{
		struct drm_mode_fb_cmd2 dfb = {0};
		struct drm_mode_create_dumb dd = {0};
		struct drm_mode_map_dumb dm = {0};
		void *map;

		dd.width = pc.dw; dd.height = pc.dh; dd.bpp = 32;
		if (ioctl(pc.dfd, DRM_IOCTL_MODE_CREATE_DUMB, &dd) < 0) {
			printf("PLAY: CREATE_DUMB ARGB: %s\n", strerror(errno)); return -1;
		}
		dfb.width = pc.dw; dfb.height = pc.dh;
		dfb.pixel_format = DRM_FORMAT_ARGB8888;
		dfb.handles[0] = dd.handle; dfb.pitches[0] = dd.pitch;
		if (ioctl(pc.dfd, DRM_IOCTL_MODE_ADDFB2, &dfb) < 0) {
			printf("PLAY: ADDFB2 ARGB: %s\n", strerror(errno));
			return -1;
		}
		/* dumb 内容未定义，必须显式清零成全透明 */
		dm.handle = dd.handle;
		if (ioctl(pc.dfd, DRM_IOCTL_MODE_MAP_DUMB, &dm) < 0) {
			printf("PLAY: MAP_DUMB: %s\n", strerror(errno)); return -1;
		}
		map = mmap(NULL, dd.size, PROT_READ | PROT_WRITE, MAP_SHARED, pc.dfd, dm.offset);
		if (map != MAP_FAILED) {
			/* 不透明黑：黑边（letterbox）靠它兜底，同时避免
			 * 透明 plane 合成到未定义底色上出现彩边 */
			uint32_t *px = map;
			size_t n = dd.size / 4, i;

			for (i = 0; i < n; i++) px[i] = 0xff000000u;
			munmap(map, dd.size);
		}
		else printf("PLAY: mmap ARGB: %s (可能残留脏像素)\n", strerror(errno));
		set.crtc_id = crtc_id;
		set.fb_id = dfb.fb_id;
	}
	set.mode = mode;
	set.mode_valid = 1;	/* 少了这行，内核 mode=NULL -> EINVAL */
	set.count_connectors = 1;
	set.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
	if (ioctl(pc.dfd, DRM_IOCTL_MODE_SETCRTC, &set) < 0) {
		printf("PLAY: SETCRTC: %s\n", strerror(errno)); return -1;
	}
	/* 挑支持 NV12 的 plane（overlay），不能盲取 ids[0] */
	{
		struct drm_mode_get_plane_res pr = {0};
		uint32_t ids[32];
		int k;

		pr.plane_id_ptr = (uint64_t)(uintptr_t)ids;
		pr.count_planes = 32;
		if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr) < 0) {
			printf("PLAY: GETPLANERESOURCES: %s\n", strerror(errno)); return -1;
		}
		unsigned force = getenv("PLANE") ? (unsigned)atoi(getenv("PLANE")) : 0;
		int listp = getenv("PLANELIST") != NULL;

		for (k = 0; k < (int)pr.count_planes; k++) {
			struct drm_mode_get_plane gp = {0};
			uint32_t fmts[32];
			int f, nv12 = 0;

			gp.plane_id = ids[k];
			if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETPLANE, &gp) < 0) continue;
			gp.format_type_ptr = (uint64_t)(uintptr_t)fmts;
			gp.count_format_types = 32;
			if (ioctl(pc.dfd, DRM_IOCTL_MODE_GETPLANE, &gp) < 0) continue;
			for (f = 0; f < (int)gp.count_format_types; f++)
				if (fmts[f] == DRM_FORMAT_NV12) nv12 = 1;
			if (listp)
				printf("PLAY: plane=%u crtc=%u fmts=%u nv12=%d\n",
				       ids[k], gp.crtc_id, gp.count_format_types, nv12);
			if (!nv12) continue;
			if (force && ids[k] != force) continue;
			if (pc.plane_id) continue;
			pc.plane_id = ids[k];
			printf("PLAY: plane=%u 收 NV12 (%u 种格式) crtc=%u\n",
			       ids[k], gp.count_format_types, gp.crtc_id);
			if (!listp) break;
		}
		if (!pc.plane_id) { printf("PLAY: 没有收 NV12 的 plane\n"); return -1; }
	}
	pc.t_start = now_s();
	return 0;
}

/* 读当前 vblank 计数：RELATIVE 0 只回报 $sequence，不阻塞 */
static uint32_t play_vbl_seq(int *ok)
{
	union drm_wait_vblank wv = {0};

	wv.request.type = _DRM_VBLANK_RELATIVE;
	wv.request.sequence = 0;
	if (ioctl(pc.dfd, DRM_IOCTL_WAIT_VBLANK, &wv) < 0) {
		if (ok) *ok = 0;
		return 0;
	}
	if (ok) *ok = 1;
	return wv.reply.sequence;
}

/* 缩放策略：SCALE=fit(默认，保比例+黑边) / fill(强制铺满，会变形) /
 * crop(保比例放大裁边). 目标矩形只跟源尺寸有关，算一次缓存。
 */
static void play_rect(unsigned sw, unsigned sh)
{
	int fill = 0, crop = 0;
	const char *sm = getenv("SCALE");

	if (pc.rect_ok && pc.rsw == sw && pc.rsh == sh) return;
	pc.rsw = sw; pc.rsh = sh;
	if (sm && !strcmp(sm, "fill")) fill = 1;
	else if (sm && !strcmp(sm, "crop")) crop = 1;

	if (crop) {
		/* 铺满屏幕，超出部分裁掉 */
		pc.dx = 0; pc.dy = 0; pc.dW = pc.dw; pc.dH = pc.dh;
	} else if (fill) {
		pc.dx = 0; pc.dy = 0; pc.dW = pc.dw; pc.dH = pc.dh;
	} else {
		/* fit：等比缩到装得下，居中，剩下的是黑边 */
		double s = (double)pc.dw / sw, sv = (double)pc.dh / sh;

		if (sv < s) s = sv;
		pc.dW = (unsigned)(sw * s + 0.5);
		pc.dH = (unsigned)(sh * s + 0.5);
		if (pc.dW > pc.dw) pc.dW = pc.dw;
		if (pc.dH > pc.dh) pc.dH = pc.dh;
		pc.dx = (int)(pc.dw - pc.dW) / 2;
		pc.dy = (int)(pc.dh - pc.dH) / 2;
	}
	pc.rect_ok = 1;
	printf("PLAY: scale=%s  src=%ux%u -> %ux%u @ +%d+%d (screen %ux%u)\n",
	       crop ? "crop" : fill ? "fill" : "fit", sw, sh, pc.dW, pc.dH,
	       pc.dx, pc.dy, pc.dw, pc.dh);
}

static int play_frame(int idx, int yfd, int cfd, unsigned sw, unsigned sh)
{
	struct drm_mode_set_plane sp = {0};
	double due = 0, now, fps = 24.0;

	if (!pc.fb[idx]) {
		pc.fb[idx] = play_addfb(yfd, cfd, sw, sh);
		if (!pc.fb[idx]) { printf("PLAY: addfb idx=%d failed\n", idx); return -1; }
	}
	if (getenv("FPS")) fps = atof(getenv("FPS"));
	now = now_s();
	if (!pc.refresh) pc.refresh = 60;

	/* 节拍=屏幕 vblank 序列，不用 usleep 猜时间：
	 * 24fps@60Hz 天然是 2.5 个 vblank/帧，按累计 ticks 取整
	 * 就是标准的 3:2 拉片，帧间隔在 2/3 之间交替，不会忽快忽慢。
	 */
	if (!pc.vbl_ok) {
		int ok = 0;

		pc.vbl_base = play_vbl_seq(&ok);
		pc.vbl_ok = ok;
		pc.t_start = now;
		if (!ok) pc.t_start = now;	/* 没有 vblank 就退回时间节拍 */
	} else if (pc.n == 0 && !pc.drops) {
		pc.t_start = now;
	}

	if (pc.vbl_ok) {
		uint32_t cur = play_vbl_seq(NULL);
		long target = (long)pc.vbl_base +
			      (long)(pc.n * (double)pc.refresh / fps + 0.5);

		if ((long)cur < target) {
			union drm_wait_vblank wv = {0};

			/* 等绝对序列：一次 ioctl 到点就醒，不空转 */
			wv.request.type = _DRM_VBLANK_ABSOLUTE;
			wv.request.sequence = (uint32_t)target;
			if (ioctl(pc.dfd, DRM_IOCTL_WAIT_VBLANK, &wv) < 0) {
				pc.timeouts++;
				pc.vbl_ok = 0;
			}
		} else if ((long)cur > target + 2L * (long)(pc.refresh / fps + 1)) {
			/* 落后超过两帧：把锚点挪到当前，避免之后一路狂追/狂丢 */
			pc.vbl_base = cur - (uint32_t)(pc.n * (double)pc.refresh / fps + 0.5);
		}
	} else {
		/* 退化路径：按时间节拍，落后 0.5s 就丢帧并重锚 */
		due = pc.t_start + pc.n / fps;
		if (now < due)
			usleep((useconds_t)((due - now) * 1e6));
		else if (now > due + 0.5) {
			pc.t_start = now - pc.n / fps;
			pc.n++;
			pc.drops++;
			return 0;
		}
	}

	sp.plane_id = pc.plane_id;
	sp.crtc_id = pc.crtc_id;
	sp.fb_id = pc.fb[idx];
	pc.cur_fb = sp.fb_id;
	play_rect(sw, sh);
	{
		/* DSTGEO=WxH+X+Y 强制目标矩形，用来单变量排查缩放/尺寸 */
		static int done;
		const char *g = getenv("DSTGEO");

		if (g && !done) {
			unsigned w, h; int x = 0, y = 0;
			done = 1;
			if (sscanf(g, "%ux%u+%d+%d", &w, &h, &x, &y) >= 2) {
				pc.dW = w; pc.dH = h; pc.dx = x; pc.dy = y;
				printf("PLAY: DSTGEO override -> %ux%u @ +%d+%d\n",
				       w, h, x, y);
			}
		}
	}
	if (getenv("SCALE") && !strcmp(getenv("SCALE"), "crop")) {
		/* crop: 源采样区按比例内缩，等价于放大后裁边 */
		unsigned cw = sw, ch = sh;
		double sa = (double)sw / sh, da = (double)pc.dw / pc.dh;

		if (sa > da) cw = (unsigned)(sh * da + 0.5);	/* 源更宽：裁左右 */
		else if (sa < da) ch = (unsigned)(sw / da + 0.5); /* 源更高：裁上下 */
		sp.src_x = ((sw - cw) / 2) << 16;
		sp.src_y = ((sh - ch) / 2) << 16;
		sp.src_w = cw << 16; sp.src_h = ch << 16;
	} else {
		sp.src_w = sw << 16; sp.src_h = sh << 16;
	}
	sp.crtc_x = pc.dx; sp.crtc_y = pc.dy;
	sp.crtc_w = pc.dW; sp.crtc_h = pc.dH;
	if (getenv("DBGPLANE"))
		printf("PLAY: setplane n=%u idx=%d src=%ux%u dst=%ux%u@%d,%d fb=%u\n",
		       pc.n, idx, sw, sh, pc.dW, pc.dH, pc.dx, pc.dy, sp.fb_id);
	if (ioctl(pc.dfd, DRM_IOCTL_MODE_SETPLANE, &sp) < 0) {
		printf("PLAY: SETPLANE: %s\n", strerror(errno));
		return -1;
	}
	pc.flips++;
	pc.n++;
	return 0;
}
#endif

/* OUTPUT 格式：一个 AU 一个 buffer。初次启动和 seek 重建会话共用。 */
static void out_fmt_setup(void)
{
	struct v4l2_format f = {0};
	size_t max = getenv("MAXAU") ? atol(getenv("MAXAU")) : (6u << 20);

	f.type = OUT_T;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_HEVC;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.width = g_w;
	f.fmt.pix_mp.height = g_h;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = (max + 8191) & ~4095UL;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) die("S_FMT out");
	printf("S_FMT OUT : %ux%u sizeimage=%u (max AU %zu)\n",
	       f.fmt.pix_mp.width, f.fmt.pix_mp.height,
	       f.fmt.pix_mp.plane_fmt[0].sizeimage, max);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	const char *path = argc > 1 ? argv[1] : "/tmp/test.265";
	struct stat st;
	struct v4l2_control ctl;
	struct v4l2_event_subscription sub = {0};
	int sf, au_idx = 0, poll_timeouts = 0, drained = 0, stream_done = 0;
	int idle_ticks = 0;	/* 连续没进展的轮次（喂不进也收不到帧） */
	double play_pace = 0;
	int lead = 0;
	int verbose = g_verbose;
	double t0, t1, tq = 0, wall;
	int expect = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 0;

	if (argc > 3) { g_w = atoi(argv[2]); g_h = atoi(argv[3]); }

	{	/* seek：重建 V4L2 会话，DRM 不动。
		 * 必须关掉 SA_RESTART（signal() 默认带），否则阻塞在 read()
		 * 等供流时信号会被内核延迟到下一帧数据，seek 白等几秒。
		 */
		struct sigaction sa;

		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = on_usr1;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sigaction(SIGUSR1, &sa, NULL);
	}

	fd = open(DEV, O_RDWR | O_NONBLOCK);
	if (fd < 0) die("open " DEV);

	if (!strcmp(path, "-")) {
		sf = STDIN_FILENO;	/* 管道直供：ffmpeg -f hevc - | player - */
	} else {
		sf = open(path, O_RDONLY);
		if (sf < 0) die("open stream");
	}
	s_fd = sf;
	if (sf != STDIN_FILENO && !fstat(sf, &st))
		printf("input: %s (%.2f GB)\n", path, st.st_size / 1073741824.0);
	else
		printf("input: stdin (pipe)\n");
	/* 只预读一小段：足够 SPS 即可，不整片读入 */
	s_fill(getenv("PREFILL") ? atol(getenv("PREFILL")) : (1u << 20));
	if (!s_len) die("stream 空");

	/* OUTPUT: one AU per buffer */
	out_fmt_setup();

	{
		unsigned sw = 0, sh = 0;
		int f = 0;

		/* sps_size() 走全局 stream/stream_size，临时指向预读窗口 */
		stream = s_buf;
		stream_size = s_len;
		f = sps_size(&sw, &sh);
		stream = NULL;
		stream_size = 0;
		if (argc > 3) {
			printf("SPS: %ux%u (被命令行覆盖为 %ux%u)\n", sw, sh, g_w, g_h);
		} else if (f) {
			printf("SPS: %ux%u\n", sw, sh);
			g_w = sw;
			g_h = sh;
		} else if (sf == STDIN_FILENO) {
			/* 管道里还没读到 SPS：多预读一些再试 */
			s_fill(4u << 20);
			stream = s_buf;
			stream_size = s_len;
			f = sps_size(&sw, &sh);
			stream = NULL;
			stream_size = 0;
			if (f) {
				printf("SPS(二读): %ux%u\n", sw, sh);
				g_w = sw;
				g_h = sh;
			} else {
				printf("SPS: 未找到，按 %ux%u 打开\n", g_w, g_h);
			}
		} else {
			printf("SPS: 未找到，按 %ux%u 打开\n", g_w, g_h);
		}
	}
	s_fmt_cap(g_w, g_h);
	capw = g_w;
	caph = g_h;
	ctl.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE;
	if (!xioctl(fd, VIDIOC_G_CTRL, &ctl))
		printf("min_buffers_for_capture(DPB)=%d\n", ctl.value);

	cap_setup();
	out_setup();

#ifdef USE_GLOUT
	if (getenv("PLAY")) {
		if (play_setup(capw, caph) < 0)
			die("play_setup");
		/* 默认 24fps 配速；FPS=0 表示不限速（跑满解码器测吞吐） */
		play_pace = getenv("FPS") ? atof(getenv("FPS")) : 24.0;
		lead = getenv("LEAD") ? atoi(getenv("LEAD")) : 6;
		if (getenv("NOPACE")) { play_pace = 0; lead = 0; }
	}
#endif

	sub.type = V4L2_EVENT_SOURCE_CHANGE;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
		die("SUBSCRIBE_EVENT");

	start_stream();
	out = getenv("NOWRITE") ? NULL : fopen(getenv("OUTYUV") ? getenv("OUTYUV")
					       : "/tmp/out.yuv", "wb");
	t0 = now_s();
	g_verbose = getenv("VERBOSE") != NULL;

	for (;;) {
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		int pr;

		/* 收到 SIGUSR1：换新码流。meson-vdec 不接受在旧会话上接新流
		 * （整份新 SPS/DPB 撞进老状态，驱动直接 Aborting decoding session），
		 * 所以关掉 /dev/video0 重开一遍；DRM master、crtc/plane 和
		 * GL 上下文都在别的 fd 上，屏幕不会黑。
		 */
		if (g_reinit) {
			unsigned i;
			int p;

			g_reinit = 0;
			printf("REINIT: 重建 V4L2 会话（DRM/GL 保留）\n");
			/* 管道里上一段流的残留全部丢掉，新流从 SPS 开始 */
			if (s_fd >= 0) {
				int fl = fcntl(s_fd, F_GETFL);

				if (fl >= 0) {
					fcntl(s_fd, F_SETFL, fl | O_NONBLOCK);
					for (;;) {
						unsigned char tmp[65536];

						if (read(s_fd, tmp, sizeof tmp) <= 0)
							break;
					}
					fcntl(s_fd, F_SETFL, fl & ~O_NONBLOCK);
				}
			}
			s_len = 0;
			s_pos = 0;
			s_au_start = 0;
			s_au_open = 0;
			s_cur_vcl = 0;
			s_eof = 0;
			s_release = 0;
			s_au_irap = 0;

			stop_stream();
			/* 旧 dmabuf 上的 fb / GL 纹理必须一起作废 */
			for (i = 0; i < cap_count; i++)
				for (p = 0; p < 2; p++)
					if (capbuf[i].dmabuf[p] >= 0) {
						close(capbuf[i].dmabuf[p]);
						capbuf[i].dmabuf[p] = -1;
					}
			/* 屏上那一张留着（删了当场黑屏），其余回收；上一轮
			 * 留下的那张此刻已不在屏上，一并删掉 —— 每次 seek
			 * 最多只多挂一张 fb。
			 */
			{
				uint32_t onscreen = pc.cur_fb;

				for (i = 0; i < NBUF_CAP_MAX; i++) {
					if (!pc.fb[i])
						continue;
					if (pc.fb[i] != onscreen) {
						uint32_t id = pc.fb[i];

						ioctl(pc.dfd, DRM_IOCTL_MODE_RMFB, &id);
					}
					pc.fb[i] = 0;
				}
				if (pc.prev_fb && pc.prev_fb != onscreen) {
					uint32_t id = pc.prev_fb;

					ioctl(pc.dfd, DRM_IOCTL_MODE_RMFB, &id);
				}
				pc.prev_fb = onscreen;
				pc.cur_fb = 0;
			}
#ifdef USE_GLOUT
			if (getenv("PLAY"))
				glout_reset();
#endif
			cap_release();
			close(fd);
			/* 驱动是异步收尾的：close 后它才在 workqueue 里打完
			 * "Aborting decoding session!"。紧接着 open 会把新会话
			 * 开在还没收干净的旧状态上，于是 seek 偶发连试两次都
			 * 吐不出帧。留一个短落定期，代价 80ms，比闪一次屏便宜。
			 */
			usleep(80000);
			fd = open(DEV, O_RDWR | O_NONBLOCK);
			if (fd < 0) die("reopen " DEV);
			out_fmt_setup();
			s_fmt_cap(g_w, g_h);
			cap_setup();
			out_setup();
			sub.type = V4L2_EVENT_SOURCE_CHANGE;
			if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
				die("SUBSCRIBE_EVENT");
			start_stream();

			/* 本地状态清零：别把上一段流的收尾当成本流的结尾 */
			pc.vbl_ok = 0;
			pc.n = 0;
			pc.drops = 0;
			drained = 0;
			stream_done = 0;
			poll_timeouts = 0;
			idle_ticks = 0;
			eos_seen = 0;
			g_refeed = 0;
			s_eof = 0;
			tq = 0;
			au_idx = 0;
			t_last_rx = now_s();
			g_mark_first = 1;
			pf.fd = fd;
			printf("REINIT: ready\n");
			continue;
		}

		/* 收尾阶段：等到预期帧数 / EOS / 长时间静默就停 */
		if (drained) {
			double el = now_s() - tq;
			double quiet = now_s() - t_last_rx;

			/* 收尾别傻等 2s：EOS 事件该驱动经常不发，
			 * OUTPUT 全回收 + 一轮 poll 无新帧就当收尾完成。
			 */
			if (eos_seen || (expect && got >= expect) ||
			    (out_nfree == n_out && (poll_timeouts >= 1 || quiet > 0.15)) ||
			    quiet > (getenv("DRAINWAIT") ? atof(getenv("DRAINWAIT")) : 0.5) ||
			    el > 2.0) {
				if (g_verbose)
					printf("drain exit: eos=%d timeouts=%d waited=%.3f got=%d\n",
					       eos_seen, poll_timeouts, el, got);
				break;
			}
		}

		/* drain 必须放在循环最开头做：下面的 poll 超时分支有
		 * continue，capture 分支也可能提前跳回，放在尾部会被绕过，
		 * 结果 stream_done 置位了却永远发不出 STOP，解码器等输入、
		 * 显示等帧，双方永久僵住（末尾几帧就是吐不出来）。
		 */
		if (stream_done && got > 0 && !drained) {
			struct v4l2_decoder_cmd cmd = {0};

			tq = now_s();
			cmd.cmd = V4L2_DEC_CMD_STOP;
			if (xioctl(fd, VIDIOC_DECODER_CMD, &cmd) < 0)
				perror("DEC_CMD_STOP");
			else if (g_verbose)
				printf("drain: DEC_CMD_STOP sent (got=%d)\n", got);
			drained = 1;
			poll_timeouts = 0;
			idle_ticks = 0;
		}

		while (out_nfree) {
			const unsigned char *ap = NULL;
			size_t al = 0;
			int r;

			/* 背压：只用"解码领先显示多少帧"限流。
			 * 解码器 100fps 全速跑也行，但显示节拍由 vblank
			 * 决定，领先超过 LEAD 帧就别再喂，否则 20 个
			 * capture buffer 一满就只能在显示前丢帧。
			 */
			if (play_pace > 0 && lead > 0 && au_idx - got >= lead)
				break;
			r = stream_next_au(&ap, &al);
			if (r < 0)
				break;		/* seek 打断：回主循环处理重建 */
			if (r == 0) { stream_done = 1; break; }
			qbuf_au(ap, al, r == 2);
			au_idx++;
			idle_ticks = 0;
		}

		pr = poll(&pf, 1, drained ? 50 : (out_nfree ? 2000 : 100));
		if (pr < 0) {
			/* SIGUSR1 会打断 poll。以前这里直接 break 退主循环，
			 * 表现是"seek 偶发卡 3s 后解码器消失"——信号恰好落在
			 * poll 而不是 read 上时就会踩到。必须回主循环重查
			 * g_reinit（顶部会重建会话），否则 seek 就是赌概率。
			 */
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}
		if (pr == 0) {
			poll_timeouts++;
			idle_ticks++;
			if (g_verbose && poll_timeouts <= 3)
				printf("poll timeout #%d au=%d/%d out_nfree=%d got=%d\n",
				       poll_timeouts, au_idx, g_stream_au, out_nfree, got);
			/* vb2_fop_poll() 不挂 fh->wait，事件不会唤醒 poll，
			 * 所以超时后主动取一次事件，否则分辨率切换会死锁。
			 */
			handle_event();
			if (g_refeed) {
				/* 流式不能回卷：保持位置继续，驱动同分辨率会自动接上 */
				drained = 0;
				g_refeed = 0;
			}
			continue;
		}
		idle_ticks = 0;
		if (g_verbose)
			printf("poll ready revents=%x\n", pf.revents);
		if (pf.revents & POLLERR) {
			printf("POLLERR\n");
			break;
		}

		handle_event();
		if (g_refeed) {
			drained = 0;
			g_refeed = 0;
			continue;
		}

		/* capture frames */
		for (;;) {
			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[2] = {{0}};

			b.type = CAP_T;
			b.memory = V4L2_MEMORY_MMAP;
			b.length = 2;
			b.m.planes = pl;
			double t_rx;

			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
				break;
			t_rx = now_s();
			if (g_mark_first) {
				g_mark_first = 0;
				printf("REINIT: first frame\n");
			}
			if (!got)
				t_first_rx = t_rx;
			t_last_rx = t_rx;
			if (verbose)
				printf("frame %d: idx=%u flags=%08x ts=%ld.%06ld\n", got,
				       b.index, b.flags, (long)b.timestamp.tv_sec,
				       (long)b.timestamp.tv_usec);
			if (g_verbose)
				fprintf(stderr, "plane len=%zu/%zu off=%u/%u\n",
					capbuf[b.index].len[0], capbuf[b.index].len[1],
					pl[0].data_offset, pl[1].data_offset);
			if ((g_verbose || got == 0) && capbuf[b.index].mem[0])
				dump_frame(b.index, pl);
			if (out && pl[0].bytesused && capbuf[b.index].mem[0]) {
				double tw = now_s();

				write_nv12(b.index, capw, caph);
				t_write_acc += now_s() - tw;
			}
			if (getenv("PLAY")) {
				double tt = now_s();

#ifdef USE_GLOUT
				if (getenv("GLPLAY")) {
					/* meson vdec 的 NV12M 是紧排：Y pitch=w，交织 CbCr pitch=w
					 * （DRM fb 路径同样用 pitches={w,w}，已验证不歪）
					 */
					unsigned ys = capw, cs = capw;

					if (!g_gl_ready) {
						glout_set_drm_fd(pc.dfd);	/* 共用 master fd */
						if (glout_init(capw, caph) < 0) die("glout_init");
						g_gl_ready = 1;
					}
					if (glout_frame(capbuf[b.index].dmabuf[0],
							capbuf[b.index].dmabuf[1],
							capw, caph, ys, cs) < 0)
						die("glout_frame");
				} else
#endif
#if defined(USE_GLOUT) || (defined(USE_DRM) && defined(USE_TM))
				{
					tm_apply(b.index, capw, caph);
					play_frame(b.index, capbuf[b.index].dmabuf[0],
						   capbuf[b.index].dmabuf[1], capw, caph);
				}
#endif
				t_tm_acc += now_s() - tt;
			}
#ifdef USE_DRM
			if (getenv("EXPBUF") && getenv("DRMFB") && got == 1)
				drm_import_test(capbuf[b.index].dmabuf[0],
						capbuf[b.index].dmabuf[1], capw, caph);
#endif
			got++;
			if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
				perror("QBUF recycle");
				break;
			}
		}

		/* recycle output buffers */
		for (;;) {
			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[1] = {{0}};

			b.type = OUT_T;
			b.memory = V4L2_MEMORY_MMAP;
			b.length = 1;
			b.m.planes = pl;
			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
				break;
			out_free[out_nfree++] = b.index;
		}

	}

	t1 = now_s();
	wall = t1 - t0;
	if (out) fclose(out);
	printf("RESULT decoded=%d / %d AUs, resets=%d, %ux%u\n", got, g_stream_au,
	       resets, g_w, g_h);
#ifdef USE_GLOUT
	if (getenv("PLAY")) {
		double el = now_s() - pc.t_start;

		printf("PLAY: screen=%ux%u src=%ux%u flips=%d drops=%d vblank_fail=%d "
		       "elapsed=%.2fs -> %.1f fps (pace %.1ffps)\n",
		       pc.dw, pc.dh, capw, caph, pc.flips, pc.drops, pc.timeouts, el,
		       el > 0 ? pc.flips / el : 0.0, play_pace);
	}
#endif
	{
		/* 纯解码吞吐：只看首帧到末帧，排除启动、收尾(tail)和写盘 */
		double active = t_last_rx - t_first_rx;
		double feed = t_last_q - t_first_q;
		double decode_busy = active - t_write_acc - t_tm_acc;

		printf("PHASE feed=%.3fs  active=%.3fs  tail=%.3fs  write=%.3fs  eos=%d\n",
		       feed, active, wall - active - (t_first_rx - t0),
		       t_write_acc, eos_seen);
		printf("PERF decode=%.2f fps (%d frames / %.3fs)", 
		       active > 0 ? (got - 1) / active : 0.0, got - 1, active);
		if (t_tm_acc > 0.001)
			printf("PHASE tm = %.3fs (%.2f ms/frame)\n",
			       t_tm_acc, t_tm_acc * 1000.0 / (got > 0 ? got : 1));
		if (t_write_acc > 0.001)
			printf("  decode-only=%.2f fps (minus write %.3fs)",
			       decode_busy > 0 ? (got - 1) / decode_busy : 0.0,
			       t_write_acc);
		printf("\n");
		printf("PERF feed=%.2f fps (%d AUs / %.3fs)  wall=%.3fs  e2e=%.2f fps  bitstream=%.2f MB/s\n",
		       feed > 0 ? got_queued / feed : 0.0, got_queued, feed, wall,
		       wall > 0 ? got / wall : 0.0,
		       wall > 0 ? g_stream_bytes / wall / 1e6 : 0.0);
	}
	stop_stream();
	close(fd);
	/* 退出把控制台还回去：DRM master 释放后 fbcon 有时仍停在
	 * FB_BLANK_POWERDOWN（屏黑但 CRTC 是开的），这里主动解黑。
	 */
	{
		int bf = open("/sys/class/graphics/fb0/blank", O_WRONLY);

		if (bf >= 0) {
			if (write(bf, "0", 1) < 0) { /* 忽略 */ }
			close(bf);
		}
	}
	return got > 0 ? 0 : 2;
}
