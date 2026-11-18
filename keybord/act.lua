-- act.lua — 一次性动作入口：luajit /opt/keybord/act.lua [app] <action> [key]
--
-- 给外部脚本/agent 用，不用起守护也不用知道 socket 长什么样：
--   luajit act.lua reader next          # 阅读器翻下一页
--   luajit act.lua reader app.toc
--   luajit act.lua player toggle        # 播放器暂停/继续
--   luajit act.lua player "vol +10"
--   luajit act.lua auto next            # 让 keybd 的判定规则自己挑 app
--   luajit act.lua --apps               # 看哪个 app 在前台
--
-- 也支持直接 -e 内联（keybd 的 DISPATCH=exec 就是这么调的）：
--   luajit -e 'dofile("/opt/keybord/act.lua")' reader next

local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"
local argv = arg or {}
local args = {}

for i = 1, #argv do args[#args + 1] = argv[i] end

local function usage()
	print([[
用法: luajit act.lua [app|auto] <action> [key]
      luajit act.lua --apps
app: reader | player | shell | auto(默认，按 keybd 的判定规则挑)]])
	os.exit(2)
end

package.path = ROOT .. "/?.lua;" .. package.path
local sock = require("sock")
local log = function(fmt, ...) io.stderr:write(("[act] " .. fmt .. "\n"):format(...)) end
local ENV = { sock = sock, log = log, cfg = {}, root = ROOT }

-- 载入 app 模块（--apps 时也要用）
local apps, by_name, order = {}, {}, {}
local p = io.popen("ls -1 " .. ROOT .. "/apps/*.lua 2>/dev/null")

if p then
	for f in p:lines() do
		local ok, m = pcall(dofile, f)

		if ok and type(m) == "table" and m.name then
			m.file = f
			local mf = ROOT .. "/maps/" .. m.name .. ".lua"
			local fh = io.open(mf)

			if fh then
				fh:close()
				local ok2, over = pcall(dofile, mf)

				if ok2 and type(over) == "table" then
					for k, v in pairs(over) do m.map[k] = v end
				end
			end
			apps[#apps + 1] = m
			by_name[m.name] = m
		else
			log("跳过 %s: %s", f, tostring(m))
		end
	end
	p:close()
end
table.sort(apps, function(a, b) return (a.order or 0) > (b.order or 0) end)

if args[1] == "--apps" or args[1] == "-l" then
	for _, a in ipairs(apps) do
		local ok, det, info = pcall(a.detect, ENV)

		print(("%-8s order=%-3d %s %s"):format(a.name, a.order or 0,
			(ok and det) and "UP  " or "down", info and tostring(info) or ""))
	end
	os.exit(0)
end

local app_name, action = args[1], args[2]

if not action then
	-- luajit act.lua next  → auto + next
	if app_name and not by_name[app_name] then action, app_name = app_name, "auto" end
end
if not action then usage() end

local app

if app_name and app_name ~= "auto" then
	app = by_name[app_name]
	if not app then
		log("没有这个 app: %s（有：%s）", app_name,
			(function()
				local t = {}

				for _, a in ipairs(apps) do t[#t + 1] = a.name end
				return table.concat(t, ",")
			end)())
		os.exit(1)
	end
else
	for _, a in ipairs(apps) do
		local ok, det = pcall(a.detect, ENV)

		if ok and det then app = a; break end
	end
	if not app then log("没有前台 app"); os.exit(1) end
end

local ok, res, detail = pcall(app.run, action, args[3], ENV)

if not ok then
	log("%s 执行 %s 出错: %s", app.name, action, tostring(res))
	os.exit(1)
end
print(type(detail) == "string" and detail or (res and "ok" or "failed"))
os.exit(res and 0 or 1)
