// V4L2 M2M HEVC decode smoke test for meson-vdec
// - feeds one access unit (AU) per OUTPUT buffer (driver matches frames by
//   vififo offset in sess->timestamps)
// - allocates >= DPB (16) capture buffers so amvdec_src_change() just resumes
// - handles V4L2_EVENT_SOURCE_CHANGE (real resolution change)
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <linux/videodev2.h>
#ifdef USE_DRM
#include <stdint.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <drm/drm_fourcc.h>
#endif

/* 一个播放器，两种 Renderer：上屏方式在 render_*.c 里，播放器不认识它们 */
#include "render.h"
#include "aout.h"	/* 内嵌音频输出（-DAOUT_EMBED 编进来，不再单独一个二进制） */
#include "osd.h"	/* 音量/暂停提示条：pctl 写，gl 后端合成到画面 */
#include "pctl.h"	/* 内置控制口 /tmp/play.sock + evdev 遥控（替代 mpvctl/rcinputd） */

/* 内容信号（SEI 里的 maxCLL / mastering display）。这个 TU 出强定义，
 * glout.c 只引用——它的 LUT 也要跟着真实峰值走，不再是写死 1000。 */
#define CSIG_OWNER
#include "spscolor.h"
#include "csig.h"
/* 定义在 SPS 解析之后（那里已经用到这条链路），AU 循环里要提前用 */
static void csig_sei(const unsigned char *nal, size_t n);
static size_t rbsp_un(unsigned char *dst, size_t cap,
		      const unsigned char *src, size_t n);

#define DEV "/dev/video0"
#define NBUF_CAP_MAX 32
#define NBUF_CAP() (getenv("CAPBUF") ? atoi(getenv("CAPBUF")) : 20)
#define NBUF_OUT 32
#define OUT_DEPTH() (getenv("NBUF_OUT") ? atoi(getenv("NBUF_OUT")) : 8)
#define CAP_T V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
#define OUT_T V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE

static volatile sig_atomic_t g_reinit;	/* 定义在下方，xioctl 要先看到 */
/* 驱动 abort 会话（POLLERR）后的连续自愈次数。meson-vdec 偶发
 * "Aborting decoding session"，重开设备就能继续；超过上限才认输退出，
 * 否则交给上层整链重启会闪屏。
 */
static int g_err_rec;

/* ---- 重建请求：两个 bit 装不下"这次要做多狠"（§3.2.2）----
 * 请求位只记录"要不要重建 + 最高档"，真正的动作由事务（tx_run）执行。
 * 规则：**只升级不降级**——一次 STALL 叠一次 seek，按 HARD 走；排队等于
 * 先做一次无用功再毁一次。
 *   档位：L1 REARM（门控重置）/ L2 REBUILD（重开设备）/ L3 HARD（+整块复位）
 *   L0（还没到要动会话）和 L4（放弃，交上层整链重启）不进事务。
 */
enum vev { VEV_NEWSTREAM, VEV_SEEK, VEV_ABORT, VEV_STALL,
	   VEV_SRCCHANGE, VEV_RAP, VEV_SELFTEST };
enum { LVL_L1 = 1, LVL_L2, LVL_L3 };
static volatile sig_atomic_t g_req_lvl;	/* 当前请求档位（0=没有请求） */
static volatile sig_atomic_t g_req_why;	/* 抬高档位的那个原因 */

static void tx_request(int lvl, enum vev why)
{
	if (lvl > g_req_lvl) {		/* 只升级不降级 */
		g_req_lvl = lvl;
		g_req_why = (int)why;
	}
	g_reinit = 1;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	for (;;) {
		r = ioctl(fd, req, arg);
		if (r != -1 || errno != EINTR)
			break;
		/* seek 打断：阻塞型 ioctl（DQBUF/DQEVENT）被 SIGUSR1 打断后
		 * 若继续重试，要等下一帧才返回——实测把 seek 拖满 3s 超时。
		 * 直接返回 EINTR，调用方 break 回主循环处理 g_reinit。
		 */
		if (g_reinit)
			return -1;
	}
	return r;
}

static void die(const char *m)
{
	fprintf(stderr, "FAIL %s: %s\n", m, strerror(errno));
	exit(1);
}

static double now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static double env_d(const char *k, double d)
{
	const char *e = getenv(k);

	return e && *e ? atof(e) : d;
}

static int env_i(const char *k, int d)
{
	const char *e = getenv(k);

	return e && *e ? atoi(e) : d;
}

/* ---- RAP 门控状态机（§1.14）------------------------------------------
 * 重建会话后必须从一个"能自解码"的随机接入点起播，但片源是 open GOP
 * （实测 10 个 RAP 里 9 个是 CRA，见 §1.3），所以判据不能只是布尔量。
 * 三个状态 + 一张超时表，每个转移都由下一帧的类型或计时器触发：
 *
 *   PLAY --(信号/abort/超时)--> WAIT --(可接受 RAP)--> {PLAY | RASL}
 *   RASL --(非 RASL 帧)--> PLAY ;  RASL --(预算超支)--> WAIT --(累计超支)--> 退出
 *
 * 超时（都可 env 覆盖，0=不限）：
 *   RAPSTRICT   3.0s   WAIT 里 strict 模式等 16..20 的预算，超过就降级收 CRA
 *   IRAPWAIT   60.0s   WAIT 的绝对上限，超过判死 → 重建（计入 ERRREC）
 *   RAPRASLMAX    8    RASL 段最多丢几个 AU（x265 的 leading picture 会有 3~4 个）
 *   RAPRASLSEC  1.5s   RASL 段的时长上限
 *   STALLSEC   12.0s   仅 PLAY 态：无新帧判死（门控态本来就不出帧，不适用）
 */
static int g_verbose;		/* VERBOSE：状态机/事件级日志 */
enum { RAP_PLAY, RAP_WAIT, RAP_RASL };
static int g_rap_st = RAP_WAIT;	/* 起播也要过闸门，语义统一 */
static double g_rap_t0;		/* 进入当前状态的时刻 */
static int g_rap_degraded;	/* strict 已降级成"CRA 也收"，每会话一次 */
static int g_rap_rasl_n;	/* 本次 RASL 段已丢的 AU 数 */
static int g_rap_rasl_over;	/* RASL 预算超支次数 */
static int g_rap_drop;		/* 本会话被门控丢掉的 AU 总数（诊断） */
static const char *g_rap_cause = "start";	/* 为什么进 WAIT */

/* RAPMODE=cra（默认）| strict|idr（只认 16..20） */
static int rap_strict(void)
{
	const char *e = getenv("RAPMODE");

	return e && (!strcmp(e, "strict") || !strcmp(e, "idr"));
}

/* 这个 RAP 类型够不够开播。16..20（BLA/IDR 系）一定够；21(CRA) 是
 * open GOP 的头，它后面的 RASL 帧参考 CRA 之前的帧——新会话里没有，
 * 所以收 CRA 的代价是紧接着丢一个 RASL AU。默认收，strict 只在降级后收。
 */
static int rap_accept(int rap)
{
	if (rap >= 16 && rap <= 20)
		return 1;
	if (rap == 21)
		return !rap_strict() || g_rap_degraded;
	return 0;
}

static void rap_enter(int st, const char *why)
{
	static const char *nm[] = { "PLAY", "WAIT", "RASL" };

	if ((g_verbose || getenv("RAPDBG")) && st != g_rap_st)
		printf("RAP %s -> %s (%s) drop=%d\n",
		       nm[g_rap_st], nm[st], why, g_rap_drop);
	g_rap_st = st;
	g_rap_t0 = now_s();
	g_rap_rasl_n = 0;
	if (st == RAP_WAIT) {
		g_rap_cause = why;
		g_rap_drop = 0;
	}
}

/* 门控态的超时/降级。返回 0=没事，1=要重建会话，2=要退出。 */
static int rap_tick(void)
{
	double el, lim;

	if (g_rap_st == RAP_PLAY)
		return 0;
	el = now_s() - g_rap_t0;

	/* strict 降级：只在 WAIT 里、每会话一次。降级后重算预算，
	 * 否则下一个 tick 立刻撞 IRAPWAIT 的旧计时。 */
	if (g_rap_st == RAP_WAIT && rap_strict() && !g_rap_degraded) {
		lim = env_d("RAPSTRICT", 3.0);
		if (lim > 0 && el > lim) {
			g_rap_degraded = 1;
			printf("RAP: strict 等了 %.1fs 没见 16..20（丢 %d AU）→ 降级收 CRA\n",
			       el, g_rap_drop);
			fflush(stdout);
			g_rap_t0 = now_s();
			el = 0;
		}
	}

	/* RASL 段失控："CRA 后面只有 RASL"这个假设不成立（预算给到 8 AU /
	 * 1.5s，正常 leading picture 最多 4 个）。退回 WAIT 重等，不许原地
	 * 死循环——同一个会话里第二次超支就交给上层重建。 */
	if (g_rap_st == RAP_RASL) {
		int n = env_i("RAPRASLMAX", 8);
		double sec = env_d("RAPRASLSEC", 1.5);

		if ((n > 0 && g_rap_rasl_n > n) || (sec > 0 && el > sec)) {
			fflush(stdout);
			if (++g_rap_rasl_over <= 2) {
				printf("RAP: RASL 段超预算（%d AU / %.1fs）→ 退回等 RAP\n",
				       g_rap_rasl_n, el);
				rap_enter(RAP_WAIT, "rasl-over");
				return 0;
			}
			printf("RAP: RASL 超预算已 %d 次，判死\n", g_rap_rasl_over);
			return 2;
		}
		return 0;
	}

	/* WAIT 绝对上限（原 IRAPWAIT 语义）。注意这一路是"流里根本没有合用
	 * 的 RAP"，硬复位治不了，只做软重建，且计入 ERRREC 防死循环。 */
	lim = env_d("IRAPWAIT", 60.0);
	if (lim > 0 && el > lim) {
		printf("RAP: 等 %.0fs 没有可用 RAP（丢 %d AU，%s）→ 重建会话\n",
		       el, g_rap_drop, g_rap_cause);
		return 1;
	}
	return 0;
}

struct capbuf {
	void *mem[VIDEO_MAX_PLANES];
	size_t len[VIDEO_MAX_PLANES];
	int dmabuf[VIDEO_MAX_PLANES];	/* EXPBUF=1 时有效 */
	void *mem2[VIDEO_MAX_PLANES];	/* dmabuf fd 另开的映射（测访问属性用） */
};
static struct capbuf capbuf[NBUF_CAP_MAX];
/* 这一块交给 Renderer 了、还没收到完成反馈：期间绝不能再 QBUF */
static int cap_busy[NBUF_CAP_MAX];
static unsigned cap_count;

static struct { void *mem; size_t len; } outbuf[NBUF_OUT];
static int out_free[NBUF_OUT], out_nfree, n_out;

static unsigned char *stream;
static size_t stream_size;
static struct { size_t off, len; int key; } au[4096];
static int n_au;

static int fd = -1;
/* 会话生命周期三个入口（实现在下发码流解析之后）：一个进程同一时刻
 * 只有一个会话，所有资源的生灭都只经过这三个函数。 */
static int vdec_open(unsigned w, unsigned h);
static int vdec_close(int hard_reset);
static int vdec_resize(unsigned w, unsigned h);
/* seek 时驱动没法在同一个 V4L2 会话里接新码流（meson-vdec 直接
 * "Unrecognized dec_status 0000000F / Aborting decoding session"），
 * 必须重开 /dev/video0。Renderer 那一路不碰，所以屏幕不黑。
 */
static void on_usr1(int sig)
{
	/* 信号里不许调 printf，也调不动 tx_request 的语义分支：直接写请求位。
	 * seek 只要 L2（换新码流），但若此前已经要 L3，就保持 L3。
	 */
	(void)sig;
	if (g_req_lvl < LVL_L2) {
		g_req_lvl = LVL_L2;
		g_req_why = VEV_SEEK;
	}
	g_reinit = 1;
}
static unsigned g_w = 640, g_h = 360;
static int got, resets, g_refeed;
/* 重建会话后必须从随机接入点重新起解：续喂到 GOP 中间，驱动 ref list
 * 是空的，每一帧都 "Couldn't find ref. frame 0"，硬件把 ref 地址当地址 0
 * 读，通常几帧内再次静默挂死（soak 实测重开后 8 帧就死）。
 * 判据在 now_s() 下面的 RAP 门控状态机里（g_rap_st），这里不再单独存布尔量。
 */
/* ---- 重建事务对象（§3.2.2）----
 * 对外可见的状态只有两种：VS_RUN(sess=N) 或 VS_DOWN(fd<0)。事务就是那个
 * "只在这两种状态之间搬东西"的过程，中间态不许被事务外的人看到。
 */
enum tx_phase { TX_IDLE, TX_PREPARE, TX_BODY, TX_COMMIT, TX_ABORT };

struct vdec_tx {
	unsigned id;		/* txid，日志对账用 */
	enum vev why;
	int level;		/* L1/L2/L3 */
	unsigned sess_before;	/* 进入时的 g_sess：commit 之前不许变 */
	int hard;		/* = (level == LVL_L3) */
	double t0, deadline;	/* 预算按时间，不按次数 */
	int tries;		/* 尝试计数（与会话代数分开记） */
	enum tx_phase phase;
};

static struct vdec_tx g_tx = { .phase = TX_IDLE };
static int g_force_reinit_at;	/* 0=未启用 */
static int g_mark_first;	/* reinit 后等待首帧，打一行供脚本同步 */
/* 计时：把"纯解码吞吐"从启动/收尾/写盘里剥出来 */
static int got_queued;
static double t_first_q, t_last_q, t_first_rx, t_last_rx, t_write_acc, t_tm_acc;
/* 分解计时：谁在让流水线变慢——读码流(rd)/喂解码器(feed)/等出帧(dq)/
 * 提交上屏(sub，含 Renderer 内部等 vblank 的配速时间)。
 * 不算清楚这三项，一卡就只能靠猜是"硬解慢"还是"上屏慢"。
 */
static double t_rd_acc, t_dq_acc, t_sub_acc, t_qb_acc, t_poll_acc, t_pump_acc;
/* RDSPLIT：把 t_rd_acc 拆成 compact(memmove)/fill(read 系统调用)/scan(找起始码+SEI 解析) */
static double t_cpt_acc, t_fil_acc; static int n_cpt, n_fil, n_rd;
static double t_hist[4]; static int n_hist[4]; static size_t b_hist[4];
static double t_slp_acc; static int n_slp; static double t_frame0;	/* 播放器自己配速睡觉的时间 */
static double t_loop;	/* 上一轮主循环的时刻，用来识别"进程被冻住过" */

static int nal_type(const unsigned char *p)
{
	return (p[0] >> 1) & 0x3f;
}

/* Split Annex-B stream into access units. */
static void parse_au(void)
{
	size_t i = 0;
	int cur_vcl = 0;
	size_t au_start = (size_t)-1;

	while (i + 4 < stream_size) {
		size_t sc, pl;
		int t, vcl, iru;

		if (!(stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1)) {
			i++;
			continue;
		}
		sc = (i >= 1 && stream[i-1] == 0) ? i - 1 : i;
		pl = i + 3;
		t = nal_type(&stream[pl]);
		vcl = (t <= 31);
		iru = (t == 32 || t == 33 || t == 34 || t == 35 ||
		       t == 39 || t == 41);

		if (au_start == (size_t)-1) {
			au_start = sc;
			cur_vcl = 0;
		} else if ((vcl && cur_vcl) || (iru && cur_vcl)) {
			if (n_au < 4096) {
				au[n_au].off = au_start;
				au[n_au].len = sc - au_start;
				au[n_au].key = 0;
				n_au++;
			}
			au_start = sc;
			cur_vcl = 0;
		}
		if (vcl)
			cur_vcl = 1;
		i = pl + 1;
	}
	if (au_start != (size_t)-1 && n_au < 4096 && stream_size > au_start) {
		au[n_au].off = au_start;
		au[n_au].len = stream_size - au_start;
		au[n_au].key = 0;
		n_au++;
	}
	if (n_au > 0)
		au[0].key = 1;
}

/* ---- §4.3.6 交叉校验：VUI（原始语法）vs V4L2 capture format（驱动翻译过）----
 * 只用来报警，一律以 VUI 为准：stateful vdec 驱动不一定填真值，常见是
 * 只给默认值（REC709/full）。所以这四个数不参与任何计算，只喂 color_report()。
 * -1 = 还没拿到格式（G/S_FMT 之前）。
 */
static int g_v4l_cs = -1, g_v4l_xf = -1, g_v4l_enc = -1, g_v4l_q = -1;

static void v4l_color_read(const struct v4l2_format *f)
{
	g_v4l_cs = (int)f->fmt.pix_mp.colorspace;
	g_v4l_xf = (int)f->fmt.pix_mp.xfer_func;
	g_v4l_enc = (int)f->fmt.pix_mp.ycbcr_enc;
	g_v4l_q = (int)f->fmt.pix_mp.quantization;
}

/* V4L2 枚举 → 码流枚举。对不上（没写/是 DEFAULT）返 0 = 不参与比较。
 * DCI-P3 故意映射到 11 而不是 12：它和 Display P3 白点不同，并过去就成了
 * "一致"，而实际上色域窄一截——宁可让日志说它不一致。 */
static int v4l_prim(int cs)
{
	switch (cs) {
	case V4L2_COLORSPACE_REC709:
	case V4L2_COLORSPACE_SRGB:	return 1;
	case V4L2_COLORSPACE_BT2020:	return 9;
	case V4L2_COLORSPACE_DCI_P3:	return 11;
	default:			return 0;
	}
}

static int v4l_tf(int xf)
{
	switch (xf) {
	case V4L2_XFER_FUNC_709:
	case V4L2_XFER_FUNC_SRGB:	return 1;
	case V4L2_XFER_FUNC_SMPTE2084:	return 16;
	default:			return 0;
	}
}

static int v4l_mat(int enc)
{
	switch (enc) {
	case V4L2_YCBCR_ENC_709:	return 1;
	case V4L2_YCBCR_ENC_BT2020:	return 9;
	default:			return 0;
	}
}

static int v4l_rng(int q)
{
	if (q == V4L2_QUANTIZATION_FULL_RANGE) return 1;
	if (q == V4L2_QUANTIZATION_LIM_RANGE) return 0;
	return -1;
}

static const char *v4l_cs_name(int cs)
{
	switch (cs) {
	case V4L2_COLORSPACE_DEFAULT:		return "default";
	case V4L2_COLORSPACE_SMPTE170M:		return "smpte170m";
	case V4L2_COLORSPACE_SMPTE240M:		return "smpte240m";
	case V4L2_COLORSPACE_REC709:		return "bt709";
	case V4L2_COLORSPACE_BT878:		return "bt878";
	case V4L2_COLORSPACE_470_SYSTEM_M:	return "470m";
	case V4L2_COLORSPACE_470_SYSTEM_BG:	return "470bg";
	case V4L2_COLORSPACE_JPEG:		return "jpeg";
	case V4L2_COLORSPACE_SRGB:		return "srgb";
	case V4L2_COLORSPACE_OPRGB:		return "oprgb";
	case V4L2_COLORSPACE_BT2020:		return "bt2020";
	case V4L2_COLORSPACE_RAW:		return "raw";
#ifdef V4L2_COLORSPACE_DCI_P3
	case V4L2_COLORSPACE_DCI_P3:		return "dcip3";
#endif
	default:				return "其它";
	}
}

