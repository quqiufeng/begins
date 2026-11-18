-- core/semantic.lua — 把「屏幕上看到了什么」翻成「state 里能读到的文字」
--
-- agent 需要的是：当前路径、选中什么、前台是谁、在播哪一部/播到第几秒、
-- 在看哪本书/第几页。这些本来散在三处（桌面自己的 fs/preview、播放器的
-- /tmp/play.state + 控制口、reader 的自动化口），在这里汇总成一份表。
--
-- 查询外部进程一律带超时（core/peer.lua），绝不为了一句 state 卡住 30fps 主循环。

local bit = require("bit")
local peer = require("core.peer")
local FS = require("core.fs")

local M = {}
M.__index = M

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- 反向表一次建好：find() 每字符扫一遍串，长 URL 上是纯浪费
local B64V = {}

for i = 1, #B64 do B64V[B64:sub(i, i)] = i - 1 end

-- play.sh 的 state 里 SRCB64 是带凭据的源地址，解出来只为取文件名
local function b64dec(s)
	if not s or s == "" then return nil end
	local out, buf, bits = {}, 0, 0

	for c in s:gmatch("[%w%+/]") do
		local v = B64V[c]

		if v then
			buf = bit.bor(bit.lshift(buf, 6), v)
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				out[#out + 1] = string.char(bit.band(bit.rshift(buf, bits), 0xff))
				buf = bit.band(buf, 0xff)
			end
		end
	end
	return table.concat(out)
end

M.b64dec = b64dec

function M.new(cfg, fs, preview, launcher)
	return setmetatable({
		cfg = cfg, fs = fs, pv = preview, launcher = launcher,
		last_open = nil,   -- { app="player"/"reader", file, path, ts }
		info = {},         -- 由 main.lua 每帧填：{ theme, cols, rows }
		cache = {},        -- 外部进程应答的短缓存：带 TTL 的 { t=, v= }
	}, M)
end

-- /tmp/play.state：play.sh 每开一部片重写一次（umask 077）
function M:play_state_file()
	local f = io.open(self.cfg.play_state, "rb")

	if not f then return nil end
	local kv = {}

	for line in f:lines() do
		-- 键里带数字（SRCB64），%u 匹配不到，得用 %w_
		local k, v = line:match("^([%w_]+)=(.*)$")

		if k then kv[k] = v end
	end
	f:close()
	if not kv.VPID and not kv.SOCK then return nil end
	return kv
end
-- 前台是谁：桌面 / 图片预览 / 交出去的外部 app
function M:front()
	local lo = self.last_open

	if self.launcher:busy() then
		return (lo and lo.app) or "external", (lo and lo.file) or nil
	end
	local pv = self.pv

	if pv.open and pv.list and pv.list[pv.idx] then
		return "image", pv.list[pv.idx].name
	end
	local it = self.fs:current()

	return "desktop", it and it.name or nil
end

-- 外部进程（播放器/reader）的应答带 TTL 缓存：一条 state 里问好几次，
-- 每次都 poll 出去，主循环就被这些 100ms 级超时拖着走。
-- 动作改状态后显式 invalidate，别让缓存吃掉 changed。
local BOOK_TTL, MEDIA_TTL = 250, 120

-- 缓存失效：what = "book" / "media" / "all"
function M:invalidate(what)
	if what and what ~= "all" then
		self.cache[what] = nil
	else
		self.cache = {}
	end
end

-- 在播什么、播到第几秒：state 文件给片源和区间，控制口给实时位置
function M:media()
	local t0 = peer.now_ms()
	local hit = self.cache.media

	if hit and t0 - hit.t < MEDIA_TTL then return hit.v end
	local ps = self:play_state_file()

	if not ps then
		self.cache.media = { t = t0, v = nil }
		return nil
	end
	local src = b64dec(ps.SRCB64) or ""
	local name = src:match("([^/%?]+)%?") or src:match("([^/]+)$") or src
	local start_s = tonumber(ps.SS) or 0
	local dur_s = tonumber(ps.DUR) or 0
	local m = {
		file = name,
		-- 凭据不回给客户端：只留 scheme://host/path
		src = (src:gsub("://[^@/]*@", "://***@")),
		pid = tonumber(ps.VPID),
		alive = peer.alive(ps.VPID),
		start_s = start_s,
		end_s = dur_s > 0 and (start_s + dur_s) or nil,
		render = ps.RENDER, scale = ps.SCALE,
	}

	local r = peer.text(self.cfg.play_sock, "status", 150)

	if r then
		m.pos_ms = tonumber(r.pos_ms)
		m.paused = tonumber(r.paused) == 1
		m.vol = tonumber(r.vol)
		m.mute = tonumber(r.mute) == 1
		m.xrun = tonumber(r.xrun)
		if m.pos_ms and m.end_s and m.end_s > 0 then
			m.percent = math.floor(m.pos_ms / (m.end_s * 1000) * 1000) / 10
		end
		if m.pos_ms then
			m.pos_h = ("%02d:%02d"):format(
				math.floor(m.pos_ms / 60000), math.floor(m.pos_ms / 1000) % 60)
		end
	end
	self.cache.media = { t = peer.now_ms(), v = m }
	return m
end

-- 在看哪本书、第几页：reader 有自己的自动化口，桌面替 agent 问一句
function M:book()
	local t0 = peer.now_ms()
	local hit = self.cache.book

	if hit and t0 - hit.t < BOOK_TTL then return hit.v end
	-- 不再先 access() 判存在：多一次系统调用还多一次 TOCTOU，
	-- 直接问，errno 是 ENOENT/ECONNREFUSED（"absent"）就是没在跑。
	local r = peer.req(self.cfg.reader_sock, { cmd = "state" }, 200)

	if not r or type(r.state) ~= "table" then
		self.cache.book = { t = t0, v = nil }
		return nil
	end
	local s = r.state
	local v = {
		open = true,
		library = s.library and true or false,
		book = s.book or s.title,
		page = tonumber(s.page), pages = tonumber(s.pages),
		chapter = tonumber(s.chapter), chapters = tonumber(s.chapters),
		font_size = tonumber(s.font_size),
	}

	self.cache.book = { t = peer.now_ms(), v = v }
	return v
end
-- 语义状态。flat 字段（pos/total/kind/size_h/app/file）是给极简解码端用的，
-- 嵌套的 screen/media/book 是细节。
function M:state()
	local fs, pv = self.fs, self.pv
	local it = fs:current()
	local app, file = self:front()
	local media = self:media()
	local book = self:book()
	local lo = self.last_open
	local n = fs:count()

	local st = {
		where = fs.dir,
		name = fs:display_name(),
		count = n,
		pos = fs.sel,
		total = n,
		kind = it and it.kind,
		size = it and it.size,
		size_h = it and FS.human_size(it.size) or nil,
		screen = {
			app = app, file = file,
			busy = self.launcher:busy() and true or false,
			since = lo and lo.ts or nil,
		},
		media = media,
		book = book,
	}

	-- 「在放」但控制口没起来（片子还在起链路的阶段）也算前台是播放器
	if media and media.alive and app == "desktop" then st.screen.app = "player" end
	if book and book.open and app == "desktop" then st.screen.app = "reader" end
	return st
end

-- 控制面指纹：路径/选中/预览/前后台/配色/网格。
-- 不含 pos_ms、页码这类每秒都在变的量 —— 否则 changed 永远 true，等于没有。
function M:digest()
	local fs, pv = self.fs, self.pv
	local it = fs:current()
	local app, file = self:front()
	local info = self.info or {}

	return table.concat({
		tostring(fs.dir), tostring(fs:count()), tostring(fs.sel),
		it and it.name or "-", tostring(pv.open and pv.idx or -1),
		app, tostring(file), tostring(self.launcher:busy()),
		tostring(info.theme), tostring(info.cols) .. "x" .. tostring(info.rows),
	}, "|")
end

return M
