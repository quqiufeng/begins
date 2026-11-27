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
local peer = require("core.peer")
local semantic = require("core.semantic")

local bit = require("bit")
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

-- fbcon 从桌面起来就解绑，一直不 bind 回去。
-- 每次「解绑 → 子进程 modeset → 退出 rebind」都是一次 CRTC 模式跳变
-- （fbcon 自己的 1080p ↔ 桌面的 4K），HDMI 跟着退锁两次，电视就弹
-- 「当前信号信息」黄条。桌面是常显进程，控制台文本没有意义，
-- 解绑一次到底，整条链再也不会让 HDMI 重新锁存。
-- 要命令行：echo 1 > /sys/class/vtconsole/vtcon1/bind
local fbcon = require("util.fbcon")

fbcon.hold()
-- 顺手把开机时残留在 /dev/fb0 里的 tty1 文本换成壁纸：
-- 之后释放 DRM master 的空档里露出来的是壁纸，不是命令行。
fbcon.wall()
-- 语义状态：把 fs/preview/播放器/reader 的现场汇总成 state 里的文字
local sem = semantic.new(cfg, fs, pv, launcher_)
local auto

-- ---------- 热插拔（U 盘）----------
-- cfg.roots 是"切根"的候选列表：NAS → 本机 → 每个挂上的 U 盘。
-- base_roots 存一份静态的（NAS/home），U 盘进出时在它上面重算，不能就地改基数。
local base_roots = {}
local hp -- 前向声明：下面的 on_change 闭包里要用到
local rescan
local toast -- 同理：下面 on_change 里先 toast 再 rescan，不声明就变成全局 nil 调用

for i, r in ipairs(cfg.roots) do base_roots[i] = r end