static const char *v4l_xf_name(int xf)
{
	switch (xf) {
	case V4L2_XFER_FUNC_DEFAULT:	return "default";
	case V4L2_XFER_FUNC_709:	return "bt709";
	case V4L2_XFER_FUNC_SRGB:	return "srgb";
	case V4L2_XFER_FUNC_OPRGB:	return "oprgb";
	case V4L2_XFER_FUNC_SMPTE240M:	return "smpte240m";
	case V4L2_XFER_FUNC_NONE:	return "none";
	case V4L2_XFER_FUNC_DCI_P3:	return "dcip3";
	case V4L2_XFER_FUNC_SMPTE2084:	return "pq";
	default:			return "其它";
	}
}

static const char *v4l_enc_name(int enc)
{
	switch (enc) {
	case V4L2_YCBCR_ENC_DEFAULT:	return "default";
	case V4L2_YCBCR_ENC_601:	return "601";
	case V4L2_YCBCR_ENC_709:	return "709";
	case V4L2_YCBCR_ENC_XV601:	return "xv601";
	case V4L2_YCBCR_ENC_XV709:	return "xv709";
	case V4L2_YCBCR_ENC_SYCC:	return "sycc";
	case V4L2_YCBCR_ENC_BT2020:	return "bt2020";
	case V4L2_YCBCR_ENC_BT2020_CONST_LUM: return "bt2020cl";
	case V4L2_YCBCR_ENC_SMPTE240M:	return "smpte240m";
	default:			return "其它";
	}
}

static const char *v4l_q_name(int q)
{
	switch (q) {
	case V4L2_QUANTIZATION_DEFAULT:		return "default";
	case V4L2_QUANTIZATION_FULL_RANGE:	return "full";
	case V4L2_QUANTIZATION_LIM_RANGE:	return "limited";
	default:				return "其它";
	}
}

static const char *cmx_mat_name(int m)
{
	switch (m) {
	case 0:  return "GBR";
	case 1:  return "BT.709";
	case 9:  return "BT.2020NCL";
	case 10: return "BT.2020CL";
	case 14: return "ICtCp";
	default: return "其它";
	}
}

/* ---- §4.3.8：一条完整的 COLOR: 行 ----
 * 只在内容信号真的变了才打印（四个 int + 三个 double 全比较）：
 * 单片段全片一条，混剪片在切换点各一条——§4.3.8「切换点前后两帧 COLOR: 行不同、
 * 无闪帧」就是靠这个判的。每帧成本是一次 memcmp，可以无条件每帧调。
 */
static struct ColorMetadata g_crep;
static int g_crep_v4l[4] = { -2, -2, -2, -2 };
static int g_crep_valid;

static void color_report(void)
{
	struct ColorMetadata *c = &g_cm;
	int v[4] = { g_v4l_cs, g_v4l_xf, g_v4l_enc, g_v4l_q };
	const char *src;
	int have, bad = 0;

	if (g_crep_valid && !memcmp(&g_crep, c, sizeof(*c)) &&
	    !memcmp(g_crep_v4l, v, sizeof(v)))
		return;
	g_crep = *c;
	memcpy(g_crep_v4l, v, sizeof(v));
	g_crep_valid = 1;

	have = c->primaries || c->transfer || c->matrix ||
	       c->max_cll > 0.0f || c->mastering_max_luminance > 0.0f;
	if (!have) {
		/* 回退值必须说出来：静默用默认=之前那个查不出来的老问题 */
		printf("COLOR: 无元数据，回退默认（峰值兜底 1000nits，"
		       "HDR 开关按 HDR=，色域按 709 透传）\n");
		return;
	}

	if (getenv("TM_SRC_PEAK"))
		src = "TM_SRC_PEAK";
	else if (c->max_cll > 0.0f)
		src = "SEI144 maxCLL";
	else if (c->mastering_max_luminance > 0.0f)
		src = "SEI137 母版";
	else
		src = "兜底";

	/* 0 一律是"码流没写"，别借用枚举里的 0（matrix=0 是 GBR，
	 * 但这里 0 的含义是"没标"，打印成 GBR 会误导）。 */
	printf("COLOR: VUI=%s/%s/%s/%s %s (p=%d tf=%d mx=%d rng=%d)"
	       " | 峰值=%.0f nits(%s) 母版=%.4g/%.4g nits",
	       c->primaries ? cm_gamut() : "未标",
	       cm_tf_name(),
	       c->matrix ? cmx_mat_name(c->matrix) : "未标",
	       c->range ? "full" : "limited",
	       c->bit_depth ? (c->bit_depth == 10 ? "10bit" :
			       c->bit_depth == 12 ? "12bit" : "8bit") : "bd未标",
	       c->primaries, c->transfer, c->matrix, c->range,
	       csig_peak() > 0.0 ? csig_peak() : 0.0, src,
	       c->mastering_max_luminance, c->mastering_min_luminance);

	if (g_v4l_cs < 0) {
		printf(" | V4L2=未读到（G/S_FMT 之前）\n");
		return;
	}

	/* §4.3.6 交叉校验：只报警，一律用 VUI（原始语法）。
	 * 驱动字段是 DEFAULT/没写时映射成 0 = 不参与比较，不冤枉它。 */
	if (c->primaries && v4l_prim(g_v4l_cs) && v4l_prim(g_v4l_cs) != c->primaries)
		bad++;
	if (c->transfer && v4l_tf(g_v4l_xf) && v4l_tf(g_v4l_xf) != c->transfer)
		bad++;
	if (c->matrix && v4l_mat(g_v4l_enc) && v4l_mat(g_v4l_enc) != c->matrix)
		bad++;
	if (v4l_rng(g_v4l_q) >= 0 && v4l_rng(g_v4l_q) != c->range)
		bad++;

	printf(" | V4L2=%s/%s/%s/%s（%s）\n",
	       v4l_cs_name(g_v4l_cs), v4l_xf_name(g_v4l_xf),
	       v4l_enc_name(g_v4l_enc), v4l_q_name(g_v4l_q),
	       bad ? "不一致，用 VUI" : "一致");
}

/* ---- 会话内的每个步骤都返回 0 / -errno ----
 * 生命周期（vdec_open/close）靠这些返回值决定"重试还是放弃"，
 * 所以这里一律不许 die()，也不许自己吞错误继续往下走。
 */
static int s_fmt_cap(unsigned w, unsigned h)
{
	struct v4l2_format f = {0};

	f.type = CAP_T;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12M;
	f.fmt.pix_mp.num_planes = 2;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = w * h;
	f.fmt.pix_mp.plane_fmt[1].sizeimage = w * h / 2;
	f.fmt.pix_mp.plane_fmt[1].bytesperline = w / 2;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		printf("S_FMT CAP %ux%u 失败: %s\n", w, h, strerror(errno));
		return -errno;
	}
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	v4l_color_read(&f);
	printf("S_FMT CAP : %ux%u pf=%08x sizeimage=%u\n", g_w, g_h,
	       f.fmt.pix_mp.pixelformat, f.fmt.pix_mp.plane_fmt[0].sizeimage);
	return 0;
}

static void g_fmt_cap(void)
{
	struct v4l2_format f = {0};

	f.type = CAP_T;
	if (xioctl(fd, VIDIOC_G_FMT, &f) < 0) return;
	g_w = f.fmt.pix_mp.width;
	g_h = f.fmt.pix_mp.height;
	v4l_color_read(&f);
	/* §4.3.6 要实测的一行：meson vdec 到底填不填这四个字段？
	 * 只打印，不参与计算（真值一律取 VUI）。 */
	printf("G_FMT CAP : %ux%u cs=%s xf=%s enc=%s q=%s\n",
	       g_w, g_h, v4l_cs_name(g_v4l_cs), v4l_xf_name(g_v4l_xf),
	       v4l_enc_name(g_v4l_enc), v4l_q_name(g_v4l_q));
}

static void cap_release(void)
{
	struct v4l2_requestbuffers rb = {0};
	unsigned i;
	int p;

	for (i = 0; i < cap_count; i++)
		for (p = 0; p < VIDEO_MAX_PLANES; p++)
			if (capbuf[i].mem[p]) {
				munmap(capbuf[i].mem[p], capbuf[i].len[p]);
				capbuf[i].mem[p] = NULL;
			}
	cap_count = 0;
	rb.type = CAP_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 0;
	xioctl(fd, VIDIOC_REQBUFS, &rb);
}

/* 导出的 dmabuf fd 是**给别人的引用**（Renderer/fb），队列释放不会
 * 回收它们；每一条 realloc / close 路径都必须自己关，否则每次 seek
 * 漏 2×cap_count 个 fd。
 */
static void close_cap_dmabufs(void)
{
	unsigned i;
	int p;

	for (i = 0; i < cap_count; i++)
		for (p = 0; p < 2; p++)
			if (capbuf[i].dmabuf[p] >= 0) {
				close(capbuf[i].dmabuf[p]);
				capbuf[i].dmabuf[p] = -1;
			}
}

static int cap_setup(void)
{
	struct v4l2_requestbuffers rb = {0};
	unsigned i;
	int p, r = 0;

	unsigned want = NBUF_CAP_MAX;

	cap_release();
	if (getenv("CAPBUF")) {
		int v = atoi(getenv("CAPBUF"));
		if (v > 0) want = v > NBUF_CAP_MAX ? NBUF_CAP_MAX : (unsigned)v;
	} else {
		want = NBUF_CAP();
	}
	rb.type = CAP_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = want;
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) < 0) {
		printf("REQBUFS cap 失败: %s\n", strerror(errno));
		return -errno;
	}
	cap_count = rb.count > want ? want : rb.count;
	printf("cap buffers=%u\n", cap_count);

	for (i = 0; i < cap_count; i++) {
		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[2] = {{0}};

		b.type = CAP_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 2;
		b.m.planes = pl;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
			printf("QUERYBUF cap[%u] 失败: %s\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
		for (p = 0; p < 2; p++) {
			capbuf[i].len[p] = pl[p].length;
			capbuf[i].dmabuf[p] = -1;
			if (getenv("NOMAP")) {		/* 零拷贝：不 mmap，只导出 */
				capbuf[i].mem[p] = NULL;
				continue;
			}
			capbuf[i].mem[p] = mmap(NULL, pl[p].length,
						PROT_READ | PROT_WRITE, MAP_SHARED,
						fd, pl[p].m.mem_offset);
			if (capbuf[i].mem[p] == MAP_FAILED) {
				capbuf[i].mem[p] = NULL;
				printf("mmap cap[%u] 失败: %s\n", i, strerror(errno));
				r = -errno;
				goto fail;
			}
		}
		if (getenv("EXPBUF") || getenv("PLAY")) {
			for (p = 0; p < 2; p++) {
				struct v4l2_exportbuffer eb = {0};

				eb.type = CAP_T;
				eb.index = i;
				eb.plane = p;
				eb.flags = O_CLOEXEC;
				if (xioctl(fd, VIDIOC_EXPBUF, &eb) < 0) {
					printf("EXPBUF cap[%u/%d] 失败: %s\n",
					       i, p, strerror(errno));
					r = -errno;
					goto fail;
				}
				capbuf[i].dmabuf[p] = eb.fd;
			}
			if (i == 0)
				printf("dmabuf: buf0 Y=%d C=%d\n",
				       capbuf[0].dmabuf[0], capbuf[0].dmabuf[1]);
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
			printf("QBUF cap[%u] 失败: %s\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
	}
	return 0;
fail:	/* 半初始化的 CAPTURE 队列不许留给调用方：整组还回去 */
	close_cap_dmabufs();
	cap_release();
	return r;
}

/* OUTPUT 侧映射整组撤掉。幂等：vdec_close 与 out_setup 都调它，
 * 事务 ABORT 之后断言 n_out==0/out_nfree==0 才能成立（§3.2.4）。
 */
static void out_release(void)
{
	int i;

	for (i = 0; i < NBUF_OUT; i++)
		if (outbuf[i].mem) {
			munmap(outbuf[i].mem, outbuf[i].len);
			outbuf[i].mem = NULL;
		}
	out_nfree = 0;		/* 重开设备时会被二次调用，不清就会重复入队 */
	n_out = 0;
}

static int out_setup(void)
{
	struct v4l2_requestbuffers rb = {0};
	int i, r = 0;

	out_release();
	rb.type = OUT_T;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = 0;
	xioctl(fd, VIDIOC_REQBUFS, &rb);

	rb.count = OUT_DEPTH();
	if (xioctl(fd, VIDIOC_REQBUFS, &rb) < 0) {
		printf("REQBUFS out 失败: %s\n", strerror(errno));
		return -errno;
	}
	n_out = rb.count;
	printf("out buffers=%u\n", rb.count);
	for (i = 0; i < (int)rb.count; i++) {
		struct v4l2_buffer b = {0};
		struct v4l2_plane pl[1] = {{0}};

		b.type = OUT_T;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 1;
		b.m.planes = pl;
		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
			printf("QUERYBUF out[%d] 失败: %s\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
		outbuf[i].len = pl[0].length;
		outbuf[i].mem = mmap(NULL, outbuf[i].len, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, pl[0].m.mem_offset);
		if (outbuf[i].mem == MAP_FAILED) {
			outbuf[i].mem = NULL;
			printf("mmap out[%d] 失败: %s\n", i, strerror(errno));
			r = -errno;
			goto fail;
		}
		out_free[out_nfree++] = i;
	}
	return 0;
fail:
	{	/* 映射过的 OUTPUT 缓冲就地撤掉，别留半套 */
		int k;

		for (k = 0; k < NBUF_OUT; k++)
			if (outbuf[k].mem) {
				munmap(outbuf[k].mem, outbuf[k].len);
				outbuf[k].mem = NULL;
			}
	}
	out_nfree = 0;
	return r;
}

static int start_stream(void)
{
	int t = CAP_T;

	if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) {
		printf("STREAMON cap 失败: %s\n", strerror(errno));
		return -errno;
	}
	t = OUT_T;
	if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) {
		/* 一半在跑等于没跑：CAPTURE 必须先停下再交还失败 */
		printf("STREAMON out 失败: %s\n", strerror(errno));
		t = CAP_T;
		xioctl(fd, VIDIOC_STREAMOFF, &t);
		return -errno;
	}
	return 0;
}

static void stop_stream(void)
{
	int t = OUT_T;

	xioctl(fd, VIDIOC_STREAMOFF, &t);
	t = CAP_T;
	xioctl(fd, VIDIOC_STREAMOFF, &t);
}

/* 喂一个 AU（流式：数据来自缓冲区，调用方保证本函数返回前有效） */
static unsigned g_au_seq;

static void qbuf_au(const unsigned char *data, size_t len, int key)
{
	int oi = out_free[--out_nfree];
	struct v4l2_buffer b = {0};
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
	b.bytesused = len;
	b.field = V4L2_FIELD_NONE;
	b.flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	if (key)
		b.flags |= V4L2_BUF_FLAG_KEYFRAME;
	b.timestamp.tv_sec = g_au_seq / 25;
	b.timestamp.tv_usec = (g_au_seq % 25) * 40000;
	g_au_seq++;
	if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
		fprintf(stderr, "QBUF out: idx=%d n_out=%d nfree=%d len=%zu/%zu\n",
			oi, n_out, out_nfree, len, outbuf[oi].len);
		die("QBUF out");
	}
	if (!got_queued)
		t_first_q = now_s();
	t_last_q = now_s();
	got_queued++;
}

static int eos_seen;
static int handle_event(void)
{
	struct v4l2_event ev;

	memset(&ev, 0, sizeof(ev));
	if (xioctl(fd, VIDIOC_DQEVENT, &ev) < 0)
		return 0;
	if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
		unsigned ow = g_w, oh = g_h, nw, nh;

		g_fmt_cap();
		nw = g_w;
		nh = g_h;
		printf("EVENT SOURCE_CHANGE %ux%u (was %ux%u, frames=%d)\n",
		       nw, nh, ow, oh, got);
		if (nw == ow && nh == oh) {
			printf("(same resolution, driver resumed)\n");
			return 0;   /* amvdec_src_change() already resumed */
		}
		if (++resets > 3) {
			printf("too many resets\n");
			exit(1);
		}
		/* 同一个会话内换分辨率：缓冲整组重建（定义在下方） */
		if (vdec_resize(nw, nh) < 0) {
			/* 就地改不动说明会话已经不好使了，交给主循环整会话重建 */
			printf("SOURCE_CHANGE: 就地上分辨率失败，转整会话重建\n");
			tx_request(LVL_L2, VEV_SRCCHANGE);
			return 0;
		}
		g_refeed = 1;     /* main() 从 AU 0 重喂 */
		return 0;
	}
	if (ev.type == V4L2_EVENT_EOS) {
		if (g_verbose) printf("EVENT EOS\n");
		eos_seen = 1;
	}
	return 0;
}

/* VDEC 固件单帧 hang 之后，STREAMOFF/ON 这一层软复位救不回来（实测重开后
 * seq_o 停在 8、每 5s 中断只 +0/+1）。真正能把 HEVC 子块拉回"刚 probe"状态
 * 的是驱动导出的 hard_reset 参数：隔离 + MEM_PD + 掉电 + 重新上电。
 * 只会在会话已经 close 掉之后写（驱动 cur_sess 为空才接受，否则 -EBUSY，
 * 因为驱动收尾是 workqueue 异步做的，所以带重试）。
 */
static int vdec_hard_reset(void)
{
	const char *p = "/sys/module/meson_vdec/parameters/hard_reset";
	const char *e = getenv("HARDRESET");
	int f, i, n = 150;	/* 150 × 20ms = 3s 等驱动 workqueue 收尾 */

	if (e && atoi(e) == 0) {
		printf("HARDRESET: 被 HARDRESET=0 关掉（固件 hang 只能靠上层重启）\n");
		return 0;
	}
	for (i = 0; i < n; i++) {
		ssize_t w;

		f = open(p, O_WRONLY);
		if (f >= 0) {
			w = write(f, "1", 1);
			close(f);
			if (w == 1) {
				printf("HARDRESET: VDEC 整块掉电复位 OK（第 %d 次尝试）\n", i + 1);
				fflush(stdout);
				return 0;
			}
		}
		usleep(20000);
	}
	/* 旧版这里只打一行就往下走，等于"明知硬件没复位还照旧开流"——
	 * 后面每一帧都会失败，自愈循环一轮一轮刷屏。必须显式失败。
	 */
	printf("HARDRESET: 失败（%s 不可写或驱动 %dms 内未收尾）\n", p, n * 20);
	fflush(stdout);
	return -1;
}

