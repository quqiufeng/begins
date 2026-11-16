// rcinputd.c — 2.4G 遥控器（evdev）→ tvplay 播放控制
//
//   rcinputd -t          dump 模式：把按键码打到 stdout（用于标定遥控器）
//   rcinputd            守护模式：按键 → exec /tmp/tvplay-node.sh key <动作>
//
// 设备自动发现：扫 /dev/input/event*，取名字里含 RC_MATCH（默认 "XING WEI"）的；
// 可用 RC_MATCH=xxx 覆盖，RC_MATCH=* 表示抓全部（含 meson-ir）。
// 打开后 EVIOCGRAB 独占，避免按键同时被 console 吃掉（光标/终端乱跳）。
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <linux/input.h>

#define MAXDEV 16
#define NODE "/tmp/tvplay-node.sh"
#define LOGF "/tmp/tvplay-rc.log"

static int dump;
static const char *last_act;
/* MSC_SCAN：接收器发的硬件扫描码。有些键内核映射不出 KEY 码（报 code=0），
 * 只能靠扫描码认人 —— 日志里带上它，标定时照着补 COMBO_SCAN 表。*/
static int last_scan;

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(LOGF, "a");
	time_t t = time(NULL);
	char tb[32];

	if (!f) return;
	strftime(tb, sizeof tb, "%H:%M:%S", localtime(&t));
	fprintf(f, "%s ", tb);
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

/* 按键码 → 名字（只收常用，未知就打数字） */
static const struct { int code; const char *name; } KN[] = {
	{KEY_PLAYPAUSE, "PLAYPAUSE"}, {KEY_PLAY, "PLAY"}, {KEY_PAUSE, "PAUSE"},
	{KEY_STOP, "STOP"}, {KEY_NEXTSONG, "NEXTSONG"}, {KEY_PREVIOUSSONG, "PREVSONG"},
	{KEY_FASTFORWARD, "FASTFWD"}, {KEY_REWIND, "REWIND"},
	{KEY_VOLUMEUP, "VOLUP"}, {KEY_VOLUMEDOWN, "VOLDN"}, {KEY_MUTE, "MUTE"},
	{KEY_LEFT, "LEFT"}, {KEY_RIGHT, "RIGHT"}, {KEY_UP, "UP"}, {KEY_DOWN, "DOWN"},
	{KEY_ENTER, "ENTER"}, {KEY_KPENTER, "KPENTER"}, {KEY_OK, "OK"},
	{KEY_BACK, "BACK"}, {KEY_ESC, "ESC"}, {KEY_EXIT, "EXIT"}, {KEY_HOMEPAGE, "HOME"},
	{KEY_POWER, "POWER"}, {KEY_MENU, "MENU"}, {KEY_INFO, "INFO"},
	{KEY_SPACE, "SPACE"}, {KEY_TAB, "TAB"},
	{KEY_1, "1"}, {KEY_2, "2"}, {KEY_3, "3"}, {KEY_4, "4"}, {KEY_5, "5"},
	{KEY_6, "6"}, {KEY_7, "7"}, {KEY_8, "8"}, {KEY_9, "9"}, {KEY_0, "0"},
	{KEY_PAGEUP, "PGUP"}, {KEY_PAGEDOWN, "PGDN"},
	{KEY_CHANNELUP, "CHUP"}, {KEY_CHANNELDOWN, "CHDN"},
	{KEY_SUBTITLE, "SUBTITLE"}, {KEY_AUDIO, "AUDIO"},
	{KEY_F1, "F1"}, {KEY_F2, "F2"}, {KEY_F3, "F3"}, {KEY_F4, "F4"},
	{KEY_CONFIG, "CONFIG"}, {KEY_BLUETOOTH, "BT"}, {KEY_RED, "RED"},
	{KEY_GREEN, "GREEN"}, {KEY_YELLOW, "YELLOW"}, {KEY_BLUE, "BLUE"},
	{KEY_REFRESH, "REFRESH"}, {KEY_ZOOM, "ZOOM"}, {KEY_TEXT, "TEXT"},
	{KEY_EPG, "EPG"}, {KEY_TITLE, "TITLE"}, {KEY_MODE, "MODE"},
};

static const char *kname(int code)
{
	static char buf[24];
	size_t i;

	for (i = 0; i < sizeof KN / sizeof KN[0]; i++)
		if (KN[i].code == code) return KN[i].name;
	snprintf(buf, sizeof buf, "K%d", code);
	return buf;
}

/* 修饰键位（遥控器是键盘模式：媒体键发 Ctrl+数字 组合）
 * 1=CTRL 2=SHIFT 4=ALT
 */
static int mods;

#define M_CTRL	1
#define M_SHIFT	2
#define M_ALT	4

