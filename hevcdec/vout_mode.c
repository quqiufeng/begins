/* vout_mode.c —— 显示能力探测 + 输出模式协商（两个纯函数，一个碰 fd 一个不碰）
 *
 * 为什么值得从 vout.c 里拆出来：
 *   1) 写死 2560x1440@60 只对开发机上那台唯一模式的显示器成立。接电视
 *      （1080p / 4K / PAL 50Hz 混杂）时，"找不到就退化为最大面积"会把
 *      选择权交给 EDID 顺序，结果不可预期也没法复现。
 *   2) 「屏幕支持什么」是硬事实（EDID），「输出什么」是策略（可配置）。
 *      两件事写在一个 40 行的循环里，改策略时会顺手改坏探测。
 *   3) 探测要能在桌面在跑时安全执行（只读），协商要能脱离设备单测（纯函数）。
 *
 * 这里不写 CRTC、不建 fb、不碰 plane —— 只读+算。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#include "vout_mode.h"

#define LOG(fmt, ...) fprintf(stderr, "VMODE: " fmt "\n", ##__VA_ARGS__)

/* ---------- 显示能力探测（只读） ---------- */

static const char *conn_type_name(uint32_t t)
{
	static const char *n[] = {
		"Unknown", "VGA", "DVI-I", "DVI-D", "DVI-A", "Composite",
		"SVIDEO", "LVDS", "Component", "DIN", "DP", "HDMI-A", "HDMI-B",
		"TV", "eDP", "Virtual", "DSI", "DPI", "Writeback", "SPI", "USB-C",
	};
	return t < sizeof(n) / sizeof(n[0]) ? n[t] : "Connector";
}

/* 只读：挑一台真连着的显示器，把它的模式表摊平。
 *
 * 排序规则（三条，都是踩过的坑）：
 *   connected  必须只认 status=CONNECTED。X96 的 card0 上 Composite-1（CVBS，
 *              status=unknown）排在 HDMI-A-1 前面且带 720x576i/480i 模式，
 *              只看 count_modes 会选中它 → 输出 720x576@50、HDMI 全黑、
 *              vout 队列瞬间堵死（"queue full, drop"）。
 *   有模式     没有 EDID 的 connector（CVBS 常如此）count_modes=0，跳过。
 *   CRTC       encoder 绑着就用它绑的；没绑就借第一块 CRTC（probe 不改它）。
 */
