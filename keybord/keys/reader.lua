-- keys/reader.lua — 【第二步·固定脚本】盒子遥控 → 阅读器
--
-- 写死的键码表（键名, evdev 码, 修饰键, 动作）；动作名 = 阅读器自动化口的 fn id，
-- 另有本地捷径 font+/font-/prev/next/page3/…（见 apps/reader.lua）。
-- 键位来源：event0 "XING WEI 2.4G" 实测，上排 5 键 = LEFTCTRL + KEY_1..KEY_5。
-- （探索阶段生成的草稿走 explore.lua --freeze，落定后以这张表为准。）
--
-- 执行（keybd DISPATCH=exec 每按一次就是这条）：
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' C-1
-- 手调 / 看表：
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' --list
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' --state
local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"

return dofile(ROOT .. "/keys/base.lua").define("reader", {
	-- ── 上排 5 键：Ctrl+1..5（实测）─────────────────────────
	{ "C-1",   2, "C", "app.library" }, -- ⌂ 首页        KEY_1
	{ "C-2",   3, "C", "app.dual" },    -- 🔇 单/双栏     KEY_2（阅读器没音频）
	{ "C-3",   4, "C", "app.toc" },     -- ☰ 菜单         KEY_3
	{ "C-4",   5, "C", "font+" },       -- 🔊＋ → 字号＋  KEY_4
	{ "C-5",   6, "C", "font-" },       -- 🔊− → 字号−   KEY_5

	-- ── 方向 / OK / 返回（实测）───────────────────────────
	{ "UP",    103, nil, "prev" },      -- ⌃
	{ "DOWN",  108, nil, "next" },      -- ⌄
	{ "LEFT",  105, nil, "prev" },      -- ‹
	{ "RIGHT", 106, nil, "next" },      -- ›
	{ "ENTER",  28, nil, "app.ok" },    -- OK = 当前面板回车 / 开目录
	{ "ESC",     1, nil, "app.back" },  -- ↶ 返回 = 关上层 / 回书架

	-- ── 备用（红外/其它键盘；11 键遥控不会上报，留着不冲突）────
	{ "HOME",  102, nil, "app.library" },
	{ "1", 2, nil, "page1" }, { "2", 3, nil, "page2" }, { "3", 4, nil, "page3" },
	{ "4", 5, nil, "page4" }, { "5", 6, nil, "page5" }, { "6", 7, nil, "page6" },
	{ "7", 8, nil, "page7" }, { "8", 9, nil, "page8" }, { "9", 10, nil, "page9" },
}, {
	order = 20,
	desc = "native-reader 阅读器（socket 自动化）",
	repeatable = { "next", "prev", "font+", "font-" },
})
