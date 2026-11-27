-- core/hotplug.lua — 外设热插拔（U 盘自动挂载 + 拔出自动卸）
--
-- 为什么不用 udisks/udev 事件：盒子上没有 dbus，也不该为了插个盘起一堆服务。
-- 这里直接啃内核的 netlink uevent（NETLINK_KOBJECT_UEVENT，group 1）：
--   内核每来一个设备事件就往这个组播组发一条 "action@devpath\0KEY=VAL\0..."，
--   我们非阻塞 recv 一次拿一批，只看 ACTION/SUBSYSTEM/DEVNAME/DEVTYPE。
-- 兜底：uevent 可能丢（进程重启、缓冲溢出），所以另有 /sys/class/block 全量扫
-- （首次 + 每 2s），插着盘才启动的情况也能发现。
--
-- 挂载只做只读（MS_RDONLY）：U 盘随时会被拔走，只读挂载拔盘时不会掉数据，
-- 也不需要 fsck。要写盘的场景（缓存/下载）本来就不该落在 U 盘上。
--
-- 用法：
--   local hp = hotplug.new(cfg, { on_change = fn })
--   hp:poll(ms)        -- 每帧调一次，非阻塞；有变化返回 true
--   hp:list()          -- { {dev=,label=,mnt=,kind="usb"}, ... }
--   hp:close()

local ffi = require("ffi")

local M = {}
M.__index = M
local C = ffi.C

-- ---------- FFI 声明 ----------
-- 全用 pcall：automation.lua 里的 socket/bind/recv/close/fcntl 已经声明过，
-- 重复声明会抛错；下面每次调用都走 ffi.cast 成自己的原型，不受声明顺序影响。

local function d(s) pcall(ffi.cdef, s) end

d [[
typedef struct { unsigned short nl_family, nl_pad; uint32_t nl_pid, nl_groups; } desk_sockaddr_nl;
int socket(int, int, int);
int bind(int, const void *, unsigned int);
long recv(int, void *, size_t, int);
int close(int);
int fcntl(int, int, int);
int setsockopt(int, int, int, const void *, unsigned int);
int mount(const char *, const char *, const char *, unsigned long, const void *);
int umount2(const char *, int);
int mkdir(const char *, unsigned int);
int rmdir(const char *);
long readlink(const char *, char *, size_t);
char *strerror(int);
]]
d [[
typedef struct __dirstream DIR;
int closedir(DIR *);
]]
-- dirent: 和 core/fs.lua 同构，谁先声明都行（布局一样，重复声明被 pcall 吃掉）

local F = {
	socket = ffi.cast("int (*)(int,int,int)", C.socket),
	bind = ffi.cast("int (*)(int,const void*,unsigned int)", C.bind),
	recv = ffi.cast("long (*)(int,void*,size_t,int)", C.recv),
	close = ffi.cast("int (*)(int)", C.close),
	fcntl = ffi.cast("int (*)(int,int,int)", C.fcntl),
	setsockopt = ffi.cast("int (*)(int,int,int,const void*,unsigned int)", C.setsockopt),
	mount = ffi.cast("int (*)(const char*,const char*,const char*,unsigned long,const void*)",
		C.mount),
	umount2 = ffi.cast("int (*)(const char*,int)", C.umount2),
	mkdir = ffi.cast("int (*)(const char*,unsigned int)", C.mkdir),
	rmdir = ffi.cast("int (*)(const char*)", C.rmdir),
	readlink = ffi.cast("long (*)(const char*,char*,size_t)", C.readlink),
	strerror = ffi.cast("char *(*)(int)", C.strerror),
}

local AF_NETLINK, SOCK_DGRAM = 16, 2
local NETLINK_KOBJECT_UEVENT = 15
local SOL_SOCKET, SO_RCVBUF, SO_PASSCRED = 1, 8, 16
local F_SETFL, F_SETFD, FD_CLOEXEC = 4, 2, 1
local O_NONBLOCK = 0x800
local MSG_DONTWAIT = 0x40
local MS_RDONLY, MS_NOSUID, MS_NODEV, MS_NOEXEC, MS_NOATIME = 1, 2, 4, 8, 0x400
local MNT_DETACH = 2

