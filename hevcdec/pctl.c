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
#include "osd.h"
#include "pctl.h"
#include "rcmap.h"

#define RC_LOGF "/tmp/play.rc.log"
#define MAXDEV 16

static const char *g_sock = "/tmp/play.sock";
static const char *g_play_sh;	/* 播放脚本：启动时按"二进制旁边"定位，见 resolve_play_sh() */
static volatile int g_paused;
static volatile int g_mute;
static int g_saved_vol = 100;		/* 静音前的音量，取消静音要还原 */
static double g_pause_acc, g_pause_t0;	/* 暂停累计秒：播放器时间轴要平移 */
static volatile int g_quit;
static volatile int g_want_exit;	/* 主循环该退了（-c quit） */
static int g_lfd = -1;

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------- 屏幕提示 ----------
 * 控制口和遥控器是两条入口，提示必须走同一处：否则 RCs 上有条，-c vol +10
 * 没有，用户看到的行为就取决于他是按遥控还是调脚本。
 */
static void osd_vol(void)
{
	osd_show(1.2, "%s%d%%", g_mute ? "静音 " : "音量 ", aout_vol());
}

static void osd_pause(int on)
{
	osd_show(on ? 0 : 0.8, on ? "|| 暂停" : "> 播放");
}

static long (*g_pos_ms)(void);
static int  (*g_au)(void);
static int  (*g_seek)(int rel);
static int  (*g_seek_abs)(double sec);

/* ---------- 观测值 ---------- */

void pctl_set_sources(long (*pos_ms)(void), int (*au)(void))
{
	g_pos_ms = pos_ms;
	g_au = au;
}

void pctl_set_seek(int (*fn)(int rel)) { g_seek = fn; }
void pctl_set_seek_abs(int (*fn)(double sec)) { g_seek_abs = fn; }

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

/* play.sh 在哪儿：以前写死 /tmp/play.sh，可 2026-11-18 起播放器落点是
 * /root（/tmp 是 tmpfs，重启即空），遥控器每个走脚本的键位（home/字幕/
 * 音轨…）都在日志里刷 "sh: cannot open /tmp/play.sh" 然后什么都不做。
 * 按二进制自己所在目录找同目录 play.sh，找不到再退回 /root、/tmp。
 */
static void resolve_play_sh(void)
{
	static char buf[256];
	const char *e = getenv("PLAY_SH");
	char exe[200];
	ssize_t n;
	static const char *cand[] = { "/root/play.sh", "/tmp/play.sh", NULL };
	int i;

	if (e && *e) { g_play_sh = e; return; }
	n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n > 0) {
		char *sl;

		exe[n] = 0;
		sl = strrchr(exe, '/');
		if (sl) {
			*sl = 0;
			snprintf(buf, sizeof buf, "%s/play.sh", exe);
			if (access(buf, X_OK) == 0) { g_play_sh = buf; return; }
		}
	}
	for (i = 0; cand[i]; i++)
		if (access(cand[i], X_OK) == 0) { g_play_sh = cand[i]; return; }
	g_play_sh = "/root/play.sh";
}

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
	/* 但 play.sh 只在它自己起播时有 state 可收（/tmp/play.state）。裸跑
	 * 的实例、或者 state 被清掉时，只关控制口等于留个还在解码上屏的
	 * 孤儿进程——屏幕照放、遥控全哑，连再 `-c quit` 都连不上（socket
	 * 已被 ctl_thread 收尾 unlink）。让主循环也退，两边都走得掉。
	 */
	g_want_exit = 1;
	g_quit = 1;
}

int pctl_want_exit(void)
{
	return g_want_exit;
}

/* ---------- 控制口协议 ---------- */

