/* vout.h —— SDR 快速路径：NV12 dma-buf → DRM overlay plane 直出
 *
 * 只做一件事：把两块 dma-buf（Y / 交织 CbCr）挂到 KMS plane 上按 pts 翻页。
 * 不读、不写、不映射帧数据——一次 memcpy 都没有。
 *
 * HDR（PQ/BT.2020）不属于这条路径：meson 的 DRM 没有 GAMMA_LUT/CTM，
 * CPU 逐像素改写 4K 一帧 ~800ms，唯一出路是 GPU（glout.c）。两条路径在
 * player 层按源格式分流，vout 只认 SDR。
 *
 * 四个概念分清楚，别混着用：
 *   提交（submit）  fd→GEM handle→fb 都在这里做完，几十微秒，不碰 vblank。
 *   队列（queue）   submit 与上屏解耦：调用方可以领先几帧，管子不再串行。
 *   节拍（vblank）  pts 算目标槽，WAIT_VBLANK(ABSOLUTE) 一次 ioctl 睡到点。
 *   完成反馈（cb）  SETPLANE 之后确认帧真的被扫过，回调把 owner 还给你。
 *
 * 生命周期契约（两条，缺一条就 tearing 或饿死解码器）：
 *   1) submit 之后，vout 自己持有 GEM handle 引用，fd 可以立刻关掉 ——
 *      但**内存不能改写**。dma-buf 被解码器 QBUF 回收去写新帧，屏上就是花屏。
 *   2) 所以：每一次 submit 恰好换来一次回调（上屏 / 丢弃 / 中止），
 *      owner 只能等回调到了再还给 vdec。同步用法（vout_frame）例外，
 *      它返回即代表帧已经挂在 plane 上，调用方按老规矩立刻回收 —— 那是
 *      深度 1 的特例，代价是每帧串行吃一个 vblank。
 */
#ifndef VOUT_H
#define VOUT_H

#include <stdint.h>

struct vout;

enum vout_scale {
	VOUT_FIT = 0,	/* 等比缩到装得下，居中，四周黑边（默认） */
	VOUT_FILL,	/* 强制铺满，会变形 */
	VOUT_CROP,	/* 等比放大铺满，超出部分裁掉 */
};

/* 完成反馈的三种结局。每一次 submit 必定收到其中之一，且只收一次。 */
enum vout_status {
	VOUT_SHOWN = 1,		/* 已确认接管扫描（latch 序号见回调参数） */
	VOUT_DROPPED = 2,	/* 节拍判定迟到/队列溢出，没有上屏，buffer 立刻可用 */
	VOUT_ABORTED = 3,	/* flush/close 清队，同上 */
};

/* ctx 是注册时给的，owner 是 submit 时给的，pts 原样带回。
 * latch = 该帧接管扫描的 vblank 序号（VOUT_SHOWN 才有意义，其余为 0）。
 * 回调里只允许调 vout_submit（线程内联、几十 µs）；pump/flush/close 会被拒。
 * 回调跑在调用 pump 的那个线程里，不是信号上下文，可以放心做 QBUF。 */
typedef void (*vout_displayed_cb)(void *ctx, void *owner, double pts,
				  uint32_t latch, int status);

struct vout_stats {
	int flips;		/* 成功 SETPLANE 次数 */
	int drops;		/* 丢帧总数（= stales + 队列溢出） */
	int timeouts;		/* WAIT_VBLANK 失败次数 */
	unsigned sw, sh;	/* 当前源尺寸 */
	unsigned dw, dh;	/* 屏幕模式 */
	unsigned refresh;	/* Hz */
	double t_first, t_last;	/* 首/末帧上屏时刻（CLOCK_MONOTONIC） */
	/* vblank 真值：用来验节拍到底落在槽上还是撞在墙上。
	 * 一帧 24fps@60Hz 应该吃掉 2 或 3 个 vblank，avg 必须是 2.5。 */
	uint32_t vbl_first, vbl_last;
	int vbl_ok;		/* WAIT_VBLANK 是否可用（不可用则本场无节拍） */

	/* 队列与丢帧 */
	int queued;		/* 当前队列深度 */
	int qdepth;		/* 配置的队列深度上限（1 = 同步） */
	int submitted;		/* submit 次数 */
	int stales;		/* 提交时目标槽已过 ≥2 个 vblank，直接丢 */
	int late;		/* 上屏但晚于目标槽 */
	double t_late_max;	/* 最大迟到 ms */

