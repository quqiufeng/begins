/* vout-mode-test.c —— 协商逻辑的离线单测（不需要 /dev/dri，不需要盒子）
 *
 * negotiate 是纯函数：喂一张假的模式表就能验策略。这正是把它从 vout_open
 * 里拆出来的好处——以前"换个电视会选成什么"只能在真机上试。
 *
 * 造的表覆盖三种真实场景：
 *   mon   开发机：单模式 2560x1440@60
 *   tv    4K 电视：4K/1080p/720p，含 50Hz 和 1080i（广播 EDID 的典型样子）
 *   tv1080 只支持 1080p 的老电视
 *
 * 用法：./modetest     全过打印 PASS，有一条不对就以非零退出
 */
#include <stdio.h>
#include <string.h>
#include <drm/drm_mode.h>
#include "vout_mode.h"

static int fails;

static struct drm_mode_modeinfo mk(int w, int h, int r, int flags)
{
	struct drm_mode_modeinfo m;

	memset(&m, 0, sizeof(m));
	m.hdisplay = (uint16_t)w;
	m.vdisplay = (uint16_t)h;
	m.vrefresh = (uint32_t)r;
	m.flags = (uint32_t)flags;
	return m;
}

static struct vout_display disp_of(const char *name,
				   const struct drm_mode_modeinfo *ms, int n,
				   int has_cur)
{
	struct vout_display d;

	memset(&d, 0, sizeof(d));
	snprintf(d.name, sizeof(d.name), "%s", name);
	d.conn_id = 1;
	d.crtc_id = 1;
	d.nmode = n;
	memcpy(d.modes, ms, (size_t)n * sizeof(ms[0]));
	if (has_cur) {
		d.has_cur = 1;
		d.cur = ms[0];
	}
	return d;
}

/* 期望：返回值、宽、高、刷新、来源、以及 why 里必须出现的子串之一 */
static void expect(const char *tag, const struct vout_display *d,
		   const char *req, int rc,
		   int w, int h, int r, enum vout_mode_src src)
{
	struct vout_mode_choice c;
	int got = vout_mode_negotiate(d, req, &c);
	int ok = 1;

	if (got != rc) ok = 0;
	if (rc == 0) {
		if ((int)c.mode.hdisplay != w || (int)c.mode.vdisplay != h ||
		    (int)c.mode.vrefresh != r) ok = 0;
		if (src != (enum vout_mode_src)-1 && c.src != src) ok = 0;
	}
	printf("%-4s %-28s %-18s rc=%d %s", ok ? "ok" : "FAIL", tag,
	       req ? req : "(null)", got,
	       rc == 0 ? "" : "(被拒绝)");
	if (rc == 0)
		printf(" → %ux%u@%u %s", c.mode.hdisplay, c.mode.vdisplay,
		       c.mode.vrefresh, vout_mode_src_name(c.src));
	printf("\n     why: %s\n", c.why);
	if (!ok) {
		fails++;
		if (rc == 0)
			printf("     期望 %dx%d@%d (src=%d)\n", w, h, r, (int)src);
	}
}

int main(void)
{
	struct drm_mode_modeinfo mon[] = {
		mk(2560, 1440, 60, 0),
	};
	struct drm_mode_modeinfo tv[] = {
		mk(3840, 2160, 60, 0),
		mk(3840, 2160, 50, 0),
		mk(1920, 1080, 60, 0),
		mk(1920, 1080, 50, 0),
		mk(1920, 1080, 50, DRM_MODE_FLAG_INTERLACE),
		mk(1280, 720, 60, 0),
		mk(720, 480, 60, DRM_MODE_FLAG_INTERLACE),
	};
	struct drm_mode_modeinfo tv1080[] = {
		mk(1920, 1080, 60, 0),
		mk(1280, 720, 60, 0),
	};
	struct vout_display dmon = disp_of("HDMI-A-1", mon, 1, 0);
	struct vout_display dtv = disp_of("HDMI-A-1", tv, 7, 0);
	struct vout_display dtv_on = disp_of("HDMI-A-1", tv, 7, 1);
	struct vout_display d1080 = disp_of("HDMI-A-1", tv1080, 2, 0);

	printf("== mon：开发机单模式 2560x1440@60 ==\n");
	expect("auto 无当前模式", &dmon, NULL, 0, 2560, 1440, 60,
	       VOUT_SRC_PREFERRED);
	expect("显式精确", &dmon, "2560x1440@60", 0, 2560, 1440, 60,
	       VOUT_SRC_EXACT);
	expect("只给尺寸", &dmon, "2560x1440", 0, 2560, 1440, 60,
	       VOUT_SRC_SIZE);
	expect("不支持 1080p", &dmon, "1920x1080", -1, 0, 0, 0, (enum vout_mode_src)-1);

	printf("\n== tv：4K 电视，含 50Hz/交错 ==\n");
	expect("auto 跟随当前(4K60)", &dtv_on, NULL, 0, 3840, 2160, 60,
	       VOUT_SRC_CURRENT);
	expect("auto 无当前→EDID 首选", &dtv, "auto", 0, 3840, 2160, 60,
	       VOUT_SRC_PREFERRED);
	expect("preferred 忽略当前", &dtv_on, "preferred", 0, 3840, 2160, 60,
	       VOUT_SRC_PREFERRED);
	expect("max", &dtv_on, "max", 0, 3840, 2160, 60, VOUT_SRC_LARGEST);
	expect("1080p 别名→逐行 60", &dtv, "1080p", 0, 1920, 1080, 60,
	       VOUT_SRC_SIZE);
	expect("1080p@50 精确", &dtv, "1920x1080@50", 0, 1920, 1080, 50,
	       VOUT_SRC_EXACT);
	expect("1080p@30 改选最近的", &dtv, "1920x1080@30", 0, 1920, 1080, 50,
	       VOUT_SRC_REFRESH);
	expect("720p", &dtv, "720p", 0, 1280, 720, 60, VOUT_SRC_SIZE);
	expect("4k 别名", &dtv, "4k", 0, 3840, 2160, 60, VOUT_SRC_SIZE);
	expect("2160p@50", &dtv, "2160p@50", 0, 3840, 2160, 50,
	       VOUT_SRC_EXACT);

	printf("\n== tv1080：只支持 1080p/720p ==\n");
	expect("要 1440p → 拒绝并列出支持项", &d1080, "2560x1440", -1,
	       0, 0, 0, (enum vout_mode_src)-1);
	expect("auto 有救", &d1080, "auto", 0, 1920, 1080, 60,
	       VOUT_SRC_PREFERRED);

	printf("\n== 语法与空表 ==\n");
	expect("乱写", &dtv, "1920x", -1, 0, 0, 0, (enum vout_mode_src)-1);
	expect("刷新为 0", &dtv, "1920x1080@0", -1, 0, 0, 0, (enum vout_mode_src)-1);
	{
		struct vout_display empty = disp_of("HDMI-A-1", tv, 0, 0);
		expect("没有模式", &empty, NULL, -1, 0, 0, 0,
		       (enum vout_mode_src)-1);
	}

	printf("\n%s（失败 %d 条）\n", fails ? "FAILED" : "PASS", fails);
	return fails ? 1 : 0;
}
