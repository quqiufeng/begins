-- explore.lua — 【第一步】动态探索一个 app 的自动化口（不改文件，随便试）
--
-- 目的：先摸清「这个 app 能干什么、现在什么状态、键位怎么走」，试稳了再用
-- --freeze 落成 keys/<app>.lua（第二步的固定脚本）。
--
-- 用法（app 省略 = reader）：
--   luajit -e 'dofile("/opt/keybord/explore.lua")' reader
--       → 探活 + 动作清单（socket 的 list）+ 当前状态 + 键表覆盖对照
--   luajit -e 'dofile("/opt/keybord/explore.lua")' reader --try app.toc
--       → 当场执行一个动作，看结果/看屏幕
--   luajit -e 'dofile("/opt/keybord/explore.lua")' reader --seq "app.library,app.toc"
--       → 连做几步
--   luajit -e 'dofile("/opt/keybord/explore.lua")' reader --keys 10
--       → 开 keybd 学码 10 秒，读回真实键名/码（配遥控器按一遍）
--   luajit -e 'dofile("/opt/keybord/explore.lua")' reader --freeze
--       → 把当前 app.map(+maps 覆盖) 落成 keys/reader.lua（固定脚本）
--
-- --freeze 生成的是「写死键码表」，之后每键就是：
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' <键名>

local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"
package.path = ROOT .. "/?.lua;" .. package.path

local sock = require("sock")
local keynames = require("keynames")

local KEYBD_SOCK = os.getenv("KEYBD_SOCK") or "/tmp/keybd.sock"
local KEYBD_LOG = os.getenv("LOG") or "/tmp/keybd.log"

-- `luajit -e '…' A B` 时 A 落在 arg[0]
local argv = {}

