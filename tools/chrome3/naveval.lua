#!/opt/reader/bin/luajit
-- naveval.lua — 在盒上 chromium 的当前页面里 eval 一段 JS，打印结果（调试 browser-nav 用）
--
-- 用法: luajit naveval.lua <js文件> [端口，默认 9222]
-- 只走 CDP（/json/list 找 type=="page" 的那只），不开窗口、不截图。
local SRC = arg[1] or error("need js file")
local PORT = arg[2] or "9222"

arg = { [3] = PORT }
local lib = dofile("/root/cdplib.lua")

local f = assert(io.open(SRC, "r"))
local js = f:read("*a")
f:close()

local function pick_page()
	local ok, st, body = pcall(lib.http_get_json_list)
	if not ok or st ~= "200" then return nil end
	for _, t in ipairs(lib.jdec(body) or {}) do
		if t.type == "page" and t.webSocketDebuggerUrl then return t end
	end
	return nil
end

local t = pick_page() or error("没有 page target（chromium 没起来？）")
local path = t.webSocketDebuggerUrl:match("^wss?://[^/]+(/.*)$")
local ws = lib.ws_open(path) or error("ws 连不上")

local function rpc(id, method, params)
	ws.send_frame('{"id":' .. id .. ',"method":"' .. method .. '"'
		.. (params and ',"params":' .. params or '') .. '}')
	for _ = 1, 12 do
		local fr = ws.recv_frame()
		if not fr then return nil end
		if fr.op == 1 and fr.payload:find('"id":' .. id, 1, true) then return fr.payload end
	end
	return nil
end

rpc(1, "Runtime.enable")
local r = rpc(2, "Runtime.evaluate",
	'{"expression":' .. lib.jenc(js) .. ',"returnByValue":true,"awaitPromise":true}')
ws.close()
if not r then error("Runtime.evaluate 无响应") end
local obj = lib.jdec(r) or {}
local res = obj.result or {}
if res.exceptionDetails then
	print("JS 异常: " .. tostring((res.exceptionDetails.text or "")))
	print(tostring(res.exceptionDetails.exception and res.exceptionDetails.exception.description or ""))
	os.exit(1)
end
local v = res.result and res.result.value
if type(v) == "table" then
	print(lib.jenc(v))
elseif v == nil then
	print("null")
else
	print(tostring(v))
end
