-- apps/shell.lua — 兜底：没有别的 app 在前台时
--
-- 盒子空屏时遥控器总得干点什么：首页键拉起阅读器，其余记日志不报错。
-- order=0，永远 detect 成功，所以它是最后一层。

local M = {
	name = "shell",
	desc = "空屏兜底（拉起 app / 忽略）",
	order = 0,
}

M.map = {
	HOME = "launch.reader", HOMEPAGE = "launch.reader", HOMEPAGE2 = "launch.reader",
	ENTER = "launch.reader", OK = "launch.reader", MENU = "launch.reader",
	BACK = "noop", ESC = "noop",
	["C-1"] = "launch.reader",
}

function M.repeatable(action) return action == "noop" end

local function running(pat)
	local p = io.popen("pgrep -f '" .. pat .. "' 2>/dev/null")

	if not p then return false end
	local out = p:read("*a")

	p:close()
	return out ~= nil and out ~= ""
end

function M.detect(env) return true, "fallback" end

function M.run(action, key, env)
	if action == "launch.reader" then
		if running("[n]ative-reader") then return false, "reader already running" end
		local rc = os.execute("/opt/reader/box-launch.sh >/dev/null 2>&1")

		env.log("launch reader rc=%s", tostring(rc))
		return rc == 0 or rc == true, "launched"
	end

	return true, "noop(" .. tostring(key) .. ")"
end

return M
