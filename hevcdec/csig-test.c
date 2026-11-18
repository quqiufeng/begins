/* csig-test.c —— 内容信号解析测试（合成 NAL + 真实码流两路）
 * 直接 include 播放器本体，测的就是播放器在跑的那个 static 函数。
 *   cc -DUSE_DRM -o csigtest csig-test.c spscolor.c render.c render_drm.c render_gl.c vout.c -lm
 *   ./csigtest                合成用例（SEI + SPS/VUI）
 *   ./csigtest x.265          扫真实码流里的 prefix SEI
 */
#define main vdec_main_unused
#include "v4l2hevc.c"
#undef main

static int fails;

static void chk(int c, const char *name, double got, double want)
{
	printf("  [%s] %-28s got=%.3f want=%.3f\n", c ? "ok" : "FAIL",
	       name, got, want);
	if (!c)
		fails++;
}

static void chks(int c, const char *name, int got, int want)
{
	printf("  [%s] %-28s got=%d want=%d\n", c ? "ok" : "FAIL",
	       name, got, want);
	if (!c)
		fails++;
}

/* ---------------- 合成 prefix SEI ----------------
 * payload 144 (maxCLL 1000 / maxFALL 400)
 * payload 137 (母版峰值 4000 / 0.005 nits)，原色字段故意填垃圾，
 * 用来验证"认不出色域就不猜"。
 */
static size_t mk_sei(unsigned char *b)
{
	static const unsigned char md[24] = {
		0x33, 0x2a, 0x2a, 0x17, 0x2c, 0x0d, 0x15, 0x2e,
		0x11, 0x00, 0x3e, 0x0f, 0x00, 0x00, 0x00, 0x00,
		0x02, 0x62, 0x5a, 0x00,		/* 4000.0000 nits */
		0x00, 0x00, 0x00, 0x32,		/* 0.0050 nits */
	};
	size_t n = 0;

	b[n++] = 0x4e; b[n++] = 0x01;			/* NAL 39 */
	b[n++] = 144; b[n++] = 4;			/* maxcll */
	b[n++] = 0x03; b[n++] = 0xe8;			/* 1000 */
	b[n++] = 0x01; b[n++] = 0x90;			/* 400 */
	b[n++] = 137; b[n++] = 24;			/* mastering display */
	memcpy(b + n, md, 24); n += 24;
	b[n++] = 0x80;					/* rbsp trailing */
	return n;
}

static int t_sei(void)
{
	unsigned char b[64];

	memset(&g_cm, 0, sizeof(g_cm));
	csig_sei(b, mk_sei(b));
	chk(fabs(g_cm.max_cll - 1000.0) < 1e-6, "max_cll", g_cm.max_cll, 1000);
	chk(fabs(g_cm.max_fall - 400.0) < 1e-6, "max_fall", g_cm.max_fall, 400);
	chk(fabs(g_cm.mastering_max_luminance - 4000.0) < 1e-3,
	    "mastering_max_luminance", g_cm.mastering_max_luminance, 4000);
	chk(fabs(g_cm.mastering_min_luminance - 0.005) < 1e-6,
	    "mastering_min_luminance", g_cm.mastering_min_luminance, 0.005);
	chk(fabs(csig_peak() - 1000.0) < 1e-6, "peak 取 max_cll", csig_peak(), 1000);
	chks(g_cm.primaries == 0, "垃圾原色 -> 不猜色域", g_cm.primaries, 0);

	/* 只有母版信息时退回 mastering_max_luminance */
	g_cm.max_cll = 0.0f;
	chk(fabs(csig_peak() - 4000.0) < 1e-3, "peak 退回母版", csig_peak(), 4000);
	g_cm.mastering_max_luminance = 0.0f;
	chk(csig_peak() == 0.0, "都没有 -> 0（走兜底）", csig_peak(), 0);
	return fails;
}

/* ---------------- 合成 SPS（带 VUI） ----------------
 * 一个最小的 4:2:0 10bit 3840x2160 SPS，VUI 里写 2020 primaries / PQ /
 * 2020-NCL matrix / limited range。sps_try() 用 88 位的 PTL，所以 PTL 整段填 0。
 */
struct bwr { unsigned char *p; size_t cap, bit; int over; };

