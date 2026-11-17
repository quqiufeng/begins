/* RAP 门控状态机自检（§1.14）：把 v4l2hevc.c 整份 include 进来调静态函数，
 * 用"手动挪 g_rap_t0"代替真的等 60s，桌面机器上就能跑，不需要 /dev/video0：
 *
 *   make raptest && ./raptest
 *
 * 覆盖：收不收 CRA 的策略、strict 降级、IRAPWAIT 软重建、RASL 预算三段式
 * （退回→退回→判死）、PLAY 态不受门控超时影响、暂停后计时修正。
 */
#define main player_main	/* 让被测文件的 main 让位 */
#include "v4l2hevc.c"
#undef main

static int fails;
static void ck(const char *what, long got, long want)
{
	if (got != want) { printf("FAIL %s: got=%ld want=%ld\n", what, got, want); fails++; }
	else printf("ok   %s = %ld\n", what, got);
}

int main(void)
{
	g_verbose = 0;

	/* 1. 默认（cra）：16..20 与 21 都收，其余不收 */
	rap_enter(RAP_WAIT, "test");
	ck("accept(20) cra", rap_accept(20), 1);
	ck("accept(21) cra", rap_accept(21), 1);
	ck("accept(0) cra", rap_accept(0), 0);

	/* 2. strict：先拒绝 CRA，超过 RAPSTRICT 后降级接受 */
	setenv("RAPMODE", "strict", 1);
	setenv("RAPSTRICT", "3", 1);
	g_rap_degraded = 0;
	rap_enter(RAP_WAIT, "test");
	ck("accept(21) strict", rap_accept(21), 0);
	ck("tick strict 未超时", rap_tick(), 0);
	g_rap_t0 -= 4.0;
	ck("tick strict 超时仍等待", rap_tick(), 0);
	ck("degraded 置位", g_rap_degraded, 1);
	ck("accept(21) degraded", rap_accept(21), 1);

	/* 3. WAIT 绝对上限：软重建信号 */
	g_rap_t0 -= 61.0;
	ck("tick IRAPWAIT 超时", rap_tick(), 1);

	/* 4. RASL 预算：超一次退回 WAIT，累计 3 次判死 */
	g_rap_rasl_over = 0;
	rap_enter(RAP_RASL, "test");
	g_rap_rasl_n = 9;
	ck("rasl 第1次超支", rap_tick(), 0);
	ck("退回 WAIT", g_rap_st == RAP_WAIT, 1);
	rap_enter(RAP_RASL, "test");
	g_rap_t0 -= 2.0;
	ck("rasl 第2次超支（按时间）", rap_tick(), 0);
	rap_enter(RAP_RASL, "test");
	g_rap_t0 -= 2.0;
	ck("rasl 第3次超支判死", rap_tick(), 2);

	/* 5. PLAY 态：谁的超时都不管 */
	rap_enter(RAP_PLAY, "test");
	g_rap_t0 -= 1000.0;
	ck("tick PLAY", rap_tick(), 0);

	/* 6. 暂停后挪计时：不该被算成等了 60s */
	rap_enter(RAP_WAIT, "test");
	g_rap_t0 -= 5.0;	/* 模拟被冻 5s 后按 now-2.0 修正 */
	g_rap_t0 += 3.0;
	ck("tick 暂停修正后", rap_tick(), 0);

	printf(fails ? "RAPTEST: %d FAIL\n" : "RAPTEST: all pass\n", fails);
	return fails != 0;
}
