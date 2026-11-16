// V4L2 M2M HEVC decode smoke test for meson-vdec
// - feeds one access unit (AU) per OUTPUT buffer (driver matches frames by
//   vififo offset in sess->timestamps)
// - allocates >= DPB (16) capture buffers so amvdec_src_change() just resumes
// - handles V4L2_EVENT_SOURCE_CHANGE (real resolution change)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <poll.h>
#include <time.h>
#include <linux/videodev2.h>

#define DEV "/dev/video0"
#define NBUF_CAP 20
#define NBUF_OUT 32
#define OUT_DEPTH() (getenv("NBUF_OUT") ? atoi(getenv("NBUF_OUT")) : 8)
#define CAP_T V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
#define OUT_T V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
	return r;
}

static void die(const char *m)
{
	fprintf(stderr, "FAIL %s: %s\n", m, strerror(errno));
	exit(1);
}

static struct {
	void *mem[VIDEO_MAX_PLANES];
	size_t len[VIDEO_MAX_PLANES];
} capbuf[NBUF_CAP];
static unsigned cap_count;

static struct { void *mem; size_t len; } outbuf[NBUF_OUT];
static int out_free[NBUF_OUT], out_nfree, n_out;

static unsigned char *stream;
static size_t stream_size;
static struct { size_t off, len; int key; } au[4096];
static int n_au;

static int fd;
static unsigned g_w = 640, g_h = 360;
static int got, resets, g_refeed;

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

	cap_release();
	rb.type = CAP_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = NBUF_CAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) < 0) die("REQBUFS cap");
	cap_count = rb.count > NBUF_CAP ? NBUF_CAP : rb.count;
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
			capbuf[i].mem[p] = mmap(NULL, pl[p].length,
						PROT_READ | PROT_WRITE, MAP_SHARED,
						fd, pl[p].m.mem_offset);
			if (capbuf[i].mem[p] == MAP_FAILED) die("mmap cap");
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0) die("QBUF cap");
	}
}

