/* pctl.h — 播放器内置控制面。
 *
 * 两件事，以前分别由 mpvctl + rcinputd 两个二进制干：
 *   1. /tmp/play.sock：一行一条命令，一行 JSON 应答。play.sh 用
 *      `player -c <命令>` 说话（同一个二进制既是服务端也是客户端）。
 *   2. evdev 遥控：按键直接在播放进程里变成动作，不再 fork 一个守护。
 *
 * 播放器侧只需要提供两个取值回调（位置/解出帧数），其余状态 pctl 自己维护。
 */
#ifndef PCTL_H
#define PCTL_H

/* 起控制口线程（以及遥控线程，RC=0 可关）。在主循环之前调一次。 */
void pctl_start(void);
/* 待播前的"打到哪儿了"：毫秒 + 已解出帧数，由主循环注册 */
void pctl_set_sources(long (*pos_ms)(void), int (*au)(void));
/* 就地 seek 回调：返回 1 表示播放器自己接管（spawn 模式，DRM 不放），
 * 返回 0 交回 play.sh 整链重开。参数是相对秒数（可为负）。 */
void pctl_set_seek(int (*fn)(int rel));
/* 绝对跳回调（"seekto 秒" 和 "seek 0" 回片头）：返回 1 = 已接管。 */
void pctl_set_seek_abs(int (*fn)(double sec));
/* 主循环每轮问一次：暂停就让出 CPU，不喂流也不上屏 */
int  pctl_paused(void);
/* 累计暂停秒，播放器加到时间轴原点上（resume 不补放欠帧） */
double pctl_pause_seconds(void);
/* 主循环在退出前调：关 socket / 释放遥控设备 */
void pctl_stop(void);

/* 键位表（rcmap.h）打到 stdout：`player -K`。脚本/文档的唯一取处。 */
void pctl_keymap_dump(void);

/* 客户端模式：`player -c <命令>`。返回进程退出码。 */
int  pctl_client(int argc, char **argv);

#endif