	/* 完成反馈 */
	int shown;		/* 已确认上屏次数 */
	int misses;		/* SETPLANE 挤进同一个 vblank：前帧从未被扫过 */

	/* 显示帧间隔分布（ms）：两个真上屏 latch 之差，不是 fps 的倒数均值。
	 * 24fps@60Hz 应该只有 33.3/50.0 两个峰。p99 掉到 50 以上说明节拍在抖，
	 * 而 avg fps 可能一点都看不出来。 */
	int iv_n;		/* 样本数（= shown - 1） */
	double iv_p50, iv_p90, iv_p99, iv_max;
	int iv_over;		/* 间隔 > 1.5 刷新周期的次数（漏槽） */
	int aborted;		/* flush/close 清掉的帧数 */
	int pending;		/* 交了但还没收到回调的帧数（含上一帧） */
};

/* drmdev 为 NULL 时取 /dev/dri/card0。失败返回 NULL 并已打日志。 */
struct vout *vout_open(const char *drmdev);

/* ---------- 同步接口（深度 1，老行为） ----------
 * 提交 + 立刻等到它上屏。返回 1=已上屏，0=本次跳过/丢弃，-1=错误。
 * pts <= 0 表示无时间戳：不等待，尽快上屏。 */
int vout_frame(struct vout *v, const int fd[2], unsigned w, unsigned h, double pts);
int vout_frame_ex(struct vout *v, const int fd[2], unsigned w, unsigned h,
		  unsigned ypitch, unsigned cpitch, double pts);

/* ---------- 异步接口（队列 + 节拍 + 反馈） ----------
 * 深度 <= 1 时退化成同步语义；建议 2~4（24fps@60 下一帧占 2~3 槽）。
 * 返回 0 = 已入队，1 = 已同时上屏（同步模式），2 = 已丢弃，-1 = 错误。 */
int vout_set_queue(struct vout *v, int depth);
int vout_submit(struct vout *v, const int fd[2], unsigned w, unsigned h,
		unsigned ypitch, unsigned cpitch, double pts, void *owner);

/* 推队列：把到点的帧翻上去。timeout_ms <0 = 一直等到队列排空。
 * 返回本次翻上去的帧数，-1 错误。非阻塞用法传 0：
 * 「该翻的全翻，没到点的一个都不等」——这是渲染线程插在解码线程里的钩子。 */
int vout_pump(struct vout *v, int timeout_ms);

/* 等到"最后一帧已确认上屏"，用于暂停/收流/切源前把画面钉住。
 * 返回 1 = 已确认，0 = 超时，-1 = 错误。 */
int vout_wait_shown(struct vout *v, int timeout_ms);

/* 队列里剩下的全部立刻翻上去（不看槽位），用于 seek 前追平。 */
int vout_drain(struct vout *v);

void vout_set_displayed_cb(struct vout *v, vout_displayed_cb cb, void *ctx);

void vout_set_scale(struct vout *v, enum vout_scale m);
/* 像素宽高比（VUI SAR）：num:den，0 或非法值按 1:1。
 * 老片源 720x576 SAR 16:15 的显示宽高比是 16:9 而不是 5:4，不传就会变形。
 * 可以在 submit 之前任意时刻改（改了当帧生效），会重算目标矩形。 */
void vout_set_par(struct vout *v, unsigned num, unsigned den);
/* 覆盖 EDID 报告的刷新率（某些盒子报 60 实际 59.94，长时间会有节拍漂移） */
void vout_set_refresh(struct vout *v, unsigned hz);

/* 解码会话重建（seek）后必须调用：清空队列（逐帧回调 VOUT_ABORTED），
 * 回收所有缓存的 fb，只留屏上那张，否则每次 seek 泄漏显存，
 * 20 次后 ADDFB2 就开始失败。 */
int vout_flush(struct vout *v);

void vout_get_stats(struct vout *v, struct vout_stats *st);

/* RMFB 除屏上那张以外的全部 fb，然后关 fd。画面保持最后一帧不动。 */
void vout_close(struct vout *v);

#endif /* VOUT_H */