static unsigned capw, caph;
static FILE *out;

/* plane0 常按 64 行对齐（如 720->768），必须按 stride 逐行取，不能整块 blob 写 */
static void write_nv12(unsigned idx, unsigned w, unsigned h)
{
	unsigned ph = (h + 63) & ~63u, stride = w, y;
	unsigned char *p0 = capbuf[idx].mem[0], *p1 = capbuf[idx].mem[1];

	if (capbuf[idx].len[0] % ph == 0 && capbuf[idx].len[0] / ph >= w)
		stride = capbuf[idx].len[0] / ph;
	for (y = 0; y < h; y++)
		fwrite(p0 + (size_t)y * stride, 1, w, out);
	for (y = 0; y < h / 2; y++)
		fwrite(p1 + (size_t)y * stride, 1, w, out);
}

static void dump_frame(unsigned idx, struct v4l2_plane *pl)
{
	static unsigned char pat[64];
	unsigned i, n = capbuf[idx].len[0];
	unsigned char *y = capbuf[idx].mem[0];

	if (got == 0) {
		memcpy(pat, y, 64);
		printf("first pixels:");
		for (i = 0; i < 16; i++)
			printf(" %02x", y[i]);
		printf("\n");
	} else if (g_verbose) {
		int same = !memcmp(pat, y, 64);
		printf("  plane0 same-as-first=%d\n", same);
	}
	if (g_verbose) {
		unsigned long sum = 0;

		for (i = 0; i < n; i += 97)
			sum += y[i];
		printf("  bytes=%u/%u ysum=%lu\n", pl[0].bytesused,
		       pl[1].bytesused, sum);
	}
}

/* ---- minimal HEVC SPS parser: get coded width/height before REQBUFS ----
 * Needed because the meson-vdec driver sizes CAPTURE buffers from the
 * format set at S_FMT time; with the wrong size no frame ever completes,
 * and since vb2_fop_poll() does not wake on V4L2 events the
 * SOURCE_CHANGE event would only be noticed on the next POLLIN -> deadlock.
 */
struct bitrd { const unsigned char *p; size_t bits, pos; };

static unsigned br_bits(struct bitrd *b, int n)
{
	unsigned v = 0;

	while (n-- > 0) {
		size_t byte = b->pos >> 3;

		if (byte >= b->bits)
			return 0;
		v = (v << 1) | ((b->p[byte] >> (7 - (b->pos & 7))) & 1);
		b->pos++;
	}
	return v;
}

static unsigned br_ue(struct bitrd *b)
{
	int lz = 0;

	while (br_bits(b, 1) == 0) {
		if (++lz > 31)
			return 0;
	}
	if (!lz)
		return 0;
	return ((1u << lz) - 1) + br_bits(b, lz);
}

/* 解析一个 SPS RBSP：ptl 为 profile_tier_level 的位数（多数编码器 88，
 * 但见过写 96 的），返回 1 表示字段自洽。
 */
static int sps_try(const unsigned char *d, size_t nbytes, int ptl,
		   unsigned *ow, unsigned *oh)
{
	struct bitrd b = { d, nbytes * 8, 8 + (size_t)ptl };
	unsigned sid, chroma, w, h, conf, bdl, bdc, poc;

	sid = br_ue(&b);
	chroma = br_ue(&b);
	if (chroma > 3)
		return 0;
	if (chroma == 3)
		br_bits(&b, 1);
	w = br_ue(&b);
	h = br_ue(&b);
	conf = br_bits(&b, 1);

	/* conformance window（色度单位）紧跟 conf flag，顺序不能挪 */
	{
		unsigned l = 0, r = 0, t = 0, bo = 0;

		if (conf) {
			l = br_ue(&b);
			r = br_ue(&b);
			t = br_ue(&b);
			bo = br_ue(&b);
		}
		bdl = br_ue(&b);
		bdc = br_ue(&b);
		poc = br_ue(&b);
		if (bdl > 8 || bdc > 8 || poc > 12)
			return 0;
		if (getenv("SPSDBG"))
			printf("SPSDBG raw id=%u chroma=%u %ux%u conf=%u crop=%u,%u,%u,%u bd_luma=%u bd_chroma=%u poc=%u\n",
			       sid, chroma, w, h, conf, l, r, t, bo, bdl, bdc, poc);
		if (conf) {
			unsigned sub = (chroma == 1 || chroma == 2) ? 2 : 1;

			if (l + r >= w || t + bo >= h)
				return 0;
			w -= (l + r) * sub;
			h -= (t + bo) * sub;
		}
	}
	if (w < 64 || h < 64 || w > 8192 || h > 8192)
		return 0;
	if ((w & 7) || (h & 7))
		return 0;
	*ow = w;
	*oh = h;
	return 1;
}

/* ------------------------------------------------------------------
 * 流式 AU 读取：不整片读入内存，支持 stdin/管道，可播任意长片源。
 * 只保留"当前 AU + 未扫完的尾巴"，窗口因此很小（几 MB）。
 * ------------------------------------------------------------------ */
static int s_fd = -1;		/* 码流 fd（文件或 STDIN） */
#ifndef CHUNK_RD
#define CHUNK_RD (64u << 10)
#endif	/* 单次 read 上限：见 s_fill() 注释 */
static unsigned char *s_buf;
static size_t s_cap, s_len;	/* 缓冲区容量 / 有效字节 */
static size_t s_pos;		/* 扫描位置 */
static size_t s_au_start;	/* 当前 AU 起点 */
static int s_au_open, s_cur_vcl, s_eof, s_release;
/* 本 AU 的随机接入点 NAL 类型：0=无，16..21=BLA/IDR/CRA。
 * 存实际类型而不是布尔量：CRA(21) 在空 DPB 上不可恢复（open GOP 的
 * RASL 参考 CRA 之前的帧），必须能和 IDR/BLA 区分开。见 design §1.10。
 */
static int s_au_rap;
/* 本 AU 含 RASL(8/9)：只在 CRA 之后出现，新会话里不可解码，需丢弃。 */
static int s_au_rasl;
/* 上一个交出的 AU 的 RAP 信息（s_au_rap/s_au_rasl 在 return 前清零，
 * 调用侧要判策略只能读这两个）。 */
static int s_au_last_rap, s_au_last_rasl;
/* 本 AU 里第一个 prefix SEI 的偏移（0 = 没有）。SEI 解析放在 AU 收口处做：
 * 只有那时才知道这条 NAL 的结束位置，不用为了找 NAL 尾巴再扫一遍码流。 */
static size_t s_au_sei;		/* 已废弃，留着不动数据布局 */
static size_t s_sei_pl;		/* 当前 SEI NAL 起点；0=没有待解析的 SEI */
static size_t s_sps_pl;		/* 当前 SPS NAL 起点；0=没有待解析的 SPS */
static size_t g_stream_bytes;	/* 已消费字节，用于码率统计 */
static int g_stream_au;		/* 已产出 AU 数 */

static void s_fill(size_t want)
{
	if (s_eof)
		return;
	if (s_len + want > s_cap) {
		size_t nc = s_cap ? s_cap : (4u << 20);

		while (nc < s_len + want)
			nc *= 2;
		{
			unsigned char *nb = realloc(s_buf, nc);

			if (!nb)
				die("realloc stream");
			s_buf = nb;
			s_cap = nc;
		}
	}
	for (;;) {
		double tf = now_s();
		/* 一次最多读 CHUNK 字节，别把整块缓冲区灌满。
		 * 之前的 read(.., s_cap - s_len) 在 4MB 缓冲下会一口气读 4MB，
		 * 于是 s_len 一直是几 MB，而 s_compact() 每交出一个 AU 就要
		 * memmove(s_len - s_au_start) —— 实测 1080p 每 AU 固定 2.44ms，
		 * 占满整个 t_rd_acc（300 AU 共 0.73s，AU 大小 13KB/48KB 都一样贵，
		 * 因为搬的是缓存里的尾巴不是 AU）。钳成小块后 memmove 只剩
		 * 「当前 AU + 一个 chunk」，大 AU 由 for(;;) 多读几次补齐。
		 * 管道上 read() 本来就只返回已有字节，不会因此多等。
		 */
		size_t room = s_cap - s_len;

		if (room > (CHUNK_RD))
			room = (CHUNK_RD);
		ssize_t r = read(s_fd, s_buf + s_len, room);

		t_fil_acc += now_s() - tf;
		n_fil++;
		if (r < 0) {
			if (errno == EINTR) {
				/* 阻塞在 read() 等 ffmpeg 供流时收到 seek 信号：
				 * 别重新阻塞回去，交给主循环重建会话。
				 */
				if (g_reinit)
					return;
				continue;
			}
			die("read stream");
		}
		if (r == 0) {
			s_eof = 1;
			return;
		}
		s_len += r;
		return;
	}
}

/* 上一轮交出的 AU 已被调用方 memcpy 走，这里可以丢弃前缀 */
static void s_compact(void)
{
	if (!s_release)
		return;
	if (s_au_start) {
		double tc = now_s();

		memmove(s_buf, s_buf + s_au_start, s_len - s_au_start);
		t_cpt_acc += now_s() - tc;
		n_cpt++;
		s_len -= s_au_start;
		s_pos -= s_au_start;
		s_au_start = 0;
	}
	s_release = 0;
}

/* 可恢复随机接入点：空 DPB（新会话）上能直接起解。
 * CRA(21) 例外——open GOP 的 RASL(8/9) 参考 CRA 之前的帧，那些帧在新会话里
 * 不存在，续喂会让驱动 "Couldn't find ref. frame" 并在几帧内静默挂死。
 * 所以 CRA 是否算"能起播"由调用侧的策略（RAPMODE）决定，不在这里拍。
 * 见 design_player.md §1.10。
 */
static int rap_recoverable(int t)
{
	return t >= 16 && t <= 20;
}

/* 内容信号是否变了：只比四个"决定怎么算颜色"的 VUI 字段。
 * 变了一位就算新片段——分母、矩阵、色域全不一样，旧片段的 SEI 峰值
 * 也必然失效（混剪片 SDR→HDR→SDR 时，不重置就会把 HDR 段的 1000nits
 * 带进后面那段 SDR，日志里表现为峰值来源还写着 SEI144）。 */
static int csig_same(const struct ColorMetadata *a, const struct ColorMetadata *b)
{
	return a->primaries == b->primaries && a->transfer == b->transfer &&
	       a->matrix == b->matrix && a->range == b->range;
}

/* 把一条 SPS NAL（含 2 字节头）的 VUI 应用到 g_cm。
 * 播放器起播前那条路径走 sps_size()，但那只是"窗口里第一条 SPS"；
 * 混剪片中途换段时 SPS 会重发，必须每 AU 都看，否则第二段的 VUI
 * 永远读不到——这正是之前"解析侧就绪但实际不生效"的原因。 */
static int sps_color_apply(const unsigned char *nal, size_t n)
{
	static unsigned char rb[8192];
	static const int ptls[] = { 88, 96, 92, 100, 104 };
	struct ColorMetadata cm;
	size_t len;
	unsigned k;

	if (n < 12 || n > (size_t)1 << 20)
		return 0;
	len = rbsp_un(rb, sizeof(rb), nal + 2, n - 2);
	memcpy(&cm, &g_cm, sizeof(cm));
	for (k = 0; k < sizeof(ptls) / sizeof(ptls[0]); k++) {
		if (!sps_color_parse(rb, len, ptls[k], &cm))
			continue;
		if (!csig_same(&cm, &g_cm)) {
			cm.max_cll = 0.0f;
			cm.max_fall = 0.0f;
			cm.mastering_max_luminance = 0.0f;
			cm.mastering_min_luminance = 0.0f;
			if (getenv("SPSDBG"))
				printf("COLOR: 内容信号变化 -> 旧 SEI 峰值作废\n");
		}
		memcpy(&g_cm, &cm, sizeof(cm));
		return 1;
	}
	return 0;
}

/* 取出下一个 AU：1=有，0=结束。*out 在下一次调用前有效。 */
static int stream_next_au(const unsigned char **out, size_t *outlen)
{
	s_compact();
	for (;;) {
		while (s_pos + 4 <= s_len) {
			unsigned char *p = s_buf + s_pos;
			size_t sc, pl;
			int t, vcl, iru;

			if (!(p[0] == 0 && p[1] == 0 && p[2] == 1)) {
				s_pos++;
				continue;
			}
			sc = (s_pos >= 1 && s_buf[s_pos - 1] == 0) ? s_pos - 1 : s_pos;
			pl = s_pos + 3;
			t = nal_type(&s_buf[pl]);
			/* 一个 AU 里可以有多个 SEI NAL（x265 就是 144 一个、137 一个），
			 * 所以必须逐个解析：只记第一个会丢掉母版亮度（SEI 137）。
			 * 范围也必须正好是这个 NAL（到下一个起始码为止）——之前给的是
			 * "到 AU 结束"，把后面的 VCL 也当 SEI 扫，读出一堆假 payload。 */
			if (s_sei_pl) {
				csig_sei(s_buf + s_sei_pl, sc - s_sei_pl);
				s_sei_pl = 0;
			}
			if (t == 39)
				s_sei_pl = pl;
			if (s_sps_pl) {	/* 同理：VUI 也要逐段解析 */
				sps_color_apply(s_buf + s_sps_pl, sc - s_sps_pl);
				s_sps_pl = 0;
			}
			if (t == 33)
				s_sps_pl = pl;
			vcl = (t <= 31);
			iru = (t == 32 || t == 33 || t == 34 || t == 35 ||
			       t == 39 || t == 41);
			/* 注意顺序：SEI 属于"将要开始的 AU"，不能在这里记。
			 * 之前就在这里赋值，AU 收口时拿到的是下一个 AU 的 SEI 偏移，
			 * sc - s_au_sei 变成巨大的 size_t，csig_sei() 就把整段压缩数据
			 * 当 SEI 扫，随机命中 type 137/144，读出 280149 nits 这种值。 */
			if (!s_au_open) {
				s_au_start = sc;
				s_au_open = 1;
				s_cur_vcl = 0;
				s_au_rap = 0;
				s_au_rasl = 0;
				s_au_sei = 0;
			} else if ((vcl && s_cur_vcl) || (iru && s_cur_vcl)) {
				size_t len = sc - s_au_start;

				if (!len) {	/* 空 AU，跳过 */
					s_pos = sc;
					continue;
				}
				*out = s_buf + s_au_start;
				*outlen = len;
				g_stream_bytes += len;
				g_stream_au++;
				s_pos = sc;
				s_au_start = sc;
				s_cur_vcl = 0;
				s_au_sei = (t == 39) ? pl : 0;	/* 归新 AU */
				s_release = 1;
				{
					int k = s_au_rap;
					int rasl = s_au_rasl;

					s_au_last_rap = k;
					s_au_last_rasl = rasl;
					s_au_rap = 0;
					s_au_rasl = 0;
					if (k && getenv("RAPDBG"))
						printf("RAPDBG au=%d rap=%d rec=%d rasl=%d\n",
						       g_stream_au, k,
						       rap_recoverable(k), rasl);
					return k ? 2 : 1;	/* 2 = 关键帧 */
				}
			}
			if (vcl) {
				s_cur_vcl = 1;
				if (t >= 16 && t <= 21)
					s_au_rap = t;
				if (t == 8 || t == 9)	/* RASL：CRA 之后、不可解码 */
					s_au_rasl = 1;
			}
			s_pos = pl + 1;
		}
		if (s_eof) {
			if (s_au_open && s_len > s_au_start) {
				size_t len = s_len - s_au_start;
				int k = s_au_rap;
				int rasl = s_au_rasl;

				if (s_sei_pl) {
					csig_sei(s_buf + s_sei_pl, s_len - s_sei_pl);
					s_sei_pl = 0;
				}
				if (s_sps_pl) {
					sps_color_apply(s_buf + s_sps_pl,
							s_len - s_sps_pl);
					s_sps_pl = 0;
				}
				*out = s_buf + s_au_start;
				*outlen = len;
				g_stream_bytes += len;
				g_stream_au++;
				s_au_start = s_len;
				s_au_open = 0;
				s_au_last_rap = k;
				s_au_last_rasl = rasl;
				s_au_rap = 0;
				s_au_rasl = 0;
				s_release = 1;
				if (k && getenv("RAPDBG"))
					printf("RAPDBG au=%d rap=%d rec=%d rasl=%d (eof)\n",
					       g_stream_au, k,
					       rap_recoverable(k), rasl);
				return k ? 2 : 1;
			}
			return 0;
		}
		s_fill(1u << 20);
		if (g_reinit)
			return -1;	/* 被打断：既不是有 AU 也不是 EOS */
	}
}

static int sps_size(unsigned *ow, unsigned *oh)
{
	static unsigned char buf[8192];
	size_t i = 0;

	while (i + 6 < stream_size) {
		size_t pl;

		if (!(stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1)) {
			i++;
			continue;
		}
		pl = i + 3;                    /* NAL header */
		if (nal_type(&stream[pl]) == 33) {
			size_t n = 0, j = pl + 2;  /* skip 2-byte NAL header */
			static const int ptls[] = { 88, 96, 92, 100, 104 };
			unsigned k;

			/* 去防竞争字节，遇到下一个起始码停止 */
			for (; j < stream_size && n < sizeof(buf); j++) {
				if (n >= 2 && buf[n-1] == 0 && buf[n-2] == 0 &&
				    stream[j] == 3) {
					if (j + 1 >= stream_size ||
					    stream[j+1] > 3)
						break;
					continue;
				}
				if (j + 2 < stream_size && stream[j] == 0 &&
				    stream[j+1] == 0 && stream[j+2] == 1)
					break;
				buf[n++] = stream[j];
			}
			if (getenv("SPSDBG"))
				printf("SPSDBG nal=%zu n=%zu\n", i, n);
			if (n < 12)
				return 0;
			for (k = 0; k < sizeof(ptls) / sizeof(ptls[0]); k++) {
				if (sps_try(buf, n, ptls[k], ow, oh)) {
					struct ColorMetadata cm;

					/* 宽高定了，顺手把 VUI 的颜色描述补上：
					 * 这里失败不算错（很多码流没写 VUI），
					 * 所以只覆盖成功解析出来的部分 */
					memcpy(&cm, &g_cm, sizeof(cm));
					if (sps_color_parse(buf, n, ptls[k], &cm))
						memcpy(&g_cm, &cm, sizeof(cm));
					if (getenv("SPSDBG"))
						printf("SPSDBG ptl=%d -> %ux%u 色域=%s(%d) tf=%d mx=%d rng=%d bd=%d\n",
						       ptls[k], *ow, *oh, cm_gamut(),
						       g_cm.primaries, g_cm.transfer,
						       g_cm.matrix, g_cm.range,
						       g_cm.bit_depth);
					return 1;
				}
			}
			return 0;
		}
		i = pl + 2;
	}
	return 0;
}

