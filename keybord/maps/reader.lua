-- maps/reader.lua — 盒子遥控器（XING WEI 2.4G）实测键位，覆盖 apps/reader.lua 的默认 map
--
-- 实测环境：全部 11 键只从 event0（"XING WEI 2.4G USB USB Composite Device"，
-- 键盘接口）上报，每个键一次 down + 一次 up，无重复设备帧。
--   event2/3/4 = Consumer/System Control，event5 = meson-ir(红外)，这几个没上报过键。
--
-- 上排 5 键是 LEFTCTRL(29) + KEY_1..KEY_5，keybd 内部拼成 C-1..C-5；
-- 方向/OK/返回是裸键。改名按 keybd 的 MODS 规则：C-=Ctrl S-=Shift A-=Alt。
--
-- 动作名 = reader 自动化 socket 的 fn id（app.* / reader.*），本文件就是唯一真源：
-- 键 → 动作在这里写死，具体执行是 `luajit -e 'dofile("/opt/keybord/act.lua")'
-- <app> <action>` 每次按键 fork 一次（DISPATCH=exec），按前台 app 动态选脚本。
return {
	-- ── 上排 5 键：Ctrl+1..5 ─────────────────────────────
	["C-1"] = "app.library", -- ⌂ 首页      code=2   KEY_1 + Ctrl
	["C-2"] = "app.dual",    -- 🔇 静音      code=3   KEY_2 + Ctrl（阅读器无音频，借作单/双栏）
	["C-3"] = "app.toc",     -- ☰ 菜单       code=4   KEY_3 + Ctrl
	["C-4"] = "font+",       -- 🔊＋        code=5   KEY_4 + Ctrl（借作放大字号）
	["C-5"] = "font-",       -- 🔊−        code=6   KEY_5 + Ctrl（借作缩小字号）

	-- ── 方向键 + OK + 返回：裸键 ─────────────────────────
	UP    = "prev",          -- ⌃ 上        code=103 KEY_UP
	DOWN  = "next",          -- ⌄ 下        code=108 KEY_DOWN
	LEFT  = "prev",          -- ‹ 左        code=105 KEY_LEFT
	RIGHT = "next",          -- › 右        code=106 KEY_RIGHT
	ENTER = "app.ok",        -- OK          code=28  KEY_ENTER（面板回车/开目录）
	ESC   = "app.back",      -- ↶ 返回      code=1   KEY_ESC（关上层 → 回书架）
}
