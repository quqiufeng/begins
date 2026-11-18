-- apps/player.lua — 播放器（/root/play.sh + 内置 pctl）自动化模块
--
-- 播放器进程自带控制口 /tmp/play.sock：一行文本命令，一行 JSON 应答。
--   status | pos | pause | resume | toggle | mute | vol <±N> | seek <秒> | quit
-- 它自己也抓 evdev 遥控（pctl.c 的 rc_thread）；keybd 抓走设备后它抓不到，
-- 会往 /tmp/play-rc.log 记一条 grab 失败继续跑，不冲突。
--
-- 摇控器上 fwd/back/fwdmore/backmore/menu 这些语义在 play.sh 里（play.sh key <动作>），
-- 这里给映射表，逐键直接走 pctl，只有 menu 才 fork 一次 play.sh。

local M = {
	name = "player",
	desc = "v4l2hevc 播放器（/tmp/play.sock）",
	order = 30,     -- 比 reader 高：播放器全屏独占，跑着就是它
}

M.socket = os.getenv("PLAY_SOCK") or "/tmp/play.sock"
M.play_sh = os.getenv("PLAY_SH") or "/root/play.sh"

-- 键 → 动作名（和 play.sh keys 的动作名一致，方便对照文档）
M.map = {
	ENTER = "toggle", KPENTER = "toggle", OK = "toggle", SELECT = "toggle",
	SPACE = "toggle", PLAYPAUSE = "toggle", PLAY = "toggle", PAUSE = "toggle",
	RIGHT = "fwd", FASTFORWARD = "fwd", NEXTSONG = "fwd",
	LEFT = "back", REWIND = "back", PREVIOUSSONG = "back",
	UP = "fwdmore", PAGEUP = "fwdmore",
	DOWN = "backmore", PAGEDOWN = "backmore",
	VOLUMEUP = "volup", VOLUMEDOWN = "voldn", MUTE = "mute",
	MENU = "menu", OPTION = "menu", C = "menu",
	STOP = "quit", STOPCD = "quit", BACK = "quit", ESC = "quit", EXIT = "quit",
	INFO = "status", BLUE = "status",
	["C-2"] = "mute", ["C-3"] = "menu", ["C-4"] = "volup", ["C-5"] = "voldn",
}

-- pctl 命令（不走 play.sh，零 fork，长按连发才跟得上）
local PCTL = {
	toggle = "toggle",
	mute = "mute",
	quit = "quit",
	volup = "vol +10",
	voldn = "vol -10",
	fwd = "seek 30",
	back = "seek -30",
	fwdmore = "seek 300",
	backmore = "seek -300",
}

function M.repeatable(action)
	return action ~= "toggle" and action ~= "mute" and action ~= "quit"
		and action ~= "menu" and action ~= "status"
end

-- 优先走 libpctl.so（FFI 直连，零 fork）；没编进/没装上再退回 sock.lua
local P
pcall(function()
	P = require("pctl")
	if not P.ffi then P = nil end
end)

local function pctl(env, cmd)
	if P and P.socket() ~= M.socket then
		-- 播放器和 keybd 用同一个口（PLAY_SOCK/PCTL_SOCK），不一致时对齐
		P.bind(M.socket)
	end
	if P then
		local r, err = P.cmd(cmd)

		if not r then return false, err end
		if r:find('"error"') or r:find('"ok":0') or r:find('"ok": *false') then
			return false, r
		end
		return true, r:gsub("%s+$", "")
	end

	local ok, r, err = env.sock.req(M.socket, cmd, 1200)

	if not ok then return false, err end
	if not r or r == "" then return false, "empty reply" end
	if r:find('"ok":0') or r:find('"ok": *false') then return false, r end
	return true, r:gsub("%s+$", "")
end

-- 前台判定：socket 在且 status 有回应
function M.detect(env)
	local ok, r = pctl(env, "status")

	return ok and r ~= nil, ok and "status ok" or "no reply"
end

function M.run(action, key, env)
	if action == "status" then
		local ok, r = pctl(env, "status")

		return ok, r
	end

	if PCTL[action] then return pctl(env, PCTL[action]) end

	-- 其余交给 play.sh（menu/seek 绝对值之类，一次 fork 可接受）
	local cmd = ("%s key %s >/dev/null 2>&1"):format(M.play_sh, action)
	local rc = os.execute(cmd)

	return rc == 0 or rc == true, action
end

function M.state(env)
	local ok, r = pctl(env, "status")

	if not ok or not r then return nil end
	local dec = env.sock.decode
	return (pcall(dec, r)) and dec(r) or nil
end

return M
