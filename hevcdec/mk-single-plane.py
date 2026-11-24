#!/usr/bin/env python3
# v4l2hevc.c: MPLANE -> 单平面（cedrus 只实现非 mplane ops）
import sys, io
p = "v4l2hevc.c"
s = io.open(p, encoding="utf-8").read()
n = 0

def rep(old, new, cnt=1):
    global s, n
    c = s.count(old)
    assert c == cnt, "命中 %d 次（期望 %d）:\n%s" % (c, cnt, old[:200])
    s = s.replace(old, new)
    n += cnt

# 1) buf type
rep("#define CAP_T V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE\n#define OUT_T V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE",
    "#define CAP_T V4L2_BUF_TYPE_VIDEO_CAPTURE\n#define OUT_T V4L2_BUF_TYPE_VIDEO_OUTPUT")

# 2) color read
rep("""	g_v4l_cs = (int)f->fmt.pix_mp.colorspace;
	g_v4l_xf = (int)f->fmt.pix_mp.xfer_func;
	g_v4l_enc = (int)f->fmt.pix_mp.ycbcr_enc;
	g_v4l_q = (int)f->fmt.pix_mp.quantization;""",
    """	g_v4l_cs = (int)f->fmt.pix.colorspace;
	g_v4l_xf = (int)f->fmt.pix.xfer_func;
	g_v4l_enc = (int)f->fmt.pix.ycbcr_enc;
	g_v4l_q = (int)f->fmt.pix.quantization;""")

# 3) s_fmt_cap
rep("""	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M;
	f.fmt.pix_mp.num_planes = 2;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = w * h;
	f.fmt.pix_mp.plane_fmt[1].sizeimage = w * h / 2;
	f.fmt.pix_mp.plane_fmt[1].bytesperline = w / 2;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		printf("S_FMT CAP %ux%u 失败: %s\\n", w, h, strerror(errno));
		return -errno;
	}
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	v4l_color_read(&f);
	printf("S_FMT CAP : %ux%u pf=%08x sizeimage=%u\\n", g_w, g_h,
	       f.fmt.pix_mp.pixelformat, f.fmt.pix_mp.plane_fmt[0].sizeimage);""",
    """	/* cedrus 的 capture 队列只注册单平面 NV12（cedrus_video.c 没有任何
	 * _mplane ops）；填 NV12M/MPLANE 会 S_FMT EINVAL。bytesperline/sizeimage
	 * 都留 0 让驱动按对齐规则自己算，之后一律以 G_FMT 回填的值为准。 */
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.bytesperline = 0;
	f.fmt.pix.sizeimage = 0;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		printf("S_FMT CAP %ux%u 失败: %s\\n", w, h, strerror(errno));
		return -errno;
	}
	g_w = f.fmt.pix.width;
	g_h = f.fmt.pix.height;
	v4l_color_read(&f);
	printf("S_FMT CAP : %ux%u pf=%08x bpl=%u sizeimage=%u\\n", g_w, g_h,
	       f.fmt.pix.pixelformat, f.fmt.pix.bytesperline, f.fmt.pix.sizeimage);""")

# 4) g_fmt_cap
rep("""	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) return;
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	v4l_color_read(&f);""",
    """	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) return;
	g_w = f.fmt.pix.width;
	g_h = f.fmt.pix.height;
	v4l_color_read(&f);""")

# 5) cap_release: mem[1] 是 mem[0] 的别名（不是独立映射），不许二次 munmap
rep("""	for (i = 0; i < cap_count; i++)
		for (p = 0; p < VIDEO_MAX_PLANES; p++)
			if (capbuf[i].mem[p]) {
				munmap(capbuf[i].mem[p], capbuf[i].len[p]);
				capbuf[i].mem[p] = NULL;
			}""",
    """	for (i = 0; i < cap_count; i++) {
		/* 单平面：mem[1] 只是 mem[0]+Y 面的别名，munmap 只能对基址做一次 */
		if (capbuf[i].mem[0])
			munmap(capbuf[i].mem[0], capbuf[i].len[0] + cap_ysize);
		for (p = 0; p < VIDEO_MAX_PLANES; p++) {
			capbuf[i].mem[p] = NULL;
			capbuf[i].len[p] = 0;
			capbuf[i].mem2[p] = NULL;
		}
	}""")