static void w_b(struct bwr *w, unsigned v, int n)
{
	while (n-- > 0) {
		size_t byte = w->bit >> 3;

		if (byte >= w->cap) { w->over = 1; return; }
		if ((v >> n) & 1)
			w->p[byte] |= 128u >> (w->bit & 7);
		w->bit++;
	}
}

static void w_ue(struct bwr *w, unsigned v)
{
	unsigned v1 = v + 1, t = v1;
	int lz = 0;

	while (t > 1) { t >>= 1; lz++; }
	w_b(w, 0, lz);
	w_b(w, v1, lz + 1);
}

static int mk_sps(unsigned char *buf, size_t cap, int with_vui, int ar_idc)
{
	struct bwr w = { buf, cap, 0, 0 };
	int i;

	memset(buf, 0, cap);
	w_b(&w, 0, 4);			/* sps_video_parameter_set_id */
	w_b(&w, 0, 3);			/* sps_max_sub_layers_minus1 */
	w_b(&w, 1, 1);			/* sps_temporal_id_nesting_flag */
	for (i = 0; i < 88; i++)	/* profile_tier_level，解析器按 88 位跳过 */
		w_b(&w, 0, 1);
	w_ue(&w, 0);			/* sps_seq_parameter_set_id */
	w_ue(&w, 1);			/* chroma_format_idc = 4:2:0 */
	w_ue(&w, 3840);
	w_ue(&w, 2160);
	w_b(&w, 0, 1);			/* conformance_window_flag */
	w_ue(&w, 2);			/* bit_depth_luma_minus8   -> 10 */
	w_ue(&w, 2);			/* bit_depth_chroma_minus8 */
	w_ue(&w, 4);			/* log2_max_pic_order_cnt_lsb_minus4 */
	w_b(&w, 0, 1);			/* sps_sub_layer_ordering_info_present */
	w_ue(&w, 4); w_ue(&w, 2); w_ue(&w, 0);	/* 只有 1 层 */
	for (i = 0; i < 6; i++)		/* 4 个 log2_*_block_size + 2 个 depth */
		w_ue(&w, 0);
	w_b(&w, 0, 1);			/* scaling_list_enabled_flag */
	w_b(&w, 0, 1);			/* amp_enabled_flag */
	w_b(&w, 1, 1);			/* sample_adaptive_offset_enabled_flag */
	w_b(&w, 0, 1);			/* pcm_enabled_flag */
	w_ue(&w, 0);			/* num_short_term_ref_pic_sets */
	w_b(&w, 0, 1);			/* long_term_ref_pics_present_flag */
	w_b(&w, 1, 1);			/* sps_temporal_mvp_enabled_flag */
	w_b(&w, 0, 1);			/* strong_intra_smoothing_enabled_flag */
	w_b(&w, with_vui, 1);		/* vui_parameters_present_flag */
	if (with_vui) {
		/* ar_idc: 0 = 没写 aspect_ratio_info，1 = idc 1 (1:1)，
		 * 255 = Ext_SAR（显式 16:15，模拟 720x576 那类老片源） */
		w_b(&w, ar_idc ? 1 : 0, 1);	/* aspect_ratio_info_present_flag */
		if (ar_idc) {
			w_b(&w, ar_idc, 8);	/* aspect_ratio_idc */
			if (ar_idc == 255) {
				w_b(&w, 16, 16);	/* sar_width */
				w_b(&w, 15, 16);	/* sar_height */
			}
		}
		w_b(&w, 0, 1);		/* overscan_info_present_flag */
		w_b(&w, 1, 1);		/* video_signal_type_present_flag */
		w_b(&w, 5, 3);		/* video_format = unspecified */
		w_b(&w, 0, 1);		/* video_full_range_flag = limited */
		w_b(&w, 1, 1);		/* colour_description_present_flag */
		w_b(&w, 9, 8);		/* colour_primaries = BT.2020 */
		w_b(&w, 16, 8);		/* transfer = PQ */
		w_b(&w, 9, 8);		/* matrix_coeffs = BT.2020-NCL */
	}
	w_b(&w, 1, 1);			/* rbsp_stop_one_bit */
	while (w.bit & 7)
		w_b(&w, 0, 1);
	return w.over ? -1 : (int)(w.bit >> 3);
}

