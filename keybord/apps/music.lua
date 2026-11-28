-- apps/music.lua — 音乐播放器（/root/music.sh = mpv 全屏 + 频谱 + 列表 OSD）
--
-- 控制口是 mpv 的 JSON IPC：/tmp/m.sock，一行一个 JSON 请求，一行 JSON 应答。
--   {"command":["cycle","pause"]}       播放/暂停
--   {"command":["playlist-next","force"]} 下一首（force=队列末尾也切）
--   {"command":["add","volume",5]}      音量 ±
--   {"command":["cycle","mute"]}        静音开关
--   {"command":["quit"]}                退出（mpv 放掉 DRM，桌面自己 resume）
--
-- mpv 自己不吃遥控（keybd grab 了设备），所以键→动作只在这一份 map 里。

local M = {
	name = "music",
	desc = "mpv 音乐播放器（/tmp/m.sock）",
	order = 30,     -- 和播放器同级：两者靠各自 socket 判活，不会同时在前台
}

M.socket = os.getenv("MUSIC_SOCK") or "/tmp/m.sock"

M.map = {
	-- 播放/暂停
	ENTER = "toggle", KPENTER = "toggle", OK = "toggle", SELECT = "toggle",
	SPACE = "toggle", PLAYPAUSE = "toggle", PLAY = "toggle", PAUSE = "toggle",
	-- 上一首 / 下一首
	RIGHT = "next", NEXTSONG = "next",
	LEFT = "prev", PREVIOUSSONG = "prev",
	-- 音量 / 静音
	-- 这台的遥控音量键上报的不是 VOLUMEUP/KEY_VOLUMEUP(115)，而是
	-- LEFTCTRL+KEY_4 / LEFTCTRL+KEY_5（name 为 C-4 / C-5），所以两头都要写。
	VOLUMEUP = "volup", VOLUMEDOWN = "voldn", MUTE = "mute",
	C4 = "volup", C5 = "voldn", C2 = "mute",
	["C-4"] = "volup", ["C-5"] = "voldn", ["C-2"] = "mute",
	-- 状态 / 退出
	INFO = "status", BLUE = "status",
	BACK = "quit", ESC = "quit", EXIT = "quit", STOP = "quit", STOPCD = "quit",
}

local CMD = {
	toggle = '{"command":["cycle","pause"]}',
	next = '{"command":["playlist-next","force"]}',
	prev = '{"command":["playlist-prev","force"]}',
	volup = '{"command":["add","volume",5]}',
	voldn = '{"command":["add","volume",-5]}',
	mute = '{"command":["cycle","mute"]}',
	quit = '{"command":["quit"]}',
	status = '{"command":["get_property","media-title"]}',
}

-- 长按连发：切歌/音量可以重复，开关类不行
function M.repeatable(action)
	return action == "next" or action == "prev" or action == "volup" or action == "voldn"
end

local function ipc(env, json, ms)
	local ok, r, err = env.sock.req(M.socket, json, ms or 400, true)

	if not ok then return false, err end
	if not r or r == "" then return false, "empty reply" end
	-- mpv 出错时回 error:"property not found" 之类，成功一律 "success"
	local e = r:match('"error"%s*:%s*"([^"]*)"')

	if e and e ~= "success" then return false, e end
	return true, (r:gsub("%s+$", ""))
end

function M.detect(env)
	local ok = ipc(env, '{"command":["get_property","pause"]}', 300)

	return ok, ok and "ipc ok" or "no reply"
end

function M.run(action, key, env)
	if action == "volume" then action = "volup" end
	local json = CMD[action]

	if not json then return false, "未知动作：" .. tostring(action) end
	return ipc(env, json)
end

-- 桌面/agent 问「在放什么」用
function M.state(env)
	local ok, r = ipc(env, '{"command":["get_property","media-title"]}', 400)

	if not ok or not r then return nil end
	local title = r:match('"data"%s*:%s*"(.-)"')
	local s = { playing = true, title = title }

	return s
end

return M
