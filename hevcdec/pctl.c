/* pctl.c — 播放器内置控制面：/tmp/play.sock 命令口 + evdev 遥控。
 *
 * 以前这是两个独立二进制：
 *   mpvctl   → 给 mpv 的 --input-ipc-server 发一行（音量/静音/位置）
 *   rcinputd → 常驻守护，按键后 fork+exec `play.sh key <动作>`
 * 现在播放器自己就是唯一常驻进程，两件事都收进来：
 *   - 控制口由播放器自己 listen，play.sh 用 `player -c <命令>` 访问；
 *   - 按键在进程内直接变成动作：暂停/音量/静音就地生效（不重启链路），
 *     只有 seek 和退出要整链重开，才回调 play.sh（它才是拼管道的人）。
 *
 * 为什么 pause 不再用 SIGSTOP 冻进程组：冻住时 CLOCK_MONOTONIC 照走，
 * 主循环还得出代码去扣掉冻结时长（v4l2hevc.c 里那段 4s 判定就是补丁）。
 * 现在是主循环自带暂停态，时间轴由播放器自己平移，音频由 aout 停写。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/input.h>

#include "aout.h"
#include "pctl.h"

#define RC_LOGF "/tmp/play.rc.log"
#define MAXDEV 16

static const char *g_sock = "/tmp/play.sock";
static const char *g_play_sh = "/tmp/play.sh";
static volatile int g_paused;
static volatile int g_mute;
static int g_saved_vol = 100;		/* 静音前的音量，取消静音要还原 */
static double g_pause_acc, g_pause_t0;	/* 暂停累计秒：播放器时间轴要平移 */
static volatile int g_quit;
static int g_lfd = -1;

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static long (*g_pos_ms)(void);
static int  (*g_au)(void);

/* ---------- 观测值 ---------- */

void pctl_set_sources(long (*pos_ms)(void), int (*au)(void))
{
	g_pos_ms = pos_ms;
	g_au = au;
}

int pctl_paused(void) { return g_paused; }

/* 累计暂停秒（暂停中也在长）。播放器把它加回时间轴原点，
 * 于是 resume 后节拍不会把暂停期间"欠"的帧一次性补放。 */
double pctl_pause_seconds(void)
{
	return g_pause_acc + (g_paused ? now_s() - g_pause_t0 : 0.0);
}

static long pos_now(void) { return g_pos_ms ? g_pos_ms() : 0; }
static int  au_now(void)  { return g_au ? g_au() : 0; }

static void set_paused(int on)
{
	if (g_paused == on) return;
	if (on)
		g_pause_t0 = now_s();
	else
		g_pause_acc += now_s() - g_pause_t0;
	g_paused = on;
	aout_set_paused(on);
	if (getenv("VERBOSE"))
		printf("PCTL: %s\n", on ? "pause" : "resume");
}

/* ---------- 动作：能就地做的就地做，要重开链路的交给 play.sh ---------- */

static void run_play_sh(const char *act)
{
	pid_t p = fork();

	if (p < 0) return;
	if (p == 0) {
		int j;

		setsid();
		/* 遥控设备的 fd 绝不能漏给子进程（否则 EVIOCGRAB 被继承，
		 * 播放器重启后新实例 grab 全 EBUSY，按键就"失灵"了） */
		for (j = 3; j < 256; j++) close(j);
		execl("/bin/sh", "sh", g_play_sh, "key", act, (char *)NULL);
		_exit(127);
	}
}

static void do_quit(void)
{
	/* 退出要连 ffmpeg 一起收：那是 play.sh 的活（它还管着 state 文件） */
	run_play_sh("quit");
	g_quit = 1;
}

/* ---------- 控制口协议 ---------- */

static void reply(int fd, const char *s)
{
	size_t n = strlen(s);

	while (n) {
		ssize_t w = write(fd, s, n);

		if (w <= 0) return;
		s += w;
		n -= (size_t)w;
	}
}

static void cmd_status(int fd)
{
	char buf[320];

	snprintf(buf, sizeof buf,
		 "{\"ok\":1,\"paused\":%d,\"pos_ms\":%ld,\"au\":%d,"
		 "\"audio\":%d,\"vol\":%d,\"mute\":%d,\"xrun\":%d}\n",
		 g_paused, pos_now(), au_now(), aout_running(),
		 aout_vol(), g_mute, aout_xrun());
	reply(fd, buf);
}

