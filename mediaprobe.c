/* 探 cedrus：media device 实体 + stateless 控制 + request API */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/media.h>
#include <linux/videodev2.h>

#ifndef MEDIA_IOC_REQUEST_ALLOC
#define MEDIA_IOC_REQUEST_ALLOC _IOR('|', 0x05, int)
#endif

int main(void)
{
	int m = open("/dev/media0", O_RDWR);
	if (m < 0) { perror("/dev/media0"); return 1; }
	struct media_device_info di;
	if (ioctl(m, MEDIA_IOC_DEVICE_INFO, &di) == 0)
		printf("media: driver=%s model=%s dev=%s\n", di.driver, di.model, di.bus_info);

	printf("-- entities:\n");
	struct media_entity_desc e;
	memset(&e, 0, sizeof(e)); e.id = 0 | MEDIA_ENT_ID_FLAG_NEXT;
	int n = 0;
	while (ioctl(m, MEDIA_IOC_ENUM_ENTITIES, &e) == 0) {
		if (n++ < 12) printf("   [%u] %-24s type=0x%08x flags=0x%x\n",
				     e.id, e.name, e.type, e.flags);
		e.id |= MEDIA_ENT_ID_FLAG_NEXT;
	}
	printf("   total %d entities\n", n);

	int req = -1;
	if (ioctl(m, MEDIA_IOC_REQUEST_ALLOC, &req) == 0) {
		printf("request API: OK (fd=%d)\n", req);
		close(req);
	} else {
		printf("request API: FAIL %s\n", strerror(errno));
	}

	int v = open("/dev/video0", O_RDWR);
	if (v < 0) { perror("/dev/video0"); return 1; }
	printf("-- stateless 控制:\n");
	static const struct { unsigned id; const char *n; } ctls[] = {
		{ V4L2_CID_STATELESS_H264_SPS, "H264_SPS" },
		{ V4L2_CID_STATELESS_H264_PPS, "H264_PPS" },
		{ V4L2_CID_STATELESS_H264_SLICE_PARAMS, "H264_SLICE_PARAMS" },
		{ V4L2_CID_STATELESS_H264_DECODE_PARAMS, "H264_DECODE_PARAMS" },
		{ V4L2_CID_STATELESS_H264_DECODE_MODE, "H264_DECODE_MODE" },
		{ V4L2_CID_STATELESS_HEVC_SPS, "HEVC_SPS" },
		{ V4L2_CID_STATELESS_MPEG2_SEQUENCE, "MPEG2_SEQUENCE" },
		{ V4L2_CID_STATELESS_VP8_FRAME, "VP8_FRAME" },
	};
	for (unsigned i = 0; i < sizeof(ctls)/sizeof(ctls[0]); i++) {
		struct v4l2_query_ext_ctrl q;
		memset(&q, 0, sizeof(q)); q.id = ctls[i].id;
		if (ioctl(v, VIDIOC_QUERY_EXT_CTRL, &q) == 0)
			printf("   OK   %-20s (%s)\n", ctls[i].n, q.name);
		else
			printf("   --   %-20s (%s)\n", ctls[i].n, strerror(errno));
	}
	close(v); close(m);
	return 0;
}
