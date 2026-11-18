/* rcmap.h — 遥控键位表：唯一起源（single source of truth）。
 *
 * 键码 → 动作只在这里写一次，三处都从它生成：
 *   pctl.c    → action_of() 查表把按键变成动作
 *   player -K → 打印整张表（键名/动作/修饰键），给脚本和文档用
 *   play.sh   → `play.sh keys` 调 -K 列表，`key <动作>` 由 do_key() 兑现
 *
 * 新增/改动一个键：只改下面 RCMAP_KEYS()，两边的行为同时生效。
 * 动作名必须与 play.sh do_key() 的 case 分支一致（toggle/volup/voldn/
 * mute/quit/fwd/back/fwdmore/backmore/menu），否则会被当成「未知动作」。
 *
 * 这块板（X96Max，XING WEI 2.4G USB 接收器，不是红外）上排 5 个功能键
 * 发的是 Ctrl+1..Ctrl+5，不是标准媒体键；首页键（Ctrl+1）按需求不登记，
 * 按下去静默 —— 这是故意的，不是失灵。
 */
#ifndef RCMAP_H
#define RCMAP_H

#include <linux/input.h>

/* 修饰键掩码：按键时按住的修饰键必须完全匹配（0 = 裸键） */
#define RC_M_CTRL	1
#define RC_M_SHIFT	2
#define RC_M_ALT	4

/* RC_KEY(修饰掩码, KEY_码, 动作)
 *   mods=0        裸键
 *   mods=RC_M_*   组合键，按住该修饰键时才匹配 */
#define RCMAP_KEYS(RC_KEY) \
	/* —— 上排功能键：Ctrl+2..5（Ctrl+1 首页键故意不登记）—— */ \
	RC_KEY(RC_M_CTRL, KEY_2, "mute")   /* 上排第 2 键：静音切换 */ \
	RC_KEY(RC_M_CTRL, KEY_3, "menu")   /* 上排第 3 键：菜单（没有 UI，忽略） */ \
	RC_KEY(RC_M_CTRL, KEY_4, "volup")  /* 上排第 4 键：音量 + */ \
	RC_KEY(RC_M_CTRL, KEY_5, "voldn")  /* 上排第 5 键：音量 - */ \
	/* —— 播放/暂停：OK 与空格都算 —— */ \
	RC_KEY(0, KEY_PLAYPAUSE,    "toggle") \
	RC_KEY(0, KEY_PLAY,         "toggle") \
	RC_KEY(0, KEY_PAUSE,        "toggle") \
	RC_KEY(0, KEY_ENTER,        "toggle") \
	RC_KEY(0, KEY_KPENTER,      "toggle") \
	RC_KEY(0, KEY_OK,           "toggle") \
	RC_KEY(0, KEY_SPACE,        "toggle") \
	/* —— 左右：±10s（整链重开）—— */ \
	RC_KEY(0, KEY_RIGHT,        "fwd") \
	RC_KEY(0, KEY_FASTFORWARD,  "fwd") \
	RC_KEY(0, KEY_NEXTSONG,     "fwd") \
	RC_KEY(0, KEY_LEFT,         "back") \
	RC_KEY(0, KEY_REWIND,       "back") \
	RC_KEY(0, KEY_PREVIOUSSONG, "back") \
	/* —— 上下：±60s —— */ \
	RC_KEY(0, KEY_UP,           "fwdmore") \
	RC_KEY(0, KEY_PAGEUP,       "fwdmore") \
	RC_KEY(0, KEY_DOWN,         "backmore") \
	RC_KEY(0, KEY_PAGEDOWN,     "backmore") \
	/* —— 音量/静音（软件增益，在播放器里就地做）—— */ \
	RC_KEY(0, KEY_VOLUMEUP,     "volup") \
	RC_KEY(0, KEY_VOLUMEDOWN,   "voldn") \
	RC_KEY(0, KEY_MUTE,         "mute") \
	/* —— 退出：连 ffmpeg 一起收，交给 play.sh —— */ \
	RC_KEY(0, KEY_STOP,         "quit") \
	RC_KEY(0, KEY_BACK,         "quit") \
	RC_KEY(0, KEY_ESC,          "quit") \
	RC_KEY(0, KEY_EXIT,         "quit") \
	RC_KEY(0, KEY_HOMEPAGE,     "quit")

#endif
