-- apps/reader.lua — native-reader 自动化模块
--
-- 和 /opt/reader/automation/reader.lua 同一套接口，只是给 keybd 用：
-- 「这个 app 在不在前台」+「键名 → 动作」+「动作怎么执行」。
--
-- 阅读器的自动化口是「一行 JSON 请求 + 半关写端 + 回一行 JSON」，
-- 所以每个动作一次连接，不要试图长连（服务端读到 EOF 才回）。
--
-- 动作名：socket 的 fn id（reader.next / app.toc / …），另有本地捷径：
--   font+ / font- / font0   改字号（读 state.font_size 再 settings.set）
--   page3 / chapter2        直接跳页 / 跳章

local M = {
	name = "reader",
	desc = "native-reader 阅读器（socket 自动化）",
	order = 20,
}

M.socket = os.getenv("READER_AUTOMATION_SOCK") or "/tmp/native-reader-automation.sock"

-- 阅读器自己也被 SDL 抓键；keybd 默认独占遥控（GRAB=1），所以方向键/pdf 键
-- 也要在这里映射，否则 reader 收不到（两处都映射就会翻两页，只留这一处）。
M.map = {
	-- 翻页
	RIGHT = "next", DOWN = "next", PAGEDOWN = "next", NEXTSONG = "next",
	NEXT = "next", FASTFORWARD = "next", SCROLLDOWN = "next", CHANNELDOWN = "next",
	SPACE = "next",
	LEFT = "prev", UP = "prev", PAGEUP = "prev", PREVIOUS = "prev",
	PREVIOUSSONG = "prev", REWIND = "prev", SCROLLUP = "prev", CHANNELUP = "prev",
	-- 面板
	ENTER = "app.toc", KPENTER = "app.toc", OK = "app.toc", SELECT = "app.toc",
	MENU = "app.toc", EPG = "app.toc", TEXT = "app.toc", SUBTITLE = "app.toc",
	HELP = "app.toc", BACK = "app.toc", ESC = "app.toc",
	HOME = "app.library", HOMEPAGE = "app.library", HOMEPAGE2 = "app.library",
	MEDIA = "app.library", ALL_APPS = "app.library",
	INFO = "app.bookmarks", BLUE = "app.bookmarks", GREEN = "bookmark.add",
	SETUP = "app.settings", OPTION = "app.settings", AUDIO = "app.settings",
	PLAYPAUSE = "app.eye", PAUSE = "app.eye", RED = "app.eye", M = "app.eye",
	C = "app.dual", YELLOW = "app.dual",
	ZOOMIN = "font+", ZOOMOUT = "font-", ZOOMRESET = "font0",
	VOLUMEUP = "font+", VOLUMEDOWN = "font-",   -- 阅读器没音频，音量键借来调字号
	TAB = "app.maximize", F11 = "app.fullscreen",
	EXIT = "app.quit", STOPCD = "app.quit",
	["1"] = "page1", ["2"] = "chapter2", ["3"] = "chapter3", ["4"] = "chapter4",
	["5"] = "chapter5", ["6"] = "chapter6", ["7"] = "chapter7", ["8"] = "chapter8",
	["9"] = "chapter9",
	-- 遥控器上排 Ctrl+数字（盒子实测）
	["C-1"] = "app.library", ["C-2"] = "app.dual", ["C-3"] = "app.toc",
	["C-4"] = "font+", ["C-5"] = "font-",
}

-- 长按连发：只放行这些（翻页/字号）
function M.repeatable(action)
	return action == "next" or action == "prev" or action == "font+"
		or action == "font-"
end

local function call(env, fn, args)
	local body = ('{"cmd":"call","fn":"%s","args":%s}'):format(fn, args or "{}")
	local r, err = env.sock.json_req(M.socket, body, 1500)

	if not r then return false, err end
	if r.ok == false then return false, tostring(r.error or "failed") end
	return true, r
end

local function state(env)
	return env.sock.json_req(M.socket, '{"cmd":"state"}', 1500)
end

-- 前台判定：ping 得通就算在跑（socket 在但进程死了会连不上/没回应）
function M.detect(env)
	local r = env.sock.json_req(M.socket, '{"cmd":"ping"}', 400)

	return r ~= nil and r.ok == true, r and "pong" or "no reply"
end

function M.run(action, key, env)
	if action == "font+" or action == "font-" or action == "font0" then
		local s = state(env)
		local cur = s and s.state and tonumber(s.state.font_size) or 24
		local fs = cur

		if action == "font+" then fs = cur + 2
		elseif action == "font-" then fs = cur - 2
		else fs = 24 end
		fs = math.max(10, math.min(72, fs))
		local ok, err = call(env, "settings.set", ('{"font_size":%d}'):format(fs))

		return ok, ok and ("font_size=" .. fs) or err
	end

	if action == "bookmark.add" then
		local s = state(env)
		local page = s and s.state and s.state.page or 0
		local note = ("遥控器书签 p%s"):format(tostring(page))

		return call(env, "reader.bookmark.add", ('{"note":"%s"}'):format(note))
	end

	local page = action:match("^page(%d+)$")
	if page then return call(env, "reader.goto", ('{"page":%d}'):format(tonumber(page))) end

	local ch = action:match("^chapter(%d+)$")
	if ch then return call(env, "reader.goto", ('{"chapter":%d,"page":1}'):format(tonumber(ch))) end

	-- 没点的补前缀：next → reader.next
	if not action:find("%.") then action = "reader." .. action end
	return call(env, action, "{}")
end

function M.state(env)
	local s = state(env)

	if not s or not s.state then return nil end
	return {
		book = s.state.book,
		page = s.state.page,
		pages = s.state.pages,
		font_size = s.state.font_size,
	}
end

return M
