-- core/fs.lua — 目录扫描与文件分类（桌面的唯一数据源）
--
-- 只做三件事：
--   1. scan(dir)   读目录 → items（文件夹在前，按名字排，跳过隐藏点文件）
--   2. 维护 sel     当前选中项（网格坐标由 ui/grid 换算）
--   3. 进入/返回     enter(i) / up()
--
-- 条目结构：{ name=, path=, dir=true|false, kind="dir|ebook|video|audio|image|other",
--           size=, mtime=, ext= }
--
-- 用 io.popen("ls") 还是 luaposix？盒子上没有 luaposix，但 readdir 得靠 FFI：
-- 这里用 LuaJIT FFI 直接调 opendir/readdir/stat，零 fork，比 ls 快一个量级。

local ffi = require("ffi")
local ok_lfs, lfs = pcall(require, "lfs")
local dav = require("core.dav")

local M = {}
M.__index = M

local function basename(p)
	p = tostring(p):gsub("/+$", "")

	return p:match("([^/]+)$") or p
end

local function dirname(p)
	local d = tostring(p):gsub("/+$", "")

	if d == "" then return "/" end
	local parent = d:match("^(.*)/[^/]+$")

	if parent == nil or parent == "" then return "/" end
	return parent
end

local function join(dir, name)
	if dir == "/" then return "/" .. name end
	return dir .. "/" .. name
end

M.basename, M.dirname, M.join = basename, dirname, join

-- ---------- 读目录 ----------
-- 优先 lfs（装了就用），否则 FFI readdir。两条路返回同样的 {name=,dir=} 列表。

