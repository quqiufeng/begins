/* render.h —— 播放器唯一的输出接口：一个播放器，多个 Renderer
 *
 * 分界线只有一条：**播放器管时间轴，Renderer 管"这一帧怎么变成光"。**
 * 播放器负责解、喂、seek、会话重建、pts、缓冲生命周期；它不知道也不许知道
 * 目标端是 KMS plane 还是 GLES/GBM。Renderer 只收到"一块 NV12 dma-buf +
 * 它该上屏的时刻"，不回问播放器任何解码状态。
 *
 * 两个后端（同一份接口，能力不同，不是两份代码路径）：
 *   drm —— NV12 dma-buf 直挂 overlay plane，零拷贝零运算（vout.c）
 *          有节拍（vblank 槽）、有队列（深度 2~4）、异步完成反馈
 *   gl  —— EGL/GBM + GLES3，导入 dmabuf 当纹理，shader 里做 HDR→SDR
 *          同步：submit 返回即已 swap，完成反馈就地触发
 *
 * 播放器看到的差异只有一个 caps 位：HDR 源要不要先在 CPU 上转 SDR
 * （drm 后端没有 GAMMA_LUT/CTM，只能播放器侧 tm_apply）。
 *
 * 完成反馈契约（缓冲安全全靠它）：
 *   每一次 submit 恰好换来一次 done 回调，三种结局之一，且只一次。
 *   owner 原样带回，播放器在回调里把 capture buffer 还给 vdec。
 *   → submit 之后内存不许改写，直到 done 回来；回调在调用 pump 的线程里跑。
 */
#ifndef RENDER_H
#define RENDER_H

#include <stdint.h>

struct renderer;

/* 一次 submit 的三种结局 */
enum render_status {
	RENDER_SHOWN = 1,	/* 已确认接管扫描/已 swap（latch 有值） */
	RENDER_DROPPED = 2,	/* 迟到或队列溢出，没上屏，owner 立刻可用 */
	RENDER_ABORTED = 3,	/* flush/close 清队，同上 */
};

#define RENDER_CAP_HDR	0x1u	/* 原生吃 PQ/BT.2020，不需要 CPU 先转 SDR */
#define RENDER_CAP_PACE	0x2u	/* 自己按 pts 排上屏槽（有节拍）；否则播放器负责睡 */

struct render_stats {
	const char *name;
	unsigned caps;

	int submitted;		/* submit 次数 */
	int shown;		/* 确认上屏次数 */
	int dropped;		/* 丢帧（迟到/溢出） */
	int aborted;		/* flush/close 清掉的帧 */
	int pending;		/* 交了还没回调的帧（在飞） */
	int misses;		/* 挤进同一个 vblank：前帧没被扫到 */
	int late;		/* 上屏但晚于目标槽 */
	double late_ms_max;

	unsigned sw, sh;	/* 源尺寸 */
	unsigned dw, dh;	/* 屏幕模式 */
	unsigned refresh;	/* Hz */
	double t_first, t_last;	/* 首/末帧上屏时刻（CLOCK_MONOTONIC） */

	/* GL 路径的耗时账；drm 路径恒为 0 */
	double draw_ms_sum, draw_ms_max, swap_ms_sum;
};

/* 每次 submit 必回调一次。latch 只有 RENDER_SHOWN 有意义。 */
typedef void (*render_done_cb)(void *ctx, void *owner, double pts,
			       uint32_t latch, int status);

struct render_ops {
	const char *name;
	unsigned caps;

	int  (*probe)(void);	/* 1 = 本后端已编进这个二进制（auto 选择用） */
	int  (*init)(struct renderer *r, unsigned sw, unsigned sh);
	int  (*submit)(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		       unsigned ypitch, unsigned cpitch, double pts, void *owner);
	int  (*pump)(struct renderer *r, int timeout_ms);
	int  (*flush)(struct renderer *r);
	int  (*wait_shown)(struct renderer *r, int timeout_ms);
	void (*close)(struct renderer *r);
	void (*stats)(struct renderer *r, struct render_stats *st);
};

struct renderer {
	const struct render_ops *ops;
	render_done_cb done;
	void *done_ctx;
	void *priv;
};

/* name: "drm" | "gl" | "auto"（auto = 第一个可用的，drm 优先）。
 * 不可用/初始化失败返回 NULL 并已打日志；播放器据此报错退出，不做回退。 */
struct renderer *render_open(const char *name, unsigned sw, unsigned sh,
			     render_done_cb done, void *done_ctx);
void render_close(struct renderer *r);

/* 返回 >=0 表示已接管（0 入队 / 1 已上屏 / 2 已丢，done 均会回调）；
 * <0 表示这一帧没进去，owner 仍在调用方手里，可立刻回收。 */
int render_submit(struct renderer *r, const int fd[2], unsigned w, unsigned h,
		  unsigned ypitch, unsigned cpitch, double pts, void *owner);
int render_pump(struct renderer *r, int timeout_ms);
int render_flush(struct renderer *r);
int render_wait_shown(struct renderer *r, int timeout_ms);
void render_stats(struct renderer *r, struct render_stats *st);

const char *render_name(const struct renderer *r);
int render_has_hdr(const struct renderer *r);
int render_has_pace(const struct renderer *r);

#endif /* RENDER_H */