/* ---- 内容信号：HEVC prefix SEI（NAL 39）→ 真实内容峰值 ----
 * 只认两条 payload：
 *   144 content_light_level_info   maxCLL / maxFALL（nits，就是内容峰值）
 *   137 mastering_display_colour_volume  母版监视器峰值/最小亮度（×0.0001）
 * 其余 payload 一律跳过。不做完整 SEI 库，只取色调映射需要的两个数。
 */
static size_t rbsp_un(unsigned char *dst, size_t cap,
		      const unsigned char *src, size_t n)
{
	size_t i, o = 0;

	for (i = 0; i < n && o < cap; i++) {
		/* 去掉防竞争字节 0x03（00 00 03 → 00 00） */
		if (o >= 2 && dst[o - 1] == 0 && dst[o - 2] == 0 && src[i] == 3)
			continue;
		dst[o++] = src[i];
	}
	return o;
}

/* nal 指向 2 字节 NAL 头，n 是整个 NAL 的字节数（含头） */
static void csig_sei(const unsigned char *nal, size_t n)
{
	static unsigned char rb[2048];
	size_t i = 0, len;	/* rb 已经是 nal+2 之后的 RBSP，别再跳 2 字节头 */
	int found = 0;

	/* 一个 SEI NAL 不可能超过 1MB。超了就是调用侧的偏移错了，
	 * 宁可不解析也不能把压缩数据当 SEI 扫（历史事故：280149 nits）。 */
	if (n < 4 || n > (size_t)1 << 20)
		return;
	len = rbsp_un(rb, sizeof(rb), nal + 2, n - 2);
	while (i + 2 <= len) {
		unsigned type = 0, size = 0;

		while (i < len && rb[i] == 0xff) { type += 255; i++; }
		if (i >= len) break;
		type += rb[i++];
		while (i < len && rb[i] == 0xff) { size += 255; i++; }
		if (i >= len) break;
		size += rb[i++];
		if (getenv("SEIDBG2"))
			printf("SEIDBG2 payload type=%u size=%u i=%zu len=%zu\n",
			       type, size, i, len);
		if (i + size > len) break;	/* 截断的 SEI，别越界读 */
		if (type == 137 && size >= 24) {
			const unsigned char *p = rb + i;
			double prim[3][2], wp[2];
			int c, id;

			/* 前 16 字节：3 组原色 + 白点，单位 0.00002。
			 * 只留"属于哪个色域"的结论（ColorMetadata.primaries 是枚举），
			 * 坐标本身不存：存了也没人按坐标算，反而多一份会过期的状态。 */
			for (c = 0; c < 3; c++) {
				prim[c][0] = (((unsigned)p[c * 4 + 0] << 8) | p[c * 4 + 1]) * 0.00002;
				prim[c][1] = (((unsigned)p[c * 4 + 2] << 8) | p[c * 4 + 3]) * 0.00002;
			}
			wp[0] = (((unsigned)p[12] << 8) | p[13]) * 0.00002;
			wp[1] = (((unsigned)p[14] << 8) | p[15]) * 0.00002;
			/* VUI 没写 colour_primaries 才用 SEI 的母版原色兜底：
			 * 两者理论上一致，冲突时 VUI 更权威（SEI 描述的是母版监视器） */
			id = cm_prim_from_sei(prim, wp);
			if (!g_cm.primaries && id)
				g_cm.primaries = id;

			g_cm.mastering_max_luminance = (((unsigned)p[16] << 24) | ((unsigned)p[17] << 16) |
							((unsigned)p[18] << 8) | p[19]) * 0.0001f;
			g_cm.mastering_min_luminance = (((unsigned)p[20] << 24) | ((unsigned)p[21] << 16) |
							((unsigned)p[22] << 8) | p[23]) * 0.0001f;
		} else if (type == 144 && size >= 4) {
			g_cm.max_cll = (float)(((unsigned)rb[i] << 8) | rb[i + 1]);
			g_cm.max_fall = (float)(((unsigned)rb[i + 2] << 8) | rb[i + 3]);
		}
		found = 1;
		i += size;
	}
	if (found && getenv("SEIDBG"))
		printf("SEIDBG cll=%.0f/%.0f md=%.0f/%.0f 色域=%s(%d) tf=%d mx=%d rng=%d bd=%d\n",
		       g_cm.max_cll, g_cm.max_fall,
		       g_cm.mastering_max_luminance, g_cm.mastering_min_luminance,
		       cm_gamut(), g_cm.primaries, g_cm.transfer, g_cm.matrix,
		       g_cm.range, g_cm.bit_depth);
	if (found)
		g_csig_seen++;
}

#ifdef USE_DRM
/* 零拷贝验证：vdec 导出的 NV12M 两块 dmabuf 能否被 card0 直接当成 NV12 fb */
static void drm_import_test(int yfd, int cfd, unsigned w, unsigned h)
{
	const char *dev = getenv("DRMDEV") ? getenv("DRMDEV") : "/dev/dri/card0";
	struct drm_mode_fb_cmd2 fb = {0};
	struct drm_prime_handle ph;
	int dfd = open(dev, O_RDWR | O_CLOEXEC);
	uint32_t handles[2];

	if (dfd < 0) {
		printf("DRM: open %s failed: %s\n", dev, strerror(errno));
		return;
	}

	ph.fd = yfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("DRM: FD_TO_HANDLE(Y) failed: %s\n", strerror(errno));
		goto out;
	}
	handles[0] = ph.handle;

	ph.fd = cfd; ph.handle = 0; ph.flags = 0;
	if (ioctl(dfd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) < 0) {
		printf("DRM: FD_TO_HANDLE(C) failed: %s\n", strerror(errno));
		goto out;
	}
	handles[1] = ph.handle;
	printf("DRM: handles Y=%u C=%u\n", handles[0], handles[1]);

	fb.width = w;
	fb.height = h;
	fb.pixel_format = DRM_FORMAT_NV12;
	fb.handles[0] = handles[0];
	fb.handles[1] = handles[1];
	fb.pitches[0] = w;
	fb.pitches[1] = w;
	fb.offsets[0] = 0;
	fb.offsets[1] = 0;
	if (ioctl(dfd, DRM_IOCTL_MODE_ADDFB2, &fb) < 0)
		printf("DRM: ADDFB2 NV12 %ux%u FAILED: %s\n", w, h, strerror(errno));
	else
		printf("DRM: ADDFB2 NV12 %ux%u OK fb_id=%u\n", w, h, fb.fb_id);
out:
	close(dfd);
}

/* ---------- HDR10 → SDR tone mapping（软件，就地改写 NV12） ----------
 * 输入：vdec 出来的是 8bit NV12，但内容是 PQ(SMPTE2084) + BT.2020，
 *       即"码值是 HDR 的，容器是 8bit 的" —— 直接上屏就是灰蒙蒙低对比。
 * 做法：Y 走一张 256 项 LUT（PQ 码 → 线性光 → 压缩 → BT.709 OETF 编码），
 *       Cb/Cr 按同点 Y 的码值增益等比缩放（保持色相/饱和度）再乘色域压缩系数。
 * 全部在已 mmap 的采集缓冲上原地做，不解码后拷内存、不加中间帧。
 *
 * 环境变量：
 *   TM=0|1|off|on|clip|curve|reinhard|hable   （默认：HDR=1 时开，curve 曲线）
 *   TM_SRC_PEAK=<nits> 覆盖内容峰值；不给就从码流 SEI 的 maxCLL 读（见 csig.h），
 *                      都没有才用 1000 兜底并在日志里标"默认"
 *   TM_TARGET=200      SDR 屏峰值/参考白 nits（面板亮就把这个调大）
 *   TM_SAT=0.85        BT.2020 → BT.709 色域压缩系数（1=不压，偏艳）
 *   TM_KNEE=0.7        拐点位置（0..1，越小越早压缩、越"电影感"）
 *   TMDIAG=1           打印映射前后 Y 的 min/max/mean
 */
#define TM_CLIP 0
#define TM_CURVE 1
#define TM_REINHARD 2
#define TM_HABLE 3

struct tmctx {
	int on, curve, diag, built, full, noop, time_it, gmode;
	int dither;		/* TMDITHER=0 关：A/B 比抖动效果用 */
	int src_env;		/* TM_SRC_PEAK 显式给了：用户说了算，不再自动跟 SEI */
	int src_auto;		/* 峰值是 SEI/兜底来的，SEI 到了要自己重建 LUT */
	int sat_env;		/* TM_SAT 显式给了：用户说了算，不跟色域走 */
	int pri;		/* 编表时用的 colour_primaries，变了要重算 sat 并重建 */
	int tf;			/* 编表时用的 transfer（HG_TF_*），变了要重建 */
	int tf_env;		/* TM= 显式给了：用户指定，不再按 VUI 自动开关 */
	int mat;		/* 色度走 2020→709 3x3（2020/未标源），0=标量增益 */
	double src_peak, target, sat, knee;
	unsigned char lut[256];		/* Y 单通道码值映射 */
	unsigned short gain[256];	/* Q10 增益：1024 = 1.0，给 Cb/Cr 用 */
	unsigned calls;
	double t_acc;
};
static struct tmctx tm;

/* 色彩数学统一在 hdrcolor.inc（glout.c 和 hdr-selftest.c 吃同一份文本） */
#include "hdrcolor.inc"

static void tm_to_hc(const struct tmctx *t, struct hdrcolor *c)
{
	c->on = t->on;
	c->curve = t->curve;		/* TM_* 与 HC_* 数值一致 */
	c->src_peak = t->src_peak;
	c->target = t->target;
	c->sat = t->sat;
	c->knee = t->knee;
	c->full = t->full;
	c->gain_mode = t->gmode;
	c->transfer = t->tf;
}

/* 把当前 tm 参数编成 256 项表并打一行日志（重建也走这条） */
static void tm_compile(void)
{
	struct hdrcolor c;

	tm_to_hc(&tm, &c);
	hc_build(&c, tm.lut, tm.gain);
	tm.built = 1;
	printf("TM: on tf=%s curve=%s gain=%s mat=%s peak=%.0fnits(%s) target=%.0fnits sat=%.2f knee=%.2f\n",
	       hc_tf_name(tm.tf),
	       tm.curve == TM_CLIP ? "clip" : tm.curve == TM_REINHARD ? "reinhard" :
	       tm.curve == TM_HABLE ? "hable" : "curve",
	       tm.gmode == HC_GAIN_LIN ? "lin" : "code",
	       tm.mat ? hc_mat_name(tm.pri) : "无",
	       tm.src_peak, tm.src_env ? "env" : csig_peak() > 0.0 ? "sei" : "默认",
	       tm.target, tm.sat, tm.knee);
	if (!tm.sat_env && tm.sat < 0.999)
		printf("TM: sat=%.2f 来自色域 %s（宽色域→709 压缩），TM_SAT 可覆盖\n",
		       tm.sat, cm_gamut());
}

static void tm_build(void)
{
	const char *e = getenv("TM");
	const char *hdr = getenv("HDR");

	memset(&tm, 0, sizeof(tm));
	tm.curve = TM_CURVE;
	tm.target = getenv("TM_TARGET") ? atof(getenv("TM_TARGET")) : 200.0;
	/* 峰值不再写死：优先码流自己的 maxCLL（csig.h 从 prefix SEI 读），
	 * 没有 mastering display 时退回母版峰值，两者都没有才用 1000 兜底，
	 * 而且打印出来说明是兜底——静默用假峰值就是之前那个长期问题。
	 * TM_SRC_PEAK 仍然可以显式覆盖，此时完全按用户的值，不跟 SEI。
	 */
	if (getenv("TM_SRC_PEAK")) {
		tm.src_peak = atof(getenv("TM_SRC_PEAK"));
		tm.src_env = 1;
	} else if (csig_peak() > 0.0) {
		tm.src_peak = csig_peak();
		tm.src_auto = 1;
	} else {
		tm.src_peak = 1000.0;
		tm.src_auto = 1;	/* 等 SEI 到，tm_refresh() 会重建 */
	}
	/* 饱和度跟着色域走，不再是独立旋钮（design_color.md §4.3.4）：
	 * 2020 源才需要往 709 压，709 源 sat=1.0（一个像素都不动）。
	 * TM_SAT 仍可覆盖，但那就是用户在“调味道”，日志里标 env。
	 */
	if (getenv("TM_SAT")) {
		tm.sat = atof(getenv("TM_SAT"));
		tm.sat_env = 1;
	} else {
		tm.sat = hc_sat_from_primaries(g_cm.primaries, 0.85);
	}
	tm.pri = g_cm.primaries;
	tm.mat = hc_needs_mat(tm.pri);
	tm.knee = getenv("TM_KNEE") ? atof(getenv("TM_KNEE")) : 0.7;
	tm.diag = getenv("TMDIAG") != NULL;
	tm.noop = getenv("TMNOOP") != NULL;	/* 只读写不做变换：量带宽上限 */
	{
		const char *d = getenv("TMDITHER");

		tm.dither = !(d && (!strcmp(d, "0") || !strcmp(d, "off")));
	}
	tm.time_it = getenv("TMTIME") != NULL;
	tm.full = getenv("TM_FULL") != NULL;	/* 源是全范围（少见） */
	{	/* TM_GAIN=code（默认/历史）| lin（线性光比值，暗部不掉色） */
		const char *gm = getenv("TM_GAIN");

		tm.gmode = (gm && (!strcmp(gm, "lin") || !strcmp(gm, "linear"))) ?
			  HC_GAIN_LIN : HC_GAIN_CODE;
	}
	if (tm.src_peak < tm.target) tm.src_peak = tm.target;
	if (tm.knee <= 0.05 || tm.knee >= 1.0) tm.knee = 0.7;
	if (tm.sat <= 0.0 || tm.sat > 2.0)
		tm.sat = tm.sat_env ? 0.85 : hc_sat_from_primaries(g_cm.primaries, 0.85);

	/* 开关：显式 TM= 优先；否则看码流自己的 VUI 传递函数（PQ/HLG 才映射，
	 * SDR 一律关掉），VUI 没写才退回 HDR=1（play.sh 用 ffprobe 判出来）。
	 * 之前只有 HDR= 一个来源，ffprobe 判错或者 SDR 片带了个 HDR 标记，
	 * 整片就被当 PQ 压一遍——发灰，还查不出来。 */
	if (e && (!strcmp(e, "0") || !strcmp(e, "off") || !strcmp(e, "no"))) {
		tm.on = 0;
		tm.tf_env = 1;		/* 用户明说不管，就不跟 VUI 走 */
		tm.tf = g_cm.transfer;
		return;
	}
	if (e && (!strcmp(e, "clip"))) tm.curve = TM_CLIP;
	else if (e && (!strcmp(e, "reinhard"))) tm.curve = TM_REINHARD;
	else if (e && (!strcmp(e, "hable"))) tm.curve = TM_HABLE;
	else if (e && (!strcmp(e, "curve") || !strcmp(e, "soft"))) tm.curve = TM_CURVE;
	if (e && (!strcmp(e, "1") || !strcmp(e, "on") || !strcmp(e, "yes") ||
		  !strcmp(e, "clip") || !strcmp(e, "curve") || !strcmp(e, "soft") ||
		  !strcmp(e, "reinhard") || !strcmp(e, "hable"))) {
		tm.on = 1;
		tm.tf_env = 1;
	} else {
		int h = cm_is_hdr();

		if (h == 1 && g_cm.transfer == 18) {
			/* §4.3.7：HLG 只识别，不映射（同 tm_refresh） */
			tm.on = 0;
			printf("TM: VUI=HLG（transfer=18），本期不做 HLG 映射，"
			       "回退 SDR 直显（TM=1 可强制）\n");
			tm.tf = g_cm.transfer;
			return;
		} else if (h == 1) {
			tm.on = 1;
		} else if (h == 0) {
			tm.on = 0;	/* VUI 说是 SDR：透传，别映射 */
			printf("TM: VUI=%s 不是 HDR，映射关闭（透传）\n", cm_tf_name());
			tm.tf = g_cm.transfer;
			return;
		} else {
			tm.on = (hdr && (!strcmp(hdr, "1") || !strcmp(hdr, "on")));
		}
	}
	tm.tf = g_cm.transfer;		/* 0=未标，按 PQ 兜底（hc_is_hdr） */

	if (!tm.on) return;
	tm_compile();
}

/* 峰值或传递函数变了（SEI 后到 / VUI 后到 / 换片）就重建 256 项表：
 * 不用重启，也不用等到下一帧才发现整片在按错的曲线压缩。每帧只多两次比较。
 */
static void tm_refresh(void)
{
	double p;
	int tfc = tm.tf_env ? tm.tf : g_cm.transfer;

	if (tfc != tm.tf) {		/* VUI 后到 / 换片：EOTF 换了 */
		int h = cm_is_hdr();

		if (!tm.tf_env && h == 1 && tfc == 18) {
			/* §4.3.7：HLG 是场景光 OETF，跟 PQ 不是一条曲线族，
			 * 本期只识别——压上去只会更灰，不如原样直显。 */
			tm.on = 0;
			printf("TM: VUI=HLG（transfer=18），本期不做 HLG 映射，"
			       "回退 SDR 直显（TM=1 可强制走 PQ 曲线）\n");
		} else if (!tm.tf_env && (h == 0 || h == 1)) {
			tm.on = (h == 1);
		}
		tm.tf = tfc;
		printf("TM: transfer→%s，%s（重建表）\n", hc_tf_name(tm.tf),
		       tm.on ? "开启映射" : "透传");
		if (tm.on)
			tm_compile();
		else {
			tm.built = 1;	/* 透传不需要表，但别每帧再进来编译 */
			return;
		}
	}
	/* VUI 后到/换片：色域变了，sat 得跟着重算，否则会拿 709 的 1.0
	 * 继续压 2020 片，或者反过来把 709 片当 2020 压掉色。 */
	if (!tm.sat_env && g_cm.primaries != tm.pri) {
		double s;

		tm.pri = g_cm.primaries;
		tm.mat = hc_needs_mat(tm.pri);
		s = hc_sat_from_primaries(tm.pri, 0.85);
		if (fabs(s - tm.sat) > 0.001) {
			tm.sat = s;
			printf("TM: 色域→%s，sat=%.2f 重算（重建表）\n",
			       cm_gamut(), tm.sat);
			if (tm.on) {
				tm_compile();
				return;	/* 表刚重建，峰值那步下帧再说 */
			}
		}
	}
	if (tm.src_env)
		return;
	p = csig_peak();
	if (p <= 0.0 || fabs(p - tm.src_peak) <= 0.5)
		return;
	tm.src_peak = (p < tm.target) ? tm.target : p;
	tm_compile();
}