# 6) close_cap_dmabufs: dmabuf[1] 与 dmabuf[0] 是同一个 fd
rep("""	for (i = 0; i < cap_count; i++)
		for (p = 0; p < 2; p++)
			if (capbuf[i].dmabuf[p] >= 0) {
				close(capbuf[i].dmabuf[p]);
				capbuf[i].dmabuf[p] = -1;
			}""",
    """	for (i = 0; i < cap_count; i++) {
		/* 单平面：dmabuf[1] 与 dmabuf[0] 是同一个 fd，只能关一次 */
		if (capbuf[i].dmabuf[0] >= 0)
			close(capbuf[i].dmabuf[0]);
		for (p = 0; p < 2; p++)
			capbuf[i].dmabuf[p] = -1;
	}""")

# 7) cap_heap_planes -> cap_geom（两模式都要几何）
rep("""static int cap_heap_planes(void)
{
	struct v4l2_format f = {0};

	f.type = CAP_T;
	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) {
		printf("G_FMT CAP 失败: %s\\n", strerror(errno));
		return -errno;
	}
	cap_psize[0] = f.fmt.pix_mp.plane_fmt[0].sizeimage;
	cap_psize[1] = f.fmt.pix_mp.plane_fmt[1].sizeimage;
	if (!cap_psize[0] || !cap_psize[1]) {
		printf("G_FMT CAP sizeimage 没填(%u/%u)，没法按 dmabuf 分配\\n",
		       cap_psize[0], cap_psize[1]);
		return -EINVAL;
	}
	printf("dmabuf cap plane: Y=%u C=%u\\n", cap_psize[0], cap_psize[1]);
	return 0;
}""",
    """/* 单平面 NV12 的几何：一块 buffer，Y 在前、UV 紧跟其后。
 * UV 起址由驱动按它自己的行/高对齐排版（cedrus: bpl=ALIGN(w,16)、
 * h=ALIGN(h,16)），所以只能从 sizeimage 反推，不能拿 bpl*h 硬算 ——
 * 1080p 上差 8 行 = 15360 字节，UV 整体错位、画面变花屏。
 * sizeimage = Y + UV = Y*3/2  =>  Y = sizeimage*2/3，再按 bpl 取整。
 */
static int cap_geom(void)
{
	struct v4l2_format f = {0};
	unsigned long long ysz;

	f.type = CAP_T;
	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) {
		printf("G_FMT CAP 失败: %s\\n", strerror(errno));
		return -errno;
	}
	cap_psize[0] = f.fmt.pix.sizeimage;
	cap_psize[1] = 0;
	cap_bpl = f.fmt.pix.bytesperline ? f.fmt.pix.bytesperline : f.fmt.pix.width;
	cap_ysize = 0;
	if (cap_psize[0] && cap_bpl)
		cap_ysize = (unsigned)((ysz = (unsigned long long)cap_psize[0] * 2 / 3)
				       / cap_bpl * cap_bpl);
	if (!cap_bpl || !cap_ysize || cap_ysize >= cap_psize[0]) {
		printf("G_FMT CAP 几何不可用(bpl=%u sizeimage=%u Y=%u)\\n",
		       cap_bpl, cap_psize[0], cap_ysize);
		return -EINVAL;
	}
	printf("cap geom: %ux%u bpl=%u sizeimage=%u Y=%u C=%u\\n",
	       f.fmt.pix.width, f.fmt.pix.height, cap_bpl, cap_psize[0],
	       cap_ysize, cap_psize[0] - cap_ysize);
	return 0;
}""")

rep("static unsigned cap_psize[2];\t/* DMABUF 模式下每 plane 的字节数 */",
    "static unsigned cap_psize[2];\t/* [0]=整块 NV12 字节数（单平面） */\n"
    "static unsigned cap_bpl, cap_ysize;\t/* Y 面行宽 / Y 面字节数（UV 偏移） */")

# 8) cap_setup: 调用与循环整段重写
rep("""	if (cap_memory == V4L2_MEMORY_DMABUF) {
		r = cap_heap_planes();
		if (r)
			goto fail;
	}""",
    """	r = cap_geom();
	if (r)
		goto fail;
	if (cap_memory == V4L2_MEMORY_DMABUF && !cap_psize[0]) {
		printf("G_FMT CAP sizeimage 没填，没法按 dmabuf 分配\\n");
		r = -EINVAL;
		goto fail;
	}""")

