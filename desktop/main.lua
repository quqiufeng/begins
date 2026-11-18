-- desktop/main.lua — 桌面入口：遥控导航 + 打开文件 + 自动化口
--
-- 结构照 reader 的自动化架构：
--   一帧 = poll 事件 → 处理按键/自动化请求 → 绘制 → present
--   外部用 json 一行一个请求走 unix socket（DESKTOP_SOCK），
--   客户端（我会在桌面里跑的自动化脚本 / 我自己的 shell）可以：
--     state / click <id> / key <NAME> / call app.capture {"path":..}
--
-- 遥控语义：
--   左右     相邻项，上下  换行同列，上下翻页键  整屏翻
--   OK/ENTER 进目录 / 开图片预览 / 交外部 app 打开书或片
--   BACK/ESC 返回上级（到顶就停在原地）；外部 app（播放器/阅读器）跑着时
--            返回 = 收掉它回桌面，播放电影按返回就是退出播放
--
-- 用法：
--   luajit main.lua                    # 真机（kmsdrm 全屏）
--   SDL_VIDEODRIVER=dummy luajit main.lua

package.path = "./?.lua;../?.lua;" .. package.path

local ffi = require("ffi")
local cfg = require("config")
local theme = require("ui.theme")
local sdl = require("ffi.sdl2")
local img = require("ffi.sdl2_image")
local ttf = require("ffi.sdl2_ttf")
local txt = require("ui.text")
local icons = require("ui.icons")
local grid = require("ui.grid")
local chrome = require("ui.chrome")
local preview = require("ui.preview")
local window = require("ui.window")
local FS = require("core.fs")
local launcher = require("core.launcher")
local hotplug = require("core.hotplug")
local automation = require("core.automation")
local png = require("util.png")
local json = require("util.json")

local floor, min, max = math.floor, math.min, math.max

-- ---------- 日志 ----------

local logf
do
	local f = io.open(cfg.log, "ab")

	if f then
		logf = function(s)
			f:write(("[%s] %s\n"):format(os.date("%H:%M:%S"), s))
			f:flush()
		end
	else
		logf = function() end
	end
end

-- ---------- 对象 ----------

local win = window.new(cfg, sdl, ttf)
local fs = FS.new(cfg, { start = cfg.start_dir })
local ico = icons.new(cfg, sdl, img)
local g = grid.new(cfg, theme, ttf, txt, img, ico, sdl)
local bar = chrome.new(cfg, theme, ttf)
local pv = preview.new(cfg, sdl, img, ttf)
local launcher_ = launcher.new(cfg, win, bar)
local auto

-- ---------- 热插拔（U 盘）----------
-- cfg.roots 是"切根"的候选列表：NAS → 本机 → 每个挂上的 U 盘。
-- base_roots 存一份静态的（NAS/home），U 盘进出时在它上面重算，不能就地改基数。
local base_roots = {}
local hp -- 前向声明：下面的 on_change 闭包里要用到
local rescan

for i, r in ipairs(cfg.roots) do base_roots[i] = r end

