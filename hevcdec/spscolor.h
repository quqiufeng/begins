#ifndef SPSCCOLOR_H
#define SPSCCOLOR_H

#include <stddef.h>
#include "csig.h"

/* 从一个 SPS RBSP（已去防竞争字节）里取颜色描述，写进 *cm：
 *   bit_depth                 ← bit_depth_luma_minus8
 *   primaries/transfer/matrix ← VUI colour_description（没写就保持 0）
 *   range                     ← VUI video_full_range_flag
 * ptl 为 profile_tier_level 占的位数（sps_try() 已试出，通常 88）。
 * 返回 1 = 走通且 VUI 存在，0 = 结构不自洽或没有 VUI（此时 *cm 不动）。
 */
int sps_color_parse(const unsigned char *rbsp, size_t n, int ptl,
		    struct ColorMetadata *cm);

#endif