if arg then
	for i = 0, #arg do
		local v = arg[i]
		-- arg[0] 用 `luajit xxx.lua` 直跑时是脚本名，跳过；`-e` 时它是第一个参数
		local skip = (i == 0 and v or ""):match("%.lua$") ~= nil

		if v and v ~= "" and not skip then argv[#argv + 1] = v end
	end
end

local app_name = argv[1] or "reader"
local function log(fmt, ...) io.stderr:write(("[explore] " .. fmt .. "\n"):format(...)) end

if app_name:sub(1, 2) == "--" then
	log("第一个参数要给 app 名（reader/player/…）")
	os.exit(2)
end

local appfile = ROOT .. "/apps/" .. app_name .. ".lua"
local ok, app = pcall(dofile, appfile)

if not ok then log("载入 %s 失败: %s", appfile, tostring(app)); os.exit(1) end

local ENV = { sock = sock, log = log, cfg = {}, root = ROOT }

-- 载入（可能还没有的）固定脚本，只取数据不执行
local function load_keys()
	local f = ROOT .. "/keys/" .. app_name .. ".lua"
	local fh = io.open(f)

	if not fh then return nil, f end
	fh:close()
	_KEYBD_DATA_ONLY = true
	local ok2, m = pcall(dofile, f)
	_KEYBD_DATA_ONLY = nil
	if not ok2 then return nil, tostring(m) end
	return m, f
end

-- —— 反向键名表：键名 → evdev 码 ——
local code_of = {}

for c, n in pairs(keynames) do
	if not code_of[n] then code_of[n] = c end
end

local function decode_key(name)
	local mod, base = name:match("^([CSAM]+)%-(.+)$")

	if mod then
		local c = code_of[base]

		return c, c and mod
	end
	return code_of[name], nil
end

-- —— 探索：这个 app 现在什么样、能干什么 ——
local function probe()
	print(("app        %s  (%s)"):format(app.name or app_name, app.desc or "?"))
	local okd, det, info = pcall(app.detect, ENV)

	print(("detect     %s  %s"):format(okd and det and "UP" or "down", tostring(info or "")))

	local st = app.state and select(2, pcall(app.state, ENV)) or nil

	print("state      " .. (st and (sock.encode(st) or "?") or "nil"))

	local actions, actsrc = {}, "app 自动化口"
	local r = app.socket and sock.json_req(app.socket, '{"cmd":"list"}', 1200) or nil

	if r and type(r.actions) == "table" then
		actions = r.actions
	else
		actsrc = "socket 不支持 list，退回本模块已知动作"
		if app.socket then print(("list       %s"):format(tostring(r and (r.error or "空")))) end
		-- 已知动作：键表 + map 里出现过的动作名
		local seen = {}

		for _, m in ipairs({ app.map or {}, (load_keys() or {}).map and (load_keys()).map() or {} }) do
			for _, a in pairs(m) do
				if not seen[a] then seen[a] = true; actions[#actions + 1] = a end
			end
		end
	end

	local km, kf = load_keys()
	local kmap = km and km.map() or {}
	local mapped = {}   -- 动作 → 键名

	for k, a in pairs(app.map or {}) do mapped[a] = mapped[a] or k end
	for k, a in pairs(kmap) do mapped[a] = mapped[a] or k end

	if #actions > 0 then
		print(("actions(%d)  [%s]"):format(#actions, actsrc))
		for _, a in ipairs(actions) do
			print(("  %-24s %s"):format(a, mapped[a] and ("键 " .. mapped[a]) or "（还没键）"))
		end
	end

	-- 键表本身
	local src = km and kf or (ROOT .. "/maps/" .. app_name .. ".lua")
	print(("keys       %s"):format(src))
	local n = 0

	for k, a in pairs(app.map or {}) do
		n = n + 1
		print(("  %-6s -> %-20s %s"):format(k, a, kmap[k] and "" or "[未冻结]"))
	end
	if n == 0 then print("  （app.map 空，只有 keybd 手工 map）") end
end

-- —— 动态执行一个动作 ——
local function try(action)
	local okr, res, detail = pcall(app.run, action, nil, ENV)

	if type(detail) == "table" then detail = sock.encode(detail) end
	if type(res) == "table" then res = sock.encode(res) end
	print(("try %-24s %s %s"):format(action, okr and res and "ok" or "FAILED",
		tostring(okr and (detail or "-") or res)))
	return okr and res
end

-- —— 学码：让 keybd 只记键，读回真实键名/码 ——
local function learn(sec)
	local r = sock.json_req(KEYBD_SOCK, '{"cmd":"learn","on":true}', 600)

	if not r or not r.ok then
		log("keybd 控制口连不上（%s）：先起 keybd 或手动 LEARN=1", KEYBD_SOCK)
		return 1
	end
	print(("学码 %d 秒：按遥控器上的键…"):format(sec))
	os.execute(("sleep %d"):format(sec))
	sock.json_req(KEYBD_SOCK, '{"cmd":"learn","on":false}', 600)

	local p = io.popen(("grep 'LEARN' %s 2>/dev/null | tail -n 30"):format(KEYBD_LOG))

	if p then
		for l in p:lines() do print(l) end
		p:close()
	end
	return 0
end

local function show_keys()
	local r = sock.json_req(KEYBD_SOCK, '{"cmd":"state"}', 800)

	if r then
		print(("keybd      focus=%s dispatch=%s learn=%s"):format(tostring(r.focus),
			tostring(r.dispatch), tostring(r.learn)))
		print(("最近按键   %s"):format(tostring(r.keys)))
	end
	return 0
end

-- —— 冻结：把键位落成 keys/<app>.lua（第二步）——
local function freeze(out)
	local km, kf = load_keys()
	local map = {}

	for k, a in pairs(app.map or {}) do map[k] = a end
	-- 固定脚本里已有、map 里没有的（手调加过的）也保留
	if km then
		for _, e in ipairs(km.list) do
			if not map[e.key] then map[e.key] = e.act end
		end
	end

	local rows, skip = {}, {}

	for k, a in pairs(map) do
		local c, mod = decode_key(k)

		if c then
			rows[#rows + 1] = { key = k, code = c, mod = mod, act = a }
		else
			skip[#skip + 1] = k
		end
	end
	table.sort(rows, function(x, y)
		if (x.code or 0) == (y.code or 0) then return x.key < y.key end
		return (x.code or 0) < (y.code or 0)
	end)

	out = out or (ROOT .. "/keys/" .. app_name .. ".lua")
	local f = assert(io.open(out, "w"))
	f:write(("-- %s — 【第二步·冻结】由 explore.lua --freeze 于 %s 生成，可手改\n")
		:format(out, os.date("%Y-%m-%d %H:%M")))
	f:write(('local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"\n\n'))
	f:write(('return dofile(ROOT .. "/keys/base.lua").define("%s", {\n'):format(app_name))
	for _, e in ipairs(rows) do
		f:write(('\t{ "%s", %d, %s, "%s" },\n'):format(e.key, e.code,
			e.mod and ('"%s"'):format(e.mod) or "nil", e.act))
	end
	f:write(("}, {\n\torder = %d,\n\tdesc = %q,\n"):format(app.order or 10,
		app.desc or app_name))
	if app.repeatable then
		local reps = {}
		-- 从键表里推：动作名重复出现的才连发没意义，这里只保留翻转类
		for _, a in ipairs({ "next", "prev", "font+", "font-", "fwd", "back",
			"fwdmore", "backmore", "volup", "voldn" }) do
			local has = false
			for _, e in ipairs(rows) do if e.act == a then has = true; break end end
			if has then reps[#reps + 1] = ('"%s"'):format(a) end
		end
		f:write(("\trepeatable = { %s },\n"):format(table.concat(reps, ", ")))
	end
	f:write("})\n")
	f:close()

	print(("freeze     %s（%d 键）"):format(out, #rows))
	if #skip > 0 then
		print("跳过（keynames 里没有这个键名）: " .. table.concat(skip, ", "))
	end
	print("之后每键：luajit -e 'dofile(\"" .. out .. "\")' <键名>")
	return 0
end

-- —— 参数分发 ——
local i, rc = 2, 0

while argv[i] do
	local a = argv[i]

	if a == "--try" then
		print("try        " .. tostring(argv[i + 1]))
		rc = try(argv[i + 1]) and 0 or 1
		i = i + 2
	elseif a == "--seq" then
		for one in tostring(argv[i + 1]):gmatch("[^,]+") do
			one = one:gsub("^%s+", ""):gsub("%s+$", "")
			if one ~= "" then rc = try(one) and rc or 1 end
		end
		i = i + 2
	elseif a == "--keys" then
		rc = show_keys()
		i = i + 1
	elseif a == "--learn" then
		local sec = tonumber(argv[i + 1]) or 8

		rc = learn(sec)
		i = (tonumber(argv[i + 1]) and i + 2 or i + 1)
	elseif a == "--freeze" then
		rc = freeze(argv[i + 1])
		i = i + 1
	elseif a == "--state" then
		local st = app.state and select(2, pcall(app.state, ENV)) or nil

		print(st and (sock.encode(st) or "?") or "nil")
		i = i + 1
	elseif a:sub(1, 2) == "--" then
		probe()
		i = i + 1
	else
		i = i + 1   -- 多余的位置参数（比如 --freeze 的输出路径）忽略
	end
end

if i == 2 then probe() end
os.exit(rc)
