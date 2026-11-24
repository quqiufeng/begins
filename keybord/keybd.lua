-- keybd.lua — 盒子常驻遥控/键盘守护（LuaJIT，无外部依赖）
--
-- 干三件事：
--   1. 独占读 /dev/input/event*（2.4G 遥控 + 红外 + 键盘，EV_KEY）
--   2. 判断「现在前台是哪个 app」——调用 apps/<name>.lua 的 detect()
--   3. 按该 app 的 map 把键翻成动作，交给它的 run() 执行（内部调用；
--      DISPATCH=exec 时改成 fork `luajit act.lua <app> <action>`，等价 luajit -e）
--
-- 每个 app 一份自动化 lua，接口和 reader 的一致：
--   name / desc / order / map / detect(env) / run(action,key,env) / repeatable(action)
--
-- 用法：
--   luajit keybd.lua                    # 常驻
--   LEARN=1 luajit keybd.lua            # 只记按键（学码）
--   luajit keybd.lua --key OK           # 手动注入一个键（不用遥控器也能测）
--   luajit keybd.lua --apps             # 看设备/前台判定
--   GRAB=0 luajit keybd.lua             # 不独占（和 SDL app 各自的键位共存）
--
-- 控制口 /tmp/keybd.sock（一行 JSON 请求，一行 JSON 应答）：
--   {"cmd":"state"}  {"cmd":"apps"}  {"cmd":"key","name":"RIGHT"}
--   {"cmd":"focus","app":"reader"}   {"cmd":"learn","on":true}
--   {"cmd":"reload"} {"cmd":"rescan"} {"cmd":"quit"}
--
-- 环境变量：DEVICES=名字子串(逗号分隔) EXCLUDE=Mouse,Touch GRAB=0
--           DEDUP_MS=40 REPEAT_MS=220 FOCUS_TTL=800 DISPATCH=inproc|exec
--           KEYBD_SOCK=/tmp/keybd.sock LOG=/tmp/keybd.log KEYBD_ROOT=/opt/keybord

local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"
package.path = ROOT .. "/?.lua;" .. package.path

local ffi = require("ffi")
local evdev = require("evdev")
local sock = require("sock")
local keynames = require("keynames")

local function num(v, d)
	local n = tonumber(v)
	return n or d
end

local CFG = {
	devices = nil,
	exclude = "Mouse,Touch,Video,HDMI",
	grab = true,
	dedup_ms = 40,
	repeat_ms = 220,
	focus_ttl = 800,
	sock = "/tmp/keybd.sock",
	log = "/tmp/keybd.log",
	appdir = ROOT .. "/apps",
	mapdir = ROOT .. "/maps",
	keydir = ROOT .. "/keys",
	dispatch = "inproc",
	learn = false,
	scan_ms = 2000,
}

-- /opt/keybord/config.lua 先铺底，环境变量最后覆盖（这样 service 里 Environment= 说了算）
pcall(function()
	local c = dofile(ROOT .. "/config.lua")

	if type(c) == "table" then
		for k, v in pairs(c) do CFG[k] = v end
	end
end)

local function env_num(k, key)
	local v = os.getenv(k)

	if v and v ~= "" then CFG[key] = tonumber(v) or CFG[key] end
end

if os.getenv("DEVICES") and os.getenv("DEVICES") ~= "" then CFG.devices = os.getenv("DEVICES") end
if os.getenv("EXCLUDE") then CFG.exclude = os.getenv("EXCLUDE") end
if os.getenv("LOG") then CFG.log = os.getenv("LOG") end
if os.getenv("KEYBD_SOCK") then CFG.sock = os.getenv("KEYBD_SOCK") end
if os.getenv("DISPATCH") then CFG.dispatch = os.getenv("DISPATCH") end
if os.getenv("GRAB") then CFG.grab = os.getenv("GRAB") ~= "0" end
if os.getenv("LEARN") then CFG.learn = os.getenv("LEARN") == "1" end
env_num("DEDUP_MS", "dedup_ms")
env_num("REPEAT_MS", "repeat_ms")
env_num("FOCUS_TTL", "focus_ttl")
CFG.appdir = ROOT .. "/apps"
CFG.mapdir = ROOT .. "/maps"
CFG.keydir = ROOT .. "/keys"