local UEVENT_BUF = 8192
-- /sys 那边每帧也可能被扫，一次分配反复用
local EV_BUF = ffi.new("char[?]", UEVENT_BUF)
local MAX_EVENTS = 64 -- 单帧最多吃这么多条，防止刷屏事件把帧拖长

-- ---------- 小工具 ----------

local function readfile(p)
	local f = io.open(p, "rb")

	if not f then return nil end
	local s = f:read("*a")

	f:close()
	return s
end

local function exists(p)
	local f = io.open(p, "rb")
	if not f then return false end
	f:close()
	return true
end

-- 只读头部 n 字节：U 盘可能有几十 G，绝不能 read("*a") 整盘
local function read_head(p, n)
	local f = io.open(p, "rb")

	if not f then return nil end
	local s = f:read(n)

	f:close()
	return s
end

local function isdir(p)
	local f = io.open(p .. "/.", "rb")
	if not f then return false end
	f:close()
	return true
end

-- 目录列表：盘上没 lfs.so，直接 FFI readdir（和 core/fs.lua 同一套 ABI）
local readdir
do
	-- 注意：core/fs.lua 已经 cdef 过同一套 ABI，这里再 cdef 会报
	-- "attempt to redefine 'dirent'"。那不是故障：结构体和符号照样能用。
	-- （曾经把 redefine 当成"不可用"→ readdir=nil → U 盘永远扫不到）
	pcall(ffi.cdef, [[
	typedef struct dirent {
		uint64_t d_ino; int64_t d_off;
		unsigned short d_reclen; unsigned char d_type; char d_name[256];
	} dirent;
	DIR *opendir(const char *name);
	struct dirent *readdir(DIR *dirp);
	int closedir(DIR *dirp);
	]])

	local opendir, rd = C.opendir, C.readdir

	if opendir and rd then
		readdir = function(path)
			local dir = opendir(path)

			if dir == nil then return {} end
			local out = {}

			while true do
				local e = rd(dir)

				if e == nil then break end
				local name = ffi.string(e.d_name)

				if name ~= "." and name ~= ".." then out[#out + 1] = name end
			end
			C.closedir(dir)
			return out
		end
	end
end

local function basename(p) return (tostring(p):gsub("/+$", ""):match("[^/]+$")) end

-- /proc/mounts → dev -> 挂载点（解析 \040 这类转义）
local function proc_mounts()
	local out = {}
	local f = io.open("/proc/mounts", "rb")

	if not f then return out end
	for line in f:lines() do
		local dev, mnt = line:match("^(%S+)%s+(%S+)%s+%S+")
		-- overlay/devtmpfs 这类也有 dev 字段，但它们不会和我们的 /dev/sdX* 撞
		if dev and mnt then
			mnt = mnt:gsub("\\040", " ")
			out[dev] = mnt
		end
	end
	f:close()
	return out
end

-- 挂载点名字：优先卷标，取不到用设备名；剔掉会惹事的字符
local function label_of(dev)
	local base = basename(dev)
	local list = readdir and readdir("/dev/disk/by-label") or {}

	if #list > 0 then
		-- 一个缓冲区问遍所有标签：每次 new 一块是给 GC 白送活
		local lbuf = ffi.new("char[512]")

		for _, name in ipairs(list) do
			local n = F.readlink("/dev/disk/by-label/" .. name, lbuf, 511)

			if n > 0 then
				local tgt = ffi.string(lbuf, tonumber(n))

				if basename(tgt) == base then return name end
			end
		end
	end
	-- 盒子上不一定有 udev（也就没有 /dev/disk/by-label），那就自己认文件系统：
	-- 先按魔数判类型，再取卷标（不能瞎读偏移，会读出引导扇区里的机器码）。
	--   vfat:  "FAT12/16" @0x36 → 卷标 @0x2B；"FAT32" @0x52 → 卷标 @0x47（11 字节）
	--   exfat: "EXFAT" @0x03 → 卷标 @0x40（UTF-16LE 22 字节）
	--   ext*:  魔数 0xEF53 @1024+0x38 → 卷标 @1024+0x78（120 字节）
	-- 只读前 4KB：U 盘可能几十 G，绝不能整盘读。
	local raw = read_head(dev, 4096)

	local function clean(b)
		if not b then return "" end
		b = b:gsub("%z.*$", ""):gsub("%s+$", "")
		if b == "NO NAME" or b == "no name" then return "" end
		if b:find("[^%w%._%-%+%(%)%[%] ]") then return "" end
		return b
	end

	if raw then
		local t = raw:sub(55, 62) -- "FAT12   " / "FAT16   "

		if t == "FAT12   " or t == "FAT16   " then
			local lab = clean(raw:sub(44, 54))

			if lab ~= "" then return lab end
		elseif raw:sub(83, 90) == "FAT32   " then
			local lab = clean(raw:sub(72, 82))

			if lab ~= "" then return lab end
		elseif raw:sub(4, 11) == "EXFAT   " then
			local ex, out = raw:sub(65, 86), {}

			for i = 1, #ex, 2 do
				local lo = ex:byte(i)

				if not lo or lo == 0 then break end
				out[#out + 1] = string.char(lo) -- 只要 ASCII 低位，中文卷标后面还有一层兜底
			end
			local lab = clean(table.concat(out))

			if lab ~= "" then return lab end
		elseif raw:sub(1081, 1082) == "\239S" then -- ext magic 0x53EF
			local lab = clean(raw:sub(1145, 1264))

			if lab ~= "" then return lab end
		end
	end
	return base
end

local function safe_name(s)
	-- 保留 UTF-8 多字节（中文卷标很常见），只把路径分隔符和奇怪字符换掉
	s = tostring(s or ""):gsub("[^%w%._%-%+%(%)%[%]%s\128-\255]", "_")
	s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_")
	if s == "" or s == "." or s == ".." then s = "usb" end
	if #s > 40 then s = s:sub(1, 40) end
	return s
end

-- ---------- netlink ----------

local function open_uevent()
	local fd = F.socket(AF_NETLINK, SOCK_DGRAM, NETLINK_KOBJECT_UEVENT)

	if fd < 0 then return nil, "netlink socket: " .. ffi.string(F.strerror(ffi.errno())) end

	local one = ffi.new("int[1]", 1)
	-- 只在本进程读完：组播组 1 会收到所有设备事件，缓冲给大点
	F.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, one, 4)

	local addr = ffi.new("desk_sockaddr_nl")

	addr.nl_family = AF_NETLINK
	addr.nl_pid = 0     -- 0 = 内核自己发
	addr.nl_groups = 1  -- KOBJECT_UEVENT 组
	if F.bind(fd, addr, ffi.sizeof(addr)) ~= 0 then
		local e = "bind uevent: " .. ffi.string(F.strerror(ffi.errno()))

		F.close(fd)
		return nil, e
	end
	F.fcntl(fd, F_SETFL, O_NONBLOCK)
	F.fcntl(fd, F_SETFD, FD_CLOEXEC) -- 播放器/阅读器是子进程，别把 fd 漏给它们
	return fd
end

-- 一条 uevent = "add@/devices/...\0ACTION=add\0SUBSYSTEM=block\0DEVNAME=sdb1\0DEVTYPE=partition\0"
local function parse_uevent(buf, n)
	local s = ffi.string(buf, n)
	local first = s:match("^([^%z]*)")

	if not first then return nil end
	local kv = {}

	for seg in s:gmatch("([^%z]+)") do
		local k, v = seg:match("^([%w_]+)=(.*)$")

		if k then kv[k] = v end
	end
	if kv.ACTION == nil then kv.ACTION = first:match("^(%a+)@") end
	return kv
end

-- ---------- 对象 ----------

-- opts = { on_change = function(kind, vol) end, root="/media", all=false, rw=false }
function M.new(cfg, opts)
	opts = opts or {}
	local self = setmetatable({
		cfg = cfg,
		root = opts.root or (cfg and cfg.usb_mount_root) or "/media",
		on_change = opts.on_change,
		-- 默认只挂"可移动"设备：eMMC/SD 系统盘不碰
		all = opts.all or (os.getenv("DESKTOP_USB_ALL") or "") ~= "",
		-- 明文点名的设备（没有真 U 盘时用 loop 设备演练）：
		-- DESKTOP_USB_EXTRA=/dev/loop16,/dev/sdc1
		extra = opts.extra or (os.getenv("DESKTOP_USB_EXTRA") or ""),
		rw = opts.rw or (os.getenv("DESKTOP_USB_RW") or "") ~= "",
		vols = {},   -- dev -> { dev, label, mnt, owned }
		used = {},   -- 见过的设备（拔了要等它真没了再从 used 里删）
		pending = false,
		last_ev = 0,
		last_scan = -1e9,
		dirty = true,
	}, M)

	self.fd, self.err = open_uevent()
	-- 挂载点根目录：/media 一般都有，没有就建
	if not isdir(self.root) then pcall(F.mkdir, self.root, 493) end
	return self
end

function M:list()
	local out = {}

	for _, v in pairs(self.vols) do out[#out + 1] = v end
	table.sort(out, function(a, b) return a.mnt < b.mnt end)
	return out
end

function M:emit(kind, v)
	if self.on_change then pcall(self.on_change, kind, v) end
end

-- 选一个不撞车的挂载点：卷标可能重名（两个盘都叫 UDISK）
function M:target(label)
	local name = safe_name(label)
	local mnt = self.root .. "/" .. name

	for i = 2, 32 do
		local taken = false

		for _, v in pairs(self.vols) do
			if v.mnt == mnt then taken = true; break end
		end
		if not taken then break end
		mnt = ("%s/%s-%d"):format(self.root, name, i)
	end
	return mnt
end

local FSTYPES = { "exfat", "vfat", "ntfs3", "ntfs", "ext4", "ext3", "ext2", "udf", "iso9660" }

function M:mount(dev, label)
	local mnt = self:target(label)

	pcall(F.mkdir, mnt, 493) -- 0755
	local flags = MS_NOSUID + MS_NODEV + MS_NOEXEC + MS_NOATIME
	local data = nil

	if not self.rw then flags = flags + MS_RDONLY end
	local last = "没有可用的文件系统类型"

	for _, t in ipairs(FSTYPES) do
		local opt = (t == "vfat" or t == "exfat") and "iocharset=utf8" or nil

		if F.mount(dev, mnt, t, flags, opt) == 0 then
			local v = { dev = dev, label = label, mnt = mnt, kind = "usb",
				owned = true, fstype = t }

			self.vols[dev] = v
			return v
		end
		last = t .. ": " .. ffi.string(F.strerror(ffi.errno()))
	end
	pcall(F.rmdir, mnt)
	return nil, last
end

-- force: 设备本身已经没了（拔盘），不管是不是我们挂的都得卸，
-- 否则 /proc/mounts 里会留一条指向空气的僵尸挂载
function M:unmount(v, force)
	if v.owned or force then
		local err

		if F.umount2(v.mnt, MNT_DETACH) ~= 0 then
			err = ffi.string(F.strerror(ffi.errno()))
		end
		-- 卸载失败也把空目录收掉（常见于别人已经卸过了，目录还留着）
		pcall(F.rmdir, v.mnt)
		if err then return nil, err end
	else
		-- 不是我们挂的（系统 automount / 用户手动挂的）：只从列表里摘掉，不动挂载
	end
	return true
end

-- ---------- 扫盘 ----------

-- /sys/class/block 全量扫一遍：发现没挂的挂上，已挂的登记，消失的摘掉
function M:scan_fs()
	local changed = false
	local mounts = proc_mounts()
	local names = readdir and readdir("/sys/class/block") or {}

	-- 有分区的整盘不单独挂（避免和 sdb1 重复），先收集"父盘"
	local has_part = {}
	local parts = {}

	for _, n in ipairs(names) do
		local disk = n:match("^(.*%a)%d+$") -- sdb1 → sdb；nvme0n1p1 → nvme0n1p

		if disk and exists("/sys/class/block/" .. n .. "/partition") then
			has_part[disk] = true
			parts[#parts + 1] = { name = n, disk = disk }
		end
	end

	local cands = {}

	for dev in tostring(self.extra or ""):gmatch("[^,;%s]+") do
		cands[#cands + 1] = { name = basename(dev), disk = basename(dev), forced = true }
	end

	for _, p in ipairs(parts) do cands[#cands + 1] = { name = p.name, disk = p.disk } end
	for _, n in ipairs(names) do
		if not has_part[n] and not n:match("^loop") and not n:match("^ram")
			and not n:match("^dm%-") and not n:match("^md") then
			cands[#cands + 1] = { name = n, disk = n }
		end
	end

	for _, c in ipairs(cands) do
		local dev = "/dev/" .. c.name

		-- 可移动/pendrive 判定：父盘的 removable 是 1，或设备挂在 usb 总线上
		local removable = (readfile("/sys/class/block/" .. c.disk .. "/removable") or "")
			:match("^%s*1") ~= nil
		if not removable then
			local link = readfile("/sys/class/block/" .. c.name .. "/device/../uevent")
				or readfile("/sys/class/block/" .. c.name .. "/uevent") or ""
			removable = link:match("USB_") ~= nil
		end
		if removable or self.all or c.forced then
			local known = self.vols[dev]

			if known then
				-- 两种"卷没了"：设备节点消失（真拔了，必须强制卸），
				-- 或者挂载表里已经没有它（被手动/别人卸了，只摘记录）
				local alive = exists(dev)

				if (not alive) or mounts[dev] ~= known.mnt then
					self:unmount(known, not alive)
					self.vols[dev] = nil
					changed = true
					self:emit("remove", known)
				end
			elseif mounts[dev] then
				-- 已经被别的东西挂上了（automount）：直接认，不动它
				if mounts[dev] ~= "/" then
					local v = { dev = dev, label = basename(mounts[dev]),
						mnt = mounts[dev], kind = "usb", owned = false }

					self.vols[dev] = v
					changed = true
					self:emit("add", v)
				end
			else
				local label = label_of(dev)
				local v, err = self:mount(dev, label)

				if v then
					changed = true
					self:emit("add", v)
				elseif err then
					self.err = ("%s 挂不上：%s"):format(dev, err)
				end
			end
		end
	end
	return changed
end

-- 有盘拔掉了：内核先发 remove，这时挂载点已经 IO 全错，必须先卸再摘
function M:handle_remove(devname)
	local dev = devname and ("/dev/" .. devname) or nil

	if not dev then return false end
	local v = self.vols[dev]

	if not v then return false end
	self:unmount(v, true)
	self.vols[dev] = nil
	self:emit("remove", v)
	return true
end

-- 每帧调：先吃 uevent，再（按需）扫 /sys
function M:poll(now)
	if not self.fd and not self.err then self.fd = open_uevent() end
	local changed = false

	if self.fd then
		local buf = EV_BUF

		for _ = 1, MAX_EVENTS do
			local n = tonumber(F.recv(self.fd, buf, UEVENT_BUF, MSG_DONTWAIT))

			if n <= 0 then break end
			local kv = parse_uevent(buf, n)

			if kv and (kv.SUBSYSTEM == "block" or kv.SUBSYSTEM == "usb") then
				local act = kv.ACTION

				if act == "add" or act == "change" then
					-- 分区表可能晚几百毫秒才完整：不当场挂，等 settle 后扫
					self.pending = true
					self.last_ev = now
				elseif act == "remove" then
					if kv.SUBSYSTEM == "block" and kv.DEVNAME then
						if self:handle_remove(kv.DEVNAME) then changed = true end
					end
					-- usb 总线 remove 也扫一遍兜底
					self.pending = true
					self.last_ev = now
				end
			end
		end
	end

	-- 插上 settle 500ms 再挂；另有 2s 全量兜底（开机前就插着的盘靠这个）
	if (self.pending and now - self.last_ev >= 500) or (now - self.last_scan >= 2000) then
		self.pending = false
		self.last_scan = now
		if self:scan_fs() then changed = true end
	end
	return changed
end

function M:close()
	if self.fd then F.close(self.fd); self.fd = nil end
end

return M
