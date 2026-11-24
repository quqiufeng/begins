// vfmtprobe.c — 探 v4l2 设备到底认单平面还是多平面 API
// 编译：aarch64-linux-gnu-gcc -O2 -o vfmtprobe-aarch64 vfmtprobe.c
// 跑：  ./vfmtprobe-aarch64 /dev/video0
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static void dump_caps(int fd)
{
	struct v4l2_capability c;

	memset(&c, 0, sizeof c);
	if (ioctl(fd, VIDIOC_QUERYCAP, &c) < 0) {
		printf("QUERYCAP 失败: %s\n", strerror(errno));
		return;
	}
	printf("driver=%s card=%s caps=0x%08x device_caps=0x%08x\n",
	       c.driver, c.card, c.capabilities, c.device_caps);
}

/* 枚举某方向的候选格式，打印 fourcc */
static void enum_fmt(int fd, unsigned type, const char *tag)
{
	struct v4l2_fmtdesc d;

	for (unsigned i = 0; i < 16; i++) {
		memset(&d, 0, sizeof d);
		d.index = i;
		d.type = type;
		if (ioctl(fd, VIDIOC_ENUM_FMT, &d) < 0) {
			if (i == 0)
				printf("%s ENUM_FMT 失败: %s\n", tag,
				       strerror(errno));
			return;
		}
		printf("%s [%u] %.4s  %s\n", tag, i, (char *)&d.pixelformat,
		       d.description);
	}
}

/* 单平面 S_FMT */
static void try_sp(int fd, unsigned type, unsigned pf, unsigned w, unsigned h)
{
	struct v4l2_format f;

	memset(&f, 0, sizeof f);
	f.type = type;
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.pixelformat = pf;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.sizeimage = 6 << 20;
	if (ioctl(fd, VIDIOC_S_FMT, &f) < 0)
		printf("  S_FMT 单平面 type=%u %.4s %ux%u: 失败 %s\n", type,
		       (char *)&pf, w, h, strerror(errno));
	else
		printf("  S_FMT 单平面 type=%u %.4s %ux%u: OK -> %.4s %ux%u sizeimage=%u bpl=%u\n",
		       type, (char *)&pf, w, h, (char *)&f.fmt.pix.pixelformat,
		       f.fmt.pix.width, f.fmt.pix.height, f.fmt.pix.sizeimage,
		       f.fmt.pix.bytesperline);
}

/* 多平面 S_FMT */
static void try_mp(int fd, unsigned type, unsigned pf, unsigned w, unsigned h)
{
	struct v4l2_format f;

	memset(&f, 0, sizeof f);
	f.type = type;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = pf;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = 6 << 20;
	if (ioctl(fd, VIDIOC_S_FMT, &f) < 0)
		printf("  S_FMT 多平面 type=%u %.4s %ux%u: 失败 %s\n", type,
		       (char *)&pf, w, h, strerror(errno));
	else
		printf("  S_FMT 多平面 type=%u %.4s %ux%u: OK -> %.4s %ux%u np=%u sizeimage=%u\n",
		       type, (char *)&pf, w, h,
		       (char *)&f.fmt.pix_mp.pixelformat, f.fmt.pix_mp.width,
		       f.fmt.pix_mp.height, f.fmt.pix_mp.num_planes,
		       f.fmt.pix_mp.plane_fmt[0].sizeimage);
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/video0";
	unsigned w = 1920, h = 808;
	int fd = open(dev, O_RDWR | O_NONBLOCK);

	if (fd < 0) {
		printf("open %s: %s\n", dev, strerror(errno));
		return 1;
	}
	printf("== %s\n", dev);
	dump_caps(fd);
	enum_fmt(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, "OUT_MPLANE");
	enum_fmt(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, "OUT_SP     ");
	enum_fmt(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, "CAP_MPLANE");
	enum_fmt(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, "CAP_SP     ");

	printf("== S_FMT 试探 %ux%u\n", w, h);
	try_mp(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_H264_SLICE, w, h);
	try_sp(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, V4L2_PIX_FMT_H264_SLICE, w, h);
	try_mp(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_HEVC_SLICE, w, h);
	try_sp(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, V4L2_PIX_FMT_HEVC_SLICE, w, h);

	printf("== CAP 侧（要在 OUT 设完之后）\n");
	try_mp(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, V4L2_PIX_FMT_NV12, w, h);
	try_sp(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, V4L2_PIX_FMT_NV12, w, h);

	close(fd);
	return 0;
}