/* 8x8 有序（Bayer）阈值。LUT 把 220 个输入码压进 112 个输出码，高光段
 * 更狠（knee=0.70 时 148..1000nits 只剩 36 个码，76 处相邻输入碰撞），
 * 平坦渐变直接出带。在输出码上叠 ±1 LSB 有序抖动：一半像素 +1、一半 -1，
 * 均值不变，一块 8x8 里能多辨约 1.6 bit 层次，代价是每像素两条饱和加减。
 * 抖动放在查表之后（输出码域），不是输入索引——索引 ±1 对"5 个输入码
 * 塌成一个输出码"毫无作用，只有抬输出电平才破得开。
 */
static const unsigned char hc_bayer8[8][8] = {
	{ 0, 32,  8, 40,  2, 34, 10, 42}, {48, 16, 56, 24, 50, 18, 58, 26},
	{12, 44,  4, 36, 14, 46,  6, 38}, {60, 28, 52, 20, 62, 30, 54, 22},
	{ 3, 35, 11, 43,  1, 33,  9, 41}, {51, 19, 59, 27, 49, 17, 57, 25},
	{15, 47,  7, 39, 13, 45,  5, 37}, {63, 31, 55, 23, 61, 29, 53, 21},
};
/* 三档：0..20 → -1，21..42 → 0，43..63 → +1，各档 21/22/21 个格子，
 * 均值精确为 0。早先写成二档（全 ±1）平坦区会出固定棋盘纹——没有像素
 * 停在原码，宁可让多数像素保持原码、少数偏一格。 */
#define HC_DTH(th) ((th) < 21 ? -1 : (th) >= 43 ? 1 : 0)

/* 就地映射一块 NV12（NV12M 两块 plane） */
static void tm_apply(int idx, unsigned w, unsigned h)
{
	unsigned char *yp, *cp;
	unsigned ystride, cstride, y, x;
	unsigned ymin = 255, ymax = 0;
	unsigned long ysum = 0;
	double t0;

	if (!tm.built) tm_build();
	else tm_refresh();
	if (!tm.on || !capbuf[idx].mem[0]) return;
	yp = capbuf[idx].mem2[0] ? capbuf[idx].mem2[0] : capbuf[idx].mem[0];
	cp = capbuf[idx].mem2[0] ? capbuf[idx].mem2[1] : capbuf[idx].mem[1];
	if (capbuf[idx].mem2[0] && tm.calls == 0)
		printf("TM: Y 走 dmabuf 映射 (mem2)\n");
	ystride = (capbuf[idx].len[0] % h == 0 && capbuf[idx].len[0] / h >= w) ?
		  capbuf[idx].len[0] / h : w;
	cstride = (cp && (h / 2) && capbuf[idx].len[1] % (h / 2) == 0) ?
		  capbuf[idx].len[1] / (h / 2) : w;
	t0 = (tm.diag || tm.time_it || tm.noop) ? now_s() : 0;

	/* 色度：2x2 一块，用左上角 Y 的码值查增益。
	 * 必须跑在 Y 平面被 LUT 改写之前 —— 表是按"输入码"编的：
	 *   gain[v]  输入码 v 的色度增益
	 *   lut[v]   输入码 v 该变成的输出码
	 * 原来这段放在 Y 之后，ry[x] 已经是输出码，等于拿错行去查表
	 * （输入 90 输出 150 的暗部会按 150 的增益去动色度）。
	 */
	if (cp) {
		if (tm.mat) {
			/* 源色域→709：色度域 3x3（hdrcolor.inc 的 hc_chroma709，
			 * 和 GL 片元的 uGm 同一组系数）+ 绕亮度轴去饱和，
			 * Y 保持 LUT 值。矩阵按 primaries 选，循环外取一次。 */
			const double *gm = hc_mat(tm.pri);

			for (y = 0; y + 1 < h; y += 2) {
				unsigned char *cr = cp + (size_t)(y / 2) * cstride;
				unsigned char *ry = yp + (size_t)y * ystride;

				for (x = 0; x + 1 < w; x += 2) {
					unsigned char src = ry[x];
					double ou, ov;

					hc_chroma709(tm.lut[src], cr[x], cr[x + 1],
						     (double)tm.gain[src], tm.sat,
						     gm, &ou, &ov);
					cr[x] = (unsigned char)(ou + 0.5);
					cr[x + 1] = (unsigned char)(ov + 0.5);
				}
			}
		} else {
			for (y = 0; y + 1 < h; y += 2) {
				unsigned char *cr = cp + (size_t)(y / 2) * cstride;
				unsigned char *ry = yp + (size_t)y * ystride;

				for (x = 0; x + 1 < w; x += 2) {
					unsigned g = tm.gain[ry[x]];
					int u = cr[x], v = cr[x + 1];

					u = 128 + (((u - 128) * (int)g) >> 10);
					v = 128 + (((v - 128) * (int)g) >> 10);
					cr[x] = (unsigned char)(u < 0 ? 0 : u > 255 ? 255 : u);
					cr[x + 1] = (unsigned char)(v < 0 ? 0 : v > 255 ? 255 : v);
				}
			}
		}
	}

#ifdef HAVE_NEON
	/* Y 平面：ARMv8 TBL 一次查 64 字节表，4 条 TBL + 4 条 select 处理 16 像��。
	 * 采集缓冲是 Normal-NC 映射，ALU 几乎不占时间，瓶颈只在访存。
	 */
	if (!tm.diag && !tm.noop) {
		uint8x16_t t0 = vld1q_u8(tm.lut + 0);
		uint8x16_t t1 = vld1q_u8(tm.lut + 16);
		uint8x16_t t2 = vld1q_u8(tm.lut + 32);
		uint8x16_t t3 = vld1q_u8(tm.lut + 48);
		uint8x16_t t4 = vld1q_u8(tm.lut + 64);
		uint8x16_t t5 = vld1q_u8(tm.lut + 80);
		uint8x16_t t6 = vld1q_u8(tm.lut + 96);
		uint8x16_t t7 = vld1q_u8(tm.lut + 112);
		uint8x16_t t8 = vld1q_u8(tm.lut + 128);
		uint8x16_t t9 = vld1q_u8(tm.lut + 144);
		uint8x16_t ta = vld1q_u8(tm.lut + 160);
		uint8x16_t tb = vld1q_u8(tm.lut + 176);
		uint8x16_t tc = vld1q_u8(tm.lut + 192);
		uint8x16_t td = vld1q_u8(tm.lut + 208);
		uint8x16_t te = vld1q_u8(tm.lut + 224);
		uint8x16_t tf = vld1q_u8(tm.lut + 240);
		uint8x16x4_t q0 = {{t0, t1, t2, t3}};
		uint8x16x4_t q1 = {{t4, t5, t6, t7}};
		uint8x16x4_t q2 = {{t8, t9, ta, tb}};
		uint8x16x4_t q3 = {{tc, td, te, tf}};
		const uint8x16_t c0 = vdupq_n_u8(0), c1 = vdupq_n_u8(1);
		const uint8x16_t c2 = vdupq_n_u8(2), c3 = vdupq_n_u8(3);
		const uint8x16_t m63 = vdupq_n_u8(63);
		/* 抖动用：每行两条 16 像素的 0/1 掩码（Bayer 周期 8、重复两遍
		 * 就够，因为 x 每次跨 16 且从 0 起，x&15 的模式每轮都一样）。
		 * inc=这一格 +1，dec=这一格 -1，两者都不置位的格子保持原码。 */
		const uint8x16_t clo = vdupq_n_u8(tm.full ? 0 : 16);
		const uint8x16_t chi = vdupq_n_u8(tm.full ? 255 : 235);
		unsigned char bm_inc[8][16], bm_dec[8][16];
		int bi, bj;

		for (bi = 0; bi < 8; bi++)
			for (bj = 0; bj < 16; bj++) {
				int t = hc_bayer8[bi][bj & 7];

				bm_inc[bi][bj] = t >= 43;
				bm_dec[bi][bj] = t < 21;
			}

		for (y = 0; y < h; y++) {
			unsigned char *r = yp + (size_t)y * ystride;
			const uint8x16_t inc = vld1q_u8(bm_inc[y & 7]);
			const uint8x16_t dec = vld1q_u8(bm_dec[y & 7]);

			for (x = 0; x + 16 <= w; x += 16) {
				uint8x16_t v = vld1q_u8(r + x);
				uint8x16_t idx = vandq_u8(v, m63);
				uint8x16_t hi = vshrq_n_u8(v, 6);
				uint8x16_t o;

				if (tm.noop) {
					o = v;
				} else {
					uint8x16_t a = vqtbl4q_u8(q0, idx);
					uint8x16_t b = vqtbl4q_u8(q1, idx);
					uint8x16_t c = vqtbl4q_u8(q2, idx);
					uint8x16_t d = vqtbl4q_u8(q3, idx);

					a = vbslq_u8(vceqq_u8(hi, c1), b, a);
					c = vbslq_u8(vceqq_u8(hi, c3), d, c);
					o = vbslq_u8(vceqq_u8(hi, c2), c, a);
					o = vbslq_u8(vceqq_u8(hi, c0), vqtbl4q_u8(q0, idx), o);
					if (tm.dither) {
						o = vqaddq_u8(vqsubq_u8(o, dec), inc);
						o = vminq_u8(vmaxq_u8(o, clo), chi);
					}
				}
				vst1q_u8(r + x, o);
			}
			for (; x < w; x++) {
				int t;

				if (tm.noop) continue;
				t = tm.lut[r[x]];
				if (tm.dither)
					t += HC_DTH(hc_bayer8[y & 7][x & 7]);
				r[x] = (unsigned char)(t < (tm.full ? 0 : 16) ? (tm.full ? 0 : 16)
						       : t > (tm.full ? 255 : 235) ? (tm.full ? 255 : 235) : t);
			}
		}
	} else
#endif
	{
		for (y = 0; y < h; y++) {
			unsigned char *r = yp + (size_t)y * ystride;

			for (x = 0; x < w; x++) {
				unsigned char v = r[x];

				if (tm.diag) {
					if (v < ymin) ymin = v;
					if (v > ymax) ymax = v;
					ysum += v;
				}
				if (tm.dither) {
					int t = tm.lut[v] + HC_DTH(hc_bayer8[y & 7][x & 7]);
					int lo = tm.full ? 0 : 16, hi = tm.full ? 255 : 235;

					r[x] = (unsigned char)(t < lo ? lo : t > hi ? hi : t);
				} else {
					r[x] = tm.lut[v];
				}
			}
		}
	}
	if (tm.diag && (tm.calls < 3 || tm.calls % 96 == 0))
		printf("TM: %ux%u stride=%u/%u Y in[%u..%u] mean=%.1f -> LUT out %.1fms\n",
		       w, h, ystride, cstride, ymin, ymax,
		       (double)ysum / ((double)w * h), (now_s() - t0) * 1000.0);
	tm.calls++;
	tm.t_acc += now_s() - t0;
	if (tm.time_it || tm.noop) {
		if (tm.calls < 4 || tm.calls % 24 == 0)
			printf("TM: frame %u %ux%u noop=%d cost=%.1fms (%.2f GB/s)\n",
			       tm.calls, w, h, tm.noop, (now_s() - t0) * 1000.0,
			       (double)w * h * 1.5 / (now_s() - t0) / 1e9);
	}
}
#endif	/* USE_DRM（色彩/tone mapping 与 DRM 探测到此为止） */

/* ---------- Renderer（上屏的唯一出口） ----------
 * 播放器只认 render.h：解、喂、seek、会话重建、pts、缓冲生命周期都在这边，
 * "这一帧怎么变成光"全在两个后端里。换 A/B 只是 RENDER=drm|gl。
 */
static struct renderer *rend;
static int g_drop_owners;	/* 会话重建中：owner 已作废，别再往旧 fd 上 QBUF */
static double g_play_fps = 24.0;	/* 播放配速；0 = 不限速（测吞吐） */
static double g_play_lead = 6;		/* 解码最多领先上屏几帧（背压） */
static int g_need_tm;			/* 后端不吃 HDR：播放器侧先 CPU 转 SDR */

/* ---------- 给控制面看的活值（/tmp/play.sock 的 status/pos）----------
 * 时间轴：t_clock0 是"会话内 0 秒"的墙钟锚点，暂停期间要把它往后推，
 * 所以真正的时钟是 t_clock0 + pctl_pause_seconds()。位置由这两个算，
 * 不再是"心跳一行 10 秒"那种粗粒度（遥控器连按时位置不动的观感就是它）。
 */
static double g_t_clock0;
static int    g_au_pub;			/* 已解出 AU 数（诊断用） */

/* ---------- 播放时钟：音频是主钟，视频只从动 ----------
 * 声音和画面在两个晶振上（ALSA 采样钟 vs 墙钟），拿墙钟按"假定 24fps"
 * 推画面，长片必然漂 —— 差 0.1% 就是 10 分钟偏 0.6 秒。音频位置是采样级
 * 的真值（aout_played_ms，hw_ptr 折算），所以画面只问它："第 got 帧该在
 * 主钟走到哪一刻上屏"，再折回墙钟去睡（带节拍器的后端要一个绝对时刻排
 * vblank 槽，不带的由这里睡够）。
 *
 * 起播锚定：音频线程通常比视频先跑几百毫秒（ffmpeg 先填满 ring），拿绝对
 * 位置对齐会白丢一截画面。锚在第一帧上，之后才跟音频走。
 *
 * 暂停不平移锚点会出事：暂停期间 played_ms 冻住、墙钟照走，resume 后 due
 * 已经落后一大截，画面会一口气追帧。所以锚点记下当时的累计暂停量，due
 * 里再加回去。
 *
 * 停走保护：声卡 xrun / FIFO 断流时 played_ms 不动，画面不能陪着冻死；
 * 超过 1s 没动就退回墙钟，等它再动起来重新锚定（不跳帧）。
 */
static long   g_pace_ms0 = -1;	/* 锚点：那一帧时的 played_ms */
static long   g_pace_got0;	/* 锚点帧号 */
static double g_pace_wall0;	/* 锚点墙钟 */
static double g_pace_pause0;	/* 锚点时的累计暂停秒数 */
static long   g_pace_seen;	/* 上次看到的 played_ms */
static double g_pace_seen_t;	/* played_ms 上次变化的墙钟 */

static double play_due(long got)
{
	long ms = aout_played_ms();
	double now = now_s(), pause = pctl_pause_seconds();

	if (ms >= 0) {
		if (ms != g_pace_seen) {
			g_pace_seen = ms;
			g_pace_seen_t = now;
		}
		if (now - g_pace_seen_t <= 1.0) {
			if (g_pace_ms0 < 0) {
				g_pace_ms0 = ms;
				g_pace_got0 = got;
				g_pace_wall0 = now;
				g_pace_pause0 = pause;
			}
			/* due 只由音频时钟推：锚点墙钟 + 音频走过的时长。
			 * 早先这里还额外加了 (got-got0)/fps，等于把"帧号进度"
			 * 和"音频进度"当两笔账一起记，dua 每帧要涨两份
			 * （2/fps = 83ms @24fps），睡出来的间隔比帧间隔大一倍，
			 * 24fps 的片子只能跑到 12fps；而且睡久了 ffmpeg 写视频
			 * 管子被顶住，音频 FIFO 跟着断粮，played_ms 一次跳掉
			 * 大半个 ring（实测 +100ms 的台阶），xrun 越滚越多。
			 */
			{
				double due = g_pace_wall0 + (pause - g_pace_pause0)
					     + (double)(ms - g_pace_ms0) / 1000.0;
				double lim = 2.0 / g_play_fps;

				/* 时钟跳变保护：xrun 恢复 / ring 一次预灌都会让
				 * played_ms 台阶式前跳，绝对对齐就变成"等它
				 * 追上来"，画面被硬拖慢。超前超过 2 帧就重锚，
				 * 宁可少等也不要跟着跳。落后超过 0.3s（音频比
				 * 画面慢一截）也重锚，避免接着一口气追帧。
				 */
				if (due > now + lim || due < now - 0.3) {
					g_pace_ms0 = ms;
					g_pace_got0 = got;
					g_pace_wall0 = now;
					g_pace_pause0 = pause;
					return now;
				}
				return due;
			}
		}
		g_pace_ms0 = -1;	/* 掉回墙钟，下次音频一动再锚 */
	} else {
		g_pace_ms0 = -1;
	}
	return g_t_clock0 + pause + got / g_play_fps;
}

static long pl_pos_ms(void)
{
	long ms = aout_played_ms();

	if (g_t_clock0 <= 0) return 0;
	/* 有音频就以音频位置为准：它才是"听到第几秒"，墙钟只是它的近似 */
	if (ms >= 0 && g_pace_ms0 >= 0)
		return (long)((g_pace_wall0 - g_t_clock0 - g_pace_pause0) * 1000.0)
		       + (ms - g_pace_ms0);
	return (long)((now_s() - g_t_clock0 - pctl_pause_seconds()) * 1000.0);
}

static int pl_au(void) { return g_au_pub; }

/* ---------- 上屏路径上报（给"上层"看） ----------
 * 脚本/自检/遥控不该去 grep 日志猜：到底是 DRM 直挂 plane，还是 GLES 导入
 * 纹理再色彩处理；HDR 是播放器 CPU 转还是 shader 转。只有播放器知道真相
 * （RENDER=auto 时选了谁、caps 决定了 tonemap 落在哪），所以由它写一份可
 * source 的状态文件，别的进程只读。先写 .tmp 再 rename，读侧永远看到完整的。
 */
static void render_dump_state(const struct render_stats *rs)
{
	const char *p = getenv("RENDERSTATE") ? getenv("RENDERSTATE")
					     : "/tmp/tvplay.render";
	char np[256], tmp[280];
	FILE *f;

	if (!rend)
		return;
	snprintf(np, sizeof(np), "%s", p);
	snprintf(tmp, sizeof(tmp), "%s.tmp", np);
	f = fopen(tmp, "w");
	if (!f)
		return;
	fprintf(f, "RENDER=%s\n", render_name(rend));
	fprintf(f, "MODE=%s\n",
		!strcmp(render_name(rend), "drm") ? "direct" : "gles");
	fprintf(f, "CAPS=%s%s\n", render_has_hdr(rend) ? "hdr" : "sdr",
		render_has_pace(rend) ? ",pace" : "");
	/* cpu = 播放器侧 tm_apply；shader = GL 片元里转；none = 没 HDR 要转 */
	fprintf(f, "TONEMAP=%s\n", g_need_tm ? "cpu" :
		(render_has_hdr(rend) ? "shader" : "none"));
	fprintf(f, "SRC=%ux%u\n", capw, caph);
	if (rs)
		fprintf(f, "SCREEN=%ux%u@%u\n", rs->dw, rs->dh, rs->refresh);
	fprintf(f, "PID=%d\n", (int)getpid());
	fclose(f);
	rename(tmp, np);
}

/* 帧从 Renderer 回到 vdec —— 唯一的缓冲回收点。
 * 回调跑在 render_pump 的调用线程里（就是我们自己），可以放心 ioctl。
 */