static void reply(int fd, const char *s)
{
	size_t n = strlen(s);

	while (n) {
		/* 必须 MSG_NOSIGNAL：客户端 write 完就 close（-c 不等应答），
		 * 服务端这条 write 撞上已关闭的对端会收 SIGPIPE，默认动作是
		 * 整个播放进程直接消失——seek 时最明显：跳一下片子自己没了，
		 * 屏幕上只剩命令行。
		 */
		ssize_t w = send(fd, s, n, MSG_NOSIGNAL);

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
	/* 首字节 0x01 = 这条命令是 play.sh 发的（"别再转回 play.sh"）。
	 * 以前用 getenv("PCTL_NODELEGATE") 判断，可是这个环境变量设在
	 * **客户端**（play.sh 的 pctl()）上，服务端是播放器进程、环境里
	 * 根本没有它 → 判断永远为假 → seek 又被 run_play_sh 转回 play.sh
	 * 一次，play.sh 自己也要重启一遍，一次快进变成 +20s（连按三次
	 * 实测 +60s）。标记必须跟着命令走，不能靠进程环境。 */
	int nodelegate = 0;
	char *a, *b;

	if ((unsigned char)line[0] == 1) { nodelegate = 1; line++; }
	a = strtok(line, " \t\r\n");
	b = strtok(NULL, " \t\r\n");

	if (!a) return 0;
	if (!strcmp(a, "status")) { cmd_status(fd); return 0; }
	if (!strcmp(a, "pos")) {
		char buf[64];

		snprintf(buf, sizeof buf, "{\"ok\":1,\"pos_ms\":%ld}\n", pos_now());
		reply(fd, buf);
		return 0;
	}
	if (!strcmp(a, "pause"))  { set_paused(1); osd_pause(1); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "resume")) { set_paused(0); osd_pause(0); reply(fd, "{\"ok\":1}\n"); return 0; }
	if (!strcmp(a, "toggle")) {
		set_paused(!g_paused);
		osd_pause(g_paused);
		reply(fd, "{\"ok\":1}\n");
		return 0;
	}
	if (!strcmp(a, "mute")) {
		if (!g_mute) {
			g_saved_vol = aout_vol() > 0 ? aout_vol() : 100;
			g_mute = 1;
			aout_set_vol_abs(0);
		} else {
			g_mute = 0;
			aout_set_vol_abs(g_saved_vol);
		}
		osd_vol();
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
		osd_vol();
		{
			char buf[64];

			snprintf(buf, sizeof buf, "{\"ok\":1,\"vol\":%d}\n", aout_vol());
			reply(fd, buf);
		}
		return 0;
	}
	/* seek <±秒>：播放器没有 IPC，seek 只能整链重开（play.sh key …）。
	 * 以前把秒数原样当动作名交给 play.sh（"seek 30" → "play.sh key 30"），
	 * play.sh 只认 fwd/back/fwdmore/backmore，未知动作直接空转 ——
	 * 遥控器 ▶ 显示"ok"、画面原地不动，就是这个。现在翻成 fwd:<秒>/back:<秒>。
	 * 非数字参数（fwd/back/fwdmore/backmore…）原样透传。 */
	if ((!strcmp(a, "seek") || !strcmp(a, "seekto")) && b) {
		char act[32];
		char *p = b;
		int neg = 0, n = 0;	/* 只在数字分支赋值；下面的 *p 判断同条件，但 gcc 看不出来 */
		int isabs = !strcmp(a, "seekto");

		if (*p == '+' || *p == '-') { neg = (*p == '-'); p++; }
		if (*p >= '0' && *p <= '9') {
			n = atoi(p);
			if (n < 0) { neg = !neg; n = -n; }
			/* seek 0 以前直接回 ok 什么都不做（屏幕上就是"按了没
			 * 反应"）；它真实意思是回片头，按绝对跳走。
			 */
			if (!isabs && n == 0)
				isabs = 1;
			if (isabs)
				snprintf(act, sizeof act, "seekto:%s%d",
					 neg ? "-" : "", n);
			else
				snprintf(act, sizeof act, "%s:%d",
					 neg ? "back" : "fwd", n);
		} else {
			snprintf(act, sizeof act, "%s", b);
		}
		/* 播放器能就地跳就别重开链路（spawn 模式：DRM 不放手，屏幕不黑） */
		if (*p >= '0' && *p <= '9') {
			if (isabs && g_seek_abs &&
			    g_seek_abs(neg ? -(double)n : (double)n)) {
				reply(fd, "{\"ok\":1,\"seek\":\"abs\"}\n");
				return 0;
			}
			if (!isabs && g_seek &&
			    g_seek(neg ? -atoi(p) : atoi(p))) {
				reply(fd, "{\"ok\":1,\"seek\":\"inplace\"}\n");
				return 0;
			}
		}
		/* 谁调的这一支很关键：遥控器/外部 -c 进来的才该往 play.sh 转；
		 * 如果这条 seek 本身就是 play.sh 转下来的（play.sh 的 pctl() 会带
		 * PCTL_NODELEGATE=1），再转回去就是死循环 ——
		 *   pctl seek → play.sh key fwd:30 → pctl seek → play.sh key fwd:30 …
		 * 表现：按一下 ▶ 日志刷几十行"seek 合并"，位置乱跳、最后落回原地。
		 * 回 "seek":"no" 让 play.sh 知道"就地跳做不到，你自己重开链路"。
		 */
		if (nodelegate) {
			reply(fd, "{\"ok\":1,\"seek\":\"no\"}\n");
			return 0;
		}
		run_play_sh(act);
		reply(fd, "{\"ok\":1}\n");
		return 0;
	}
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

static int mod_of(int code)
{
	switch (code) {
	case KEY_LEFTCTRL: case KEY_RIGHTCTRL: return RC_M_CTRL;
	case KEY_LEFTSHIFT: case KEY_RIGHTSHIFT: return RC_M_SHIFT;
	case KEY_LEFTALT: case KEY_RIGHTALT: return RC_M_ALT;
	}
	return 0;
}

/* 键位表就是 rcmap.h 那一份：这里只是把 x-macro 展开成数组，
 * 没有第二处按键定义，改键只改 rcmap.h。 */
#define RC_ENTRY(m, c, a) { m, c, a },
static const struct { int mods; int code; const char *act; } RCMAP[] = {
	RCMAP_KEYS(RC_ENTRY)
};
#undef RC_ENTRY

#define RC_NAME(m, c, a) #c,
static const char *const RCMAP_NAMES[] = {
	RCMAP_KEYS(RC_NAME)
};
#undef RC_NAME

#define RCMAP_N (sizeof RCMAP / sizeof RCMAP[0])

/* 先按「修饰键 + 码」精确匹配（Ctrl+2 静音不会和裸 2 打架）；
 * 没命中再退回裸键，这样按住 Ctrl 按媒体键也不会突然失灵。 */
static const char *action_of(int code)
{
	size_t i;

	for (i = 0; i < RCMAP_N; i++)
		if (RCMAP[i].mods == g_mods && RCMAP[i].code == code)
			return RCMAP[i].act;
	if (g_mods)
		for (i = 0; i < RCMAP_N; i++)
			if (RCMAP[i].mods == 0 && RCMAP[i].code == code)
				return RCMAP[i].act;
	return NULL;
}

/* `player -K`：把整张表打出来，play.sh / 文档都从这取，不要再手抄一遍。
 * 制表符分隔：修饰键<TAB>键名<TAB>动作，脚本用 cut/awk 就能解析。 */
void pctl_keymap_dump(void)
{
	size_t i;

	printf("# 遥控键位表（rcmap.h）：修饰<TAB>KEY_名<TAB>动作\n");
	for (i = 0; i < RCMAP_N; i++) {
		const char *m = RCMAP[i].mods & RC_M_CTRL ? "CTRL"
			      : RCMAP[i].mods & RC_M_SHIFT ? "SHIFT"
			      : RCMAP[i].mods & RC_M_ALT ? "ALT" : "-";

		printf("%s\t%s\t%s\n", m, RCMAP_NAMES[i], RCMAP[i].act);
	}
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

				if (!strcmp(act, "toggle")) {
					set_paused(!g_paused);
					osd_pause(g_paused);
				} else if (!strcmp(act, "volup")) {
					aout_set_vol_abs(aout_vol() + 10);
					osd_vol();
				} else if (!strcmp(act, "voldn")) {
					aout_set_vol_abs(aout_vol() - 10);
					osd_vol();
				}
				else if (!strcmp(act, "mute")) {
					if (!g_mute) {
						g_saved_vol = aout_vol() > 0 ? aout_vol() : 100;
						g_mute = 1;
						aout_set_vol_abs(0);
					} else {
						g_mute = 0;
						aout_set_vol_abs(g_saved_vol);
					}
					osd_vol();
				}
				else if (!strcmp(act, "quit"))
					do_quit();
				else if ((!strcmp(act, "fwd") || !strcmp(act, "back") ||
					  !strcmp(act, "fwdmore") || !strcmp(act, "backmore")) &&
					 g_seek && g_seek(!strcmp(act, "fwd") ? 10 :
							   !strcmp(act, "back") ? -10 :
							   !strcmp(act, "fwdmore") ? 60 : -60)) {
					/* 就地跳完（spawn 模式），不用整链重开 */
				}
				else		/* seek/menu：整链重开或忽略，交给 play.sh */
					run_play_sh(act);
			}
		}
	}
	for (i = 0; i < n; i++) close(fds[i]);
	return NULL;
}