local function refresh_roots()
	local roots = {}

	for i, r in ipairs(base_roots) do roots[i] = r end
	for _, v in ipairs(hp and hp:list() or {}) do
		roots[#roots + 1] = { path = v.mnt, label = v.label, kind = "usb" }
	end
	cfg.roots = roots
end

hp = cfg.usb.enabled and hotplug.new(cfg, {
	root = cfg.usb.root, rw = cfg.usb.rw, all = cfg.usb.all,
	on_change = function(kind, v)
		refresh_roots()
		local name = v.label or v.mnt

		if kind == "add" then
			logf(("U 盘挂上 %s → %s"):format(v.dev, v.mnt))
			toast(("U 盘 %s 已就绪（TAB 切换）"):format(name), 3)
			-- 正停在挂载点父目录（/media）上：直接刷新，新盘立刻出现在网格里
			if fs.dir == v.mnt or fs.dir == (v.mnt:match("^(.*)/[^/]+$") or v.mnt) then
				rescan()
			end
		else
			logf(("U 盘拔了 %s"):format(v.dev))
			toast(("U 盘 %s 已移除"):format(name), 3)
			-- 正在看被拔走的盘：退回起始目录，别留在空气里
			if fs.dir == v.mnt or fs.dir:sub(1, #v.mnt + 1) == v.mnt .. "/" then
				fs:scan(cfg.start_dir)
				layout()
			else
				rescan()
			end
		end
	end,
}) or nil

refresh_roots()

local running = true
local dirty = true
local last_clock = ""
local need_scan = true

local function toast(msg, sec, color) bar:toast(msg, sec, color); dirty = true end

local function layout()
	if not win.ren then return end
	g:layout(win.W, win.H)
	dirty = true
end

local function open_current()
	local item = fs:current()

	if not item then toast("没有可打开的文件"); return end
	local res, err = launcher_:open(fs, pv, item)

	-- 外部 app 回来了：解除自动化口的 busy（pump 期间只答只读查询）
	if auto then auto.busy = false end

	if res == "into" then
		win:suspend()
		local ok, e2 = win:resume()

		if not ok then
			logf("resume 失败：" .. tostring(e2))
			running = false
			return
		end
		-- 外部 app 把 KMS 抢走过，纹理全废了，清缓存重画
		ico:destroy()
		g:clear_thumbs(false)  -- KMS 被抢过，纹理已失效：只丢引用，不销毁
		pv:clear_tex()
		layout()
		dirty = true
		toast(("进入 %s"):format(fs:display_name()))
	elseif err then
		toast(err, 3, theme.warn)
		logf("open 失败：" .. tostring(err))
	else
		dirty = true
	end
end

-- 会阻塞的动作（open_current → launcher:open 要挂起桌面、一直等到播放器/阅读器退出）
-- 绝不能跑在 automation 的 poll 里：应答发不出去，keybd 等 3s 就判执行失败，
-- 然后 fallback 又把 reader 拉起来跟播放器抢屏（2026-11-18 13:08:16 那次）。
-- 一律排队，回包先落进内核缓冲，主循环下一轮再执行。
local deferred = {}

local function defer(fn, what)
	deferred[#deferred + 1] = fn
	return { ok = true, deferred = true, what = what }
end

local BLOCKING_KEYS = {
	OK = true, ENTER = true, RETURN = true, SPACE = true,
}

local function key_is_blocking(name)
	return BLOCKING_KEYS[tostring(name or ""):upper()] == true
end

-- 在根之间切换（NAS / 本机 / 每个 U 盘）。dir 是子目录时按前缀归到所属根。
local function root_index()
	for i, r in ipairs(cfg.roots) do
		if fs.dir == r.path then return i end
	end
	local best, blen = nil, -1

	for i, r in ipairs(cfg.roots) do
		local p = r.path .. "/"

		if #fs.dir >= #p and fs.dir:sub(1, #p) == p and #p > blen then
			best, blen = i, #p
		end
	end
	return best or 1
end

local function cycle_root(step)
	local roots = cfg.roots

	if #roots == 0 then return false end
	local i = root_index()
	local nxt = ((i - 1 + (step or 1)) % #roots) + 1
	local r = roots[nxt]

	if not r then return false end
	local ok, err = fs:scan(r.path)

	if not ok then toast(tostring(err), 2, theme.warn); return false end
	layout()
	toast(("→ %s（%d 个根）"):format(r.label or r.path, #roots), 2)
	return true
end

local function go_up()
	local dir, err = fs:up()

	if dir then
		layout()
		dirty = true
	elseif err then
		toast(err, 1.5, theme.text_dim)
	end
end

function rescan()
	fs:scan(fs.dir, fs:current() and fs:current().name)
	layout()
	dirty = true
end

-- 遥控键名 → 动作。返回 true 表示已消费
local function on_key(name)
	name = tostring(name or ""):upper()

	if pv:key(name) then dirty = true; return true end
	if name == "LEFT" then g:move(fs, -1, 0)
	elseif name == "RIGHT" then g:move(fs, 1, 0)
	elseif name == "UP" then g:move(fs, 0, -1)
	elseif name == "DOWN" then g:move(fs, 0, 1)
	elseif name == "PAGEUP" or name == "CHANNELUP" then g:page(fs, -1)
	elseif name == "PAGEDOWN" or name == "CHANNELDOWN" then g:page(fs, 1)
	elseif name == "HOME" then g:home(fs)
	elseif name == "MENU" then
		-- 刷新顺手换一套随机配色（同一份 12 套调色板，版式不动）
		rescan()
		theme.random()
		toast(("已刷新 · 配色：%s"):format(theme.label or theme.name), 2)
		logf("MENU 刷新 + 随机配色 → " .. tostring(theme.name))
	elseif name == "END" then g:endk(fs)
	elseif name == "OK" or name == "ENTER" or name == "RETURN" or name == "SPACE" then
		open_current()
	elseif name == "BACK" or name == "ESC" or name == "ESCAPE" then
		if fs.dir == cfg.start_dir then toast("已在起始目录")
		else go_up() end
	elseif name == "REFRESH" or name == "F5" then rescan()
	elseif name == "QUIT" or name == "EXIT" then running = false
	elseif name == "UP_DIR" then go_up()
	elseif name == "ROOTS" or name == "TAB" or name == "NEXTROOT" then
		if not cycle_root(1) then
			toast("只有这一个根", 1.5, theme.text_dim)
		end
	elseif name == "T" or name == "THEME" then
		-- 换色系：和 lite 的 12 套同一份调色板，T 循环（不改版式）
		theme.cycle(1)
		toast(("配色：%s"):format(theme.label or theme.name), 2)
		logf("配色切换 → " .. tostring(theme.name))
	else
		return false
	end
	dirty = true
	return true
end

-- SDL scancode/keysym → 名字（真机上遥控走 keybd，这里也认键盘）
local KEYSYM = {}
do
	local K = sdl.SDLK

	for _, p in ipairs({
		{ K.LEFT, "LEFT" }, { K.RIGHT, "RIGHT" }, { K.UP, "UP" }, { K.DOWN, "DOWN" },
		{ K.RETURN, "OK" }, { K.KP_ENTER, "OK" }, { K.SPACE, "OK" },
		{ K.ESCAPE, "BACK" }, { K.BACKSPACE, "BACK" }, { K.PAGEUP, "PAGEUP" },
		{ K.PAGEDOWN, "PAGEDOWN" }, { K.HOME, "HOME" }, { K.END, "END" },
		{ K.F5, "REFRESH" }, { K.Q, "QUIT" }, { K.T, "THEME" },
		{ K.TAB, "ROOTS" },
	}) do KEYSYM[p[1]] = p[2] end
end

-- ---------- 自动化 ----------

local function capture(path)
	path = path or "/tmp/desktop-shot.png"
	if not win.ren then return nil, "renderer 已交出（外部 app 正在跑）" end
	local W, H = win.W, win.H
	local buf = ffi.new("uint8_t[?]", W * H * 4)

	if sdl.lib.SDL_RenderReadPixels(win.ren, nil, sdl.PIXELFORMAT_ARGB8888, buf, W * 4) ~= 0 then
		return nil, "readpixels: " .. tostring(sdl.err())
	end
	local ok, err = png.save(path, W, H, buf, W * 4)

	if not ok then return nil, err end
	return path
end

local ACTIONS = {
	"nav.left", "nav.right", "nav.up", "nav.down", "nav.pageup", "nav.pagedown",
	"nav.home", "nav.end", "nav.ok", "nav.back", "nav.refresh", "nav.roots",
	"nav.menu",
	"view.screenshot", "view.quit",
}

local function action_map()
	return {
		["nav.left"] = function() return on_key("LEFT") end,
		["nav.right"] = function() return on_key("RIGHT") end,
		["nav.up"] = function() return on_key("UP") end,
		["nav.down"] = function() return on_key("DOWN") end,
		["nav.pageup"] = function() return on_key("PAGEUP") end,
		["nav.pagedown"] = function() return on_key("PAGEDOWN") end,
		["nav.home"] = function() return on_key("HOME") end,
		["nav.end"] = function() return on_key("END") end,
		["nav.ok"] = function()
			return defer(function() on_key("OK") end, "nav.ok")
		end,
		["nav.back"] = function() return on_key("BACK") end,
		["nav.refresh"] = function() return on_key("REFRESH") end,
		["nav.roots"] = function() return on_key("ROOTS") end,
		["nav.menu"] = function() return on_key("MENU") end,
		["view.screenshot"] = function()
			local p = capture(("/tmp/desktop-%s.png"):format(os.date("%H%M%S")))
			return { ok = p ~= nil, path = p }
		end,
		["view.quit"] = function() running = false; return true end,
	}
end

local function on_click(id)
	if not id or id == "" then return { ok = false, error = "id 为空" } end
	-- 也支持 "select.<name>" 和 "open.<name>"
	local kind, name = id:match("^(%w+)%.(.+)$")

	if kind == "select" then
		local it = fs:select_name(name)

		if not it then return { ok = false, error = "没有 " .. name } end
		g:ensure(fs); dirty = true
		return { ok = true, selected = name }
	elseif kind == "open" then
		if fs:select_name(name) then
			g:ensure(fs); dirty = true
			return defer(function() open_current() end, "open." .. name)
		end
		return { ok = false, error = "没有 " .. name }
	end
	local fn = action_map()[id]

	if fn then
		local ok, r = pcall(fn)

		if not ok then return { ok = false, error = tostring(r) } end
		return { ok = true, result = r }
	end
	return { ok = false, error = "未知动作 " .. id }
end

auto = automation.start(cfg.sock, {
	actions = function()
		local list = {}

		for i, a in ipairs(ACTIONS) do list[i] = a end
		-- 当前目录的每个条目也能直接点
		for i = 1, min(fs:count(), 60) do
			local it = fs:at(i)

			if it then list[#list + 1] = "select." .. it.name end
		end
		return list
	end,
	state = function()
		local st = fs:state()

		st.preview = pv.open and pv.idx or false
		st.window = { w = win.W, h = win.H, driver = win.driver }
		st.cols, st.rows = g.cols, g.rows
		st.visible = g.rows * g.cols
		st.roots = {}

		for i, r in ipairs(cfg.roots) do
			st.roots[i] = { path = r.path, label = r.label, kind = r.kind }
		end
		st.mounts = {}

		for i, v in ipairs(hp and hp:list() or {}) do
			st.mounts[i] = { dev = v.dev, label = v.label, mnt = v.mnt, owned = v.owned }
		end
		st.reader = launcher_:has_reader()
		st.player = launcher_:has_player()
		return st
	end,
	click = function(id) return on_click(id) end,
	-- 外部 app（播放器/阅读器）独占屏幕期间唯一放行的操作：「返回」= 收掉它。
	-- 播放电影时按返回要能退出播放，而不是回一句 busy 让遥控器看着像失灵。
	-- keybd 打过来的是 nav.back（click）或 BACK/ESC（key），两种都认。
	busy = function(id, how)
		local CLICK_BACK = { ["nav.back"] = true, ["view.quit"] = true }
		local KEY_BACK = {
			BACK = true, ESC = true, EXIT = true, QUIT = true, STOPCD = true,
		}
		local back = (how == "click") and CLICK_BACK[id] or false

		if how ~= "click" then back = KEY_BACK[id] or false end

		if back and launcher_:stop() then
			return { ok = true, stopped = true, state = fs:state() }
		end
		return nil
	end,
	key = function(name)
		if key_is_blocking(name) then
			return defer(function() on_key(name) end, "key." .. tostring(name))
		end
		local ok = on_key(name)

		return { ok = ok, state = fs:state() }
	end,
	call = function(fn, args)
		args = args or {}
		if fn == "app.capture" then
			local p, err = capture(args.path)

			return { ok = p ~= nil, path = p, error = err }
		elseif fn == "app.key" then
			if key_is_blocking(args.name) then
				return defer(function() on_key(args.name) end,
					"app.key." .. tostring(args.name))
			end
			return { ok = on_key(args.name), state = fs:state() }
		elseif fn == "app.goto" then
			local ok, err = fs:scan(args.dir or cfg.start_dir)

			if not ok then return { ok = false, error = err } end
			layout(); dirty = true
			return { ok = true, state = fs:state() }
		elseif fn == "app.rescan" then
			rescan()
			return { ok = true, state = fs:state() }
		elseif fn == "app.size" then
			return { ok = true, w = win.W, h = win.H, cols = g.cols, rows = g.rows }
		elseif fn == "app.quit" then
			running = false
			return { ok = true }
		end
		return { ok = false, error = "未知 fn " .. tostring(fn) }
	end,
})

-- 外部 app 运行期间（launcher:open 的等待循环）继续伺候自动化口：
-- 只答 ping/brief/state，点击/按键回 busy。不做这件事，keybd 每 800ms 的
-- 前台判定会超时掉到兜底 shell，遥控器就"按什么都没反应"了。
launcher_.pump = function()
	if not auto then return end
	auto.busy = true
	auto:poll()
end

-- ---------- 主循环 ----------

local function boot()
	local ok, err = win:open()

	if not ok then
		io.stderr:write("窗口起不来：" .. tostring(err) .. "\n")
		os.exit(1)
	end
	-- 随机配色要真随机：LuaJIT 不喂种子，每次开机都是同一条序列
	math.randomseed(os.time() * 1000 + math.floor(os.clock() * 1e6) % 1000)
	-- 字号按屏幕高度自适应（1080p 上 22px 的名字在沙发上太细）
	theme.fit(win.H)
	layout()
	rescan()
	logf(("启动 dir=%s %dx%d driver=%s 字号x%.2f"):format(fs.dir, win.W, win.H,
		tostring(win.driver), theme.font_scale or 1))
end

local function draw()
	local ren = win.ren

	if not ren then return end
	sdl.clear(ren, theme.bg)
	g:draw(ren, fs, win.W, win.H)
	bar:draw_top(ren, fs, win.W, sdl)
	bar:draw_bottom(ren, fs, win.W, win.H, sdl)
	bar:draw_toast(ren, win.W, win.H, sdl)
	pv:draw(ren, win.W, win.H)
	win:present()
end

boot()

local ev = ffi.new("SDL_Event")
local frame_ms = floor(1000 / max(1, cfg.fps))

while running do
	local t0 = sdl.ticks()
	local handled = 0

	while sdl.poll(ev) do
		local ty = ev.type

		if ty == sdl.QUIT then
			running = false
		elseif ty == sdl.KEYDOWN then
			local name = KEYSYM[tonumber(ev.key.keysym.sym)]

			if name then on_key(name) end
		elseif ty == sdl.WINDOWEVENT then
			if ev.window.event == sdl.WINDOWEVENT_SIZE_CHANGED
				or ev.window.event == sdl.WINDOWEVENT_RESIZED then
				if win:refresh_size() then
					-- 拉窗口也可能跨过字号档位：先算字号，再重排网格
					theme.fit(win.H)
					layout()
					dirty = true
				end
			elseif ev.window.event == sdl.WINDOWEVENT_EXPOSED then
				dirty = true
			end
		elseif ty == sdl.MOUSEBUTTONDOWN then
			if ev.button.button == 1 then
				local hit = g:hit(fs, tonumber(ev.button.x), tonumber(ev.button.y))

				if hit then
					if hit == fs.sel then open_current()
					else fs:select(hit); dirty = true end
				end
			end
		end
	end

	if hp and hp:poll(sdl.ticks()) then dirty = true end
	handled = auto:poll()
	if handled > 0 then dirty = true end
	-- 回包已经 send 出去，这时再跑阻塞动作（开视频 = 桌面挂起到播放结束）
	if #deferred > 0 then
		local q = deferred

		deferred = {}
		for i = 1, #q do
			local ok, err = pcall(q[i])

			if not ok then logf("延迟动作失败：" .. tostring(err)) end
		end
		dirty = true
	end

	-- 顶栏时间是秒级的：每秒变一次 → 每秒重画一帧，别每帧都 set dirty
	local now = os.date("%H:%M:%S")

	if now ~= last_clock then last_clock = now; dirty = true end
	if bar:tick() then dirty = true end
	if dirty then draw() end

	local spent = sdl.ticks() - t0

	if spent < frame_ms then sdl.delay(frame_ms - spent) end
end

if hp then hp:close() end
auto:close()
pv:close()
g:clear_thumbs(true)
ico:destroy()
win:close()
logf("退出")
