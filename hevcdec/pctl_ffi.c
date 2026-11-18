/* pctl_ffi.c — 播放器控制面的 FFI 薄层（libpctl.so）
 *
 * 以前 lua 想控制播放只能：起进程 `player -c <命令>`、或者自己实现
 * /tmp/play.sock 的文本协议。这里把同一套协议做成一个 .so，lua 直接
 *
 *   local ffi = require "ffi"
 *   ffi.cdef[[ const char *pctl_cmd(const char *); ... ]]
 *   local lib = ffi.load("/opt/keybord/libpctl.so")
 *   lib.pctl_seek(-30)
 *
 * 就能暂停/快进/音量/跳播，一进程一轮 FFI 调用，零 fork、零字符串拼 shell。
 *
 * 约定：
 *   - 返回 const char * 的函数给的都是线程本地缓冲，下次调用即失效，
 *     lua 侧必须 ffi.string() 立刻拷走。
 *   - 数字返回值：>=0 成功（按函数语义），-1 失败，失败原因问 pctl_err()。
 *   - socket 路径：PCTL_SOCK > PLAY_SOCK > /tmp/play.sock（和服务端一致）。
 *   - pctl_play() 另起播：fork + setsid 跑 $PLAY_SH（默认 /root/play.sh），
 *     不阻塞调用方，播完/失败跟 lua 无关。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define PCTL_VER       "1.0"
#define PCTL_TMO_MS    1500
#define PCTL_BUF       1024

static char g_sock[108] = "";
static const char *g_err = "";

static __thread char tl_reply[PCTL_BUF];

const char *pctl_version(void) { return PCTL_VER; }
const char *pctl_err(void) { return g_err ? g_err : ""; }

static const char *sock_path(void)
{
	const char *e;

	if (g_sock[0]) return g_sock;
	if ((e = getenv("PCTL_SOCK")) && *e) return e;
	if ((e = getenv("PLAY_SOCK")) && *e) return e;
	return "/tmp/play.sock";
}

/* lua 侧可显式指定（多实例/测试用）：pctl_set_sock("/tmp/x.sock") */
int pctl_set_sock(const char *path)
{
	if (!path) { g_sock[0] = 0; return 0; }
	snprintf(g_sock, sizeof g_sock, "%s", path);
	return 0;
}

const char *pctl_sock(void) { return sock_path(); }

/* ---------- 一问一答 ---------- */

/* 发一行命令，读一行应答。成功返回 0，应答在 out（含换行，已截断）。 */
static int talk(const char *cmd, char *out, size_t n)
{
	struct sockaddr_un sa;
	struct pollfd pfd;
	int fd, r;
	size_t len = 0;

	if (!cmd || !*cmd) { g_err = "空命令"; return -1; }

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) { g_err = strerror(errno); return -1; }

	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock_path());

	/* 非阻塞 connect + poll：播放器没在跑时立刻报错，不吊住 lua */
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
	r = connect(fd, (struct sockaddr *)&sa, sizeof sa);
	if (r < 0 && errno == EINPROGRESS) {
		int e = 0;
		socklen_t el = sizeof e;

		pfd.fd = fd; pfd.events = POLLOUT;
		r = poll(&pfd, 1, PCTL_TMO_MS);
		if (r <= 0) { close(fd); g_err = "连接超时"; return -1; }
		if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el) < 0 || e) {
			close(fd);
			g_err = "播放器没在跑（socket 连不上）";
			return -1;
		}
	} else if (r < 0) {
		close(fd);
		g_err = (errno == ENOENT || errno == ECONNREFUSED)
			? "播放器没在跑（socket 不存在）" : strerror(errno);
		return -1;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);

	{
		size_t cl = strlen(cmd);
		char line[256];

		if (cl >= sizeof line - 2) { close(fd); g_err = "命令太长"; return -1; }
		memcpy(line, cmd, cl);
		if (line[cl - 1] != '\n') { line[cl++] = '\n'; }
		line[cl] = 0;
		if (write(fd, line, cl) != (ssize_t)cl) {
			close(fd); g_err = "写命令失败"; return -1;
		}
	}

	pfd.fd = fd; pfd.events = POLLIN;
	if (poll(&pfd, 1, PCTL_TMO_MS) <= 0) {
		close(fd); g_err = "应答超时"; return -1;
	}
	while (len < n - 1) {
		ssize_t k = read(fd, out + len, n - 1 - len);

		if (k <= 0) break;
		len += (size_t)k;
		if (memchr(out, '\n', len)) break;
	}
	close(fd);
	out[len] = 0;
	if (!len) { g_err = "空应答"; return -1; }
	g_err = "";
	return 0;
}

static int is_ok(const char *j)
{
	return j && !strstr(j, "\"error\"") &&
	       !strstr(j, "\"ok\":0") && !strstr(j, "\"ok\": 0") &&
	       !strstr(j, "\"ok\":false");
}

