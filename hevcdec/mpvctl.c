// mpvctl — 给 mpv 的 --input-ipc-server 发一行 JSON 命令，读完应答即退出。
// 盒子是 busybox，没有 socat / nc / python，所以自带一个 12KB 的静态小程序。
//   mpvctl /tmp/tvplay.sock '{"command":["add","volume","5"]}'
//   mpvctl /tmp/tvplay.sock vol +5        <-- 简写，见 shortcmd()
// 退出码：0 成功，1 参数/连接错误，2 mpv 报错。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

static int write_all(int fd, const char *b, size_t n)
{
	while (n) {
		ssize_t w = write(fd, b, n);
		if (w < 0) { if (errno == EINTR) continue; return -1; }
		b += w; n -= (size_t)w;
	}
	return 0;
}

/* 简写：vol +5 / vol -5 / mute / toggle / seek 10 / seek -10 / quit */
static const char *shortcmd(int argc, char **argv, char *buf, size_t n)
{
	if (argc < 3) return NULL;
	const char *c = argv[2];
	if (!strcmp(c, "vol") && argc >= 4) {
		long v = strtol(argv[3], NULL, 10);
		snprintf(buf, n, "{\"command\":[\"add\",\"volume\",\"%ld\"]}", v);
	} else if (!strcmp(c, "mute")) {
		snprintf(buf, n, "{\"command\":[\"cycle\",\"mute\"]}");
	} else if (!strcmp(c, "toggle")) {
		snprintf(buf, n, "{\"command\":[\"cycle\",\"pause\"]}");
	} else if (!strcmp(c, "seek") && argc >= 4) {
		snprintf(buf, n, "{\"command\":[\"seek\",\"%s\",\"relative\"]}", argv[3]);
	} else if (!strcmp(c, "quit")) {
		snprintf(buf, n, "{\"command\":[\"quit\"]}");
	} else {
		return NULL;
	}
	return buf;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: mpvctl <socket> <json>|vol N|mute|toggle|seek N|quit\n");
		return 1;
	}
	char buf[512];
	const char *msg = NULL;
	if (argv[2][0] == '{')
		msg = argv[2];
	else
		msg = shortcmd(argc, argv, buf, sizeof buf);
	if (!msg) { fprintf(stderr, "mpvctl: bad command\n"); return 1; }

	struct sockaddr_un sa;
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if (strlen(argv[1]) >= sizeof sa.sun_path) {
		fprintf(stderr, "mpvctl: socket path too long\n");
		return 1;
	}
	strcpy(sa.sun_path, argv[1]);

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
		fprintf(stderr, "mpvctl: connect %s: %s\n", sa.sun_path, strerror(errno));
		return 1;
	}

	char line[600];
	int ln = snprintf(line, sizeof line, "%s\n", msg);
	if (write_all(fd, line, (size_t)ln) < 0) { perror("write"); return 1; }

	/* 读一行应答：{"error":"success",...} */
	char rb[1024];
	size_t got = 0;
	while (got < sizeof rb - 1) {
		ssize_t r = read(fd, rb + got, sizeof rb - 1 - got);
		if (r <= 0) break;
		got += (size_t)r;
		if (memchr(rb, '\n', got)) break;
	}
	rb[got] = 0;
	close(fd);

	if (!got) { fprintf(stderr, "mpvctl: no reply\n"); return 2; }
	/* MPVCTL_ECHO=1 时把应答打到 stdout（排查用，例如 get_property volume） */
	if (getenv("MPVCTL_ECHO"))
		fputs(rb, stdout);
	if (strstr(rb, "\"error\":\"success\""))
		return 0;
	fprintf(stderr, "mpvctl: %s", rb);
	return 2;
}