static int t_sps(void)
{
	unsigned char buf[256];
	struct ColorMetadata cm;
	int n, rc;

	n = mk_sps(buf, sizeof(buf), 1, 0);
	if (n < 0) { printf("  [FAIL] 合成 SPS 溢出\n"); fails++; return fails; }

	memset(&cm, 0, sizeof(cm));
	chks(sps_color_parse(buf, n, 88, &cm), "VUI 走通", 1, 1);
	chks(cm.bit_depth, "bit_depth", cm.bit_depth, 10);
	chks(cm.primaries, "colour_primaries", cm.primaries, 9);
	chks(cm.transfer, "transfer(PQ)", cm.transfer, 16);
	chks(cm.matrix, "matrix(2020NCL)", cm.matrix, 9);
	chks(cm.range == 0, "range(limited)", cm.range, 0);

	/* 同一份 SPS 装进 g_cm 后，色域名/移位量都要跟着枚举走
	 * （cm_range_shift() 读的是 g_cm，所以先装再测） */
	memcpy(&g_cm, &cm, sizeof(cm));
	chks(cm_range_shift(), "10bit limited 右移", cm_range_shift(), 2);
	printf("  [%s] %-28s %s\n",
	       !strcmp(cm_gamut(), "BT.2020") ? "ok" : "FAIL",
	       "primaries=9 -> 色域", cm_gamut());
	if (strcmp(cm_gamut(), "BT.2020"))
		fails++;

	/* SAR（aspect_ratio_info）：idc 1 -> 1:1；Ext_SAR -> 显式 16:15 */
	memset(&cm, 0, sizeof(cm));
	n = mk_sps(buf, sizeof(buf), 1, 1);
	rc = sps_color_parse(buf, n, 88, &cm);	/* 先跑再抽查，别让实参求值顺序坑人 */
	chks(rc && cm.sar_num == 1 && cm.sar_den == 1,
	     "SAR idc=1 -> 1:1", cm.sar_num * 100 + cm.sar_den, 101);
	memset(&cm, 0, sizeof(cm));
	n = mk_sps(buf, sizeof(buf), 1, 255);
	rc = sps_color_parse(buf, n, 88, &cm);
	chks(rc && cm.sar_num == 16 && cm.sar_den == 15,
	     "SAR Ext_SAR -> 16:15", cm.sar_num * 100 + cm.sar_den, 1615);

	/* 没有 VUI：返回 0，且不把 cm 改脏 */
	n = mk_sps(buf, sizeof(buf), 0, 0);
	memset(&cm, 0, sizeof(cm));
	cm.primaries = 77;	/* 哨兵：解析失败时不该被动过 */
	chks(!sps_color_parse(buf, n, 88, &cm), "无 VUI -> 返回 0", 0, 0);
	chks(cm.primaries, "无 VUI -> 不改 cm", cm.primaries, 77);

	/* 截断的 SPS：必须老实报错，而不是读越界 */
	chks(!sps_color_parse(buf, 6, 88, &cm), "截断 -> 返回 0", 0, 0);
	chks(!sps_color_parse(buf, n, 96, &cm), "PTL 猜错 -> 不自洽", 0, 0);
	return fails;
}

int main(int argc, char **argv)
{
	printf("内容信号解析测试\n");
	t_sei();
	t_sps();
	if (argc > 1) {			/* 真实码流：扫所有 prefix SEI */
		FILE *f = fopen(argv[1], "rb");
		unsigned char *p;
		long n;
		size_t i, cnt = 0;

		if (!f) { perror(argv[1]); return 2; }
		fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
		p = malloc(n);
		if (fread(p, 1, n, f) != (size_t)n) return 2;
		fclose(f);
		memset(&g_cm, 0, sizeof(g_cm));
		for (i = 0; i + 5 < (size_t)n; i++) {
			if (p[i] || p[i+1] || p[i+2] != 1) continue;
			if (nal_type(&p[i+3]) == 39) { csig_sei(&p[i+3], n - i - 3); cnt++; }
			i += 2;
		}
		printf("  扫到 %zu 条 prefix SEI：maxCLL=%.0f maxFALL=%.0f md=%.0f/%.4f 色域=%s\n",
		       cnt, g_cm.max_cll, g_cm.max_fall,
		       g_cm.mastering_max_luminance, g_cm.mastering_min_luminance,
		       cm_gamut());
		printf("  csig_peak()=%.0f\n", csig_peak());
		free(p);
	}
	printf("%s（失败 %d 项）\n", fails ? "有失败项" : "全部通过", fails);
	return fails != 0;
}