old_loop_start = """	for (i = 0; i < cap_count; i++) {
		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[2] = {{0}};

		b.type = CAP_T;
		b.memory = cap_memory;
		b.index = i;
		b.length = 2;
		b.m.planes = pl;
"""
i0 = s.index(old_loop_start)
i1 = s.index("	return 0;\nfail:\t/* 半初始化的 CAPTURE 队列不许留给调用方：整组还回去 */")
new_loop = """	for (i = 0; i < cap_count; i++) {
		struct v4l2_buffer b = {0};

		b.type = CAP_T;
		b.memory = cap_memory;
		b.index = i;

		if (cap_memory == V4L2_MEMORY_DMABUF) {
			int hfd = dma_heap_alloc(cap_psize[0]);

			if (hfd < 0) {
				printf("dma_heap cap[%u] 失败: %s\\n", i,
				       strerror(errno));
				r = -errno;
				goto fail;
			}
			capbuf[i].dmabuf[0] = hfd;
			capbuf[i].dmabuf[1] = hfd;	/* 同一块，UV 靠偏移 */
			capbuf[i].len[0] = cap_psize[0];
			capbuf[i].len[1] = cap_psize[0] - cap_ysize;
			capbuf[i].mem[0] = mmap(NULL, cap_psize[0],
						PROT_READ | PROT_WRITE,
						MAP_SHARED, hfd, 0);
			if (capbuf[i].mem[0] == MAP_FAILED) {
				capbuf[i].mem[0] = NULL;
				printf("mmap cap[%u] 失败: %s\\n", i,
				       strerror(errno));
				r = -errno;
				goto fail;
			}
			capbuf[i].mem[1] = (unsigned char *)capbuf[i].mem[0] + cap_ysize;
			b.m.fd = hfd;
			b.length = cap_psize[0];
		} else {
			if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
				printf("QUERYBUF cap[%u] 失败: %s\\n", i,
				       strerror(errno));
				r = -errno;
				goto fail;
			}
			capbuf[i].len[0] = b.length;
			capbuf[i].len[1] = b.length - cap_ysize;
			if (getenv("NOMAP")) {	/* 零拷贝：只导出 */
				capbuf[i].mem[0] = NULL;
				capbuf[i].mem[1] = NULL;
			} else {
				capbuf[i].mem[0] = mmap(NULL, b.length,
							PROT_READ | PROT_WRITE,
							MAP_SHARED, fd, b.m.offset);
				if (capbuf[i].mem[0] == MAP_FAILED) {
					capbuf[i].mem[0] = NULL;
					printf("mmap cap[%u] 失败: %s\\n", i,
					       strerror(errno));
					r = -errno;
					goto fail;
				}
				capbuf[i].mem[1] = (unsigned char *)capbuf[i].mem[0]
						   + cap_ysize;
			}
			if (getenv("EXPBUF") || getenv("PLAY")) {
				struct v4l2_exportbuffer eb = {0};

				eb.type = CAP_T;
				eb.index = i;
				eb.plane = 0;
				eb.flags = O_CLOEXEC;
				if (xioctl(fd, VIDIOC_EXPBUF, &eb) < 0) {
					printf("EXPBUF cap[%u] 失败: %s\\n", i,
					       strerror(errno));
					r = -errno;
					goto fail;
				}
				capbuf[i].dmabuf[0] = eb.fd;
				capbuf[i].dmabuf[1] = eb.fd;
				if (i == 0)
					printf("dmabuf: buf0 fd=%d（NV12 单块，UV@%u）\\n",
					       capbuf[0].dmabuf[0], cap_ysize);
			}
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
			printf("QBUF cap[%u] 失败: %s\\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
	}
"""
s = s[:i0] + new_loop + s[i1:]
n += 1

# 9) out_setup QUERYBUF
rep("""		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[1] = {{0}};

		b.type = OUT_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 1;
		b.m.planes = pl;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
			printf("QUERYBUF out[%d] 失败: %s\\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
		outbuf[i].len = pl[0].length;
		outbuf[i].mem = mmap(NULL, outbuf[i].len, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, pl[0].m.mem_offset);""",
    """		struct v4l2_buffer b = {0};

		b.type = OUT_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
			printf("QUERYBUF out[%d] 失败: %s\\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
		outbuf[i].len = b.length;
		outbuf[i].mem = mmap(NULL, outbuf[i].len, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, b.m.offset);""")

# 10) qbuf_au
rep("""	struct v4l2_buffer b = {0};
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
	b.bytesused = len;""",
    """	struct v4l2_buffer b = {0};

	if (len > outbuf[oi].len)
		die("AU 大于 OUTPUT 缓冲（调大 MAXAU）");
	memcpy(outbuf[oi].mem, data, len);
	b.type = OUT_T;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = oi;
	b.length = outbuf[oi].len;
	b.bytesused = len;""")