static int handle_line(int fd, char *line)
{
	char *a = strtok(line, " \t\r\n");
	char *b = strtok(NULL, " \t\r\n");

	if (!a) return 0;
	if (!strcmp(a, "status")) { cmd_status(fd); return 0; }
	if (!strcmp(a, "pos")) {
		char buf[64];

		snprintf(buf, sizeof buf, "{\"ok\":1,\"pos_ms\":%ld}\n", pos_now());
		reply(fd, buf);
		return 0;
	}
	if (!strcmp(a, "pause"))  { set_paused(1); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "resume")) { set_paused(0); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "toggle")) { set_paused(!g_paused); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "mute")) {
		if (!g_mute) {
			g_saved_vol = aout_vol() > 0 ? aout_vol() : 100;
			g_mute = 1;
			aout_set_vol_abs(0);
		} else {
			g_mute = 0;
			aout_set_vol_abs(g_saved_vol);
		}
		{
			char buf[64];

			snprintf(buf, sizeof buf, "{\"ok\":1,\"mute\":%d}\n", g_mute);
			reply(fd, buf);
		}
		return 0;
	}
	if (!strcmp(a, "vol") && b) {
		int cur = aout_vol(), nv;

		/* 相对量在这里算：调用方不做"读旧值写新值"，连按不丢 */
		if (b[0] == '+' || b[0] == '-')
			nv = cur + atoi(b);
		else
			nv = atoi(b);
		aout_set_vol_abs(nv);
		if (aout_vol() > 0) g_mute = 0;
		{
			char buf[64];

			snprintf(buf, sizeof buf, "{\"ok\":1,\"vol\":%d}\n", aout_vol());
			reply(fd, buf);
		}
		return 0;
	}
	if (!strcmp(a, "seek") && b) { run_play_sh(b); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "quit")) { do_quit(); reply(fd, "{\"ok\":1}\n"); return 1; }
	reply(fd, "{\"error\":\"unknown\"}\n");
	return 0;
}

static void *ctl_thread(void *arg)
{
	struct sockaddr_un sa;
	char line[256];

	(void)arg;
	unlink(g_sock);
	g_lfd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (g_lfd < 0) return NULL;
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", g_sock);
	if (bind(g_lfd, (struct sockaddr *)&sa, sizeof sa) < 0 ||
	    listen(g_lfd, 8) < 0) {
		fprintf(stderr, "pctl: 控制口 %s 起不来: %s\n", g_sock, strerror(errno));
		close(g_lfd);
		g_lfd = -1;
		return NULL;
	}
	chmod(g_sock, 0666);

	while (!g_quit) {
		int cfd = accept(g_lfd, NULL, NULL);

		if (cfd < 0) {
			if (errno == EINTR) continue;
			break;
		}
		for (;;) {			/* 一个连接多条命令，短连接也行 */
			ssize_t n = read(cfd, line, sizeof line - 1);

			if (n <= 0) break;
			line[n] = 0;
			if (handle_line(cfd, line)) break;
		}
		close(cfd);
	}
	close(g_lfd);
	g_lfd = -1;
	unlink(g_sock);
	return NULL;
}

/* ---------- 遥控器（evdev，原 rcinputd）---------- */

static int g_mods;
static const char *g_last_act;
static time_t g_last_t;

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

/* 组合键：这台遥控器（XING WEI 2.4G）上排 5 个功能键发的是 Ctrl+1..Ctrl+5，
 * 不是标准媒体键。首页键（Ctrl+1）按需求不响应，故不登记。 */
static const struct { int mods; int code; const char *act; } COMBO[] = {
	{ M_CTRL, KEY_2, "mute"   },
	{ M_CTRL, KEY_3, "menu"   },
	{ M_CTRL, KEY_4, "volup"  },
	{ M_CTRL, KEY_5, "voldn"  },
};

