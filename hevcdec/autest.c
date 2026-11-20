/* AU 切分自检：把 v4l2hevc.c 整份 include 进来，直接把文件当码流灌给
 * stream_next_au()，输出每个 AU 的字节数和 slice 宽度分布。不需要 /dev/video：
 *
 *   make autest && ./autest test720.265          # 当前实现
 *   ./autest test720.265 | md5sum                # 与改前对比用
 *
 * 用来验证两件事：
 *   1) 单 slice 片源改前改后 AU 边界/字节数必须逐字节一致（回归）
 *   2) 多 slice 片源（x265 --slices）一帧只能出一个 AU
 */
#define main player_main	/* 让被测文件的 main 让位 */
#include "v4l2hevc.c"
#undef main

int main(int argc, char **argv)
{
	FILE *f;
	long n;
	int au = 0, rap = 0, ret;
	const unsigned char *au_p = NULL;
	size_t au_len = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s file.265|file.264\n", argv[0]);
		return 2;
	}
	if (getenv("CODEC") && !strcmp(getenv("CODEC"), "h264"))
		g_h264 = 1;
	f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 2;
	}
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	s_cap = (size_t)n + (1u << 20);
	s_buf = malloc(s_cap);
	s_len = fread(s_buf, 1, (size_t)n, f);
	fclose(f);
	s_pos = 0;
	s_au_start = 0;
	s_au_open = 0;
	s_cur_vcl = 0;
	s_eof = 1;		/* 数据全在内存里：不给 s_fill() 机会 */

	while ((ret = stream_next_au(&au_p, &au_len)) > 0) {
		au++;
		if (ret == 2)
			rap++;
		printf("au%-4d len=%-7zu %s\n", au, au_len, ret == 2 ? "RAP" : "");
	}
	printf("file=%s codec=%s bytes=%ld au=%d total=%d rap=%d "
	       "extra_slices=%d (frames with slices=%d)\n",
	       argv[1], g_h264 ? "h264" : "hevc", n, au, g_stream_au,
	       rap, g_ms_slices, g_ms_au);
	return 0;
}
