-- /opt/keybord/config.lua — keybd 的可选覆盖（不改 keybd.lua 本身）
-- 改完 `systemctl restart keybd` 或往控制口发 {"cmd":"reload"}
return {
	-- 只吃这些设备（名字子串，逗号分隔）；nil = 除了 exclude 全吃
	devices = nil,
	exclude = "Mouse,Touch,Video,HDMI",
	-- 独占输入设备：开了 app 自己就收不到遥控（SDL/播放器都是），
	-- 全部按键由 keybd 翻译；关掉则各吃各的（容易一按两翻）
	grab = true,
	dedup_ms = 40,     -- 同一键在两个设备上报，去重窗口
	repeat_ms = 220,   -- 长按连发最小间隔
	focus_ttl = 800,   -- 前台判定缓存（越小越灵，越大越省钱）
	-- 每键 fork 一次 `luajit -e 'dofile("/opt/keybord/keys/<app>.lua")' <键名>`：
	-- 键位=keys/<app>.lua（第二步冻结的写死键码表，真源），执行=apps/<app>.lua
	-- → app 自己的自动化口。没有 keys/<app>.lua 时退回 act.lua <app> <action>。
	-- 守护只负责判前台+分发，脚本改了不用重启 keybd。
	dispatch = "exec",
	log = "/tmp/keybd.log",
	sock = "/tmp/keybd.sock",
}