static const char *action_of(int code)
{
	size_t i;

	for (i = 0; i < sizeof COMBO / sizeof COMBO[0]; i++)
		if (COMBO[i].mods == g_mods && COMBO[i].code == code)
			return COMBO[i].act;

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

static void rc_log(const char *act, int code, int val)
{
	FILE *f = fopen(RC_LOGF, "a");

	if (!f) return;
	fprintf(f, "%ld %s code=%d mods=%d val=%d\n",
		(long)time(NULL), act, code, g_mods, val);
	fclose(f);
}

static int rc_open(const char *path, const char *match)
{
	char nm[256] = "";
	int fd = open(path, O_RDONLY | O_NONBLOCK);

	if (fd < 0) return -1;
	if (ioctl(fd, EVIOCGNAME(sizeof nm), nm) < 0) nm[0] = 0;
	if (match && strcmp(match, "*") && !strstr(nm, match)) {
		close(fd);
		return -1;
	}
	if (!getenv("RC_NOGRAB") && ioctl(fd, EVIOCGRAB, 1) < 0) {
		FILE *f = fopen(RC_LOGF, "a");

		if (f) {
			fprintf(f, "%ld WARN grab %s(%s) 失败: %s\n",
				(long)time(NULL), path, nm, strerror(errno));
			fclose(f);
		}
	}
	/* 绝不能漏进 play.sh 子进程：漏了 grab 就被继承，重启后 EBUSY */
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fd;
}

static void *rc_thread(void *arg)
{
	const char *match = getenv("RC_MATCH");
	int fds[MAXDEV], n = 0, i;
	struct dirent *de;
	DIR *d;

	(void)arg;
	if (!match || !*match) match = "XING WEI";

	d = opendir("/dev/input");
	if (!d) return NULL;
	while ((de = readdir(d)) && n < MAXDEV) {
		char p[512];
		int fd;

		if (strncmp(de->d_name, "event", 5)) continue;
		snprintf(p, sizeof p, "/dev/input/%s", de->d_name);
		fd = rc_open(p, match);
		if (fd >= 0) fds[n++] = fd;
	}
	closedir(d);
	if (!n) {
		fprintf(stderr, "pctl: 没有匹配的遥控设备 (RC_MATCH=%s)，按键不可用\n",
			match);
		return NULL;
	}
	if (getenv("VERBOSE"))
		printf("PCTL: 遥控已接管 %d 个设备\n", n);

	while (!g_quit) {
		fd_set rs;
		int mx = -1, r;

		FD_ZERO(&rs);
		for (i = 0; i < n; i++) {
			FD_SET(fds[i], &rs);
			if (fds[i] > mx) mx = fds[i];
		}
		r = select(mx + 1, &rs, NULL, NULL, NULL);
		if (r <= 0) continue;
		for (i = 0; i < n; i++) {
			struct input_event ev[64];
			ssize_t len, k;

			if (!FD_ISSET(fds[i], &rs)) continue;
			len = read(fds[i], ev, sizeof ev);
			if (len <= 0) continue;
			for (k = 0; k < len / (ssize_t)sizeof ev[0]; k++) {
				const char *act;
				int m;

				if (ev[k].type != EV_KEY) continue;
				if (ev[k].value == 0) continue;
				m = mod_of(ev[k].code);
				if (m) {
					g_mods |= m;
					continue;
				}
				/* 这块板的遥控器有些键报出离谱 value（458976 之类），只认 1/2 */
				if (ev[k].value > 2) continue;
				act = action_of(ev[k].code);
				if (!act) continue;
				/* OK 只认按下那一下：长按连发会把 toggle 来回抖 */
				if (ev[k].value == 2 && !strcmp(act, "toggle"))
					continue;
				/* 长按连发只压同一动作，换键不能被上一键的时间戳吃掉 */
				if (ev[k].value == 2 && act == g_last_act &&
				    time(NULL) == g_last_t)
					continue;
				rc_log(act, ev[k].code, ev[k].value);
				g_last_act = act;
				g_last_t = time(NULL);

				if (!strcmp(act, "toggle"))
					set_paused(!g_paused);
				else if (!strcmp(act, "volup"))
					aout_set_vol_abs(aout_vol() + 10);
				else if (!strcmp(act, "voldn"))
					aout_set_vol_abs(aout_vol() - 10);
				else if (!strcmp(act, "mute")) {
					if (!g_mute) {
						g_saved_vol = aout_vol() > 0 ? aout_vol() : 100;
						g_mute = 1;
						aout_set_vol_abs(0);
					} else {
						g_mute = 0;
						aout_set_vol_abs(g_saved_vol);
					}
				}
				else if (!strcmp(act, "quit"))
					do_quit();
				else		/* seek/menu：整链重开或忽略，交给 play.sh */
					run_play_sh(act);
			}
		}
	}
	for (i = 0; i < n; i++) close(fds[i]);
	return NULL;
}

/* ---------- 启动/收尾 ---------- */

void pctl_start(void)
{
	pthread_t th;
	const char *e;

	if ((e = getenv("PLAY_SOCK")) && *e) g_sock = e;
	if ((e = getenv("PLAY_SH")) && *e) g_play_sh = e;
	if (pthread_create(&th, NULL, ctl_thread, NULL) == 0)
		pthread_detach(th);
	if (!getenv("RC") || atoi(getenv("RC")) != 0) {
		if (pthread_create(&th, NULL, rc_thread, NULL) == 0)
			pthread_detach(th);
	}
}

void pctl_stop(void)
{
	g_quit = 1;
	if (g_lfd >= 0) {
		shutdown(g_lfd, SHUT_RDWR);
		close(g_lfd);
		g_lfd = -1;
	}
}

/* ---------- 客户端：`player -c <命令...>` ---------- */

int pctl_client(int argc, char **argv)
{
	struct sockaddr_un sa;
	const char *e;
	char cmd[192] = "", buf[512];
	int fd, i, n;

	/* 客户端也认 PLAY_SOCK：不然服务端换了口，-c 还往老地方connect */
	if ((e = getenv("PLAY_SOCK")) && *e) g_sock = e;
	for (i = 0; i < argc; i++) {
		size_t l = strlen(cmd);

		snprintf(cmd + l, sizeof cmd - l, "%s%s", l ? " " : "", argv[i]);
	}
	if (!cmd[0]) return 2;
	n = (int)strlen(cmd);
	if (n < (int)sizeof cmd - 1) {
		cmd[n] = '\n';
		cmd[n + 1] = 0;
	}

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", g_sock);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
		fprintf(stderr, "player: 连不上 %s（没在放？）\n", g_sock);
		return 1;
	}
	if (write(fd, cmd, strlen(cmd)) < 0) { close(fd); return 1; }
	if (getenv("PCTL_ECHO")) {
		ssize_t r = read(fd, buf, sizeof buf - 1);

		if (r > 0) {
			buf[r] = 0;
			fputs(buf, stdout);
		}
	}
	close(fd);
	return 0;
}
