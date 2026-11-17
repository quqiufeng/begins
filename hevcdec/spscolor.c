/* spscolor.c —— HEVC SPS → ColorMetadata
 *
 * v4l2hevc.c 里的 sps_try() 只走到 log2_max_pic_order_cnt_lsb_minus4 就返回
 * （它只为拿宽高，好在 REQBUFS 之前把 CAPTURE 尺寸设对）。VUI 在 SPS 的最末，
 * 中间隔着 short-term RPS 表、scaling list、PCM 等可变长结构，必须照样走完
 * 才能读到颜色描述。这里就把那段尾巴补上，单独一个 TU 是为了能被单测：
 * csig-test.c 造一个合成 SPS 直接喂进来，不用起硬件。
 */
#include <string.h>
#include "spscolor.h"

struct brd { const unsigned char *p; size_t bits, pos; int over; };

static unsigned br_b(struct brd *b, int n)
{
	unsigned v = 0;

	while (n-- > 0) {
		size_t byte = b->pos >> 3;

		if (byte >= b->bits) {
			b->over = 1;
			return 0;
		}
		v = (v << 1) | ((b->p[byte] >> (7 - (b->pos & 7))) & 1);
		b->pos++;
	}
	return v;
}

/* ue(v)：前导零 + 1 + 后缀。全零 / 超长一律判坏，避免解出天文数字后越界。 */
static unsigned br_ue(struct brd *b)
{
	int lz = 0;
	unsigned v;

	while (br_b(b, 1) == 0) {
		if (b->over || ++lz > 15) { b->over = 1; return 0; }
	}
	if (!lz)
		return 0;
	v = ((1u << lz) - 1) + br_b(b, lz);
	return v;
}

/* scaling_list_data()：只为跳过，但逐项校验 delta 的合法范围，
 * 结构错位时能立刻发现，而不是悄悄读到下一段的比特上。 */
static int skip_scaling_list(struct brd *b)
{
	int size_id, matrix_id;

	for (size_id = 0; size_id < 4; size_id++) {
		for (matrix_id = 0; matrix_id < 6;
		     matrix_id += (size_id == 3) ? 3 : 1) {
			if (!br_b(b, 1)) {		/* scaling_list_pred_mode_flag */
				if (br_ue(b) > 7)	/* delta -8..7 */
					return 0;
			} else {
				int n = (size_id == 0) ? 16 : 64;
				int i;

				if (br_ue(b) > 7)		/* delta_dc -8..7 */
					return 0;
				for (i = 0; i < n; i++)
					if (br_ue(b) > 7)
						return 0;
			}
			if (b->over)
				return 0;
		}
	}
	return 1;
}

/* st_ref_pic_set(idx)。预测型（inter_ref_pic_set_prediction_flag）要参考前一个
 * 集合的 NumDeltaPocs，所以得把每个表项的 poc 数记下来。 */
static int skip_st_rps(struct brd *b, unsigned idx, unsigned *num_pocs,
		       unsigned nsets)
{
	unsigned ref, cnt = 0, j;

	if (idx != 0 && br_b(b, 1)) {		/* inter_ref_pic_set_prediction_flag */
		ref = idx - 1;
		if (ref >= nsets)
			return 0;
		br_b(b, 1);			/* delta_rps_sign */
		if (br_ue(b) > 0xffff)
			return 0;		/* abs_delta_rps_minus1 */
		for (j = 0; j <= num_pocs[ref]; j++) {
			unsigned used = br_b(b, 1);

			if (used || br_b(b, 1))	/* use_delta_flag */
				cnt++;
		}
		if (b->over)
			return 0;
		num_pocs[idx] = cnt;
		return 1;
	}

	/* 显式型 */
	{
		unsigned neg = br_ue(b), pos = br_ue(b), i;

		if (neg > 16 || pos > 16)
			return 0;
		for (i = 0; i < neg + pos; i++) {
			br_ue(b);		/* delta_poc_s0/s1_minus1 */
			br_b(b, 1);		/* used_by_curr_pic_sx_flag */
		}
		if (b->over)
			return 0;
		num_pocs[idx] = neg + pos;
	}
	return 1;
}