static int mod_of(int code)
{
	switch (code) {
	case KEY_LEFTCTRL: case KEY_RIGHTCTRL: return M_CTRL;
	case KEY_LEFTSHIFT: case KEY_RIGHTSHIFT: return M_SHIFT;
	case KEY_LEFTALT: case KEY_RIGHTALT: return M_ALT;
	}
	return 0;
}

/* 组合键码表：mods + code → 动作。实测这台遥控器（XING WEI 2.4G，图见 docs/remote.md）
 * 上排 5 个功能键 = Ctrl+1..Ctrl+5：首页/静音/菜单/音量+/音量-
 * 注意：它们不是 KEY_HOMEPAGE/KEY_MUTE 等标准媒体键，接收器发的是 Ctrl+数字。
 *
 * 首页键（Ctrl+1）按需求「不响应」，故不登记：它会落到 action_of 的 switch
 * 之外返回 NULL，只记一行「忽略」日志，不产生任何动作。
 */
static const struct { int mods; int code; const char *act; } COMBO[] = {
	{ M_CTRL, KEY_2, "mute"   },	/* 🔇静音  Ctrl+2 */
	{ M_CTRL, KEY_3, "menu"   },	/* ≡ 菜单  Ctrl+3 */
	{ M_CTRL, KEY_4, "volup"  },	/* 🔊+     Ctrl+4 */
	{ M_CTRL, KEY_5, "voldn"  },	/* 🔊-     Ctrl+5 */
	{ 0,      KEY_ENTER, "toggle" },	/* OK 兼播放/暂停（无独立播放键）*/
	{ 0,      KEY_UP,     "fwdmore"  },
	{ 0,      KEY_DOWN,   "backmore" },
	{ 0,      KEY_RIGHT,  "fwd"      },
	{ 0,      KEY_LEFT,   "back"     },
};

/* 扫描码 → 动作（内核给不出 KEY 码的键走这里）。按 docs/remote.md 标定后填。 */
static const struct { int scan; const char *act; } COMBO_SCAN[] = {
	{ 0, NULL }
};

/* 按键 → 动作名（空 = 不处理）。tvplay-node.sh key 里对同名动作实现。
 * 长按（value==2）只对 FASTFWD/BACK 生效，且节流到 1 秒一次。
 */
static const char *action_of(int code)
{
	size_t ci;

	for (ci = 0; ci < sizeof COMBO / sizeof COMBO[0]; ci++)
		if (COMBO[ci].mods == mods && COMBO[ci].code == code)
			return COMBO[ci].act;

	switch (code) {
	case KEY_PLAYPAUSE: case KEY_PLAY: case KEY_PAUSE:
	case KEY_ENTER: case KEY_KPENTER: case KEY_OK: case KEY_SPACE:
		return "toggle";
	case KEY_RIGHT: case KEY_FASTFORWARD: case KEY_NEXTSONG:
		return "fwd";
	case KEY_LEFT: case KEY_REWIND: case KEY_PREVIOUSSONG:
		return "back";
	case KEY_UP: case KEY_PAGEUP:
		return "fwdmore";
	case KEY_DOWN: case KEY_PAGEDOWN:
		return "backmore";
	case KEY_VOLUMEUP:
		return "volup";
	case KEY_VOLUMEDOWN:
		return "voldn";
	case KEY_MUTE:
		return "mute";
	case KEY_STOP: case KEY_BACK: case KEY_ESC: case KEY_EXIT: case KEY_HOMEPAGE:
		return "quit";
	}
	return NULL;
}

static int open_dev(const char *path, const char *match)
{
	char nm[256] = "";
	int fd = open(path, O_RDONLY | O_NONBLOCK);

	if (fd < 0) return -1;
	if (ioctl(fd, EVIOCGNAME(sizeof nm), nm) < 0) nm[0] = 0;
	if (match && strcmp(match, "*") && !strstr(nm, match)) {
		close(fd);
		return -1;
	}
	if (!getenv("RC_NOGRAB") && ioctl(fd, EVIOCGRAB, 1) < 0)
		logmsg("WARN grab %s(%s) 失败: %s（继续只读）", path, nm, strerror(errno));
	return fd;
}