static void cap_recycle(int idx)
{
	struct v4l2_buffer b = {0};
	struct v4l2_plane pl[2] = {{0}};

	if (idx < 0 || idx >= NBUF_CAP_MAX)
		return;
	cap_busy[idx] = 0;
	if (g_drop_owners || fd < 0)
		return;
	b.type = CAP_T;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = idx;
	b.length = 2;
	b.m.planes = pl;
	if (ioctl(fd, VIDIOC_QBUF, &b) < 0 && errno != EINVAL)
		perror("QBUF recycle(renderer)");
}

static void on_frame_done(void *ctx, void *owner, double pts, uint32_t latch,
			  int status)
{
	(void)ctx; (void)latch;
	cap_recycle((int)((struct capbuf *)owner - capbuf));
	if (status == RENDER_DROPPED && g_verbose)
		printf("RENDER: drop pts=%.3f\n", pts);
}

/* OUTPUT 格式：一个 AU 一个 buffer。初次启动和 seek 重建会话共用。 */
static int out_fmt_setup(unsigned w, unsigned h)
{
	struct v4l2_format f = {0};
	size_t max = getenv("MAXAU") ? atol(getenv("MAXAU")) : (6u << 20);

	f.type = OUT_T;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_HEVC;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = (max + 8191) & ~4095UL;
	if (xioctl(fd, VIDIOC_S_FMT, &f) < 0) {
		printf("S_FMT OUT 失败: %s\n", strerror(errno));
		return -errno;
	}
	printf("S_FMT OUT : %ux%u sizeimage=%u (max AU %zu)\n",
	       f.fmt.pix_mp.width, f.fmt.pix_mp.height,
	       f.fmt.pix_mp.plane_fmt[0].sizeimage, max);
	return 0;
}

/* ================= 解码器会话生命周期 =================
 *
 * 一个会话 = /dev/video0 的 fd + 它的 OUTPUT/CAPTURE 队列、映射、导出的
 * dmabuf、事件订阅、流的开关状态。**只有下面两个函数动这些资源**，
 * main/事件回调里再不许出现 stop_stream + close(fd) + REQBUFS 的自由组合
 * （旧代码在 seek、SOURCE_CHANGE、退出三处各抄了一遍，谁漏一步就漏 fd、
 * 漏 render_flush、或者把旧 owner QBUF 回新 fd）。
 *
 * 不变式：
 *  1) fd >= 0 ⟺ 会话活着。任何失败路径都必须回到 fd = -1，
 *     绝不留半初始化会话——带半套资源继续跑正是"自激重建"的源头。
 *  2) 各步骤（S_FMT / REQBUFS / QBUF / STREAMON）返回 0 / -errno，
 *     不许 die()，由 vdec_open 决定重试还是交还失败。
 *  3) g_sess 是**提交计数**，不是尝试计数：只有 vdec_tx_commit() 才递增
 *     （§3.2.3）。失败的尝试不占代数，否则日志里"重建 4 次"对不上账。
 *     关闭时先作废 Renderer 手里的旧帧，再放队列、关 dmabuf、最后 close(fd)。
 *  4) hard_reset 失败是硬错误：返回 -1，不许当没发生继续开流。
 */
static int g_sess;		/* 已提交的会话代数：只增不减，commit 时才 ++ */
static int g_tx_attempt;	/* 事务里的 open 尝试数（含失败），和 g_sess
				 * 一起构成"成功率 = g_sess 增量 / attempts" */

/* 把 Renderer 手里属于旧缓冲的帧全部作废：清队会逐帧回调 ABORTED，
 * 那些 owner 属于旧会话/旧 dmabuf，一律不许再 QBUF（g_drop_owners）。
 */
static void retire_capture_frames(void)
{
	if (rend) {
		g_drop_owners = 1;
		render_flush(rend);
		g_drop_owners = 0;
	}
	memset(cap_busy, 0, sizeof(cap_busy));
}

/* 一次完整开流：open + S_FMT×2 + 队列 + 订阅 + STREAMON。
 * 成功 0、会话可用；失败 -errno，且 fd 已回到 -1，可以直接重试。
 */
static int vdec_open(unsigned w, unsigned h)
{
	const char *dev = getenv("VDECDEV") ? getenv("VDECDEV") : DEV;
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	struct v4l2_control ctl = { .id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE };
	int r;

	if (fd >= 0)		/* 不变式 1：一个进程一个会话 */
		vdec_close(0);

	/* 换片 = 分辨率/码流身份变了：上一片的内容信号（峰值、色域、传递函数）
	 * 必须先清掉，否则这一片没写 VUI/SEI 时会继续按上一片的峰值压缩。
	 * 同一片内部的 seek 不清：seek 目标 GOP 未必带 SEI，保留原峰值更接近真相。 */
	if (g_w && g_h && (w != g_w || h != g_h) &&
	    (g_cm.max_cll > 0.0f || g_cm.mastering_max_luminance > 0.0f ||
	     g_cm.transfer)) {
		printf("CSIG: 换片 %ux%u→%ux%u，清空上一片的内容信息\n", g_w, g_h, w, h);
		cm_reset();
	}
	g_w = w;
	g_h = h;
	fd = open(dev, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		r = -errno;
		printf("VDEC: open %s 失败: %s\n", dev, strerror(errno));
		return r;
	}
	/* 注意：这里**不**递增 g_sess —— 拿到 fd 不等于会话成立（§3.2.3）。
	 * 号在 vdec_tx_commit() 里才给，失败的事务连号都占不到。
	 */
	r = out_fmt_setup(w, h);
	if (!r) r = s_fmt_cap(w, h);
	if (!r) r = cap_setup();
	if (!r) r = out_setup();
	if (!r && xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
		printf("SUBSCRIBE_EVENT 失败: %s\n", strerror(errno));
		r = -errno;
	}
	if (!r) r = start_stream();
	if (r) {
		printf("VDEC: 开流失败 (%s)，回落关闭会话\n", strerror(-r));
		vdec_close(0);
		return r;
	}
	capw = g_w;
	caph = g_h;
	if (!xioctl(fd, VIDIOC_G_CTRL, &ctl))
		printf("min_buffers_for_capture(DPB)=%d\n", ctl.value);
	printf("VDEC: 会话打开成功 %ux%u（cap=%u out=%u）\n",
	       capw, caph, cap_count, n_out);
	return 0;
}

/* 关会话，幂等：任何阶段都能调，重复调用是空操作。
 * hard_reset=1 时在 close 之后做整块掉电复位（驱动 cur_sess 已空才接受）。
 * 返回 0 成功，-1 表示硬复位没做成（硬件可能还挂着）。
 */
static int vdec_close(int hard_reset)
{
	int r = 0;

	if (fd < 0)
		return 0;

	stop_stream();
	/* 顺序要紧：先让 Renderer 交回/丢弃旧帧，再关它们引用的 dmabuf，
	 * 最后才拆队列。反过来会把还在用的 dmabuf fd 关在纹理下面。
	 */
	retire_capture_frames();
	close_cap_dmabufs();
	cap_release();
	out_release();		/* fd 关掉后这些映射就没人会用了，就地撤 */
	close(fd);
	fd = -1;		/* 不变式 1 */

	/* 驱动是异步收尾的：close 后它才在 workqueue 里打完
	 * "Aborting decoding session!"。紧接着 open 会把新会话开在
	 * 还没收干净的旧状态上（实测 seek 偶发连试两次不出帧），
	 * 所以留一个落定期。复位流程本身就在等，不必再等一遍。
	 */
	if (hard_reset) {
		if (vdec_hard_reset() < 0)
			r = -1;
	} else {
		usleep(80000);
	}
	printf("VDEC: 会话 #%d 已关闭%s\n", g_sess, hard_reset ? "（硬复位）" : "");
	return r;
}

/* 同一个会话内换分辨率（SOURCE_CHANGE）：队列整组重建。
 * 失败就把会话置回不可用状态（fd=-1），让调用方走整会话重建。
 */
static int vdec_resize(unsigned w, unsigned h)
{
	int r;

	if (fd < 0)
		return -EINVAL;
	stop_stream();
	retire_capture_frames();
	close_cap_dmabufs();
	cap_release();
	g_w = w;
	g_h = h;
	r = s_fmt_cap(w, h);
	if (!r) r = cap_setup();
	if (!r) r = out_setup();
	if (!r) r = start_stream();
	if (r) {
		printf("RESIZE: %ux%u 失败 (%s)，会话作废\n", w, h, strerror(-r));
		stop_stream();
		close_cap_dmabufs();
		cap_release();
		close(fd);
		fd = -1;
		return r;
	}
	capw = g_w;
	caph = g_h;
	printf("RESIZE: %ux%u 会话 #%d 已重建\n", capw, caph, g_sess);
	return 0;
}

/* ================= 重建事务（§3.2）=================
 *
 * 补偿式事务，不是两阶段提交：驱动 cur_sess 是全局单例（§1.10），开不了
 * 影子会话，所以"原子性"不表现为回到旧状态，而表现为
 *
 *   对外只承认两种状态：VS_RUN(sess=N) / VS_DOWN(fd<0)；
 *   中间态（fd 在、队列半套、dmabuf 半套、owner 悬空）不许被外人看到。
 *
 * 三段：PREPARE（只读定档定预算）→ BODY（破坏性、可重试、全返回 -errno）
 * → COMMIT（唯一写屏障：g_sess++ 与门控归位）／ABORT（无条件补偿到空态）。
 * 旧代码把 s_len/s_pos/...清零放在 close/open 成功之前、g_sess++ 放在
 * open 一进门，于是"失败的重建"也改了可见状态——这里两处都收进事务。
 */

static const char *tx_why_name(int why)
{
	static const char *nm[] = { "newstream", "seek", "abort", "stall",
				    "srcchange", "rap", "selftest" };

	return (why >= 0 && why < (int)(sizeof(nm) / sizeof(nm[0])))
		       ? nm[why] : "?";
}

/* BODY 1：管道残留读空 + 码流扫描状态归零。
 * 必须在 close/open 之前做完，但本身不改变"会话可见状态"——它是码流侧的
 * 准备，重复做无副作用。EAGAIN 是终点，不算失败。
 */
static void tx_flush_pipe(void)
{
	if (s_fd >= 0) {
		int fl = fcntl(s_fd, F_GETFL);

		if (fl >= 0) {
			fcntl(s_fd, F_SETFL, fl | O_NONBLOCK);
			for (;;) {
				unsigned char tmp[65536];

				if (read(s_fd, tmp, sizeof tmp) <= 0)
					break;
			}
			fcntl(s_fd, F_SETFL, fl & ~O_NONBLOCK);
		}
	}
	s_len = 0;
	s_pos = 0;
	s_au_start = 0;
	s_au_open = 0;
	s_cur_vcl = 0;
	s_eof = 0;
	s_release = 0;
	s_au_rap = 0;
	s_au_rasl = 0;
}

/* 失败注入（§3.2.6）：REBUILD_FAIL=STEP:ERRNO，STEP∈{S_FMT,REQBUFS,
 * STREAMON,hard_reset}。没有注入就没有事务——四条分支必须能被主动踩到，
 * 否则"回滚清单"只是注释。REBUILD_FAILN 限注入次数（默认 0=一直失败）。
 */
static const char *tx_step = "open";

static int tx_inject(const char *step)
{
	static const char *e;
	static int used;
	const char *c;
	char buf[64];
	size_t n;

	if (!e)
		e = getenv("REBUILD_FAIL");
	if (!e || !*e)
		return 0;
	if (env_i("REBUILD_FAILN", 0) > 0 && used >= env_i("REBUILD_FAILN", 0))
		return 0;
	c = strchr(e, ':');
	n = c ? (size_t)(c - e) : strlen(e);
	if (n >= sizeof(buf))
		n = sizeof(buf) - 1;
	memcpy(buf, e, n);
	buf[n] = 0;
	if (strcmp(buf, step))
		return 0;
	used++;
	tx_step = step;
	if (!c || !c[1])
		return -EIO;
	/* 只认四个常用 errno，别把注入做成通用 errno 解析器 */
	if (!strcmp(c + 1, "EBUSY"))   return -EBUSY;
	if (!strcmp(c + 1, "EAGAIN"))  return -EAGAIN;
	if (!strcmp(c + 1, "ENOMEM"))  return -ENOMEM;
	if (!strcmp(c + 1, "EINVAL"))  return -EINVAL;
	if (!strcmp(c + 1, "EPERM"))   return -EPERM;
	if (!strcmp(c + 1, "ENODEV"))  return -ENODEV;
	return -EIO;
}

/* errno 分类（§3.2.3 的表）。次数预算之外最省事的一步：同一个 EBUSY 值得
 * 再等 200ms，同一个 EINVAL 再等一万次也不会变。
 */
enum tx_action { TXA_RETRY, TXA_ABORT };

static enum tx_action tx_classify(int e, int *nohard)
{
	*nohard = 0;
	switch (e) {
	case EBUSY:
	case EAGAIN:
		return TXA_RETRY;	/* 驱动 workqueue 还没收完 */
	case ENOMEM:
	case ENOSPC:
		*nohard = 1;		/* CMA 碎片：复位只会更糟（§2.5） */
		return TXA_RETRY;
	case ENOENT:
	case EACCES:
	case EINVAL:
	case ENODEV:
	case ENXIO:
		return TXA_ABORT;	/* 重试只是把黑屏时间拉长 */
	default:
		return TXA_RETRY;
	}
}

/* ABORT 之后的不变式断言（§3.2.4）。靠人眼看不出来，所以让它自己喊。 */
static int tx_assert_clean(void)
{
	unsigned i;
	int bad = 0, p;

	if (fd >= 0) {
		printf("TX-ASSERT: fd=%d 还开着\n", fd);
		bad = 1;
	}
	if (cap_count) {
		printf("TX-ASSERT: cap_count=%u 没还回去\n", cap_count);
		bad = 1;
	}
	if (n_out || out_nfree) {
		printf("TX-ASSERT: n_out=%d out_nfree=%d 没撤掉\n", n_out, out_nfree);
		bad = 1;
	}
	if (g_drop_owners) {
		printf("TX-ASSERT: g_drop_owners 没复位\n");
		bad = 1;
	}
	for (i = 0; i < NBUF_CAP_MAX; i++) {
		for (p = 0; p < 2; p++)
			if (capbuf[i].dmabuf[p] >= 0) {
				printf("TX-ASSERT: cap[%u/%d] dmabuf fd=%d 泄漏\n",
				       i, p, capbuf[i].dmabuf[p]);
				bad = 1;
			}
		if (capbuf[i].mem[0] || capbuf[i].mem[1]) {
			printf("TX-ASSERT: cap[%u] mmap 未撤\n", i);
			bad = 1;
		}
	}
	printf("TX-ASSERT: %s（不变式 fd<0 cap=0 out=0 owners=0）\n",
	       bad ? "FAILED" : "OK");
	return bad;
}

/* PREPARE：定档、记快照、定预算、打 BEGIN。只读，不碰任何 fd。 */
static void tx_begin(enum vev why, int level)
{
	static unsigned next_id;
	double budget = env_d("REBUILDMS", 3000) / 1000.0;

	memset(&g_tx, 0, sizeof(g_tx));
	g_tx.id = ++next_id;
	g_tx.why = why;
	g_tx.level = level;
	g_tx.hard = (level >= LVL_L3);
	g_tx.sess_before = g_sess;
	g_tx.t0 = now_s();
	/* L3 单次硬复位实测 150×20ms=3s，所以预算按 3 倍给 */
	g_tx.deadline = g_tx.t0 + budget * (g_tx.hard ? 3.0 : 1.0);
	g_tx.phase = TX_PREPARE;
	printf("TX#%u BEGIN why=%s level=L%d sess=%u budget=%.0fms\n",
	       g_tx.id, tx_why_name(why), level, g_tx.sess_before,
	       (g_tx.deadline - g_tx.t0) * 1000.0);
	fflush(stdout);
}

/* 暂停（pkill -STOP）会把进程冻在 BODY 中间，而 CLOCK_MONOTONIC 照走：
 * deadline 会在冻住时过期，resume 后第一轮就误判"重试超预算"去 L4。
 * 修法与 STALL 同源：整体平移（不重置，保持已花的预算）。 */
static void tx_shift_pause(double wall, double expect)
{
	double d = wall - expect;

	if (d > 4.0) {
		g_tx.t0 += d;
		g_tx.deadline += d;
		printf("TX#%u: 进程被冻住 %.1fs，预算整体平移（已花的不退）\n",
		       g_tx.id, d);
	}
}

static void tx_sleep(double sec)
{
	double a = now_s();

	usleep((useconds_t)(sec * 1e6));
	tx_shift_pause(now_s() - a, sec);
}

/* COMMIT：唯一的写屏障。只有 vdec_open()==0 才走到这里。 */
static void tx_commit(const char *cause)
{
	double ms = (now_s() - g_tx.t0) * 1000.0;

	g_tx.phase = TX_COMMIT;
	g_sess++;		/* 提交计数：全程序唯一的递增点 */
	rap_enter(RAP_WAIT, cause);
	g_rap_degraded = 0;
	g_rap_rasl_over = 0;
	printf("TX#%u COMMIT why=%s sess=%u→%u %.0fms tries=%d\n",
	       g_tx.id, tx_why_name(g_tx.why), g_tx.sess_before, g_sess,
	       ms, g_tx.tries);
	fflush(stdout);
	g_tx.phase = TX_IDLE;
}

/* BODY + COMMIT/ABORT 全流程。
 * flush=1：新码流（seek/重建）要先把管道残留读空；
 * flush=0：进程启动，s_buf 里已经预读了 SPS，一滴都不能丢。
 * 返回 0=已提交，-1=ABORT 且已回到干净空态（可以再来一次），-2=放弃(L4)。
 */