/* ---------- 启动/收尾 ---------- */

/* 起播提示：seek 是整链重开，屏幕先黑 ~1s 再出画面。新实例一起来就把
 * "跳到第几秒"挂上，用户才知道这次确实跳了、跳到了哪儿。play.sh 把目标
 * 位置塞进 PLAY_OSD；4s 足够盖住首帧黑洞，也不会赖在画面上。
 * 没有这个环境变量（正常起播）就什么都不显示。
 */
static void osd_startup(void)
{
	const char *e = getenv("PLAY_OSD");

	if (e && *e)
		osd_show(4.0, "%s", e);
}

void pctl_start(void)
{
	pthread_t th;
	const char *e;

	if ((e = getenv("PLAY_SOCK")) && *e) g_sock = e;
	resolve_play_sh();
	if (pthread_create(&th, NULL, ctl_thread, NULL) == 0)
		pthread_detach(th);
	if (!getenv("RC") || atoi(getenv("RC")) != 0) {
		if (pthread_create(&th, NULL, rc_thread, NULL) == 0)
			pthread_detach(th);
	}
	osd_startup();
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
	if (n < (int)sizeof cmd - 2) {
		cmd[n] = '\n';
		cmd[n + 1] = 0;
	}
	/* PCTL_NODELEGATE=1：告诉服务端"这条命令是 play.sh 发的，别再往
	 * play.sh 转"（否则 seek 会乒乓一次、快进翻倍）。标记必须随命令
	 * 传输：服务端是播放器进程，读不到客户端的进程环境。 */
	if (getenv("PCTL_NODELEGATE")) {
		memmove(cmd + 1, cmd, strlen(cmd) + 1);
		cmd[0] = 1;
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