int main(int argc, char **argv)
{
	const char *match = getenv("RC_MATCH");
	int fds[MAXDEV], n = 0, i;
	struct dirent *de;
	DIR *d;
	time_t last = 0;
	const char *act;

	if (argc > 1 && !strcmp(argv[1], "-t")) dump = 1;
	if (argc > 1 && !strcmp(argv[1], "-T")) dump = 2;
	if (!match) match = "XING WEI";

	d = opendir("/dev/input");
	if (!d) { perror("opendir /dev/input"); return 1; }
	while ((de = readdir(d)) && n < MAXDEV) {
		char p[512];
		int fd;

		if (strncmp(de->d_name, "event", 5)) continue;
		snprintf(p, sizeof p, "/dev/input/%s", de->d_name);
		fd = open_dev(p, match);        /* 名字不匹配的在这里关掉 */
		/* 必须 CLOEXEC：rcinputd 每按一次键都 fork+exec 播放助手，
		 * 播放链（ffmpeg / hevcplay）会继承设备 fd，从而一直持有
		 * EVIOCGRAB。守护进程重启后新实例 grab 全部 EBUSY，
		 * 而真正持锁的播放进程从不 read → 按键全被丢进没人读的
		 * 缓冲区，表现就是"遥控按键无用"。*/
		if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
		if (fd < 0) continue;
		fds[n++] = fd;
		if (!dump) logmsg("open %s", p);
		else { printf("# open %s\n", p); fflush(stdout); }
	}
	closedir(d);
	if (!n) { fprintf(stderr, "没有匹配的输入设备 (match=%s)\n", match); return 1; }
	if (!dump) fflush(NULL);

	for (;;) {
		fd_set rs;
		int mx = -1, r;

		FD_ZERO(&rs);
		for (i = 0; i < n; i++) { FD_SET(fds[i], &rs); if (fds[i] > mx) mx = fds[i]; }
		r = select(mx + 1, &rs, NULL, NULL, NULL);
		if (r <= 0) continue;
		for (i = 0; i < n; i++) {
			struct input_event ev[64];
			ssize_t len, k;

			if (!FD_ISSET(fds[i], &rs)) continue;
			len = read(fds[i], ev, sizeof ev);
			if (len <= 0) continue;
			for (k = 0; k < len / (ssize_t)sizeof ev[0]; k++) {
				if (dump) {
					if (ev[k].type == EV_SYN) { fflush(stdout); continue; }
					if (ev[k].type == EV_KEY) {
						struct timeval tv;

						gettimeofday(&tv, NULL);
						printf("%ld.%03ld dev%d KEY code=%-4d %-12s val=%d\n",
						       (long)tv.tv_sec, (long)tv.tv_usec / 1000,
						       i, ev[k].code, kname(ev[k].code), ev[k].value);
					}
					else if (dump > 1)
						printf("dev%d type=%d code=%d val=%d\n",
						       i, ev[k].type, ev[k].code, ev[k].value);
					fflush(stdout);
					continue;
				}
				if (ev[k].type == EV_MSC && ev[k].code == MSC_SCAN) {
					last_scan = ev[k].value;
					continue;
				}
				if (ev[k].type != EV_KEY) continue;
				if (ev[k].value == 0) continue;
				{
					int m = mod_of(ev[k].code);

					if (m) {
						if (ev[k].value) mods |= m;
						else mods &= ~m;
						continue;
					}
				}
				/* 这块板子的遥控器有些键会报出离谱的 value
				 * （如 code=4 val=458976，把菜单键刷成连发），只认 1/2 */
				if (ev[k].value > 2) continue;
				act = action_of(ev[k].code);
				if (!act) {
					size_t si;

					for (si = 0; si < sizeof COMBO_SCAN / sizeof COMBO_SCAN[0]; si++)
						if (COMBO_SCAN[si].act && COMBO_SCAN[si].scan == last_scan)
							{ act = COMBO_SCAN[si].act; break; }
				}
				if (!act) {
					logmsg("key %s(%d) mods=%d scan=0x%x val=%d → 忽略",
					       kname(ev[k].code), ev[k].code,
					       mods, last_scan, ev[k].value);
					continue;
				}
				/* OK 只认按下那一下：长按连发会把 toggle 来回
				 * 反复触发（实测一次长按有 4~5 个 val=2）*/
				if (ev[k].value == 2 && !strcmp(act, "toggle"))
					continue;
				/* 长按连发只压同一动作；换键（比如音量+ → 音量−）
				 * 不能被上一键的时间戳吃掉 */
				if (ev[k].value == 2 && act == last_act &&
				    time(NULL) == last)
					continue;
				logmsg("key %s(%d) mods=%d scan=0x%x val=%d → %s",
				       kname(ev[k].code), ev[k].code, mods,
				       last_scan, ev[k].value, act);
				last = time(NULL);
				last_act = act;
				if (!fork()) {
					char a[32];
					int j;

					snprintf(a, sizeof a, "%s", act);
					setsid();
					/* 双保险：CLOEXEC 之外再显式关掉，别让
					 * 播放链继承设备 fd 把 grab 带走 */
					for (j = 3; j < 256; j++) close(j);
					execl(NODE, NODE, "key", a, (char *)NULL);
					_exit(127);
				}
				wait(NULL);
			}
		}
	}
	return 0;
}
