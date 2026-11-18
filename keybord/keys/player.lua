-- keys/player.lua — 【第二步·固定脚本】盒子遥控 → v4l2hevc 播放器
--
-- 写死的键码表；动作名对齐 /root/play.sh key <动作> 与播放器控制口 /tmp/play.sock：
--   toggle fwd back fwdmore backmore volup voldn mute menu status quit
--
-- 执行：
--   luajit -e 'dofile("/opt/keybord/keys/player.lua")' ENTER
-- 看表：
--   luajit -e 'dofile("/opt/keybord/keys/player.lua")' --list
local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"

return dofile(ROOT .. "/keys/base.lua").define("player", {
	-- ── 播放/暂停 ────────────────────────────────────────
	{ "ENTER",      28, nil, "toggle" },  -- OK
	{ "SPACE",      57, nil, "toggle" },
	{ "PLAYPAUSE", 164, nil, "toggle" },
	{ "C-1",         2, "C", "toggle" },  -- ⌂ 上排第 1 键借作播放/暂停

	-- ── 快退 / 快进（连发）────────────────────────────────
	{ "RIGHT",     106, nil, "fwd" },
	{ "LEFT",      105, nil, "back" },
	{ "UP",        103, nil, "fwdmore" },
	{ "DOWN",      108, nil, "backmore" },
	{ "NEXTSONG",  163, nil, "fwd" },
	{ "PREVIOUSSONG",165, nil, "back" },

	-- ── 音量 ────────────────────────────────────────────
	{ "VOLUMEUP",  115, nil, "volup" },   -- 🔊＋  code=115
	{ "VOLUMEDOWN",114, nil, "voldn" },   -- 🔊−  code=114
	{ "MUTE",      113, nil, "mute" },    -- 🔇
	{ "C-2",         3, "C", "mute" },    -- 上排借键
	{ "C-4",         5, "C", "volup" },
	{ "C-5",         6, "C", "voldn" },

	-- ── 菜单 / 状态 / 退出 ────────────────────────────────
	{ "C-3",         4, "C", "menu" },    -- ☰ 菜单
	{ "BLUE",      401, nil, "status" },  -- 看进度
	{ "ESC",         1, nil, "quit" },    -- ↶ 退出
	{ "STOPCD",    166, nil, "quit" },
}, {
	order = 30,
	desc = "v4l2hevc 播放器（/tmp/play.sock）",
	repeatable = { "fwd", "back", "fwdmore", "backmore", "volup", "voldn" },
})
