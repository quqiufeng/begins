/* 极简 V4L2 m2m(MPLANE) 硬解测试：cedrus 喂 H.264，收帧 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <linux/videodev2.h>

#define DEV "/dev/video0"
#define T_OUT V4L2_BUF_TYPE_VIDEO_OUTPUT
#define T_CAP V4L2_BUF_TYPE_VIDEO_CAPTURE
#define NBUF_OUT 2
#define NBUF_CAP 4

static int xi(int fd, unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
	return r;
}

static void *bmap[16];
static size_t blen[16];

static int setup(int fd, enum v4l2_buf_type type, unsigned nbuf)
{
	struct v4l2_requestbuffers rb = { .count = nbuf, .type = type,
		.memory = V4L2_MEMORY_MMAP };
	if (xi(fd, VIDIOC_REQBUFS, &rb) < 0) { perror("REQBUFS"); return -1; }
	for (unsigned i = 0; i < rb.count; i++) {
		struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP,
			.index = i };
		if (xi(fd, VIDIOC_QUERYBUF, &b) < 0) { perror("QUERYBUF"); return -1; }
		int slot = (type == T_OUT) ? i : 8 + i;
		bmap[slot] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
				  MAP_SHARED, fd, b.m.offset);
		if (bmap[slot] == MAP_FAILED) { perror("mmap"); return -1; }
		blen[slot] = b.length;
	}
	return rb.count;
}

static int qbuf(int fd, enum v4l2_buf_type type, int index, size_t used)
{
	struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP,
		.index = index, .bytesused = (unsigned)used };
	return xi(fd, VIDIOC_QBUF, &b);
}

static int dqbuf(int fd, enum v4l2_buf_type type, struct v4l2_buffer *b,
		 void *unused)
{
	(void)unused;
	memset(b, 0, sizeof(*b));
	b->type = type; b->memory = V4L2_MEMORY_MMAP;
	return xi(fd, VIDIOC_DQBUF, b);
}

int main(int argc, char **argv)
{
	const char *in = (argc > 1) ? argv[1] : "/tmp/test.h264";
	FILE *f = fopen(in, "rb");
	if (!f) { perror("open stream"); return 1; }
	fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
	unsigned char *es = malloc(fsz);
	if (fread(es, 1, fsz, f) != (size_t)fsz) { perror("read"); return 1; }
	fclose(f);
	printf("stream %ld bytes\n", fsz);

	int fd = open(DEV, O_RDWR);
	if (fd < 0) { perror("open " DEV); return 1; }

	struct v4l2_format fmt = { .type = T_OUT };
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_H264;
	fmt.fmt.pix.width = 640; fmt.fmt.pix.height = 360;
	fmt.fmt.pix.sizeimage = fsz;
	if (xi(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT out"); return 1; }
	printf("OUT: %ux%u sizeimage=%u\n", fmt.fmt.pix.width,
	       fmt.fmt.pix.height, fmt.fmt.pix.sizeimage);

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = T_CAP;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
	fmt.fmt.pix.width = 640; fmt.fmt.pix.height = 360;
	if (xi(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT cap"); return 1; }
	printf("CAP: %ux%u sizeimage=%u\n", fmt.fmt.pix.width,
	       fmt.fmt.pix.height, fmt.fmt.pix.sizeimage);

	if (setup(fd, T_OUT, NBUF_OUT) < 0) return 1;
	if (setup(fd, T_CAP, NBUF_CAP) < 0) return 1;

	for (int i = 0; i < NBUF_CAP; i++)
		if (qbuf(fd, T_CAP, i, 0) < 0) { perror("QBUF cap"); return 1; }

	enum v4l2_buf_type t = T_OUT;
	if (xi(fd, VIDIOC_STREAMON, &t) < 0) { perror("STREAMON out"); return 1; }
	t = T_CAP;
	if (xi(fd, VIDIOC_STREAMON, &t) < 0) { perror("STREAMON cap"); return 1; }

	long off = 0;
	int frames = 0, fed = 0, bad = 0;
	size_t n0 = blen[0] < (size_t)fsz ? blen[0] : (size_t)fsz;
	memcpy(bmap[0], es, n0);
	if (qbuf(fd, T_OUT, 0, n0) < 0) { perror("QBUF out"); return 1; }
	off = n0; fed = n0;

	for (int iter = 0; iter < 600; iter++) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN | POLLOUT };
		int pr = poll(&pfd, 1, 2000);
		if (pr <= 0) { printf("poll %s\n", pr ? "err" : "timeout"); break; }
		struct v4l2_buffer b; struct v4l2_plane pl[VIDEO_MAX_PLANES]; memset(pl, 0, sizeof(pl));

		if (pfd.revents & POLLIN) {
			if (dqbuf(fd, T_CAP, &b, pl) == 0) {
				frames++;
				printf("frame %d: idx=%u used=%u flags=0x%x%s\n", frames,
				       b.index, b.bytesused, b.flags,
				       (b.flags & V4L2_BUF_FLAG_ERROR) ? " [ERR]" : "");
				if (b.flags & V4L2_BUF_FLAG_ERROR) bad++;
				qbuf(fd, T_CAP, b.index, 0);
			} else { printf("DQBUF cap: %s\n", strerror(errno)); break; }
		}
		if ((pfd.revents & POLLOUT) && off < fsz) {
			if (dqbuf(fd, T_OUT, &b, pl) == 0) {
				size_t n = blen[b.index] < (size_t)(fsz - off) ? blen[b.index] : (size_t)(fsz - off);
				memcpy(bmap[b.index], es + off, n);
				off += n; fed += n;
				qbuf(fd, T_OUT, b.index, n);
			}
		}
		if (frames >= 3) break;
	}

	t = T_OUT; xi(fd, VIDIOC_STREAMOFF, &t);
	t = T_CAP; xi(fd, VIDIOC_STREAMOFF, &t);
	close(fd);
	printf("RESULT: fed=%d/%ld frames=%d err_frames=%d\n", fed, fsz, frames, bad);
	return (frames > 0 && !bad) ? 0 : 2;
}