# 11) cap_recycle
rep("""	struct v4l2_buffer b = {0};
	struct v4l2_plane pl[2] = {{0}};

	if (idx < 0 || idx >= NBUF_CAP_MAX)""",
    """	struct v4l2_buffer b = {0};

	if (idx < 0 || idx >= NBUF_CAP_MAX)""")

rep("""	b.type = CAP_T;
	b.memory = cap_memory;
	b.index = idx;
	b.length = 2;
	b.m.planes = pl;
	if (cap_memory == V4L2_MEMORY_DMABUF) {
		/* DMABUF 的 QBUF 每次都要重报 fd 与长度：不带的话驱动回
		 * EINVAL，而这里的 EINVAL 是被当成"重复回收"忽略掉的，
		 * 于是 buffer 永远回不了队 —— 表现是放十几帧后 STALL
		 * （inflight 只增不减）→ 重建会话。 */
		pl[0].m.fd = capbuf[idx].dmabuf[0];
		pl[0].length = capbuf[idx].len[0];
		pl[1].m.fd = capbuf[idx].dmabuf[1];
		pl[1].length = capbuf[idx].len[1];
	}""",
    """	b.type = CAP_T;
	b.memory = cap_memory;
	b.index = idx;
	if (cap_memory == V4L2_MEMORY_DMABUF) {
		/* DMABUF 的 QBUF 每次都要重报 fd 与长度：不带的话驱动回
		 * EINVAL，而这里的 EINVAL 是被当成"重复回收"忽略掉的，
		 * 于是 buffer 永远回不了队 —— 表现是放十几帧后 STALL
		 * （inflight 只增不减）→ 重建会话。 */
		b.m.fd = capbuf[idx].dmabuf[0];
		b.length = capbuf[idx].len[0];
	}""")

# 12) DQBUF cap
rep("""			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[2] = {{0}};
			int rendered = 0;

			b.type = CAP_T;
			b.memory = cap_memory;
			b.length = 2;
			b.m.planes = pl;
			double t_rx;""",
    """			struct v4l2_buffer b = {0};
			/* 单平面没有 pl[]；下游用 pl[0].bytesused/data_offset，
			 * 这里用一个本地影子填好，改动面最小。 */
			struct v4l2_plane sh = {0};
			struct v4l2_plane *pl = &sh;
			int rendered = 0;

			b.type = CAP_T;
			b.memory = cap_memory;
			double t_rx;""")

# DQBUF 之后补影子赋值
rep("""			t_rx = now_s();
			t_frame0 = t_rx;""",
    """			sh.bytesused = b.bytesused;
			sh.data_offset = b.data_offset;
			t_rx = now_s();
			t_frame0 = t_rx;""")

# 13) out DQBUF
rep("""			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[1] = {{0}};

			b.type = OUT_T;
			b.memory = V4L2_MEMORY_MMAP;
			b.length = 1;
			b.m.planes = pl;
			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)""",
    """			struct v4l2_buffer b = {0};

			b.type = OUT_T;
			b.memory = V4L2_MEMORY_MMAP;
			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)""")

# 14) s_fmt_out
rep("""	f.fmt.pix_mp.pixelformat = g_h264 ? V4L2_PIX_FMT_H264_SLICE
					 : V4L2_PIX_FMT_HEVC_SLICE;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = (max + 8191) & ~4095UL;""",
    """	f.fmt.pix.pixelformat = g_h264 ? V4L2_PIX_FMT_H264_SLICE
				       : V4L2_PIX_FMT_HEVC_SLICE;
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	f.fmt.pix.sizeimage = (max + 8191) & ~4095UL;""")
rep("""	       f.fmt.pix_mp.width, f.fmt.pix_mp.height,
	       f.fmt.pix_mp.plane_fmt[0].sizeimage, max);""",
    """	       f.fmt.pix.width, f.fmt.pix.height,
	       f.fmt.pix.sizeimage, max);""")

# 15) 提交处的 pitch：用驱动给的 bpl 而不是 capw
rep("""				rc = render_submit(rend, capbuf[b.index].dmabuf,
						   capw, caph, capw, capw,""",
    """				rc = render_submit(rend, capbuf[b.index].dmabuf,
						   capw, caph, cap_bpl, cap_bpl,""")

io.open(p, "w", encoding="utf-8").write(s)
print("patched, %d hunks" % n)
