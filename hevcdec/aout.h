/* aout.h — 内嵌音频输出（aout.c 用 -DAOUT_EMBED 编进 player）。
 *
 * 盒上只有一个播放二进制：音频不再是独立进程，也就没有 stdin 归属问题——
 * PCM 从调用方给的 fd 读（play.sh 那条 ffmpeg 写 /tmp/play.afifo）。
 * 控制也随之并进播放器的 /tmp/play.sock，aoutctl 一并下线。
 */
#ifndef AOUT_H
#define AOUT_H

/* 打开声卡并定好参数。fmt: "s16le"/"s32le"/"s24le"；buf/period 单位是帧，
 * 传 0 用默认（8192/2048）。vol 传 -1 用默认 100。rate/ch 传 0 用 48k/2。
 * 返回 0 成功，-1 打不开声卡（没声音但画面照放），-2 格式不认识。 */
int  aout_open(int rate, int ch, const char *fmt, int buf, int period,
	       int vol, int quiet);
/* 起播放线程，从 infd 读 PCM（阻塞读，ALSA 写阻塞就是节拍）。 */
int  aout_start(int infd);

void aout_set_paused(int on);
int  aout_paused(void);
void aout_set_vol_abs(int v);		/* 0..100，内部夹住 */
int  aout_vol(void);
long aout_played_ms(void);		/* hw_ptr 折算的已播毫秒；无音频 -1 */
/* 起播/seek 对齐闸门：1 = 不取上游 PCM（ffmpeg 被背压顶住），0 = 放行 */
void aout_set_gate(int on);
int  aout_gate(void);
void aout_flush_input(void);		/* 丢管道里残留的旧 PCM（seek） */
long aout_fed_ms(void);			/* 已从上游吃进的毫秒（内容位置） */
void aout_drop(void);			/* 丢 ALSA 缓冲 + 位置归零（seek） */
int  aout_xrun(void);
int  aout_running(void);
void aout_stop(void);

#endif
