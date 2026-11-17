/* 解析侧混剪验证：只跑 AU 切分 + SEI 解析 + COLOR 行，不碰 VPU */
#define main v4l2hevc_main_unused
#include "v4l2hevc.c"
#undef main

int main(int argc, char **argv)
{
	const unsigned char *au;
	size_t len;
	int r, n = 0;

	if (argc < 2) return 1;
	s_fd = open(argv[1], O_RDONLY);
	if (s_fd < 0) { perror("open"); return 1; }
	while ((r = stream_next_au(&au, &len)) > 0) {
		n++;
		color_report();	/* SPS/SEI 由 stream_next_au() 内部解析 */		/* 内部有变化检测，同一色域只打一条 */
	}
	printf("--- 共 %d 个 AU ---\n", n);
	return 0;
}