local function refresh_roots()
	local roots = {}
	-- 已挂上的 U 盘：既进"根"（TAB 切换），也进首页图标（core/fs.lua 的
	-- app_items 读 cfg.usb_vols，没盘就是空表，图标自然不出现）
	local vols = hp and hp:list() or {}

	for i, r in ipairs(base_roots) do roots[i] = r end
	for _, v in ipairs(vols) do
		roots[#roots + 1] = { path = v.mnt, label = v.label, kind = "usb" }
	end
	cfg.roots = roots
	cfg.usb_vols = vols
end

hp = cfg.usb.enabled and hotplug.new(cfg, {
	root = cfg.usb.root, rw = cfg.usb.rw, all = cfg.usb.all,
	on_change = function(kind, v)
		refresh_roots()
		local name = v.label or v.mnt

		if kind == "add" then
			logf(("U 盘挂上 %s → %s"):format(v.dev, v.mnt))
			toast(("U 盘 %s 已就绪（桌面图标）"):format(name), 3)
			-- 正停在首页：立刻把 U 盘图标画出来
			if fs.dir == cfg.home_dir then rescan() end
			-- 正停在挂载点父目录（/media）上：直接刷新，新盘立刻出现在网格里
			if fs.dir == v.mnt or fs.dir == (v.mnt:match("^(.*)/[^/]+$") or v.mnt) then
				rescan()
			end
		else
			logf(("U 盘拔了 %s"):format(v.dev))
			toast(("U 盘 %s 已移除"):format(name), 3)
			if fs.dir == cfg.home_dir then rescan() end
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

-- 注意：上面 on_change 在 145 行之前就调用 toast，所以这里必须是给前向声明的
-- local 赋值，写成 "local function toast" 会让 on_change 里的 toast 变成全局 nil
toast = function(msg, sec, color) bar:toast(msg, sec, color); dirty = true end

local function layout()
	if not win.ren then return end
	g:layout(win.W, win.H)
	sem.info = { theme = theme.name, cols = g.cols, rows = g.rows }
	dirty = true
end

-- 最近一次交出去的外部 app（reader/player）：前台语义靠它 + launcher_:busy()
local last_open = nil

local function open_current()
	local item = fs:current()

	if not item then toast("没有可打开的文件"); return end
	-- 记下这次交出去打开的东西：运行期间 state 要能回答"前台是谁、在放哪一部"
	if item.kind == "ebook" then
		last_open = { app = "reader", file = item.name, path = item.path, ts = os.time() }
		sem.last_open = last_open
	elseif item.kind == "video" or item.kind == "audio" then
		last_open = { app = "player", file = item.name, path = item.path, ts = os.time() }
		sem.last_open = last_open
	end
	local res, err = launcher_:open(fs, pv, item)

	-- 外部 app 回来了：解除自动化口的 busy（pump 期间只答只读查询）
	if auto then auto.busy = false end

	if res == "into" then
		-- 进目录只是 fs:enter()，全程没碰 KMS（launcher:open 对 item.dir 直接 return，
		-- 根本不跑外部命令），所以【绝对不能】suspend/resume。
		-- 老代码在这里 win:suspend()+resume()：suspend 会 SDL_DestroyWindow +
		-- quit_video，把 DRM master 放掉，fbcon 立刻合法接管、把控制台画上屏；
		-- resume 再重建窗口抢回 master。窗口期内屏幕上是命令行，而 resume 在
		-- KMSDRM 上偶发抢不到 master 就返回 false → running=false → 桌面退出，
		-- 屏幕永久停在 shell 提示符（用户报的"进目录再返回就变命令行"）。
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
		toast(err == "at home" and "已在桌面" or err, 1.5, theme.text_dim)
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
		-- 遥控器 ☰ 键（keybd 派 nav.menu）：刷新 + 换一套配色，和底部提示
		-- "MENU 刷新·换色" 一致。遥控器上没有 T 键，以前这里只刷新，
		-- 于是"按 MENU 换主题"永远换不了。
		-- 内部路径（进目录 / 退出播放器回来）只调 rescan()，不走这里，
		-- 所以不会再出现"颜色自己乱变"。
		rescan()
		local n = theme.cycle(1)
		toast(("配色：%s"):format(theme.label or n), 2)
		logf("MENU 刷新 + 配色 → " .. tostring(n))
	elseif name == "FONTUP" or name == "FONTDOWN" then
		-- 字号 ±10%，落盘 theme.json（下次开桌面还是这个字号）
		local k = theme.step_scale(name == "FONTUP" and 0.1 or -0.1)

		layout()
		toast(("字号：%d%%"):format(k * 100), 2)
		logf(("字号 → %d%%"):format(k * 100))
	elseif name == "FONTRESET" then
		layout()
		toast(("字号：自动 %d%%"):format((theme.reset_scale() or 1) * 100), 2)
	elseif name == "END" then g:endk(fs)
	elseif name == "OK" or name == "ENTER" or name == "RETURN" or name == "SPACE" then
		open_current()
	elseif name == "BACK" or name == "ESC" or name == "ESCAPE" then
		-- 根在哪由 fs:up() 按路径回答（home: / roots[] / "/"），
		-- 这里不再拿 cfg.start_dir 比：它只是开机落点，不是根
		go_up()
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
		-- 字号：键盘上 +/-，遥控器上 C-4/C-5（keybd 派 nav.fontup/fontdown）
		{ K.PLUS, "FONTUP" }, { K.EQUALS, "FONTUP" }, { K.KP_PLUS, "FONTUP" },
		{ K.MINUS, "FONTDOWN" }, { K.KP_MINUS, "FONTDOWN" },
		{ K.F6, "FONTRESET" },
	}) do
		-- 少一项就整张表挂掉（KEYSYM[nil]），宁可跳过也别让桌面起不来
		if p[1] then KEYSYM[p[1]] = p[2] end
	end
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

-- ---------- 能力白名单 ----------
--
-- agent 的自由度 ≠ root 自由度。协议一旦通了就什么都能干，等于把 root 交出去，
-- 所以这里显式列一遍「哪些动作可以、可以到什么程度」：
--   nav.* / 方向键      可逆、无副作用 → 随便按
--   select./open.       只作用于当前目录里真实存在的条目
--   call               只有桌面自己的查询/截图 + reader/player 的自动化口，不给 shell
--   关桌面、关外部 app   默认拒绝（要开得显式 DESKTOP_ALLOW_QUIT=1）
-- 白名单的判定在 core/automation.lua（:-allowed），这里是唯一那份配置。
local CAPS = {
	cmds = {
		ping = true, list = true, state = true, brief = true, digest = true,
		click = true, key = true, call = true,
	},
	click = { "^nav%.[a-z]+$", "^select%.", "^open%." },
	keys = {
		LEFT = true, RIGHT = true, UP = true, DOWN = true,
		PAGEUP = true, PAGEDOWN = true, HOME = true, END = true,
		OK = true, ENTER = true, RETURN = true, SPACE = true,
		BACK = true, ESC = true, ESCAPE = true,
		REFRESH = true, F5 = true, UP_DIR = true,
		ROOTS = true, TAB = true, NEXTROOT = true,
		MENU = true, T = true, THEME = true,
		FONTUP = true, FONTDOWN = true, FONTRESET = true,
	},
	calls = {
		"^app%.capture$", "^app%.goto$", "^app%.rescan$", "^app%.size$",
		"^app%.key$", "^reader%.[%w_.]+$", "^player%.[%w_.]+$",
	},
}

if cfg.allow_quit then
	CAPS.keys.QUIT, CAPS.keys.EXIT = true, true
	CAPS.click[#CAPS.click + 1] = "^view%.quit$"
	CAPS.calls[#CAPS.calls + 1] = "^app%.quit$"
end

-- reader 的 call 参数是扁平的（它按 path/page/q… 自己取字段），照它的口味拼
local function flatten_into(dst, args)
	for k, v in pairs(args or {}) do
		if type(v) ~= "table" then dst[k] = v end
	end
	return dst
end

-- 转发一条给 reader：返回它的应答表，或 nil, err（err == "absent" 就是没在跑）
local function reader_do(sub, args, timeout)
	-- 不再先 access() 判存在：直接问，省一次系统调用也省一次 TOCTOU
	-- state/ping 自己就带页码，不用再问一次 book 算 changed
	local ask = sub ~= "state" and sub ~= "ping"
	local b0

	if ask then
		sem:invalidate("book")
		b0 = sem:book()
	end
	local req

	if sub == "state" or sub == "ping" then
		req = flatten_into({ cmd = sub }, args)
	else
		req = flatten_into({ cmd = "call", fn = "reader." .. sub }, args)
	end
	local r, err = peer.req(cfg.reader_sock, req, timeout or 2500)

	if not r then return nil, err end
	if ask and type(r) == "table" then
		-- 缓存里是问之前的那一份，变化得重新问才知道，别让 TTL 把 changed 吃掉
		sem:invalidate("book")
		local b1 = sem:book()

		if b0 and b1 then
			r.changed = (b0.page ~= b1.page) or (b0.library ~= b1.library)
		end
	end
	return r
end

-- 一个门进所有能力：call "reader.next" / "reader.state" 由桌面转发给 reader 的自动化口。
-- 读（state/ping）必须当场回，否则 agent 拿不到页码；
-- 改（翻页/开书）可能慢，挂到帧末跑，别把 30fps 主循环按住两秒半。
local function reader_call(fn, args)
	local sub = fn:match("^reader%.(.+)$")

	if not sub then return { ok = false, error = "fn 用法：reader.state / reader.next" } end
	if sub ~= "state" and sub ~= "ping" then
		return defer(function()
			local _, err = reader_do(sub, args)

			if err then logf(("转发 reader.%s 失败：%s"):format(sub, tostring(err))) end
		end, "reader." .. sub)
	end
	local r, err = reader_do(sub, args, 2500)

	if not r then
		if err == "absent" then
			return { ok = false, error = "阅读器没在跑：" .. cfg.reader_sock }
		end
		return { ok = false, error = "reader 无应答：" .. tostring(err) }
	end
	return r
end

-- 播放器控制口是文本协议（status/pos/pause/…）。只放这几条：
-- 按键/seek 走 key、nav.*，这里不开一条能重开整条播放链的路。
local PLAYER_CMDS = {
	status = true, pos = true, pause = true, resume = true,
	toggle = true, mute = true, vol = true,
}

local PLAYER_HELP = "播放器只支持 player.status/pos/pause/resume/toggle/mute/vol"

local function player_call(fn, args)
	local sub = fn:match("^player%.(.+)$")

	if not sub or not PLAYER_CMDS[sub] then return { ok = false, error = PLAYER_HELP } end
	local cmd = sub

	if sub == "vol" then
		cmd = ("vol %d"):format(tonumber(args and (args.level or args.vol)) or 100)
	end
	-- 播放器的控制口只回一条命令的结果，不告诉你"到底变没变"：
	-- 改状态的那几条命令前后各问一次 status，自己算 changed。
	local mutating = sub ~= "status" and sub ~= "pos"
	local s0 = mutating and peer.text(cfg.play_sock, "status", 300) or nil
	local r, raw = peer.text(cfg.play_sock, cmd, 500)

	if not r then
		if raw == "absent" then
			return { ok = false, error = "播放器控制口不在：" .. cfg.play_sock }
		end
		return { ok = false, error = "播放器无应答：" .. tostring(raw) }
	end
	-- 播放状态变了：语义缓存里的 pos/paused 立刻作废
	if mutating then sem:invalidate("media") end
	if mutating then
		local s1 = peer.text(cfg.play_sock, "status", 300)

		if s0 and s1 then
			r.changed = (s0.paused ~= s1.paused) or (s0.mute ~= s1.mute)
				or (s0.vol ~= s1.vol)
		end
	end
	return r
end

local ACTIONS = {
	"nav.left", "nav.right", "nav.up", "nav.down", "nav.pageup", "nav.pagedown",
	"nav.home", "nav.end", "nav.ok", "nav.back", "nav.refresh", "nav.roots",
	"nav.menu", "nav.fontup", "nav.fontdown", "nav.fontreset",
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
		["nav.fontup"] = function() return on_key("FONTUP") end,
		["nav.fontdown"] = function() return on_key("FONTDOWN") end,
		["nav.fontreset"] = function() return on_key("FONTRESET") end,
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
	-- 语义优先：路径/选中项/前台是谁/在播什么/看到第几页，agent 读文字就够，
	-- 不必截图猜。fs:state() 的老字段一个不动，老调用方照旧能用。
	state = function()
		local st = fs:state()

		for k, v in pairs(sem:state()) do st[k] = v end
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
	-- 控制面指纹（动作应答里的 state_digest / changed 由 automation 加）
	digest = function() return sem:digest() end,
	-- 能力白名单：nav.* 随便按，call 只到 reader/player 的 API，关桌面要显式开
	caps = CAPS,
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
		elseif fn:match("^reader%.") then
			return reader_call(fn, args)
		elseif fn:match("^player%.") then
			return player_call(fn, args)
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
			local name = KEYSYM[tonumber(ev.key.sym)]

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
-- 退出前再铺一遍：tty1 这几秒里可能又被 getty/dmesg 画了几行
fbcon.wall(true)
logf("退出")