static int parse_vui(struct brd *b, struct ColorMetadata *cm)
{
	/* ... 直到 colour_description：后面的 aspect ratio、timing、bitstream
	 * restriction 都不影响颜色，读到 matrix_coeffs 就收工。 */
	if (br_b(b, 1)) {			/* aspect_ratio_info_present_flag */
		if (br_b(b, 8) == 255) {	/* aspect_ratio_idc == Ext_SAR */
			br_b(b, 16);
			br_b(b, 16);
		}
	}
	if (br_b(b, 1))				/* overscan_info_present_flag */
		br_b(b, 1);			/* overscan_appropriate_flag */
	if (!br_b(b, 1))			/* video_signal_type_present_flag */
		return 0;
	br_b(b, 3);				/* video_format */
	cm->range = br_b(b, 1);			/* video_full_range_flag */
	if (br_b(b, 1)) {			/* colour_description_present_flag */
		cm->primaries = br_b(b, 8);
		cm->transfer = br_b(b, 8);
		cm->matrix = br_b(b, 8);
	}
	return b->over ? 0 : 1;
}

int sps_color_parse(const unsigned char *d, size_t n, int ptl,
		    struct ColorMetadata *cm)
{
	struct brd b = { d, n * 8, 0, 0 };
	unsigned msl, chroma, poc4, i, nsets;
	unsigned num_pocs[64];

	memset(num_pocs, 0, sizeof(num_pocs));

	br_b(&b, 4);				/* sps_video_parameter_set_id */
	msl = br_b(&b, 3);			/* sps_max_sub_layers_minus1 */
	if (msl > 6)
		return 0;
	br_b(&b, 1);				/* sps_temporal_id_nesting_flag */
	b.pos = 8 + (size_t)ptl;		/* profile_tier_level，宽度已由外部试出 */

	br_ue(&b);				/* sps_seq_parameter_set_id */
	chroma = br_ue(&b);
	if (chroma > 3)
		return 0;
	if (chroma == 3)			/* separate_colour_plane_flag */
		br_b(&b, 1);
	br_ue(&b);				/* pic_width_in_luma_samples */
	br_ue(&b);				/* pic_height_in_luma_samples */
	if (br_b(&b, 1))			/* conformance_window_flag */
		for (i = 0; i < 4; i++)		/* left/right/top/bottom */
			br_ue(&b);
	cm->bit_depth = 8 + (int)br_ue(&b);	/* bit_depth_luma_minus8 */
	br_ue(&b);				/* bit_depth_chroma_minus8 */
	poc4 = br_ue(&b);			/* log2_max_pic_order_cnt_lsb_minus4 */
	if (poc4 > 12)
		return 0;

	/* sps_sub_layer_ordering_info_present_flag */
	{
		unsigned f = br_b(&b, 1);

		for (i = f ? 0 : msl; i <= msl; i++) {
			br_ue(&b);			/* max_dec_pic_buffering_minus1 */
			br_ue(&b);			/* max_num_reorder_pics */
			br_ue(&b);			/* max_latency_increase_plus1 */
		}
	}
	for (i = 0; i < 6; i++)			/* log2_*_block_size / transform_depth */
		br_ue(&b);
	if (br_b(&b, 1)) {			/* scaling_list_enabled_flag */
		if (br_b(&b, 1) && !skip_scaling_list(&b))
			return 0;
	}
	br_b(&b, 1);				/* amp_enabled_flag */
	br_b(&b, 1);				/* sample_adaptive_offset_enabled_flag */
	if (br_b(&b, 1)) {			/* pcm_enabled_flag */
		br_b(&b, 4);			/* pcm_sample_bit_depth_luma_minus1 */
		br_b(&b, 4);			/* pcm_sample_bit_depth_chroma_minus1 */
		br_ue(&b);			/* log2_min_pcm_luma_coding_block_size_minus3 */
		br_ue(&b);			/* log2_diff_max_min_pcm_luma_coding_block_size */
		br_b(&b, 1);			/* pcm_loop_filter_disabled_flag */
	}

	nsets = br_ue(&b);			/* num_short_term_ref_pic_sets */
	if (nsets > 64)
		return 0;
	for (i = 0; i < nsets; i++)
		if (!skip_st_rps(&b, i, num_pocs, 64))
			return 0;

	if (br_b(&b, 1)) {			/* long_term_ref_pics_present_flag */
		unsigned nlt = br_ue(&b);

		if (nlt > 32)
			return 0;
		for (i = 0; i < nlt; i++) {
			br_b(&b, (int)poc4 + 4);	/* lt_ref_pic_poc_lsb_sps */
			br_b(&b, 1);			/* used_by_curr_pic_lt_sps_flag */
		}
	}
	br_b(&b, 1);				/* sps_temporal_mvp_enabled_flag */
	br_b(&b, 1);				/* strong_intra_smoothing_enabled_flag */
	if (!br_b(&b, 1))			/* vui_parameters_present_flag */
		return 0;
	if (b.over)
		return 0;
	return parse_vui(&b, cm);
}