/* 只取 "key":<整数>；取不到返回 0（调用方看默认值） */
static int jint(const char *j, const char *key, int dflt)
{
	char pat[48];
	const char *p;

	snprintf(pat, sizeof pat, "\"%s\"", key);
	p = strstr(j, pat);
	if (!p) return dflt;
	p += strlen(pat);
	while (*p == ' ' || *p == ':' || *p == '\t') p++;
	if (*p < '0' || *p > '9') {
		if (*p == '-') return atoi(p);
		return dflt;
	}
	return atoi(p);
}

/* ---------- 原始命令 / 查询 ---------- */

const char *pctl_cmd(const char *cmd)
{
	if (talk(cmd, tl_reply, sizeof tl_reply) < 0) return NULL;
	return tl_reply;
}

/* 有应答就算活着（连上即活的证据） */
int pctl_ping(void)
{
	return pctl_cmd("status") ? 1 : 0;
}

const char *pctl_status(void)
{
	const char *r = pctl_cmd("status");

	return is_ok(r) ? r : NULL;
}

int pctl_paused(void)
{
	const char *r = pctl_status();

	return r ? jint(r, "paused", -1) : -1;
}

/* 位置毫秒；失败 -1 */
int pctl_pos_ms(void)
{
	const char *r = pctl_cmd("pos");

	if (!is_ok(r)) return -1;
	return jint(r, "pos_ms", -1);
}

double pctl_pos_sec(void)
{
	int ms = pctl_pos_ms();

	return ms < 0 ? -1.0 : ms / 1000.0;
}

/* ---------- 动作 ---------- */

static int simple(const char *cmd, const char *key)
{
	const char *r = pctl_cmd(cmd);

	if (!is_ok(r)) return -1;
	return key ? jint(r, key, 0) : 0;
}

int pctl_pause(void)  { return simple("pause", NULL); }
int pctl_resume(void) { return simple("resume", NULL); }

/* 返回切换后的状态：1 暂停、0 播放、-1 失败 */
int pctl_toggle(void) { return simple("toggle", "paused"); }

/* 返回切换后的静音态：1 静音、0 有声、-1 失败 */
int pctl_mute(void) { return simple("mute", "mute"); }

/* 相对调音量（±N），返回调整后音量；失败 -1 */
int pctl_vol(int delta)
{
	char cmd[48];

	snprintf(cmd, sizeof cmd, "vol %+d", delta);
	return simple(cmd, "vol");
}

int pctl_set_vol(int v)
{
	char cmd[48];

	if (v < 0) v = 0;
	if (v > 150) v = 150;
	snprintf(cmd, sizeof cmd, "vol %d", v);
	return simple(cmd, "vol");
}

/* 相对跳播（秒，负数是回退）。播放器内部整条链重开，约 1s 黑屏。 */
int pctl_seek(int sec)
{
	char cmd[48];

	snprintf(cmd, sizeof cmd, "seek %d", sec);
	return simple(cmd, NULL);
}

int pctl_quit(void) { return simple("quit", NULL); }

/* ---------- 起播 ---------- */

/* 跑 play.sh 的子命令（不阻塞）：pctl_run("play /root/a.mkv -r gl") */
int pctl_run(const char *args)
{
	const char *sh = getenv("PLAY_SH");
	char full[1024];
	pid_t pid;

	if (!sh || !*sh) sh = "/root/play.sh";
	if (!args || !*args) { g_err = "空参数"; return -1; }
	if (access(sh, X_OK) != 0) { g_err = "找不到 play.sh"; return -1; }
	snprintf(full, sizeof full, "%s %s", sh, args);

	pid = fork();
	if (pid < 0) { g_err = strerror(errno); return -1; }
	if (pid == 0) {
		setsid();
		/* 子进程别抱着调用方的 stdout/stderr（ssh 里起播会等不到 EOF） */
		execl("/bin/sh", "sh", "-c", full, (char *)NULL);
		_exit(127);
	}
	return (int)pid;
}

/* 起播一个片源：等价 `play.sh play <src>`，多余的 play.sh 选项走 opts */
int pctl_play(const char *src, const char *opts)
{
	char args[1024];

	if (!src || !*src) { g_err = "空片源"; return -1; }
	/* 单引号转义：片源里可能有空格/中文/& */
	{
		char q[768];
		size_t i, o = 0;

		q[o++] = '\'';
		for (i = 0; src[i] && o < sizeof q - 8; i++) {
			if (src[i] == '\'') { q[o++] = '\''; q[o++] = '\\'; q[o++] = '\''; q[o++] = '\''; }
			else q[o++] = src[i];
		}
		q[o++] = '\'';
		q[o] = 0;
		snprintf(args, sizeof args, "play %s %s", q, opts ? opts : "");
	}
	return pctl_run(args);
}

/* 起播并等到 socket 出现（最多 wait_ms）：成功 0、超时 -1 */
int pctl_play_wait(const char *src, const char *opts, int wait_ms)
{
	int i;

	if (pctl_play(src, opts) < 0) return -1;
	for (i = 0; i < wait_ms / 50; i++) {
		usleep(50 * 1000);
		if (pctl_ping()) return 0;
	}
	g_err = "起播超时（socket 一直没起来）";
	return -1;
}
