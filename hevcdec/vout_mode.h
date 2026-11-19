/* vout_mode.h —— 把「盒子输出什么分辨率」和「显示设备支持什么」拆成两件事
 *
 * 以前这两件事在 vout_open() 里缠在一起，而且目标写死 2560x1440@60：
 * 换一台电视（1080p 或 4K）就掉进「退化为最大面积」分支，选出来对不对全靠
 * 运气，事后也没法回答「为什么最后是 1920x1080」。
 *
 * 拆开之后各管一段：
 *   vout_display_probe()    只读探测：哪台显示设备连着、EDID 报了几条模式、
 *                           现在 CRTC 上跑的是哪条。不写 CRTC，桌面在跑时也安全。
 *   vout_mode_negotiate()   纯函数协商：显示能力 + 用户请求 → 实际输出模式，
 *                           并给出理由（why）。不碰 fd，能脱离设备单测。
 *
 * 语义只有一条，别弄反：请求是「偏好」，显示设备才是权威。屏幕没报的尺寸
 * 绝不硬上（那只能黑屏或走 scaler 变形），协商结果一定落在 probe 的模式表里。
 * 请求做不到时 negotiate 返回 -1 并写清 why，由调用方决定是降级还是报错——
 * 库不替调用方偷偷改分辨率。
 */
#ifndef VOUT_MODE_H
#define VOUT_MODE_H

#include <stdint.h>
#include <drm/drm_mode.h>

#define VOUT_DISP_MODES 64
#define VOUT_DISP_NAME  32

/* 一台已连接显示设备的全部能力。字段全是 probe 填的，调用方只读。 */
struct vout_display {
	uint32_t conn_id;	/* connector id */
	uint32_t enc_id;	/* 灌给 vout 的 encoder（优先 connector 当前绑的） */
	uint32_t crtc_id;	/* 当前绑的 CRTC；0 = 没绑，取第一块 */
	uint32_t crtc_idx;	/* crtc_id 在 GETRESOURCES 里的下标（possible_crtcs 用） */
	char name[VOUT_DISP_NAME];	/* "HDMI-A-1"，只给人看 */
	int nmode;
	struct drm_mode_modeinfo modes[VOUT_DISP_MODES];
	int has_cur;			/* CRTC 上真有一条 mode 在跑 */
	struct drm_mode_modeinfo cur;
};

/* 只读探测：挑第一个 status=connected 且有 mode 的 connector。
 *
 * 必须只认 connected：X96 的 card0 上 Composite-1（CVBS）排在 HDMI-A-1 前面
 * 且 status=unknown，只看 count_modes 会选中它 → 输出 720x576i、HDMI 黑屏、
 * vout 队列瞬间堵死。
 *
 * 返回 0 成功；-1 表示这台机器上没有可用显示设备（原因打到 stderr）。 */
int vout_display_probe(int dfd, struct vout_display *d);

/* 协商结局的来源，why 之外再给一个可编程的枚举（日志/测试用）。 */
enum vout_mode_src {
	VOUT_SRC_EXACT = 0,	/* 请求的 WxH@R 精确命中 */
	VOUT_SRC_SIZE,		/* 尺寸命中，刷新率是挑的（请求没给 R） */
	VOUT_SRC_REFRESH,	/* 尺寸命中，刷新率取最接近请求值 */
	VOUT_SRC_CURRENT,	/* auto：沿用屏幕当前模式 */
	VOUT_SRC_PREFERRED,	/* auto：EDID 首选（modes[0]） */
	VOUT_SRC_LARGEST,	/* 兜底：最大面积（<= 4096 宽，避开 CVBS 干扰） */
	VOUT_SRC_FIRST,		/* 最后一条：modes[0]，能跑就行 */
};

struct vout_mode_choice {
	struct drm_mode_modeinfo mode;
	enum vout_mode_src src;
	char why[160];		/* 人话：为什么是这条 */
};

const char *vout_mode_src_name(enum vout_mode_src s);

/* 协商。req 语法：
 *   NULL / "" / "auto"     显示设备说了算：有当前模式用当前，否则 EDID 首选
 *   "2560x1440@60"         宽 x 高 @ 刷新（@R 可省：R=0 时按 60Hz 优先挑）
 *   "1920x1080" / "1080p"  只给尺寸；480p/576p/720p/1080p/1440p/2160p 也认
 *
 * 返回 0 成功；-1 表示屏幕根本不支持（why 里列出它支持的几条），或者
 * req 语法错。auto 不会失败，除非 probe 没给出任何模式。 */
int vout_mode_negotiate(const struct vout_display *d, const char *req,
			struct vout_mode_choice *out);

/* "2560x1440@60" 格式化，给日志和外部共享屏幕信息用。返回写入长度。 */
int vout_mode_fmt(const struct drm_mode_modeinfo *m, char *buf, int cap);

/* 一句话问「这块屏最终会输出什么」：开 dev（O_RDONLY）→ probe → negotiate，
 * 把结果格成 "WxH[@R]" 写进 buf，理由走 stderr。
 *
 * 存在的唯一理由是「唯一真源」：壳（play.sh / 桌面）需要在自己起播放器之前
 * 就知道几何，以前只能照着 sysfs 再猜一遍；两套猜测一旦不一致，DSTGEO 和
 * 播放器实际铺的模式就错位（黑边/缩放到角落里）。让壳直接问播放器二进制，
 * 壳就不再有自己的策略，只有一份。
 *
 * req 语义同 vout_mode_negotiate；req=NULL 时看 VOUT_MODE 环境变量。
 * 返回 0 成功；-1 打不开设备/没有显示设备/协商失败（why 已打到 stderr）。 */
int vout_mode_query(const char *dev, const char *req, char *buf, int cap);

/* 把最终输出几何落一个文件（VOUT_GEO_FILE，默认 /tmp/vout-geo），给壳/桌面/
 * 监控当"播放器此刻到底铺的多少"读。两条上屏路径（vout.c 的 DRM 平面、
 * glout.c 的 GL）都调它，形状只有一个：文本 "WxH[@R]\n"。
 * 先写 .tmp 再 rename：读方永远看不到半截（"2560x1" 会算出荒唐的缩放比）。
 * 写失败不算错——这是旁路信息，不参与播放。返回 0 成功。 */
int vout_geo_publish(const char *geo);

#endif /* VOUT_MODE_H */
