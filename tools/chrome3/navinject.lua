#!/opt/reader/bin/luajit
-- navinject.lua — 把 browser-nav.js 注入 chromium 每个文档（方向键选 URL / OK 进入）
--
-- 常驻：每 2s 看一次 /json/list，对每个 page target 开一条 CDP websocket，
-- 发 Page.addScriptToEvaluateOnNewDocument（之后每次导航自动注入）+ Runtime.evaluate
-- （当前这只页面立刻生效）。target 变了（chromium 重启 / 新标签）就重连重注。
--
-- 用法: luajit navinject.lua [/root/browser-nav.js] [9222]
local bit  = require("bit")
local band = bit.band

local SRC_PATH = arg[1] or "/root/browser-nav.js"
local PORT     = arg[2] or "9222"
local LIB_PATH = "/root/cdplib.lua"
local LOG_PATH = "/tmp/navinject.log"

-- cdplib 加载时读全局 arg[3] 定 CDP 端口，先塞好
arg = { [3] = PORT }
local lib = dofile(LIB_PATH)

-- 单实例：浏览器每次启动都会把我们拉起来，重复的实例立刻退出，
-- 不要在启动命令里用 pkill -f 杀同名进程——那条命令行本身也含 "navinject.lua"，
-- 会把自己所在的 sh -c 一起杀掉（实测浏览器刚起来就被杀、退出码 0）。
local PID_PATH = "/run/navinject.pid"
local function own_pid()
	local ok, ffi = pcall(require, "ffi")
	if not ok then return nil end
	pcall(ffi.cdef, "int getpid(void);")
	return tonumber(ffi.C.getpid())
end
local function already_running()
	local f = io.open(PID_PATH, "r")
	if not f then return false end
	local pid = tonumber((f:read("*a") or ""):match("%d+"))
	f:close()
	if not pid or pid == 0 then return false end
	return os.execute("kill -0 " .. pid .. " 2>/dev/null") == 0
end

local function log(fmt, ...)
	local s = fmt:format(...)
	local f = io.open(LOG_PATH, "a")
	if f then f:write(os.date("%H:%M:%S "), s, "\n") f:close() end
end

local function read_src()
	local f = io.open(SRC_PATH, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- 一条连接 = 一个 target
local function open_target(wsurl, src)
	local path = wsurl:match("^wss?://[^/]+(/.*)$")
	if not path then return nil, "无法解析 ws url" end
	local ws, err = lib.ws_open(path)
	if not ws then return nil, err end

	local function rpc(id, method, params)
		local msg = { '"id":' .. id, '"method":"' .. method .. '"' }
		if params then msg[#msg + 1] = '"params":' .. params end
		ws.send_frame("{" .. table.concat(msg, ",") .. "}")
		-- 读回这一条的响应（最多等几个包，别的通知跳过）
		for _ = 1, 6 do
			local fr = ws.recv_frame()
			if not fr then return nil end
			if fr.op == 1 and fr.payload:find('"id":' .. id, 1, true) then
				return fr.payload
			end
		end
		return nil
	end

	local ok_body = rpc(1, "Page.enable")
	if not ok_body then ws.close() return nil, "Page.enable 无响应" end
	local escaped = lib.jenc(src)
	local r = rpc(2, "Page.addScriptToEvaluateOnNewDocument",
		'{"source":' .. escaped .. ',"runImmediately":true}')
	-- 老版本 chromium 不认 runImmediately，参数报错就用不带它的再来一次
	if r and r:find('"error"', 1, true) then
		r = rpc(3, "Page.addScriptToEvaluateOnNewDocument", '{"source":' .. escaped .. '}')
	end
	-- 当前页面（如果是老版本浏览器没有 runImmediately，靠这条补上）
	rpc(4, "Runtime.evaluate", '{"expression":' .. escaped .. ',"returnByValue":true}')
	return ws
end

local conns = {}   -- wsurl -> ws

local function alive()
	local p = io.popen("pgrep -x chromium >/dev/null 2>&1 && echo y")
	if not p then return false end
	local s = p:read("*a")
	p:close()
	return s and s:find("y") ~= nil
end

local function sweep(src)
	local body
	local ok, st, b = pcall(lib.http_get_json_list)
	if ok and st == "200" then body = b end
	if not body then return end
	local list = lib.jdec(body) or {}
	local seen = {}
	for _, t in ipairs(list) do
		if t.type == "page" and t.webSocketDebuggerUrl then
			local u = t.webSocketDebuggerUrl
			seen[u] = true
			if not conns[u] then
				local ws, err = open_target(u, src)
				if ws then
					conns[u] = ws
					log("inject ok %s (%s)", tostring(t.url), u:match("/devtools/page/(%w+)"))
				else
					log("inject fail %s: %s", tostring(t.url), tostring(err))
				end
			end
		end
	end
	-- 消失的 target 收掉连接（chromium 退出/关标签时连接已断，close 无害）
	for u, ws in pairs(conns) do
		if not seen[u] then pcall(ws.close) conns[u] = nil end
	end
end

if already_running() then
	log("already running, exit")
	os.exit(0)
end
local me = own_pid()
if me then local f = io.open(PID_PATH, "w") if f then f:write(tostring(me), "\n") f:close() end end

log("start, src=%s port=%s", SRC_PATH, PORT)
local last_src = nil
while true do
	if not alive() then
		for u, ws in pairs(conns) do pcall(ws.close) conns[u] = nil end
		os.execute("sleep 2")
	else
		local src = read_src()
		if src and src ~= last_src then
			-- 脚本内容变了（重新部署）：清掉旧连接，强制重注一遍
			if last_src then
				for u, ws in pairs(conns) do pcall(ws.close) conns[u] = nil end
			end
			last_src = src
		end
		if src then sweep(src) end
		os.execute("sleep 2")
	end
end