static void out_setup(void)
{
	struct v4l2_requestbuffers rb = {0};
	int i;

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

static void qbuf_au(int idx)
{
	int oi = out_free[--out_nfree];
	struct v4l2_buffer b = {0};
	struct v4l2_plane pl[1] = {{0}};

	memcpy(outbuf[oi].mem, stream + au[idx].off, au[idx].len);
	pl[0].bytesused = au[idx].len;
	pl[0].data_offset = 0;
	pl[0].length = outbuf[oi].len;
	b.type = OUT_T;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = oi;
	b.length = 1;
	b.m.planes = pl;
	b.bytesused = au[idx].len;
	b.field = V4L2_FIELD_NONE;
	b.flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	if (au[idx].key)
		b.flags |= V4L2_BUF_FLAG_KEYFRAME;
	b.timestamp.tv_sec = 0;
	b.timestamp.tv_usec = idx * 40000;
	if (xioctl(fd, VIDIOC_QBUF, &b) < 0) die("QBUF out");
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

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	const char *path = argc > 1 ? argv[1] : "/tmp/test.265";
	struct stat st;
	struct v4l2_format f = {0};
	struct v4l2_control ctl;
	struct v4l2_event_subscription sub = {0};
	int sf, au_idx = 0, poll_timeouts = 0, drained = 0;
	int verbose = g_verbose;
	struct timespec t0, t1, tq;
	int got_queued = 0, expect = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 0;
	double wall;

	if (argc > 3) { g_w = atoi(argv[2]); g_h = atoi(argv[3]); }

	fd = open(DEV, O_RDWR | O_NONBLOCK);
	if (fd < 0) die("open " DEV);

	sf = open(path, O_RDONLY);
	if (sf < 0) die("open stream");
	fstat(sf, &st);
	stream_size = st.st_size;
	stream = malloc(stream_size);
	if (read(sf, stream, stream_size) != (ssize_t)stream_size) die("read");
	close(sf);
	parse_au();
	printf("stream %s: %zu bytes, %d AUs\n", path, stream_size, n_au);
	if (n_au < 1) return 1;

	/* OUTPUT: one AU per buffer */
	{
		size_t max = 0;
		int i;

		for (i = 0; i < n_au; i++)
			if (au[i].len > max)
				max = au[i].len;
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

	{
		unsigned sw = 0, sh = 0;

		if (argc <= 3 && sps_size(&sw, &sh)) {
			printf("SPS: %ux%u\n", sw, sh);
			g_w = sw;
			g_h = sh;
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

	sub.type = V4L2_EVENT_SOURCE_CHANGE;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0)
		die("SUBSCRIBE_EVENT");

	start_stream();
	out = getenv("NOWRITE") ? NULL : fopen("/tmp/out.yuv", "wb");
	clock_gettime(CLOCK_MONOTONIC, &t0);
	g_verbose = getenv("VERBOSE") != NULL;

	for (;;) {
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		int pr;

		/* 收尾阶段：等到预期帧数 / EOS / 长时间静默就停 */
		if (drained) {
			struct timespec tn;
			double el;

			clock_gettime(CLOCK_MONOTONIC, &tn);
			el = (tn.tv_sec - tq.tv_sec) + (tn.tv_nsec - tq.tv_nsec) / 1e9;
			if (eos_seen || (expect && got >= expect) ||
			    (out_nfree == n_out && poll_timeouts >= 3) ||
			    el > 2.0) {
				if (g_verbose)
					printf("drain exit: eos=%d timeouts=%d waited=%.3f got=%d\n",
					       eos_seen, poll_timeouts, el, got);
				break;
			}
		}

		while (out_nfree && au_idx < n_au)
			qbuf_au(au_idx++);

		pr = poll(&pf, 1, drained ? 50 : 2000);
		if (pr < 0) { perror("poll"); break; }
		if (pr == 0) {
			poll_timeouts++;
			if (g_verbose && poll_timeouts <= 3)
				printf("poll timeout #%d au=%d/%d out_nfree=%d got=%d\n",
				       poll_timeouts, au_idx, n_au, out_nfree, got);
			/* vb2_fop_poll() 不挂 fh->wait，事件不会唤醒 poll，
			 * 所以超时后主动取一次事件，否则分辨率切换会死锁。
			 */
			handle_event();
			if (g_refeed) {
				au_idx = 0;
				drained = 0;
				g_refeed = 0;
			}
			continue;
		}
		if (g_verbose)
			printf("poll ready revents=%x\n", pf.revents);
		if (pf.revents & POLLERR) {
			printf("POLLERR\n");
			break;
		}

		handle_event();
		if (g_refeed) {
			au_idx = 0;
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
			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
				break;
			if (verbose)
				printf("frame %d: idx=%u flags=%08x ts=%ld.%06ld\n", got,
				       b.index, b.flags, (long)b.timestamp.tv_sec,
				       (long)b.timestamp.tv_usec);
			if (g_verbose)
				fprintf(stderr, "plane len=%zu/%zu off=%u/%u\n",
					capbuf[b.index].len[0], capbuf[b.index].len[1],
					pl[0].data_offset, pl[1].data_offset);
			if (g_verbose || got == 0)
				dump_frame(b.index, pl);
			if (out && pl[0].bytesused)
				write_nv12(b.index, capw, caph);
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

		/* 所有 AU 已投递：立刻请求 drain，不等 poll 超时 */
		if (au_idx >= n_au && got > 0 && !drained) {
			struct v4l2_decoder_cmd cmd = {0};

			clock_gettime(CLOCK_MONOTONIC, &tq);
			cmd.cmd = V4L2_DEC_CMD_STOP;
			if (xioctl(fd, VIDIOC_DECODER_CMD, &cmd) < 0)
				perror("DEC_CMD_STOP");
			else if (verbose)
				printf("drain: DEC_CMD_STOP sent\n");
			drained = 1;
			poll_timeouts = 0;
		}
	}

	clock_gettime(CLOCK_MONOTONIC, &t1);
	wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	if (out) fclose(out);
	printf("RESULT decoded=%d / %d AUs, resets=%d, %ux%u\n", got, n_au,
	       resets, g_w, g_h);
	{
		double t_stream = tq.tv_sec - t0.tv_sec + tq.tv_nsec / 1e9;

		printf("PHASE feed=%.3fs (%.1f fps)  drain=%.3fs  eos=%d\n",
		       t_stream, t_stream > 0 ? got_queued / t_stream : 0.0,
		       wall - t_stream, eos_seen);
	}
	printf("PERF wall=%.3fs  fps=%.2f  bitstream=%.2f MB/s\n", wall,
	       wall > 0 ? got / wall : 0.0,
	       wall > 0 ? stream_size / wall / 1e6 : 0.0);
	stop_stream();
	close(fd);
	return got > 0 ? 0 : 2;
}
