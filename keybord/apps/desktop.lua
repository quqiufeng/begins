-- apps/desktop.lua — 桌面文件浏览器（KMSDRM UI，socket 自动化）
--
-- 桌面自己也被 SDL 抓过键，但 keybd 默认 GRAB=1 独占遥控，所以遥控必须
-- 从 keybd 派发进来：键名 → nav.* 动作 → /tmp/desktop-automation.sock。
--
-- 优先级最低（order=10）：阅读器(20)/播放器(30)在跑时它们自动胜出。
-- 桌面在外部 app 运行期间仍然活着、socket 也还在，所以 detect 只靠 ping
-- 还不够——用 order 让它永远排在 reader/player 之后。

local M = {
	name = "desktop",
	desc = "桌面文件浏览器（/opt/desktop，KMSDRM）",
	order = 10,
}

M.socket = os.getenv("DESKTOP_AUTOMATION_SOCK") or "/tmp/desktop-automation.sock"

M.map = {
	LEFT = "nav.left", RIGHT = "nav.right", UP = "nav.up", DOWN = "nav.down",
	PAGEUP = "nav.pageup", PAGEDOWN = "nav.pagedown",
	HOME = "nav.home", END = "nav.end", HOMEPAGE = "nav.home",
	ENTER = "nav.ok", KPENTER = "nav.ok", OK = "nav.ok", SELECT = "nav.ok",
	SPACE = "nav.ok",
	BACK = "nav.back", ESC = "nav.back",
	REFRESH = "nav.refresh", F5 = "nav.refresh",
	EXIT = "view.quit", QUIT = "view.quit", STOPCD = "view.quit",
	-- 遥控器上的 ☰ 键实测报 KEY_3 带 Ctrl 修饰（C-3）；键盘上也认 MENU/CONTEXT_MENU
	["C-3"] = "nav.menu", MENU = "nav.menu",
	OPTION = "nav.menu", CONTEXT_MENU = "nav.menu",
}

-- 长按连发：只放行方向键（翻列表）
function M.repeatable(action)
	return action == "nav.up" or action == "nav.down"
		or action == "nav.left" or action == "nav.right"
end

function M.detect(env)
	local r, err = env.sock.json_req(M.socket, '{"cmd":"ping"}', 500)

	if not r or r.ok ~= true then return false, "no reply: " .. tostring(err) end
	-- brief 是扁平应答：盒子上没装 cjson，sock.lua 的极简解码解不出嵌套 state
	local b = env.sock.json_req(M.socket, '{"cmd":"brief"}', 2500)

	if not b then return true, "up (brief timeout)" end
	if b.preview then return true, ("preview %s"):format(tostring(b.sel)) end
	return true, ("dir %s %s(%s/%s)"):format(tostring(b.dir),
		tostring(b.sel), tostring(b.selected), tostring(b.count))
end

local function call(env, id)
	local body = ('{"cmd":"click","id":"%s"}'):format(id)
	local r, err = env.sock.json_req(M.socket, body, 3000)

	-- 桌面重绘/开目录时可能接了连接晚回包；连不上才算真失败（会重试一次）。
	if not r then
		if tostring(err):find("connect failed", 1, true) then
			r, err = env.sock.json_req(M.socket, body, 3000)
		end
		if not r then return false, "sent (no reply: " .. tostring(err) .. ")" end
	end
	if r.ok == false then return false, tostring(r.error or "failed") end
	return true, r.result ~= nil and tostring(r.result) or "ok"
end

function M.run(action, key, env)
	if action:find("^nav%.") or action:find("^view%.") then
		return call(env, action)
	end
	return false, "未知动作 " .. tostring(action)
end

return M
