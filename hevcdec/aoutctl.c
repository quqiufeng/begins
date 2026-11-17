// aoutctl — 给 aout 的控制口发一行命令，打印应答。
//   aoutctl status | pause | resume | toggle | vol 60 | vol +5 | vol -5 | quit
// 盒子是 busybox，没有 socat/nc，所以跟 mpvctl 一样自带静态小程序。
// 默认 socket /tmp/aout.sock，可用 AOUT_SOCK 或 $2 覆盖。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

int main(int argc, char **argv)
{
	const char *path = getenv("AOUT_SOCK");
	struct sockaddr_un sa;
	char msg[128], buf[1024];
	int fd, n, off = 0;
	size_t len;

	if (!path) path = "/tmp/aout.sock";
	if (argc < 2) {
		fprintf(stderr, "usage: aoutctl status|pause|resume|toggle|vol N|+N|-N|quit [socket]\n");
		return 1;
	}
	/* 拼成 aout 能吃的一行 */
	if (!strcmp(argv[1], "vol")) {
		if (argc < 3) { fprintf(stderr, "aoutctl: vol 需要参数\n"); return 1; }
		snprintf(msg, sizeof msg, "vol %s\n", argv[2]);
	} else {
		snprintf(msg, sizeof msg, "%s\n", argv[1]);
	}
	if (argc > 2 && argv[1][0] != 'v') path = argv[2];

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
		fprintf(stderr, "aoutctl: connect %s: %s\n", path, strerror(errno));
		return 1;
	}
	len = strlen(msg);
	if (write(fd, msg, len) != (ssize_t)len) { perror("write"); return 1; }
	n = read(fd, buf, sizeof buf - 1);
	if (n <= 0) { fprintf(stderr, "aoutctl: 无应答\n"); return 1; }
	buf[n] = 0;
	fputs(buf, stdout);
	/* status 会带 JSON，脚本用 sed 抠字段；其余就直接回显 */
	(void)off;
	return 0;
}