-- —— 日志 ——
local logf
local function log(fmt, ...)
	local line = ("[%s] " .. fmt .. "\n"):format(os.date("%Y-%m-%d %H:%M:%S"), ...)

	if not logf then logf = io.open(CFG.log, "a") end
	if logf then
		logf:write(line)
		logf:flush()
	else
		io.stderr:write(line)   -- 日志都开不了就退到 stderr（systemd 也是 append 同一个文件）
	end
end

local ENV = { sock = sock, log = log, cfg = CFG, root = ROOT }

-- —— 加载 app 模块 ——
local apps, app_by_name = {}, {}

local function merge_map(dst, src)
	if type(src) == "table" then
		for k, v in pairs(src) do dst[k] = v end
	end
end

local function ls(dir)
	local out = {}
	local p = io.popen("ls -1 " .. dir .. "/*.lua 2>/dev/null")

	if not p then return out end
	for l in p:lines() do out[#out + 1] = l end
	p:close()
	return out
end

local function load_apps()
	apps, app_by_name = {}, {}
	for _, f in ipairs(ls(CFG.appdir)) do
		local ok, m = pcall(dofile, f)

		if not ok then
			log("app load FAILED %s: %s", f, tostring(m))
		elseif type(m) == "table" and m.name then
			m.file = f
			-- /opt/keybord/maps/<app>.lua 覆盖默认键位（老 remote-map.lua 的用法）
			local mf = CFG.mapdir .. "/" .. m.name .. ".lua"
			local fh = io.open(mf)
			if fh then
				fh:close()
				local ok2, over = pcall(dofile, mf)
				if ok2 then merge_map(m.map, over); log("app %s: 覆盖键位 %s", m.name, mf) end
			end
			-- keys/<app>.lua：第二步落地的固定脚本，键码表就是唯一真源
			-- （只取数据不执行：置 _KEYBD_DATA_ONLY）
			local kf = CFG.keydir .. "/" .. m.name .. ".lua"
			local kfh = io.open(kf)
			if kfh then
				kfh:close()
				_KEYBD_DATA_ONLY = true
				local ok3, km = pcall(dofile, kf)
				_KEYBD_DATA_ONLY = nil
				if ok3 and type(km) == "table" and km.map then
					m.keysfile = kf
					merge_map(m.map, km.map())
					if km.repeatable then m.repeatable = km.repeatable end
					m.order = km.order or m.order
					log("app %s: 固定脚本 %s（%d 键）", m.name, kf, #(km.list or {}))
				else
					log("app %s: 固定脚本载入失败 %s: %s", m.name, kf, tostring(km))
				end
			end
			apps[#apps + 1] = m
			app_by_name[m.name] = m
		end
	end
	table.sort(apps, function(a, b)
		if (a.order or 0) == (b.order or 0) then return a.name < b.name end
		return (a.order or 0) > (b.order or 0)
	end)
	log("apps: %s", (function()
		local t = {}

		for _, a in ipairs(apps) do t[#t + 1] = ("%s(%d)"):format(a.name, a.order or 0) end
		return table.concat(t, " ")
	end)())
end

load_apps()

-- —— 前台判定（带缓存，避免每个键都 ping 两遍）——
local cache = { at = 0, app = nil, info = nil }
local forced = nil

local function app_of(name) return name and app_by_name[name] or nil end

local function resolve(force)
	local now = evdev.now_ms()

	if forced then
		local a = app_of(forced)

		if a then return a, "forced:" .. forced end
		log("forced app %s 不存在，忽略", forced)
		forced = nil
	end
	if not force and cache.app and now - cache.at < CFG.focus_ttl then
		return cache.app, cache.info
	end

	for _, a in ipairs(apps) do
		local ok, det, info = pcall(a.detect, ENV)

		if ok and det then
			cache.at, cache.app, cache.info = now, a, info or "up"
			return a, cache.info
		end
		if not ok then log("app %s detect 出错: %s", a.name, tostring(det)) end
	end
	cache.at, cache.app, cache.info = now, nil, "none"
	return nil, "none"
end

-- —— 动作执行 ——
-- luajit 必须是绝对路径：systemd 的 PATH 里没有 /opt/reader/bin，裸 `luajit`
-- 会 sh: luajit: not found → rc=127 → 每个动作都 FAILED（表现为遥控器完全没反应）。
local LUAJIT = os.getenv("LUAJIT_EXE")
if not LUAJIT or LUAJIT == "" then
	for _, c in ipairs({ "/opt/reader/bin/luajit", "/usr/local/bin/luajit", "/usr/bin/luajit" }) do
		local fh = io.open(c, "rb")
		if fh then fh:close(); LUAJIT = c; break end
	end
end
LUAJIT = LUAJIT or "luajit"

local function run_action(app, action, key)
	if CFG.dispatch == "exec" then
		-- 真·外部进程：按键 → fork 一次 luajit -e 跑该 app 的固定脚本
		-- keys/<app>.lua 存在就把它当唯一入口（它自己查固定键码表再调 app 自动化），
		-- 没有才退回 act.lua <app> <action>（探索期的临时调法）。
		local cmd

		-- 一律套 timeout：动作进程自己卡住（对端 socket 满/没应答）时，
		-- os.execute 会把整个 keybd 主循环一起拖死——表现就是"所有按键都没反应"。
		if app.keysfile then
			-- 传「动作名」而不是键名：键→动作的映射只该有一份（apps/<app>.lua 的
			-- M.map）。以前传键名，keys/<app>.lua 表里漏一个键（比如 BACK=158）
			-- 就被当成未知动作悄悄空转，遥控器按了没反应。
			cmd = ("timeout 6 %s -e 'dofile(%q)' %q >/dev/null 2>&1")
				:format(LUAJIT, app.keysfile, action)
		else
			cmd = ("timeout 6 %s -e 'dofile(%q)' %s %q >/dev/null 2>&1")
				:format(LUAJIT, ROOT .. "/act.lua", app.name, action)
		end
		local rc = os.execute(cmd)

		return rc == 0 or rc == true, "exec " .. (app.keysfile and "keys/" .. app.name .. ".lua" or "act.lua")
	end

	local ok, res, detail = pcall(app.run, action, key, ENV)

	if not ok then return false, "lua error: " .. tostring(res) end
	return res and true or false, detail
end

local ring = {}     -- 最近按键（控制口 state 用）
local function ring_add(v)
	ring[#ring + 1] = v
	if #ring > 32 then table.remove(ring, 1) end
end

-- 一个键从"设备事件"到"app 动作"
local function press(name, code, val, devname)
	ring_add(("%s%s"):format(name, val == 2 and "~" or ""))
	if CFG.learn then
		log("LEARN %s code=%s val=%s dev=%s", name, tostring(code), tostring(val), tostring(devname))
		return
	end

	local app, why = resolve()
	if not app then
		log("press %s code=%s: 没有前台 app（%s）", name, tostring(code), tostring(why))
		return
	end

	local layer = tostring(why or "up")

	local action = app.map and app.map[name]
	if not action then
		log("press %s code=%s focus=%s[%s]: 该 app 无此键", name, tostring(code), app.name, layer)
		return
	end
	if val == 2 and not (app.repeatable and app.repeatable(action)) then return end

	local ok, detail = run_action(app, action, name)
	log("press %s%s code=%s focus=%s[%s] -> %s %s", name, val == 2 and "~" or "",
		tostring(code), app.name, layer, action, ok and "ok" or ("FAILED " .. tostring(detail)))

	if not ok then
		cache.at = 0
		-- 前台判定错了（比如 app 刚退出）：顺手把下一层试一次
		local nxt
		for i, a in ipairs(apps) do
			if a.name == app.name then nxt = apps[i + 1]; break end
		end
		if nxt and nxt.map and nxt.map[name] then
			local ok2, d2 = run_action(nxt, nxt.map[name], name)
			log("  fallback %s -> %s %s", nxt.name, nxt.map[name], ok2 and "ok" or tostring(d2))
		end
	end
end

-- —— 输入设备 ——
local devs, open_by_path = {}, {}
local MODS = { [29] = "C-", [97] = "C-", [42] = "S-", [54] = "S-",
	[56] = "A-", [100] = "A-", [125] = "M-", [126] = "M-" }
local mods = {}
local last, last_rep = {}, {}

local function scan_devices()
	local all = evdev.scan()
	local chosen = evdev.pick(all, CFG.devices, CFG.exclude)
	local seen = {}

	for _, e in ipairs(chosen) do
		seen[e.dev] = true
		if not open_by_path[e.dev] then
			local fd, err = evdev.open(e.dev, { grab = CFG.grab })

			if fd then
				local d = { fd = fd, name = e.name, path = e.dev }

				devs[#devs + 1] = d
				open_by_path[e.dev] = d
				log("open %s (%s) grab=%s", e.dev, e.name, tostring(CFG.grab))
			else
				log("open %s 失败: %s", e.dev, tostring(err))
			end
		end
	end
	-- 拔掉的设备：read 会 -1，这里顺手清理
	for i = #devs, 1, -1 do
		local d = devs[i]

		if not seen[d.path] then
			log("close %s (%s) 设备消失", d.path, d.name)
			evdev.close(d.fd)
			open_by_path[d.path] = nil
			table.remove(devs, i)
		end
	end
end

local function handle_ev(d, type, code, val)
	if type ~= evdev.EV_KEY then return end
	local raw = keynames[code] or ("KEY_" .. code)
	local now = evdev.now_ms()

	if MODS[code] then
		mods[code] = (val ~= 0) and true or nil
		if val == 1 then ring_add(raw) end
		return
	end
	if val ~= 0 and val ~= 1 and val ~= 2 then return end   -- 有的遥控报天外飞仙值
	-- 只认按下(1)/连发(2)：抬起(0) 绝不能派发动作，否则一次按键翻两次页
	if val == 0 then return end

	local prefix = ""
	for _, c in ipairs({ 29, 97, 42, 54, 56, 100, 125, 126 }) do
		if mods[c] then
			local p = MODS[c]
			if not prefix:find(p, 1, true) then prefix = prefix .. p end
		end
	end
	local name = prefix .. raw

	-- 两个设备可能报同一个键（键盘接口 + Consumer Control）
	if val == 1 then
		if last[code] and now - last[code] < CFG.dedup_ms then return end
		last[code], last_rep[code] = now, nil
	elseif val == 2 then
		-- 长按连发：设备自己的重复率可能是 33ms，这里按 REPEAT_MS 压一遍
		if last_rep[code] and now - last_rep[code] < CFG.repeat_ms then return end
		last_rep[code] = now
	end
	press(name, code, val, d.name)
end

-- —— 控制口 ——
local running = true

local function ctl_state()
	local app, why = resolve(false)
	local list = {}

	for _, a in ipairs(apps) do
		local ok, det = pcall(a.detect, ENV)

		list[#list + 1] = { name = a.name, order = a.order or 0, up = ok and det and true or false }
	end
	return {
		ok = true,
		focus = app and app.name or nil,
		focus_why = why,
		forced = forced or "",
		learn = CFG.learn,
		dispatch = CFG.dispatch,
		pid = tonumber((io.open("/proc/self/stat"):read("*a"):match("^(%d+)")) or 0),
		keys = table.concat(ring, ","),
		apps = list,
	}
end

local function ctl_handle(cfd)
	local req = sock.read(cfd, 400)

	if not req or req == "" then sock.close(cfd); return end
	req = req:gsub("^%s+", ""):gsub("%s+$", "")

	local msg = { cmd = req }
	if req:sub(1, 1) == "{" then
		local ok, v = pcall(sock.decode, req)

		if ok and type(v) == "table" then msg = v end
	end

	local cmd = tostring(msg.cmd or "state")
	local resp

	if cmd == "state" then
		resp = ctl_state()
	elseif cmd == "apps" then
		resp = ctl_state()
	elseif cmd == "key" then
		local name = msg.name or tostring(msg.code or "")
		local val = tonumber(msg.value) or 1
		local code = tonumber(msg.code)

		if not code then
			for c, n in pairs(keynames) do
				if n == name then code = c; break end
			end
		end
		if not code then
			-- 组合键（C-1 / S-RIGHT …）：去掉修饰前缀查本键 code，
			-- 名字原样传给 press()，所以 map 里写的 C-1 能直接命中
			local base = name:match("^[CSAM]+%-(.+)$")
			if base then
				for c, n in pairs(keynames) do
					if n == base then code = c; break end
				end
			end
		end
		if not code then
			resp = { ok = false, error = "unknown key: " .. name }
		else
			press(name, code, val, "ctl")
			resp = { ok = true, key = name, code = code, value = val }
		end
	elseif cmd == "focus" then
		local a = msg.app or ""
		if a == "" or a == "auto" then
			forced = nil
			resp = { ok = true, focus = "auto" }
		else
			forced = a
			cache.at = 0
			resp = { ok = true, focus = a }
		end
	elseif cmd == "learn" then
		local on = msg.on

		if on == nil then on = true end
		CFG.learn = on and true or false
		resp = { ok = true, learn = CFG.learn }
	elseif cmd == "reload" then
		load_apps()
		cache.at = 0
		resp = { ok = true, apps = #apps }
	elseif cmd == "rescan" then
		scan_devices()
		resp = { ok = true, devices = #devs }
	elseif cmd == "quit" then
		running = false
		resp = { ok = true, bye = true }
	else
		resp = { ok = false, error = "unknown cmd: " .. cmd, cmds = "state|apps|key|focus|learn|reload|rescan|quit" }
	end

	sock.write(cfd, (sock.encode(resp) or '{"ok":false}') .. "\n")
	sock.close(cfd)
end

-- —— 一次性命令（--key / --apps），方便不用遥控器测试 ——
local function shortcuts(argv)
	local i = 1

	while argv[i] do
		local a = argv[i]

		if a == "--key" or a == "-k" then
			local name = argv[i + 1]

			if not name then print("用法: --key <键名，如 OK/RIGHT/C-1>"); os.exit(2) end
			local code
			for c, n in pairs(keynames) do
				if n == (name:gsub("^[CSA]%-", "")) then code = c; break end
			end
			if not code then print("未知键: " .. name); os.exit(2) end
			CFG.learn = false
			press(name, code, 1, "cli")
			return true
		elseif a == "--apps" or a == "--list" then
			local list = evdev.scan()

			print(("设备：%d 个，匹配 %d 个 (grab=%s)"):format(#list,
				#evdev.pick(list, CFG.devices, CFG.exclude), tostring(CFG.grab)))
			for _, e in ipairs(evdev.pick(list, CFG.devices, CFG.exclude)) do
				print(("  %-18s %s"):format(e.dev, e.name))
			end
			print("app（order 大者优先）：")
			for _, ap in ipairs(apps) do
				local ok, det, info = pcall(ap.detect, ENV)

				print(("  %-8s order=%-3d %s %-18s %s"):format(ap.name, ap.order or 0,
					(ok and det) and "UP  " or "down",
					ap.keysfile and ("keys/" .. ap.name .. ".lua") or "-",
					info and tostring(info) or ""))
			end
			return true
		elseif a == "--learn" then
			CFG.learn = true
		elseif a == "--no-grab" then
			CFG.grab = false
		elseif a == "--socket" then
			CFG.sock = argv[i + 1]
			i = i + 1
		end
		i = i + 1
	end
	return false
end

if shortcuts(arg) then os.exit(0) end

-- —— 主循环 ——
local ctl_fd, err = sock.listen(CFG.sock)

if not ctl_fd then
	log("控制口 %s 建不起来: %s", CFG.sock, tostring(err))
	os.exit(1)
end

scan_devices()
if #devs == 0 then
	log("ERROR: 没有可用输入设备（DEVICES=%s EXCLUDE=%s）", tostring(CFG.devices), CFG.exclude)
else
	log("ready learn=%s grab=%s dispatch=%s ttl=%dms", tostring(CFG.learn), tostring(CFG.grab),
		CFG.dispatch, CFG.focus_ttl)
end

local last_scan = evdev.now_ms()

while running do
	local fds = { ctl_fd }
	for _, d in ipairs(devs) do fds[#fds + 1] = d.fd end

	evdev.poll(fds, 500)

	if sock.wait(ctl_fd, 0) then
		local c = sock.accept(ctl_fd)

		if c then ctl_handle(c) end
	end
	for i = #devs, 1, -1 do
		local d = devs[i]

		-- 设备消失（拔掉/虚拟键盘退出）时 read 报 ENODEV：立刻摘掉并马上重扫，
		-- 否则要等 scan_ms 才发现，期间新节点上的按键会丢。
		local _, gone = evdev.drain(d.fd, function(t, c, v) handle_ev(d, t, c, v) end)

		if gone then
			log("close %s (%s) 设备消失", d.path, d.name)
			evdev.close(d.fd)
			open_by_path[d.path] = nil
			table.remove(devs, i)
			last_scan = 0
		end
	end
	local now = evdev.now_ms()
	if now - last_scan >= CFG.scan_ms then
		last_scan = now
		scan_devices()
	end
end

log("exit")
for _, d in ipairs(devs) do evdev.close(d.fd) end
sock.close(ctl_fd)
os.remove(CFG.sock)