local readdir_ffi
do
	local ok = pcall(function()
		ffi.cdef [[
		typedef struct __dirstream DIR;
		typedef struct dirent {
			uint64_t        d_ino;
			int64_t         d_off;
			unsigned short  d_reclen;
			unsigned char   d_type;
			char            d_name[256];
		} dirent;
		DIR *opendir(const char *name);
		struct dirent *readdir(DIR *dirp);
		int closedir(DIR *dirp);
		]]
	end)

	if ok then
		local C = ffi.C
		local DT_DIR, DT_LNK, DT_UNKNOWN = 4, 10, 0

		readdir_ffi = function(path)
			local d = C.opendir(path)

			if d == nil then return nil, "opendir failed: " .. path end
			local out = {}

			while true do
				local e = C.readdir(d)

				if e == nil then break end
				local name = ffi.string(e.d_name)

				if name ~= "." and name ~= ".." then
					local isdir = e.d_type == DT_DIR

					-- 符号链接/未知类型：留 nil，让上层 lstat 再判一次
					if e.d_type == DT_LNK or e.d_type == DT_UNKNOWN then isdir = nil end
					out[#out + 1] = { name = name, dir = isdir }
				end
			end
			C.closedir(d)
			return out
		end
	end
end

-- size/mtime/目录判定：优先 lfs，否则 FFI stat()
-- （盒子上没有 lfs.so，只能走 FFI；x86_64 和 aarch64 的 st_size/st_mtim 偏移一样，
--   只有 st_mode 差一个位置，按 ffi.arch 分一下）
local stat_ffi
do
	local ok = pcall(function()
		ffi.cdef [[ int stat(const char *path, void *buf); ]]
	end)

	if ok then
		local bit = require("bit")
		local mode_off = (ffi.arch == "x64") and 24 or 16
		local size_off, mtime_off = 48, 88

		stat_ffi = function(path)
			local buf = ffi.new("uint8_t[256]")

			if ffi.C.stat(path, buf) ~= 0 then return nil end
			local p = ffi.cast("uint8_t *", buf)
			local mode = ffi.cast("uint32_t *", p + mode_off)[0]

			return {
				size = tonumber(ffi.cast("int64_t *", p + size_off)[0]),
				mtime = tonumber(ffi.cast("int64_t *", p + mtime_off)[0]),
				dir = bit.band(mode, 0xF000) == 0x4000,
			}
		end
	end
end

local function stat_of(path)
	if lfs and lfs.attributes then
		local a = lfs.attributes(path)

		if not a then return nil end
		return { size = a.size or 0, mtime = a.modification or 0,
			dir = a.mode == "directory" }
	end
	if stat_ffi then return stat_ffi(path) end
	return nil
end

-- NAS 走 WebDAV（虚拟路径 dav:/...），本地走 readdir
local function list_raw(path, cfg)
	if dav.is_dav(path) then
		if not dav.enabled(cfg) then return nil, "NAS 未配置（缺 WEBDAV_URL）" end
		return dav.list(cfg, path)
	end
	if lfs and lfs.dir then
		local it, dir = lfs.dir(path)

		if not it then return nil, "lfs.dir failed: " .. path end
		local out = {}

		for name in it, dir do
			if name ~= "." and name ~= ".." then out[#out + 1] = { name = name } end
		end
		return out
	end
	if readdir_ffi then return readdir_ffi(path) end
	return nil, "no readdir backend"
end

-- ---------- 排序 ----------
-- 文件夹优先；同组按名字（数字段做自然排序，第2章别排到第10章后面）；大小写不敏感

local function natural_key(s)
	s = s:lower()
	local parts = {}

	for chunk in s:gmatch("(%d+)") do parts[#parts + 1] = chunk end
	return s, parts
end

local function cmp_name(a, b)
	local an, ad = natural_key(a.name)
	local bn, bd = natural_key(b.name)

	-- 主键：剔除数字后的字母骨架，再逐段比数字
	local as, bs = an:gsub("%d+", ""), bn:gsub("%d+", "")

	if as ~= bs then return as < bs end
	local n = math.min(#ad, #bd)

	for i = 1, n do
		local x, y = tonumber(ad[i]), tonumber(bd[i])

		if x ~= y then return x < y end
	end
	if #ad ~= #bd then return #ad < #bd end
	return an < bn
end

local function cmp_items(a, b)
	if a.dir ~= b.dir then return a.dir end
	return cmp_name(a, b)
end

M.cmp_items = cmp_items

-- ---------- 对象 ----------

-- opts: { start=目录, show_hidden=bool }
function M.new(cfg, opts)
	opts = opts or {}
	local self = setmetatable({
		cfg = cfg,
		dir = opts.start or cfg.start_dir,
		items = {},
		sel = 1,
		offset = {},
		scanned = 0,
		err = nil,
	}, M)

	return self
end

function M:display_name()
	local cfg = self.cfg

	-- 标题栏：NAS 根显示 "NAS"，子目录显示目录名（远端路径太长了）
	if dav.is_dav(self.dir) then
		local remote = dav.remote(self.dir):gsub("/+$", "")

		if remote == "" or remote == (cfg.nas.base or ""):gsub("/+$", "") then
			return cfg.nas.label or "NAS"
		end
		return basename(self.dir)
	end
	return basename(self.dir)
end

function M:scan(dir, keep)
	dir = dir or self.dir
	local raw, err = list_raw(dir, self.cfg)

	if not raw then
		self.err = tostring(err)
		self.items = {}
		self.sel = 1
		return false, self.err
	end
	local cfg = self.cfg
	local items = {}
	local is_nas = dav.is_dav(dir)

	for _, e in ipairs(raw) do
		local name = e.name

		if cfg.show_hidden or name:sub(1, 1) ~= "." then
			local path = join(dir, name)
			local isdir = e.dir
			local size, mtime = e.size or 0, e.mtime or 0

			if is_nas then
				-- WebDAV 的 PROPFIND 已经给了 size/mtime，别再 lstat 虚空路径
				isdir = isdir == true
			elseif isdir == nil then
				local st = stat_of(path)

				if st then isdir, size, mtime = st.dir, st.size, st.mtime end
			elseif not isdir then
				local st = stat_of(path)

				if st then size, mtime = st.size, st.mtime end
			end
			isdir = isdir or false
			items[#items + 1] = {
				name = name, path = path, dir = isdir,
				kind = cfg.kind_of(name, isdir),
				size = size, mtime = mtime, ext = cfg.ext(name),
			}
		end
	end
	table.sort(items, cmp_items)

	local prev = keep
	self.dir = dir
	self.items = items
	self.scanned = os.time()
	self.err = nil
	self.sel = 1
	if prev then
		for i, it in ipairs(items) do
			if it.name == prev then self.sel = i; break end
		end
	end
	return true
end

function M:count() return #self.items end

function M:current()
	return self.items[self.sel]
end

function M:at(i)
	return self.items[i]
end

function M:select(i)
	local n = #self.items

	if n == 0 then self.sel = 1; return nil end
	self.sel = math.max(1, math.min(n, i))
	return self.items[self.sel]
end

function M:select_name(name)
	for i, it in ipairs(self.items) do
		if it.name == name then return self:select(i) end
	end
	return nil
end

-- 进入目录：成功返回 "dir"，否则返回 nil（文件由 launcher 处理）
function M:enter(i)
	local it = i and self:at(i) or self:current()

	if not it then return nil, "empty" end
	if not it.dir then return nil, "not a directory" end
	local ok, err = self:scan(it.path)

	if not ok then return nil, err end
	return "dir"
end

-- 返回上级；把刚才那个目录选回来（桌面上很关键，不然每次返回都跳回第一页）
function M:up()
	if self.dir == "/" then return nil, "at root" end
	-- NAS 的根：base 的上一级一般是共享列表，没意义；上到 base 就停
	if dav.is_dav(self.dir) then
		local remote = dav.remote(self.dir):gsub("/+$", "")
		local base = (self.cfg.nas.base or ""):gsub("/+$", "")

		if remote == "" or remote == "/" or remote == base then
			return nil, "at nas root"
		end
	end
	local child = basename(self.dir)
	local parent = dirname(self.dir)
	local ok, err = self:scan(parent, child)

	if not ok then return nil, err end
	return parent
end

-- 供自动化 / 状态展示
function M:state()
	local it = self:current()

	return {
		dir = self.dir,
		name = self:display_name(),
		nas = dav.is_dav(self.dir),
		count = #self.items,
		selected = self.sel,
		item = it and {
			name = it.name, path = it.path, kind = it.kind,
			dir = it.dir, size = it.size,
		} or nil,
	}
end

-- 人类可读大小
function M.human_size(n)
	n = tonumber(n) or 0
	if n < 1024 then return n .. " B" end
	if n < 1024 * 1024 then return ("%.1f KB"):format(n / 1024) end
	if n < 1024 * 1024 * 1024 then return ("%.1f MB"):format(n / 1048576) end
	return ("%.2f GB"):format(n / 1073741824)
end

return M
