-- keys/base.lua — 第二步「固定脚本」的公共执行器
--
-- 每个 app 一份数据文件 keys/<app>.lua，只写一张写死的键码表；查表/执行/环境都在这里。
-- 数据文件长这样：
--   local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"
--   return dofile(ROOT .. "/keys/base.lua").define("reader", {
--       { "C-1", 2, "C", "app.library" },   -- 键名, evdev 码, 修饰键, 动作
--   }, { order = 20 })
--
-- 平时被 keybd 当数据 dofile（置 _KEYBD_DATA_ONLY，不执行）；带参数就当场执行：
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' C-1   # 按一下首页
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' 2     # 也认裸键码
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' app.toc  # 直接点名动作
--   luajit -e 'dofile("/opt/keybord/keys/reader.lua")' --list   # 看表
--
-- 动作执行交给 apps/<app>.lua（它再去调 app 自己的自动化口/socket）。

local ROOT = os.getenv("KEYBD_ROOT") or "/opt/keybord"
package.path = ROOT .. "/?.lua;" .. package.path

local B = {}

local function log(app, fmt, ...)
	io.stderr:write(("[keys/%s] " .. fmt .. "\n"):format(app, ...))
end

-- 收集本次参数：`luajit -e '…' A B` 时 A 落在 arg[0]，脚本文件名不算参数
local function argv_of()
	local t = {}

	if not arg then return t end
	for i = 0, #arg do
		local v = arg[i]
		-- arg[0] 在用 `luajit xxx.lua` 直跑时是脚本名，跳过；`-e` 时它才是第一个参数
		local skip = (i == 0 and v or ""):match("%.lua$") ~= nil

		if v and v ~= "" and not skip then t[#t + 1] = v end
	end
	return t
end

function B.define(app, keys, opt)
	opt = opt or {}
	local M = { app = app, desc = opt.desc or app, order = opt.order or 10, list = {} }
	local byname, bycode = {}, {}

	for _, e in ipairs(keys) do
		local ent = { key = e[1], code = tonumber(e[2]), mod = e[3], act = e[4] }

		if ent.key and ent.act then
			byname[ent.key] = ent
			-- 裸键码只认无修饰的，免得 C-1 把 1 抢走
			if ent.code and not ent.mod then bycode[ent.code] = ent end
			M.list[#M.list + 1] = ent
		end
	end

	-- 给 keybd 用：键名 → 动作
	function M.map()
		local m = {}

		for k, e in pairs(byname) do m[k] = e.act end
		return m
	end

	function M.repeatable(act)
		if opt.repeatable then
			for _, a in ipairs(opt.repeatable) do
				if a == act then return true end
			end
			return false
		end
		return act == "next" or act == "prev" or act == "font+" or act == "font-"
	end

	function M.lookup(k)
		if not k or k == "" then return nil end
		k = tostring(k)
		local e = byname[k]

		if e then return e end
		local n = tonumber(k)

		if n and bycode[n] then return bycode[n] end
		-- 探索阶段的手调：直接给动作名（next / app.toc / reader.next）
		if k:match("^[A-Za-z][%w._%-]*$") then return { key = k, act = k } end
		return nil
	end

	local APP
	local function appmod()
		if not APP then
			local f = ROOT .. "/apps/" .. app .. ".lua"
			local ok, m = pcall(dofile, f)

			if not ok then error(("载入 %s 失败: %s"):format(f, tostring(m))) end
			APP = m
		end
		return APP
	end

	function M.env()
		return {
			sock = require("sock"),
			log = function(fmt, ...) log(app, fmt, ...) end,
			cfg = {},
			root = ROOT,
		}
	end

	-- 一个键 → app 自动化动作（socket 短连，一次动作一次连接）
	function M.call(key, env)
		local e = M.lookup(key)

		if not e then return false, "该 app 无此键: " .. tostring(key) end
		local ok, r, d = pcall(appmod().run, e.act, e.key, env or M.env())

		if not ok then return false, "lua error: " .. tostring(r) end
		if type(d) == "table" then d = require("sock").encode(d) end   -- 回包是 JSON 表时压成一行
		return r and true or false, tostring(d or e.act)
	end

	function M.state(env)
		local m = appmod()

		if not m.state then return nil end
		local ok, s = pcall(m.state, env or M.env())

		return ok and s or nil
	end

	function M.main(argv)
		local a = argv[1]

		if not a or a == "--list" or a == "-l" then
			print(("keys/%s — %s（%d 键）"):format(app, M.desc, #M.list))
			for i, e in ipairs(M.list) do
				print(("%-2d %-6s code=%-3d %-2s %s"):format(i, e.key,
					e.code or 0, e.mod or "", e.act))
			end
			return 0
		end

		if a == "--state" then
			local s = M.state()

			print(s and (require("sock").encode(s) or "?") or "nil")
			return s and 0 or 1
		end

		local ok, d = M.call(a)

		log(app, "%s -> %s %s", a, ok and "ok" or "FAILED", d)
		if not ok then print(d) end
		return ok and 0 or 1
	end

	local argv = argv_of()

	if not _KEYBD_DATA_ONLY and argv[1] then os.exit(M.main(argv)) end

	return M
end

return B
