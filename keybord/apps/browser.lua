-- apps/browser.lua — 浏览器直出（cage + chromium kiosk）
--
-- keybd GRAB=1 独占遥控，cage/chromium 自己收不到遥控；keybd 会把按键原样重放进
-- uinput 虚拟键盘（passthru），所以方向键/OK 天然到页面里。
--
-- chromium kiosk 里「返回」没有浏览器 UI 可点，页面也不认 ESC（外部网站根本
-- 不处理 ESC），所以这里由 keybd 自己导航：合成 Alt+Left（chromium 的前进/后退
-- 加速键，任何站点都生效），走不动了（已经在首页）才退出浏览器。
--
-- 判断"在不在首页"靠 CDP：chromium 启动带 --remote-debugging-port=9222
-- （见 /opt/desktop/config.lua 的 browser cmd），取 /json/list 里第一个 page 的 url。
-- 拿不到 url 时保守只后退、不退出，避免在用户正常浏览时把浏览器杀掉。
--
-- order=25：高于 desktop(10)（桌面在浏览器底下还活着、socket 也在，否则按键会被
-- 它的 nav.* 吃掉），低于 player(30)。

local M = {
	name = "browser",
	desc = "浏览器（cage + chromium kiosk，直出）",
	order = 25,
}

M.cdp = os.getenv("BROWSER_CDP") or "http://127.0.0.1:9222"
M.home_pat = os.getenv("BROWSER_HOME") or "browser%-home%.html"

-- 键 → 动作名
M.map = {
	-- 返回：能后退就后退，已经在首页就退出（见 run）
	BACK = "back", ESC = "back", BROWSER_BACK = "back",
	-- 直接退出：☰ / STOP / EXIT
	MENU = "quit", OPTION = "quit", CONTEXT_MENU = "quit",
	["C-3"] = "quit", EXIT = "quit", STOP = "quit", STOPCD = "quit",
	-- 其余显式吞掉：不落回 desktop 的 nav.*（那会把背后的桌面翻一遍）
	LEFT = "noop", RIGHT = "noop", UP = "noop", DOWN = "noop",
	ENTER = "noop", KPENTER = "noop", OK = "noop", SELECT = "noop", SPACE = "noop",
	HOME = "noop", HOMEPAGE = "noop", END = "noop",
	PAGEUP = "noop", PAGEDOWN = "noop",
	REFRESH = "noop", F5 = "noop",
	VOLUMEUP = "noop", VOLUMEDOWN = "noop", MUTE = "noop",
	INFO = "noop", BLUE = "noop", RED = "noop", GREEN = "noop", YELLOW = "noop",
}

function M.repeatable(action) return action == "noop" end

local function up(pat)
	local p = io.popen("pgrep -x " .. pat .. " 2>/dev/null")

	if not p then return false end
	local out = p:read("*a")

	p:close()
	return out ~= nil and out ~= ""
end

-- 当前活动页面 url。盒子没装 cjson，按条目切一下手解。
local function cur_url()
	local p = io.popen("curl -s --max-time 1 " .. M.cdp .. "/json/list 2>/dev/null")

	if not p then return nil end
	local body = p:read("*a")

	p:close()
	if not body or body == "" then return nil end
	for chunk in body:gmatch("{[^{}]*}") do
		if chunk:find('"type"%s*:%s*"page"') then
			local u = chunk:match('"url"%s*:%s*"([^"]*)"')

			if u then return u end
		end
	end
	return body:match('"url"%s*:%s*"([^"]*)"')
end

local function at_home(u)
	if not u or u == "" or u == "about:blank" then return true end
	return u:find(M.home_pat) ~= nil
end

-- 页面自己后退：合成 KEY_BACK(158) 进 uinput 虚拟键盘，cage/libinput 收下后交给
-- chromium。实测（CDP 探针）：158 → 页面 keydown key="BrowserBack" keyCode=166，
-- chromium 的浏览器级「后退」也认它；而遥控器的返回键实测发的是 ESC(1)，
-- Chromium 里 Escape 只是「停止加载」，外部网站又不处理 ESC —— 这就是
-- 「网页打不开回主页」的根因：以前只把 ESC 直通过去，什么都不会发生。
-- 设备名带 keybd- 前缀，keybd 扫设备时跳过它，不会自激。
local function nav_back(env)
	local ok, ev = pcall(dofile, (env and env.root or "/opt/keybord") .. "/evdev.lua")

	if not ok or not ev then return false, "evdev 加载失败" end
	local fd, err = ev.uinput_create("keybd-nav")

	if not fd then return false, "uinput: " .. tostring(err) end
	ev.sleep(200)                    -- 等 libinput 热插拔认出来，太急会丢
	ev.uinput_emit(fd, 1, 158, 1)    -- KEY_BACK down
	ev.sleep(60)
	ev.uinput_emit(fd, 1, 158, 0)    -- up（漏了它内核会当长按一直连发后退）
	ev.sleep(100)
	ev.close(fd)
	return true, "key_back"
end

local function quit(env, key)
	-- 先收 chromium 再收 cage：反过来的话 cage 一退 chromium 会丢 wayland 连接刷崩溃日志。
	-- 模式带 [] 防止 pkill -f 匹配到自己这条 sh -c 命令行。
	os.execute("pkill -f '[c]hromium .*--kiosk' >/dev/null 2>&1; "
		.. "pkill -x cage >/dev/null 2>&1; sleep 0.5; "
		.. "systemctl unmask --runtime desktop >/dev/null 2>&1; "
		-- 必须 restart，不能 is-active||start：cage 起的时候把 DRM master 抢走了，
		-- 退出时不会还回来；desktop 进程还在（socket 也照答），但画不上屏 = 黑屏。
		-- desktop.service 是 KillMode=process，这里重启不会连坐 keybd 自己。
		.. "systemctl restart desktop")
	env.log("browser quit by %s", tostring(key))
	return true, "quit"
end

function M.detect(env)
	if not up("cage") then return false, "no cage" end
	return true, up("chromium") and "cage+chromium" or "cage"
end

function M.run(action, key, env)
	if action == "quit" then return quit(env, key) end
	if action == "back" then
		local u = cur_url()

		if u and at_home(u) then return quit(env, tostring(key) .. " @" .. u) end
		local ok, d = nav_back(env)

		return ok, ("back(%s) %s"):format(tostring(u), tostring(d))
	end
	return true, "noop(" .. tostring(key) .. ")"
end

return M