int vout_display_probe(int dfd, struct vout_display *d)
{
	static uint32_t crtcs[16], conns[32];
	static struct drm_mode_modeinfo modes[VOUT_DISP_MODES];
	struct drm_mode_card_res res = {0};
	uint32_t i, ncrtc;
	int got = 0;

	if (!d) return -1;
	memset(d, 0, sizeof(*d));

	res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
	res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
	res.count_connectors = 32;
	if (ioctl(dfd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
		LOG("GETRESOURCES 失败: %s", strerror(errno));
		return -1;
	}
	ncrtc = res.count_crtcs > 16 ? 16 : res.count_crtcs;

	for (i = 0; i < res.count_connectors && i < 32 && !got; i++) {
		struct drm_mode_get_connector gc = {0};
		struct drm_mode_get_encoder ge = {0};
		struct drm_mode_crtc crtc = {0};
		uint32_t encs[16] = {0}, enc_id;
		int j, n;

		gc.connector_id = conns[i];
		gc.modes_ptr = (uint64_t)(uintptr_t)modes;
		gc.count_modes = VOUT_DISP_MODES;
		gc.encoders_ptr = (uint64_t)(uintptr_t)encs;
		gc.count_encoders = 16;
		if (ioctl(dfd, DRM_IOCTL_MODE_GETCONNECTOR, &gc) < 0)
			continue;
		/* 内核 uapi 只给裸数字（libdrm 才定义 DRM_MODE_CONNECTED=1），
		 * 这里不要引入 libdrm：vout 整条路径都是裸 ioctl。 */
		if (gc.connection != 1 /* DRM_MODE_CONNECTED */ || !gc.count_modes)
			continue;

		n = gc.count_modes > VOUT_DISP_MODES ? VOUT_DISP_MODES
						     : (int)gc.count_modes;
		d->conn_id = conns[i];
		d->nmode = n;
		memcpy(d->modes, modes, (size_t)n * sizeof(modes[0]));
		snprintf(d->name, sizeof(d->name), "%s-%u",
			 conn_type_name(gc.connector_type),
			 gc.connector_type_id);

		/* 优先用 connector 此刻绑着的 encoder；没绑就借第一个能用的，
		 * 只是为了让 vout 能拿到 CRTC，不代表要动它的绑定。 */
		enc_id = gc.encoder_id ? gc.encoder_id : gc.count_encoders ? encs[0] : 0;
		d->enc_id = enc_id;
		if (enc_id) {
			ge.encoder_id = enc_id;
			if (ioctl(dfd, DRM_IOCTL_MODE_GETENCODER, &ge) == 0)
				d->crtc_id = ge.crtc_id;
			if (!d->crtc_id && ge.possible_crtcs)
				for (j = 0; j < (int)ncrtc; j++)
					if (ge.possible_crtcs & (1u << j)) {
						d->crtc_id = crtcs[j];
						break;
					}
		}
		/* 兜底：借第一块，probe 只是"看看"，不动 CRTC 状态 */
		if (!d->crtc_id && ncrtc) d->crtc_id = crtcs[0];
		for (j = 0; j < (int)ncrtc; j++)
			if (crtcs[j] == d->crtc_id) d->crtc_idx = (uint32_t)j;

		/* 当前模式：auto 策略下"别动屏幕"的依据。GETCRTC 是只读的。 */
		if (d->crtc_id) {
			crtc.crtc_id = d->crtc_id;
			if (ioctl(dfd, DRM_IOCTL_MODE_GETCRTC, &crtc) == 0 &&
			    crtc.mode_valid && crtc.mode.hdisplay) {
				d->has_cur = 1;
				d->cur = crtc.mode;
			}
		}
		got = 1;
	}

	if (!got) {
		LOG("没有已连接且有 mode 的显示设备");
		return -1;
	}
	return 0;
}

/* ---------- 输出模式协商（纯函数） ---------- */

const char *vout_mode_src_name(enum vout_mode_src s)
{
	switch (s) {
	case VOUT_SRC_EXACT:	return "请求精确命中";
	case VOUT_SRC_SIZE:	return "尺寸命中，刷新自选";
	case VOUT_SRC_REFRESH:	return "尺寸命中，刷新改选最近的";
	case VOUT_SRC_CURRENT:	return "auto，跟随屏幕当前模式";
	case VOUT_SRC_PREFERRED:return "auto，EDID 首选模式";
	case VOUT_SRC_LARGEST:	return "兜底，最大面积";
	case VOUT_SRC_FIRST:	return "兜底，EDID 第一条";
	}
	return "?";
}

int vout_mode_fmt(const struct drm_mode_modeinfo *m, char *buf, int cap)
{
	if (!m || !buf || cap <= 0) return 0;
	return snprintf(buf, (size_t)cap, "%ux%u%s@%u",
			m->hdisplay, m->vdisplay,
			(m->flags & DRM_MODE_FLAG_INTERLACE) ? "i" : "",
			m->vrefresh);
}

/* 常见分辨率别名，纯粹为了 shell 里少打字。 */
static const struct { const char *k; int w, h; } aliases[] = {
	{ "480p",   720,  480 },
	{ "576p",   720,  576 },
	{ "720p",  1280,  720 },
	{ "1080p", 1920, 1080 },
	{ "1440p", 2560, 1440 },
	{ "2160p", 3840, 2160 },
	{ "4k",    3840, 2160 },
};

/* 0 = auto 类关键字，1 = 解析出尺寸，-1 = 语法错（why 已填） */
static int parse_req(const char *req, int *w, int *h, int *r,
		     char *why, size_t cap)
{
	char buf[64];
	const char *at;
	char *end;
	unsigned int a, b, c;
	size_t n;

	*w = *h = *r = 0;
	if (!req || !*req) return 0;

	if (strlen(req) >= sizeof(buf)) goto bad;
	snprintf(buf, sizeof(buf), "%s", req);

	/* 先切 @R，再认左边：别名和 WxH 都要能用 "2160p@50" 这种写法。
	 * 以前别名走的是整串 strcasecmp，于是 "2160p@50" 被判语法错。 */
	at = strchr(buf, '@');
	c = 0;
	if (at) {
		*((char *)at) = '\0';
		if (sscanf(at + 1, "%u", &c) != 1 || c == 0) goto bad;
	}

	for (n = 0; n < sizeof(aliases) / sizeof(aliases[0]); n++)
		if (!strcasecmp(buf, aliases[n].k)) {
			*w = aliases[n].w;
			*h = aliases[n].h;
			*r = (int)c;
			return 1;
		}

	end = NULL;
	a = (unsigned int)strtoul(buf, &end, 10);
	if (!end || (*end != 'x' && *end != 'X')) goto bad;
	b = (unsigned int)strtoul(end + 1, &end, 10);
	if (!end || *end != '\0') goto bad;
	if (!a || !b || a > 8192 || b > 8192) goto bad;

	*w = (int)a;
	*h = (int)b;
	*r = (int)c;
	return 1;
bad:
	snprintf(why, cap, "VOUT_MODE=%s 语法不认识（要 auto / WxH / WxH@R / 1080p）", req);
	return -1;
}

/* 在模式表里找 WxH，target_r 是想靠近的刷新率：
 *   exact=1  必须 vrefresh == target_r
 *   exact=0  取 |vrefresh - target_r| 最小的
 * 评分里还加了"逐行优先"（+100 惩罚交错）：电视 EDID 里 1080p50 和
 * 1080i50 并存，交错是给广播的，播放器要逐行。
 *
 * target_r 必须来自"请求"（请求没给刷新才用 60 当锚），不能一律锚 60：
 * 24p 素材要 1080p@30 时，锚 60 会选到 60Hz（3:2 抖动），锚 30 才选 50。
 */
static int find_size(const struct vout_display *d, int w, int h,
		     int target_r, int exact)
{
	int i, best = -1, best_score = 1 << 30;

	for (i = 0; i < d->nmode; i++) {
		const struct drm_mode_modeinfo *m = &d->modes[i];
		int score;

		if (m->hdisplay != w || m->vdisplay != h) continue;
		if (exact && (int)m->vrefresh != target_r) continue;
		score = abs((int)m->vrefresh - target_r);
		if (m->flags & DRM_MODE_FLAG_INTERLACE) score += 100;
		if (score < best_score) { best_score = score; best = i; }
	}
	return best;
}

/* 最大面积（宽度限 4096：防 EDID 里塞了 8K 却跑不动）。返回下标或 -1。 */
static int find_largest(const struct vout_display *d)
{
	int i, best = -1;
	uint32_t area = 0;

	for (i = 0; i < d->nmode; i++) {
		const struct drm_mode_modeinfo *m = &d->modes[i];
		uint32_t a;

		if (m->hdisplay > 4096) continue;
		a = m->hdisplay * m->vdisplay;
		if (a > area) { area = a; best = i; }
	}
	return best;
}

/* 失败时列几条屏幕真支持的，让日志直接能定位（不用再跑 drmprobe）。 */
static void supported_hint(const struct vout_display *d, char *buf, size_t cap)
{
	int i, shown = 0;
	size_t off = 0;

	off += (size_t)snprintf(buf, cap, "屏幕只报 %d 条:", d->nmode);
	for (i = 0; i < d->nmode && shown < 4 && off < cap; i++) {
		int j, dup = 0;
		char one[48];

		for (j = 0; j < i; j++)
			if (d->modes[j].hdisplay == d->modes[i].hdisplay &&
			    d->modes[j].vdisplay == d->modes[i].vdisplay) {
				dup = 1;
				break;
			}
		if (dup) continue;
		vout_mode_fmt(&d->modes[i], one, sizeof(one));
		off += (size_t)snprintf(buf + off, cap - off, " %s", one);
		shown++;
	}
}

static void set_choice(struct vout_mode_choice *out, const struct vout_display *d,
		       int idx, enum vout_mode_src src, const char *what)
{
	char one[48];

	out->mode = d->modes[idx];
	out->src = src;
	vout_mode_fmt(&out->mode, one, sizeof(one));
	snprintf(out->why, sizeof(out->why), "%s → %s（%s）",
		 what, one, vout_mode_src_name(src));
}

int vout_mode_negotiate(const struct vout_display *d, const char *req,
			struct vout_mode_choice *out)
{
	int w, h, r, idx;
	char why[160] = "";
	int kind;

	if (!d || !out) return -1;
	memset(out, 0, sizeof(*out));
	if (d->nmode <= 0) {
		snprintf(out->why, sizeof(out->why), "显示设备没有上报任何模式");
		return -1;
	}

	/* 三个策略关键字，其余按尺寸解析 */
	if (req && (!strcasecmp(req, "auto") || !*req)) req = NULL;
	if (req && !strcasecmp(req, "preferred")) {
		set_choice(out, d, 0, VOUT_SRC_PREFERRED, "VOUT_MODE=preferred");
		return 0;
	}
	if (req && (!strcasecmp(req, "max") || !strcasecmp(req, "largest"))) {
		idx = find_largest(d);
		if (idx < 0) idx = 0;
		set_choice(out, d, idx, VOUT_SRC_LARGEST, "VOUT_MODE=max");
		return 0;
	}

	if (!req) {			/* auto：屏幕说了算 */
		if (d->has_cur) {
			char one[48];

			out->mode = d->cur;
			out->src = VOUT_SRC_CURRENT;
			vout_mode_fmt(&out->mode, one, sizeof(one));
			snprintf(out->why, sizeof(out->why),
				 "auto 跟随屏幕当前模式 → %s（%s）", one,
				 vout_mode_src_name(out->src));
		} else {
			set_choice(out, d, 0, VOUT_SRC_PREFERRED, "auto");
		}
		return 0;
	}

	kind = parse_req(req, &w, &h, &r, why, sizeof(why));
	if (kind < 0) {
		snprintf(out->why, sizeof(out->why), "%s", why);
		return -1;
	}
	if (kind == 0) {		/* 理论上不会走到（前面已处理空串） */
		set_choice(out, d, 0, VOUT_SRC_PREFERRED, "auto");
		return 0;
	}

	/* 1) 尺寸命中：R 给了就精确要，没给就按 60Hz 挑（60 是显示器默认档） */
	if (r > 0) {
		idx = find_size(d, w, h, r, 1);
		if (idx >= 0) {
			set_choice(out, d, idx, VOUT_SRC_EXACT, req);
			return 0;
		}
		/* 2) 刷新率不对 → 仍以请求的 R 为锚挑最近的（电视常只有 50/60） */
		idx = find_size(d, w, h, r, 0);
		if (idx >= 0) {
			set_choice(out, d, idx, VOUT_SRC_REFRESH, req);
			return 0;
		}
	} else {
		idx = find_size(d, w, h, 60, 0);
		if (idx >= 0) {
			set_choice(out, d, idx, VOUT_SRC_SIZE, req);
			return 0;
		}
	}

	/* 3) 屏幕压根没有这个尺寸：不硬上，把事实摆出来交给调用方。
	 * 两边都截断到位（req 24 字符、提示 96），免得 why 被 snprintf 悄悄
	 * 砍掉后半截——那行日志正是用来定位问题的。 */
	{
		char hint[96];

		supported_hint(d, hint, sizeof(hint));
		snprintf(out->why, sizeof(out->why),
			 "屏幕不支持 %.24s；%s", req, hint);
	}
	return -1;
}

/* ---------- 一句话查询：壳和播放器共用同一套 probe+negotiate ----------
 *
 * 只读 fd 就够：probe 全是 GET*，negotiate 是纯函数。所以桌面在跑、或者
 * 播放器已经占着 master 的时候问一句也安全（不会抢 master、不动 CRTC）。
 */
int vout_mode_query(const char *dev, const char *req, char *buf, int cap)
{
	struct vout_display d;
	struct vout_mode_choice mc, alt;
	const char *p = dev && *dev ? dev : "/dev/dri/card0";
	int dfd, ret = -1;

	if (!buf || cap <= 0) return -1;
	buf[0] = '\0';
	if (!req) req = getenv("VOUT_MODE");

	dfd = open(p, O_RDONLY | O_CLOEXEC);
	if (dfd < 0) {
		LOG("打开 %s 失败: %s", p, strerror(errno));
		return -1;
	}
	if (vout_display_probe(dfd, &d) < 0) goto out;

	if (vout_mode_negotiate(&d, req, &mc) < 0) {
		/* 和 vout_open 一样的降级语义：问不出就按显示设备说了算答，
		 * 但把「为什么不按你说的来」照原话打出去。 */
		LOG("%s", mc.why);
		if (vout_mode_negotiate(&d, NULL, &alt) < 0) {
			LOG("%s", alt.why);
			goto out;
		}
		LOG("降级 → %s", alt.why);
		mc = alt;
	}
	vout_mode_fmt(&mc.mode, buf, cap);
	/* stdout 只给机器读的 WxH@R，人话一律 stderr，壳可以直接 $(...) 取值 */
	LOG("%s 输出 %s（%s）", d.name, buf, mc.why);
	ret = 0;
out:
	close(dfd);
	return ret;
}

/* ---------- 输出几何落盘：两条上屏路径共用的"事实出口" ---------- */
int vout_geo_publish(const char *geo)
{
	const char *p = getenv("VOUT_GEO_FILE");
	char tmp[128];
	FILE *f;

	if (!geo || !*geo) return -1;
	if (!p || !*p) p = "/tmp/vout-geo";
	if (snprintf(tmp, sizeof(tmp), "%s.tmp", p) >= (int)sizeof(tmp)) return -1;
	f = fopen(tmp, "w");
	if (!f) return -1;
	fprintf(f, "%s\n", geo);
	if (fclose(f) != 0) { unlink(tmp); return -1; }
	if (rename(tmp, p) < 0) { unlink(tmp); return -1; }
	return 0;
}
