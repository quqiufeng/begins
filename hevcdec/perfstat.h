/* perfstat.h —— 帧级性能计量：要分布，不要平均
 *
 * 平均 fps 是这几个量的商，把差别全抹掉了：一半 8ms 一半 50ms 和全是 29ms
 * 显示同一个数，前者每两帧卡一下、后者是稳定掉帧，处置完全不同。所以这里
 * 只记能单独判定的量，且全部落分布表：
 *
 *   draw  GPU 完成时间（含 glFinish）：单帧算力够不够，看 p99/max 不看均值
 *   flip  提交翻页 → flip 完成事件：> 1 个刷新周期 = 错过最近那个 vblank
 *   intv  两次真上屏之间的间隔：节拍抖动/掉槽直接看它，不用反推 fps
 *   drops 提交了但没上屏的次数：是"该显示的没显示"，与 fps 无关
 *
 * 两套账，用途不同：
 *   ps_add    连续量（ms），出 p50/p90/p99/max。桶边界刻意在常见节拍
 *             （16.7/33.3/50/66.7）处加密，否则 33.3ms 会落进 ≤40 的桶、
 *             报成 p50=40，把 24fps@60 的正常节拍显示成异常。
 *   ps_slot   离散量（占几个刷新周期），按周期直接取整计数。间隔必须这样
 *             记：33.3 和 50.0 只差 17ms，落到同一个粗桶里就分不清是
 *             "2 槽"还是"3 槽"，而这两者的故障含义完全相反。
 *
 * 分位数按桶上沿报（"p95 <= 14ms" 这种读法），不插值——插值会造出数据里
 * 没有的精度，把 3 个样本算出的 p99=13.27ms 当成真相。
 */
#ifndef PERFSTAT_H
#define PERFSTAT_H

#include <stdio.h>
#include <string.h>
#include <math.h>

/* 桶边界：ms。10ms 以下密（一个 60Hz 周期内的差距要能看出来），
 * 16.7/33.3/41.7/50/58.4/66.8 附近必有一条，正好卡住 n 个 vblank 的理论值 */
#define PS_NB 31
static const double ps_edges[PS_NB] = {
	0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 14, 15.5, 16.7, 18, 20,
	22, 25, 29, 32, 33.4, 36, 40, 41.7, 45, 50.1, 55, 58.4, 62, 66.8, 75
};
#define PS_SLOT_MAX 9		/* 记录 1..8 个周期，>=9 归一桶 */

struct ps_hist {
	const char *name;
	const char *unit;
	long n;			/* 样本数 */
	long cnt[PS_NB + 1];	/* 最后一个桶 = 超过 75ms */
	double sum, maxv;
	long over;		/* 超 budget 的次数 */
	double budget;		/* ms；<= 0 表示不判超限 */
	/* 离散账：按 unit（刷新周期 ms）取整的槽位分布 */
	double slot_unit;
	long slot[PS_SLOT_MAX];
};

static inline void ps_init(struct ps_hist *h, const char *name, const char *unit,
			   double budget)
{
	memset(h, 0, sizeof(*h));
	h->name = name;
	h->unit = unit;
	h->budget = budget;
}

static inline int ps_bucket(double v)
{
	int i;

	for (i = 0; i < PS_NB; i++)
		if (v <= ps_edges[i]) return i;
	return PS_NB;
}

/* 记一个连续量（毫秒）。slot_unit > 0 时同时记它是几个周期。 */
static inline void ps_add(struct ps_hist *h, double v)
{
	h->n++;
	h->cnt[ps_bucket(v)]++;
	h->sum += v;
	if (v > h->maxv) h->maxv = v;
	if (h->budget > 0 && v > h->budget) h->over++;
	if (h->slot_unit > 0) {
		long k = lround(v / h->slot_unit);

		if (k < 1) k = 1;
		if (k > PS_SLOT_MAX - 1) k = PS_SLOT_MAX - 1;
		h->slot[k]++;
	}
}

/* 分位数：第一个累计占比 >= p 的桶的上沿 */
static inline double ps_pct(const struct ps_hist *h, double p)
{
	long acc = 0, want;
	int i;

	if (!h->n) return 0;
	want = (long)(h->n * p + 0.999);	/* 向上取整，p99 至少取 1 个样本 */
	for (i = 0; i <= PS_NB; i++) {
		acc += h->cnt[i];
		if (acc >= want) return i < PS_NB ? ps_edges[i] : h->maxv;
	}
	return h->maxv;
}

/* 一个周期内的样本数（<=1.5 周期），用来判"这帧到底吃没吃到下一个 vblank" */
static inline long ps_under(const struct ps_hist *h, double lim)
{
	long acc = 0;
	int i;

	for (i = 0; i <= PS_NB; i++) {
		if (i > 0 && ps_edges[i - 1] >= lim) break;
		acc += h->cnt[i];
	}
	return acc;
}

static inline void ps_print(const struct ps_hist *h)
{
	if (!h->n) {
		printf("PERF %-5s 无样本\n", h->name);
		return;
	}
	printf("PERF %-5s n=%-5ld avg=%6.2f p50=%6.2f p90=%6.2f p99=%6.2f "
	       "max=%6.2f %s",
	       h->name, h->n, h->sum / h->n, ps_pct(h, 0.50),
	       ps_pct(h, 0.90), ps_pct(h, 0.99), h->maxv, h->unit);
	if (h->budget > 0)
		printf(" | 超 %.1f%s %ld 次 (%.1f%%)", h->budget, h->unit,
		       h->over, 100.0 * h->over / h->n);
	printf("\n");
	if (h->slot_unit > 0 && h->slot[1] + h->slot[2] + h->slot[3] +
	    h->slot[4] + h->slot[5] + h->slot[6] + h->slot[7] + h->slot[8]) {
		int k;

		printf("       按周期(%.2fms)分: ", h->slot_unit);
		for (k = 1; k < PS_SLOT_MAX; k++)
			printf("%d%s=%ld ", k, k == PS_SLOT_MAX - 1 ? "+" : "",
			       h->slot[k]);
		printf("\n");
	}
}

#endif /* PERFSTAT_H */