static int tx_run(int flush)
{
	int r, e = 0, nohard = 0;
	enum vev why_again = (enum vev)g_req_why;

	if (flush)
		tx_flush_pipe();

	tx_begin((enum vev)g_req_why, g_req_lvl ? g_req_lvl : LVL_L2);

	for (;;) {
		int hinj = 0;

		g_tx.phase = TX_BODY;
		tx_step = "hard_reset";
		if (g_tx.hard)
			hinj = tx_inject("hard_reset");	/* REBUILD_FAIL=hard_reset:EPERM */
		tx_step = "close";
		/* BODY 3：关。幂等；硬复位失败是硬错误，不许当没发生继续开流。 */
		if (vdec_close(g_tx.hard && !hinj) < 0)
			printf("TX#%u: 硬复位失败（step=hard_reset），会话已关，仍尝试重开\n",
			       g_tx.id);
		g_tx.hard = 0;		/* 复位的是硬件不是会话：只做一次 */
		if (hinj) {
			e = -hinj;
			tx_step = "hard_reset";
			printf("TX#%u: 硬复位失败（%s）→ L3 硬错误，直接 ABORT\n",
			       g_tx.id, strerror(e));
			goto abort;
		}

		/* 事务期间又来请求（seek 落在 BODY 里）：只升级档位，不打断，
		 * 也不排队（排队 = 先做一次无用功再毁一次）。
		 */
		if (g_reinit) {
			int nl = g_req_lvl;

			g_reinit = 0;
			g_req_lvl = 0;
			g_req_why = 0;
			if (nl > g_tx.level) {
				printf("TX#%u: 期间收到新请求（L%d）→ 档位升级，继续本次事务\n",
				       g_tx.id, nl);
				g_tx.level = nl;
				g_tx.hard = (nl >= LVL_L3);
			}
		}

		/* BODY 5：开（注入先于真开：STEP 就是"假设它在这一步失败"，
		 * 不必把注入点塞进 vdec_open 的每一行）。
		 */
		tx_step = "S_FMT";
		r = tx_inject("S_FMT");
		if (!r) {
			tx_step = "REQBUFS";
			r = tx_inject("REQBUFS");
		}
		if (!r) {
			tx_step = "STREAMON";
			r = tx_inject("STREAMON");
		}
		if (!r) {
			tx_step = "open";
			r = vdec_open(g_w, g_h);
		}
		g_tx.tries++;
		g_tx_attempt++;
		if (!r)
			break;			/* → COMMIT */

		e = -r;
		/* SIGUSR1 打在事务中间：不算失败，也不吃预算（seek 是正常操作） */
		if (e == EINTR) {
			printf("TX#%u: EINTR（信号打断），不消耗预算，重试\n", g_tx.id);
			continue;
		}
		if (tx_classify(e, &nohard) == TXA_ABORT) {
			printf("TX#%u: step=%s errno=%s 是硬错误，立即 ABORT\n",
			       g_tx.id, tx_step, strerror(e));
			goto abort;
		}
		if (nohard && g_tx.level >= LVL_L3) {
			/* CMA 碎片：降回 L2，别再往上加复位（§2.5 的教训） */
			printf("TX#%u: %s（CMA 类），本次不再硬复位\n",
			       g_tx.id, strerror(e));
			g_tx.level = LVL_L2;
			g_tx.hard = 0;
		}
		if (now_s() >= g_tx.deadline) {
			printf("TX#%u: 预算耗尽（try %d，最后 errno=%s）\n",
			       g_tx.id, g_tx.tries, strerror(e));
			goto abort;
		}
		printf("TX#%u: try %d 失败（step=%s errno=%s），200ms 后重试（剩 %.0fms）\n",
		       g_tx.id, g_tx.tries, tx_step, strerror(e),
		       (g_tx.deadline - now_s()) * 1000.0);
		tx_sleep(0.2);
	}

	tx_commit(flush ? "reinit" : "start");
	return 0;

abort:
	g_tx.phase = TX_ABORT;
	printf("TX#%u ABORT step=%s errno=%s(%d) tries=%d %.0fms\n",
	       g_tx.id, tx_step, strerror(e), e, g_tx.tries,
	       (now_s() - g_tx.t0) * 1000.0);
	/* 补偿式：不追踪走到第几步，无条件再关一次（fd<0 是空操作） */
	vdec_close(0);
	tx_assert_clean();	/* §3.2.4 的不变式要能自己喊，不能靠人眼 */
	/* 门控**不**回 PLAY，也不 rap_enter：ABORT 不动门控（§3.2.5） */
	g_err_rec++;
	if (g_err_rec > env_i("ERRREC", 4)) {
		printf("TX#%u: 连续 %d 次自愈失败 → L4 GIVEUP（交上层整链重启）\n",
		       g_tx.id, g_err_rec);
		fflush(stdout);
		g_tx.phase = TX_IDLE;
		return -2;
	}
	g_tx.phase = TX_IDLE;
	/* 会话已经是 VS_DOWN，但请求位在 BEGIN 时就清掉了：不重新挂一次请求，
	 * 主循环会带着 fd<0 继续跑（poll(-1) 立刻 EINVAL）。重挂的档位回到 L2
	 * ——硬复位刚失败过，再拿它开一轮只是白等一次 3s。
	 */
	tx_request(LVL_L2, why_again);
	return -1;
}

/* 内建音频：ffmpeg 往 /tmp/play.afifo 写 PCM，这里读出来喂 ALSA。
 * 声卡打不开不算致命——画面照放，只是没声音（和以前 mpv 起不来一致）。
 *
 * 必须在读码流之前就把 fifo 接上：ffmpeg 的多路输出是顺序写的，声音那个
 * muxer 一开写就阻塞在"没人读的 fifo"上，视频那条被一起带停；而播放器这边
 * 要先预读 1MB 才解析得出 SPS —— 两边互等，结果就是屏幕一直黑着。
 * 幂等：调用多次只起一次。
 */
static void audio_boot(void)
{
	static int done;
	const char *fifo;
	int afd;

	if (done) return;
	done = 1;
	if (!(getenv("AUDIO") && atoi(getenv("AUDIO")) == 1)) return;
	fifo = getenv("AUDIO_FIFO");
	if (!fifo || !*fifo) fifo = "/tmp/play.afifo";
	/* O_RDWR 而不是 O_RDONLY：自己也算 writer，
	 * "ffmpeg 还没开口"就不会被读成 EOF 把音频线程送走。
	 */
	afd = open(fifo, O_RDWR);
	if (afd < 0) {
		printf("AUDIO: 打不开 %s（%s），只放画面\n", fifo, strerror(errno));
		return;
	}
	if (aout_open(48000, 2,
		      getenv("AUDIO_FMT") ? getenv("AUDIO_FMT") : "s16le",
		      env_i("AUDIO_BUF", 8192), env_i("AUDIO_PERIOD", 2048),
		      getenv("AUDIO_VOL") ? atoi(getenv("AUDIO_VOL")) : 100,
		      0) < 0) {
		printf("AUDIO: 声卡打不开（被占用？），只放画面\n");
		close(afd);
		return;
	}
	if (aout_start(afd) < 0) {
		printf("AUDIO: 音频线程起不来，只放画面\n");
		close(afd);
		return;
	}
	printf("AUDIO: 内建 aout 48000 Hz 2ch s16le（%s）\n", fifo);
	atexit(aout_stop);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	/* 客户端模式：player -c status|vol +10|toggle|... 就是 play.sh 的控制入口
	 * （以前这是 mpvctl 的活）。必须先于一切设备操作，不碰 /dev/video0。
	 */
	if (argc > 2 && !strcmp(argv[1], "-c"))
		return pctl_client(argc - 2, argv + 2);

	const char *path = argc > 1 ? argv[1] : "/tmp/test.265";
	struct stat st;
	int sf, au_idx = 0, poll_timeouts = 0, drained = 0, stream_done = 0;
	int i;
	int idle_ticks = 0;	/* 连续没进展的轮次（喂不进也收不到帧） */
	double t_play0 = 0;
	int verbose = g_verbose;
	double t0, t1, tq = 0, wall;
	int expect = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 0;

	if (argc > 3) { g_w = atoi(argv[2]); g_h = atoi(argv[3]); }

	{	/* seek：重建 V4L2 会话，DRM 不动。
		 * 必须关掉 SA_RESTART（signal() 默认带），否则阻塞在 read()
		 * 等供流时信号会被内核延迟到下一帧数据，seek 白等几秒。
		 */
		struct sigaction sa;

		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = on_usr1;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sigaction(SIGUSR1, &sa, NULL);
	}

	/* 会话在 SPS 解析之后才开（vdec_open 需要真实分辨率去 S_FMT），
	 * 这里只管把码流接上。 */
	if (!strcmp(path, "-")) {
		sf = STDIN_FILENO;	/* 管道直供：ffmpeg -f hevc - | player - */
	} else {
		sf = open(path, O_RDONLY);
		if (sf < 0) die("open stream");
	}
	s_fd = sf;
	/* 先接上声音 fifo 再去预读码流：ffmpeg 那边是顺序写多路输出的，
	 * 没人读 PCM 就会卡在写 fifo 上，连视频一起停。
	 */
	audio_boot();
	if (sf != STDIN_FILENO && !fstat(sf, &st))
		printf("input: %s (%.2f GB)\n", path, st.st_size / 1073741824.0);
	else
		printf("input: stdin (pipe)\n");
	/* 只预读一小段：足够 SPS 即可，不整片读入 */
	s_fill(getenv("PREFILL") ? atol(getenv("PREFILL")) : (1u << 20));
	if (!s_len) die("stream 空");

	{
		unsigned sw = 0, sh = 0;
		int f = 0;

		/* sps_size() 走全局 stream/stream_size，临时指向预读窗口 */
		stream = s_buf;
		stream_size = s_len;
		f = sps_size(&sw, &sh);
		stream = NULL;
		stream_size = 0;
		if (argc > 3) {
			printf("SPS: %ux%u (被命令行覆盖为 %ux%u)\n", sw, sh, g_w, g_h);
		} else if (f) {
			printf("SPS: %ux%u\n", sw, sh);
			g_w = sw;
			g_h = sh;
		} else if (sf == STDIN_FILENO) {
			/* 管道里还没读到 SPS：多预读一些再试 */
			s_fill(4u << 20);
			stream = s_buf;
			stream_size = s_len;
			f = sps_size(&sw, &sh);
			stream = NULL;
			stream_size = 0;
			if (f) {
				printf("SPS(二读): %ux%u\n", sw, sh);
				g_w = sw;
				g_h = sh;
			} else {
				printf("SPS: 未找到，按 %ux%u 打开\n", g_w, g_h);
			}
		} else {
			printf("SPS: 未找到，按 %ux%u 打开\n", g_w, g_h);
		}
	}
	/* 会话建立走同一个事务（flush=0：s_buf 里预读的 SPS 一滴都不能丢）。
	 * 上一次进程异常退出时驱动可能还在异步收尾，所以靠事务里的
	 * EBUSY→退避重试撑过落定期，而不是外面再写一遍 3 次循环。
	 */
	for (i = 0; i < NBUF_CAP_MAX; i++) {
		int p2;

		for (p2 = 0; p2 < 2; p2++)
			capbuf[i].dmabuf[p2] = -1;	/* ABORT 断言要求"未用 = -1" */
	}
	g_req_lvl = LVL_L2;
	g_req_why = VEV_NEWSTREAM;
	{
		int r = tx_run(0);

		/* 启动时没有旧会话可回滚：失败就是失败，别在事务外再自旋 */
		if (r) {
			printf("FATAL: %ux%u 打不开解码器会话（%s），退出\n",
			       g_w, g_h, r == -2 ? "L4" : "ABORT");
			return 1;
		}
	}

	if (getenv("PLAY")) {
		/* 配速归播放器，Renderer 只按 pts 找上屏槽 */
		g_play_fps = getenv("FPS") ? atof(getenv("FPS")) : 24.0;
		g_play_lead = getenv("LEAD") ? atof(getenv("LEAD")) : 6;
		if (getenv("NOPACE")) {
			g_play_fps = 0;
			g_play_lead = 0;
		}
		rend = render_open(getenv("RENDER") ? getenv("RENDER") : "auto",
				   capw, caph, on_frame_done, NULL);
		if (!rend)
			die("render_open");
		t_play0 = now_s();
		printf("PACE: render_has_pace=%d fps=%.2f lead=%.1f\n",
		       render_has_pace(rend), g_play_fps, g_play_lead);
		g_t_clock0 = t_play0;

		/* 控制面起来：/tmp/play.sock（play.sh 用 `player -c ...` 说话）
		 * + evdev 遥控。盒上不再有 mpvctl / rcinputd 两个常驻件。
		 */
		pctl_set_sources(pl_pos_ms, pl_au);
		pctl_start();
		atexit(pctl_stop);

		/* 声音一般已经在 main 开头 audio_boot() 起好了；这里兜底一次 */
		audio_boot();
	}
	if (getenv("PLAY") && !render_has_hdr(rend))
		/* 这条后端不吃 PQ/BT.2020：HDR 源先在这边 CPU 转 SDR */
		g_need_tm = 1;
	if (getenv("PLAY")) {
		/* 上屏路径定下来了，报给上层：drm 直显 / gles，tonemap 在谁手上 */
		printf("RENDER: mode=%s tonemap=%s src=%ux%u\n",
		       !strcmp(render_name(rend), "drm") ? "direct" : "gles",
		       g_need_tm ? "cpu" : (render_has_hdr(rend) ? "shader" : "none"),
		       capw, caph);
		render_dump_state(NULL);
	}

	/* 事件订阅和 STREAMON 已经在 vdec_open 里做完了，这里只剩输出文件 */
	out = getenv("NOWRITE") ? NULL : fopen(getenv("OUTYUV") ? getenv("OUTYUV")
					       : "/tmp/out.yuv", "wb");
	t0 = now_s();
	g_verbose = getenv("VERBOSE") != NULL;
	rap_enter(RAP_WAIT, "start");	/* 起播也走同一个闸门 */

	for (;;) {
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		int pr;

		/* 暂停：不喂流也不上屏，音频由 pctl 同步停写。上游 ffmpeg 被管子
		 * 顶住（-re 供流本来就是阻塞的）——不需要再 SIGSTOP 整个进程组，
		 * 也就不会再有"冻住过"那种要靠 HERE 时钟猜的误判。
		 */
		if (pctl_paused()) {
			/* 暂停时没有新帧，提示条只能靠补画出现/擦掉：
			 * 不补，冻住的那一帧会把"|| 暂停"永远挂在屏幕上。
			 */
			if (osd_poll_dirty())
				render_repaint(rend);
			usleep(20000);
			continue;
		}

		/* 进程被冻住过的识别：tvplay 的"暂停"就是 pkill -STOP 整条链，
		 * 冻住的这段时间 CLOCK_MONOTONIC 照走，而循环一轮都没转。
		 * 不扣掉它，resume 后第一次 poll 超时就会算出 quiet=暂停时长，
		 * 直接误判成硬件 STALL 去重建会话（闪一下黑屏 + 掉 buffer）。
		 * 一轮正常最多卡一个 poll 周期（2s），超过 4s 只可能是被冻过；
		 * 恢复后按"刚过一个 poll 周期"重算基准，既不误判也不会算出负数。
		 */
		{
			double tl = now_s();

			if (t_loop > 0 && tl - t_loop > 4.0) {
				t_last_rx = tl - 2.0;
				/* 门控态的计时也要一起挪，否则 resume 后
				 * 第一批 poll 超时就会撞 RAPSTRICT/IRAPWAIT
				 * 去重建会话（和 STALL 误判同源）。
				 */
				if (g_rap_st != RAP_PLAY)
					g_rap_t0 = tl - 2.0;
			}
			t_loop = tl;
		}

		/* 心跳：长跑时才知道"什么时候"停的画。没有这行，画面冻住
		 * 只能靠外部 rchar 采样反推，前端时间全是黑的。
		 */
		{
			static double t_hb;

			if (now_s() - t_hb >= 10.0) {
				t_hb = now_s();
				printf("HB t=%.0f au=%d got=%d out_nfree=%d/%d quiet=%.1f rec=%d\n",
				       t_hb - t0, au_idx, got, out_nfree, n_out,
				       t_hb - t_last_rx, g_err_rec);
				fflush(stdout);
			}
		}

		/* 重建请求（seek / POLLERR / STALL / RAP 缺失 / FORCEREINIT）。
		 * 请求位是 g_reinit + g_req_lvl，真正动手的是 tx_run：开会话、
		 * 清码流、跳帧、归位计数器全在事务里，失败要么回到干净空态，
		 * 要么整体放弃（返回 3 让上层整链重启）。
		 */
		if (g_reinit) {
			int rr;

			printf("REINIT: 开始重建事务（DRM/GL 保留）\n");
			rr = tx_run(1);
			if (rr == -2) {
				printf("REINIT: 事务放弃（L4），退出让上层重启\n");
				fflush(stdout);
				return 3;
			}
			if (rr < 0) {
				/* ABORT 已回到干净空态（fd<0），但码流位置已经
				 * 前移到新流开头；下一轮重新发起事务。
				 */
				continue;
			}
			/* 本地状态清零：别把上一段流的收尾当成本流的结尾。
			 * 门控状态/计数器在 tx_commit() 里已经归位（rap_enter），
			 * 这里只管 main 自己的局部量。
			 */
			drained = 0;
			stream_done = 0;
			poll_timeouts = 0;
			idle_ticks = 0;
			eos_seen = 0;
			g_refeed = 0;
			tq = 0;
			au_idx = 0;
			t_last_rx = now_s();
			g_mark_first = 1;
			printf("REINIT: ready (waiting RAP, mode=%s)\n",
			       rap_strict() ? "strict" : "cra");
			continue;
		}

		/* 收尾阶段：等到预期帧数 / EOS / 长时间静默就停 */
		if (drained) {
			double el = now_s() - tq;
			double quiet = now_s() - t_last_rx;

			/* 收尾别傻等 2s：EOS 事件该驱动经常不发，
			 * OUTPUT 全回收 + 一轮 poll 无新帧就当收尾完成。
			 */
			if (eos_seen || (expect && got >= expect) ||
			    (out_nfree == n_out && (poll_timeouts >= 1 || quiet > 0.15)) ||
			    quiet > (getenv("DRAINWAIT") ? atof(getenv("DRAINWAIT")) : 0.5) ||
			    el > 2.0) {
				if (g_verbose)
					printf("drain exit: eos=%d timeouts=%d waited=%.3f got=%d\n",
					       eos_seen, poll_timeouts, el, got);
				break;
			}
		}

		/* drain 必须放在循环最开头做：下面的 poll 超时分支有
		 * continue，capture 分支也可能提前跳回，放在尾部会被绕过，
		 * 结果 stream_done 置位了却永远发不出 STOP，解码器等输入、
		 * 显示等帧，双方永久僵住（末尾几帧就是吐不出来）。
		 */
		if (stream_done && got > 0 && !drained) {
			struct v4l2_decoder_cmd cmd = {0};

			tq = now_s();
			cmd.cmd = V4L2_DEC_CMD_STOP;
			if (xioctl(fd, VIDIOC_DECODER_CMD, &cmd) < 0)
				perror("DEC_CMD_STOP");
			else if (g_verbose)
				printf("drain: DEC_CMD_STOP sent (got=%d)\n", got);
			drained = 1;
			poll_timeouts = 0;
			idle_ticks = 0;
		}

		while (out_nfree) {
			const unsigned char *ap = NULL;
			size_t al = 0;
			int r;

			/* 背压：只用"解码领先显示多少帧"限流。
			 * 解码器 100fps 全速跑也行，但显示节拍由 vblank
			 * 决定，领先超过 LEAD 帧就别再喂，否则 20 个
			 * capture buffer 一满就只能在显示前丢帧。
			 */
			if (g_play_fps > 0 && g_play_lead > 0 &&
			    au_idx - got >= g_play_lead)
				break;
			{
				double tr = now_s();
				size_t p0 = s_len - s_pos;
				int hi;

				r = stream_next_au(&ap, &al);
				{
					double dt = now_s() - tr;

					t_rd_acc += dt;
					hi = (r > 2) ? 3 : (r < -1 ? 0 : r + 1);
					t_hist[hi] += dt;
					n_hist[hi]++;
					b_hist[hi] += (s_len - s_pos > p0) ?
						0 : (p0 - (s_len - s_pos));
				}
				n_rd++;
			}
			if (r < 0)
				break;		/* seek 打断：回主循环处理重建 */
			if (r == 0) {
				if (g_rap_st != RAP_PLAY)
					printf("RAP: 流结束仍没有可用 RAP（丢 %d AU，%s）\n",
					       g_rap_drop, g_rap_cause);
				stream_done = 1;
				break;
			}
			/* 闸门（§1.14）：只有 rap_accept() 放行的 RAP 能开播；
			 * 收 CRA 时还要连带丢掉它后面那串 RASL——那些帧参考的
			 * 是 CRA 之前的图，新会话里根本不存在。
			 */
			if (g_rap_st != RAP_PLAY) {
				if (r == 2 && rap_accept(s_au_last_rap)) {
					int idr = s_au_last_rap <= 20;

					rap_enter(idr ? RAP_PLAY : RAP_RASL,
						  idr ? "IDR" : (g_rap_degraded
								 ? "CRA/degraded" : "CRA"));
					t_last_rx = now_s();
				} else if (g_rap_st == RAP_RASL && !s_au_last_rasl) {
					rap_enter(RAP_PLAY, "rasl-done");
					t_last_rx = now_s();
				} else {
					if (g_rap_st == RAP_RASL)
						g_rap_rasl_n++;
					g_rap_drop++;
					idle_ticks = 0;
					continue;
				}
			} else if (r == 2) {
				t_last_rx = now_s();
			}
			{
				double tq2 = now_s();

				qbuf_au(ap, al, r == 2);
				t_qb_acc += now_s() - tq2;
			}
			au_idx++;
			idle_ticks = 0;
		}

		/* 门控态的超时/降级：每轮都算，不依赖 poll 是否超时
		 * （丢 AU 时事件照样来，走不到 pr==0 的分支）。
		 */
		{
			int rr = rap_tick();

			if (rr == 1) {
				fflush(stdout);
				if (++g_err_rec <= env_i("ERRREC", 4))
					tx_request(LVL_L2, VEV_RAP);	/* 软重建：RAP 缺失不是固件问题 */
				else {
					printf("RAP: 连续 %d 次没等到可用 RAP，退出\n",
					       g_err_rec);
					break;
				}
				continue;
			}
			if (rr == 2) {
				fflush(stdout);
				break;
			}
		}

		{
			double tp = now_s();

			pr = poll(&pf, 1, drained ? 50 : (out_nfree ? 2000 : 100));
			t_poll_acc += now_s() - tp;
		}
		if (pr < 0) {
			/* SIGUSR1 会打断 poll。以前这里直接 break 退主循环，
			 * 表现是"seek 偶发卡 3s 后解码器消失"——信号恰好落在
			 * poll 而不是 read 上时就会踩到。必须回主循环重查
			 * g_reinit（顶部会重建会话），否则 seek 就是赌概率。
			 */
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}
		if (pr == 0) {
			poll_timeouts++;
			idle_ticks++;
			/* 播放中但暂时没新帧（供流打嗝/门控等待）：提示条到期
			 * 也要擦掉，否则最后那一帧会被永久烙在画面上。
			 */
			if (osd_poll_dirty())
				render_repaint(rend);
			if (g_verbose && poll_timeouts <= 3)
				printf("poll timeout #%d au=%d/%d out_nfree=%d got=%d\n",
				       poll_timeouts, au_idx, g_stream_au, out_nfree, got);
			/* vb2_fop_poll() 不挂 fh->wait，事件不会唤醒 poll，
			 * 所以超时后主动取一次事件，否则分辨率切换会死锁。
			 */
			handle_event();
			if (g_refeed) {
				/* 流式不能回卷：保持位置继续，驱动同分辨率会自动接上 */
				drained = 0;
				g_refeed = 0;
			}
			/* 看门狗：硬件偶尔静默挂死——vdec IRQ 完全停、DQBUF 永不
			 * 返回，poll 只是无限超时，进程活着但画面冻住（Soak 实测：
			 * 127 分钟后 poll(/dev/video0) 空转，vdec irq 计数不动）。
			 * 距上一帧超过 STALLSEC 秒就判死并重建会话自愈。
			 */
			/* 门控态（等 RAP / 跳 RASL）本来就不该出帧，超时归
			 * rap_tick() 管；这里只看正常播放，否则等一个长 GOP
			 * 就会被 STALLSEC 判死，反复重建。
			 */
			if (!drained && g_rap_st == RAP_PLAY) {
				double limit = env_d("STALLSEC", 12.0), base = t_last_rx;
				{
				double quiet2 = now_s() - base;

				if (limit > 0 && base > 0 && quiet2 > limit) {
					printf("STALL: %.1fs 无新帧 au=%d out_nfree=%d/%d got=%d → 重建会话\n",
					       quiet2, au_idx, out_nfree, n_out, got);
					fflush(stdout);
					if (++g_err_rec <= (getenv("ERRREC") ? atoi(getenv("ERRREC")) : 4)) {
						tx_request(LVL_L3, VEV_STALL);
					} else {
						printf("STALL: 连续 %d 次自愈失败，退出\n", g_err_rec);
						break;
					}
				}
				}
			}
			continue;
		}
		idle_ticks = 0;
		if (g_verbose)
			printf("poll ready revents=%x\n", pf.revents);
		if (pf.revents & POLLERR) {
			printf("POLLERR（驱动 abort 会话）rec=%d\n", g_err_rec + 1);
			/* 不退出：驱动只是把这个会话 abort 掉了，重开设备即可
			 * 继续；退出会让上层整链重启（黑一下屏）。只有连续多次
			 * 重建后仍拿不到帧才真正放弃。
			 */
			if (++g_err_rec <= (getenv("ERRREC") ? atoi(getenv("ERRREC")) : 4)) {
				tx_request(LVL_L3, VEV_ABORT);
				stream_done = 0;
				drained = 0;
				continue;
			}
			printf("POLLERR: 连续 %d 次自愈失败，退出\n", g_err_rec);
			break;
		}

		handle_event();
		if (g_refeed) {
			drained = 0;
			g_refeed = 0;
			continue;
		}

		/* capture frames */
		for (;;) {
			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[2] = {{0}};
			int rendered = 0;

			b.type = CAP_T;
			b.memory = V4L2_MEMORY_MMAP;
			b.length = 2;
			b.m.planes = pl;
			double t_rx;

			{
				double td = now_s();
				int qr;

				qr = xioctl(fd, VIDIOC_DQBUF, &b);
				t_dq_acc += now_s() - td;
				if (qr < 0)
					break;
			}
			t_rx = now_s();
			t_frame0 = t_rx;
			if (g_mark_first) {
				g_mark_first = 0;
				g_err_rec = 0;	/* 真的出帧了，自愈计数归零 */
				printf("REINIT: first frame\n");
			}
			if (!got)
				t_first_rx = t_rx;
			t_last_rx = t_rx;
			if (verbose)
				printf("frame %d: idx=%u flags=%08x ts=%ld.%06ld\n", got,
				       b.index, b.flags, (long)b.timestamp.tv_sec,
				       (long)b.timestamp.tv_usec);
			if (g_verbose)
				fprintf(stderr, "plane len=%zu/%zu off=%u/%u\n",
					capbuf[b.index].len[0], capbuf[b.index].len[1],
					pl[0].data_offset, pl[1].data_offset);
			if ((g_verbose || got == 0) && capbuf[b.index].mem[0])
				dump_frame(b.index, pl);
			/* §4.3.8 每次内容信号变化打一条完整 COLOR: 行。
			 * 放在 g_need_tm 之外：SDR 片（on=0/透传）也得有这条，
			 * 否则"709 片不被误压"和"无元数据回退"两栏没法验。 */
			color_report();
			if (out && pl[0].bytesused && capbuf[b.index].mem[0]) {
				double tw = now_s();

				write_nv12(b.index, capw, caph);
				t_write_acc += now_s() - tw;
			}
			if (rend) {
				int rc;

				if (g_need_tm) {
					double tt = now_s();

					tm_apply(b.index, capw, caph);
					t_tm_acc += now_s() - tt;
				}
				/* 时间轴在播放器手里：首帧锚点 + 帧号/配速。
				 * pts 只用来让 Renderer 找上屏槽（它不改解码状态）。
				 * 但只有"自己带节拍器"的后端才需要槽（RENDER_CAP_PACE）；
				 * 没节拍器的后端（DRM 直出：submit 只入队不阻塞）由播放器
				 * 按 pts 睡够了再交，这里再给 pts 反而会和墙钟错位——队首
				 * 槽永远比当前 vblank 领先，pump 等不到就整场不上屏。
				 */
				/* 先标在飞再提交：后端可能就地回调（丢帧/同步后端），
				 * 回调里 cap_recycle 会把它清掉，撤不回来就永远别再 QBUF。
				 */
				cap_busy[b.index] = 1;
				{
				double ts = now_s();
				rc = render_submit(rend, capbuf[b.index].dmabuf,
						   capw, caph, capw, capw,
						   (g_play_fps > 0 && render_has_pace(rend)) ?
						   play_due(got) : 0,
						   &capbuf[b.index]);
				t_sub_acc += now_s() - ts;
				}
				if (rc >= 0) {
					static int yn;
					if (getenv("YSTAT") && yn < 5 &&
					    capbuf[b.index].mem[0]) {
						unsigned char *yp8 = capbuf[b.index].mem[0];
						size_t i, n = (size_t)capw * caph;
						unsigned lo = 255, hi = 0;
						unsigned long long sum = 0;
						for (i = 0; i < n; i += 97) {
							unsigned v = yp8[i];
							if (v < lo) lo = v;
							if (v > hi) hi = v;
							sum += v;
						}
						printf("YSTAT #%d %ux%u ypitch=%u "
						       "min=%u max=%u mean=%.1f\n",
						       yn, capw, caph, capw, lo, hi,
						       (double)sum / (double)((n + 96) / 97));
						if (yn == 0) {
							FILE *df = fopen("/tmp/y.raw", "wb");
							if (df) {
								fwrite(yp8, 1, n, df);
								fclose(df);
							}
						}
						yn++;
					}
					rendered = 1;	/* 交接成功：回收权归 Renderer */
				} else {
					cap_busy[b.index] = 0;
					printf("RENDER: submit 失败 (%d)\n", rc);
				}
			}
#ifdef USE_DRM
			if (getenv("EXPBUF") && getenv("DRMFB") && got == 1)
				drm_import_test(capbuf[b.index].dmabuf[0],
						capbuf[b.index].dmabuf[1], capw, caph);
#endif
			/* 后端没有节拍器（同步后端不会自己等）：配速归播放器 */
			if (rend && g_play_fps > 0 && !render_has_pace(rend)) {
				double due = play_due(got);
				double nn = now_s();

				if (due > nn) {
					usleep((useconds_t)((due - nn) * 1e6));
					t_slp_acc += now_s() - nn;
					n_slp++;
				}
				if (getenv("PACEDBG") && got < 40)
					printf("PACEDBG got=%ld audio_ms=%ld due_now=%.3f "
					       "sleep_ms=%.1f sub_ms=%.1f\n",
					       (long)got, aout_played_ms(), due - nn,
					       (due > nn ? (due - nn) * 1000.0 : 0.0),
					       (now_s() - t_frame0) * 1000.0);
			}
			/* 每解出一帧就推一次：解码器一次 DQBUF 可能连吐多帧（DPB
			 * 重排），pump 只在轮末调的话会把攒下的几帧在同一个 vblank
			 * 里一次翻完——中间的等于白翻（算 miss），屏幕上是卡顿。 */
			if (rend)
				render_pump(rend, 0);
			got++;
			g_au_pub = got;
			/* 自愈路径的确定性验证开关：FORCEREINIT=300 在第 300 帧
			 * 主动走一遍"固件 hang → 整块复位 → 等 IRAP"流程，
			 * 用来确认重建后能真的接着解，而不是干等（正常播放时
			 * 不该出现这段）。
			 */
			if (!g_force_reinit_at && getenv("FORCEREINIT"))
				g_force_reinit_at = atoi(getenv("FORCEREINIT"));
			if (g_force_reinit_at > 0 && got == g_force_reinit_at) {
				printf("FORCEREINIT: 第 %d 帧主动重建\n", got);
				fflush(stdout);
				g_force_reinit_at = -1;
				tx_request(LVL_L3, VEV_SELFTEST);
				break;
			}
			if (rendered) {
				/* 等 Renderer 的完成回调来回收（cap_busy 已置位） */
			} else if (xioctl(fd, VIDIOC_QBUF, &b) < 0) {
				perror("QBUF recycle");
				break;
			}
		}

		/* 兜底再推一次（每帧的那次在解帧处已经调过）：这里不阻塞，
		 * 只把还没翻掉的一并清掉，免得轮末还挂着帧。 */
		if (rend) {
			double tpu = now_s();

			render_pump(rend, 0);
			t_pump_acc += now_s() - tpu;
		}

		/* recycle output buffers */
		for (;;) {
			struct v4l2_buffer b = {0};
			struct v4l2_plane pl[1] = {{0}};

			b.type = OUT_T;
			b.memory = V4L2_MEMORY_MMAP;
			b.length = 1;
			b.m.planes = pl;
			if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
				break;
			out_free[out_nfree++] = b.index;
		}

	}

	t1 = now_s();
	wall = t1 - t0;
	if (out) fclose(out);
	printf("RESULT decoded=%d / %d AUs, resets=%d, %ux%u\n", got, g_stream_au,
	       resets, g_w, g_h);
	if (rend) {
		/* 收尾：把在飞的帧等回来（否则 QBUF 没还、下一段流开场少 buffer），
		 * 再以 Renderer 自己的账报一次统计 —— 两个后端同一张表。
		 */
		struct render_stats rs;
		double el;

		render_wait_shown(rend, 500);
		render_stats(rend, &rs);
		render_dump_state(&rs);	/* 结束时补上屏幕模式，上层才看得到全貌 */
		el = rs.t_last - rs.t_first;
		printf("PLAY: renderer=%s screen=%ux%u@%u src=%ux%u fps=%.2f\n",
		       rs.name, rs.dw, rs.dh, rs.refresh, rs.sw, rs.sh, g_play_fps);
		printf("PLAY: submit=%d shown=%d drop=%d abort=%d pending=%d "
		       "miss=%d late=%d(%.1fms) elapsed=%.2fs -> %.1f fps\n",
		       rs.submitted, rs.shown, rs.dropped, rs.aborted, rs.pending,
		       rs.misses, rs.late, rs.late_ms_max, el,
		       el > 0 ? rs.shown / el : 0.0);
		if (rs.draw_ms_sum > 0)
			printf("PLAY: draw avg=%.2fms max=%.2fms swap=%.2fs\n",
			       rs.draw_ms_sum / (rs.shown ? rs.shown : 1),
			       rs.draw_ms_max, rs.swap_ms_sum);
	}
	{
		/* 纯解码吞吐：只看首帧到末帧，排除启动、收尾(tail)和写盘 */
		double active = t_last_rx - t_first_rx;
		double feed = t_last_q - t_first_q;
		double decode_busy = active - t_write_acc - t_tm_acc;

		printf("SPLIT read=%.3fs qbuf=%.3fs dq=%.3fs submit=%.3fs "
		       "poll=%.3fs pump=%.3fs sleep=%.3fs(%d) frames=%d\n",
		       t_rd_acc, t_qb_acc, t_dq_acc, t_sub_acc,
		       t_poll_acc, t_pump_acc, t_slp_acc, n_slp, got);
		printf("SPLIT2 per-frame: read=%.2fms dq=%.2fms sub=%.2fms "
		       "poll=%.2fms pump=%.2fms\n",
		       t_rd_acc * 1000.0 / (got_queued ? got_queued : 1),
		       t_dq_acc * 1000.0 / (got ? got : 1),
		       t_sub_acc * 1000.0 / (got ? got : 1),
		       t_poll_acc * 1000.0 / (got ? got : 1),
		       t_pump_acc * 1000.0 / (got ? got : 1));
		if (getenv("RDSPLIT") && n_rd)
			printf("RDSPLIT per-au: total=%.2fms compact=%.2fms(%d/%d) "
			       "read=%.3fms(%d) scan=%.2fms\n",
			       t_rd_acc * 1000.0 / n_rd,
			       t_cpt_acc * 1000.0 / n_rd, n_cpt, n_rd,
			       t_fil_acc * 1000.0 / (n_rd ? n_rd : 1), n_fil,
			       (t_rd_acc - t_cpt_acc - t_fil_acc) * 1000.0 / n_rd);
		if (getenv("RDSPLIT")) {
			int i;

			for (i = 0; i < 4; i++)
				if (n_hist[i])
					printf("RDSPLIT r=%d: n=%d %.2fms/call "
					       "scan=%zuB/call\n", i - 1,
					       n_hist[i],
					       t_hist[i] * 1000.0 / n_hist[i],
					       b_hist[i] / n_hist[i]);
		}
		printf("PHASE feed=%.3fs  active=%.3fs  tail=%.3fs  write=%.3fs  eos=%d\n",
		       feed, active, wall - active - (t_first_rx - t0),
		       t_write_acc, eos_seen);
		printf("PERF decode=%.2f fps (%d frames / %.3fs)", 
		       active > 0 ? (got - 1) / active : 0.0, got - 1, active);
		if (t_tm_acc > 0.001)
			printf("PHASE tm = %.3fs (%.2f ms/frame)\n",
			       t_tm_acc, t_tm_acc * 1000.0 / (got > 0 ? got : 1));
		if (t_write_acc > 0.001)
			printf("  decode-only=%.2f fps (minus write %.3fs)",
			       decode_busy > 0 ? (got - 1) / decode_busy : 0.0,
			       t_write_acc);
		printf("\n");
		printf("PERF feed=%.2f fps (%d AUs / %.3fs)  wall=%.3fs  e2e=%.2f fps  bitstream=%.2f MB/s\n",
		       feed > 0 ? got_queued / feed : 0.0, got_queued, feed, wall,
		       wall > 0 ? got / wall : 0.0,
		       wall > 0 ? g_stream_bytes / wall / 1e6 : 0.0);
	}
	/* 退出也走同一条关闭路径（幂等）：停流、作废在飞的帧、关 dmabuf、
	 * 拆队列、close(fd)。硬复位不做——正常退出不该动硬件。 */
	vdec_close(0);
	/* 退出把控制台还回去：DRM master 释放后 fbcon 有时仍停在
	 * FB_BLANK_POWERDOWN（屏黑但 CRTC 是开的），这里主动解黑。
	 */
	{
		int bf = open("/sys/class/graphics/fb0/blank", O_WRONLY);

		if (bf >= 0) {
			if (write(bf, "0", 1) < 0) { /* 忽略 */ }
			close(bf);
		}
	}
	return got > 0 ? 0 : 2;
}
