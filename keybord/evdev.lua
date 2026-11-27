-- evdev.lua — 输入设备枚举 + 读键（LuaJIT FFI，无 libevdev）
--
-- 遥控器/键盘/红外都走 EV_KEY，盒子上的设备形如：
--   event0  XING WEI 2.4G 键盘接口   event2  Consumer Control
--   event1  meson-ir（红外）
-- 一个按键可能同时从两个设备到达（键盘接口 + Consumer Control），
-- 所以 keybd 侧按 code 做去重（见 keybd.lua 的 DEDUP_MS）。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
struct ev_timeval { long tv_sec; long tv_usec; };
struct input_event { struct ev_timeval time; uint16_t type; uint16_t code; int32_t value; };
struct ev_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clk, struct ev_timespec *ts);
int open(const char *path, int flags, ...);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
int ioctl(int fd, unsigned long req, ...);
int nanosleep(const struct ev_timespec *req, struct ev_timespec *rem);
int select(int nfds, void *rd, void *wr, void *ex, void *tv);
int *__errno_location(void);
]]

local C = ffi.C
local M = {}

M.SIZE = ffi.sizeof("struct input_event")   -- 24 on arm64/x86_64 (timeval 16 + 8)
M.EV_KEY = 1
M.EV_REP = 20
local O_RDONLY, O_NONBLOCK = 0, 2048
local EVIOCGRAB = 0x40044590

-- /proc/bus/input/devices → { {dev="/dev/input/event0", name="...", handlers={...}}, ... }
function M.scan()
	local list, cur = {}, nil
	local f = io.open("/proc/bus/input/devices")

	if not f then return list end
	for line in f:lines() do
		if line:match("^N: Name=") then
			cur = { name = line:match('Name="(.-)"') or "?" }
		elseif line:match("^H: Handlers=") and cur then
			cur.handlers = line:match("Handlers=(.*)$") or ""
			for ev in cur.handlers:gmatch("(event%d+)") do
				list[#list + 1] = {
					dev = "/dev/input/" .. ev,
					name = cur.name,
					handlers = cur.handlers,
				}
			end
		end
	end
	f:close()
	return list
end

-- 按名字子串包含/排除挑设备
--   include = "2.4G,ir"   exclude = "Mouse,Touch"
function M.pick(all, include, exclude)
	local function hit(name, pats)
		for p in tostring(pats or ""):gmatch("[^,]+") do
			if name:lower():find(p:lower(), 1, true) then return true end
		end
		return false
	end

	local out = {}

	for _, e in ipairs(all) do
		local ok = (include == nil or include == "") and true or hit(e.name, include)

		if ok and exclude and exclude ~= "" and hit(e.name, exclude) then ok = false end
		if ok then out[#out + 1] = e end
	end
	return out
end

function M.open(dev, ob)
	local fd = C.open(dev, O_RDONLY + O_NONBLOCK)

	if fd < 0 then return nil, "open failed: " .. dev end
	if ob and ob.grab then
		if C.ioctl(fd, EVIOCGRAB, ffi.cast("int", 1)) ~= 0 then
			C.close(fd)
			return nil, "EVIOCGRAB failed (已被别的进程独占?)"
		end
	end
	return fd
end

function M.ungrab(fd) C.ioctl(fd, EVIOCGRAB, ffi.cast("int", 0)) end
function M.close(fd) if fd and fd >= 0 then C.close(fd) end end

-- 事件自带的内核时间戳（CLOCK_REALTIME）→ 单调时钟毫秒。
-- 主循环被阻塞时（比如一次桌面动作花了 300ms），按下事件会被"晚读到"：
-- 拿读到的时间当按下时刻，按 0.9s 的长按会被算成 0.6s，0.7s 阈值永远差一口气。
-- 所以长按判定用事件里的 time，而不是读到的时刻。
local clk_offset
local function rt_offset()
	if clk_offset then return clk_offset end
	local rt, mo = ffi.new("struct ev_timespec"), ffi.new("struct ev_timespec")

	C.clock_gettime(0, rt)   -- CLOCK_REALTIME
	C.clock_gettime(1, mo)   -- CLOCK_MONOTONIC
	clk_offset = (tonumber(rt.tv_sec) * 1000 + math.floor(tonumber(rt.tv_nsec) / 1e6))
		- (tonumber(mo.tv_sec) * 1000 + math.floor(tonumber(mo.tv_nsec) / 1e6))
	return clk_offset
end

function M.ev_ms(t)
	return tonumber(t.tv_sec) * 1000 + math.floor(tonumber(t.tv_usec) / 1e3) - rt_offset()
end

-- 读一批事件；回调 fn(type, code, value, time)。返回 条数, 设备是否已消失(ENODEV)
local evbuf = ffi.new("struct input_event[64]")
local ENODEV, ENXIO = 19, 6
function M.drain(fd, fn)
	local n = 0

	while true do
		local r = C.read(fd, evbuf, M.SIZE * 64)

		if r <= 0 then
			local e = (r < 0) and C.__errno_location()[0] or 0
			return n, (e == ENODEV or e == ENXIO)
		end
		local cnt = tonumber(r) / M.SIZE

		for i = 0, cnt - 1 do
			local e = evbuf[i]

			fn(e.type, e.code, e.value, e.time)
			n = n + 1
		end
	end
	return n, false
end

-- 阻塞等可读（ms 超时）；fds 为 fd 数组
function M.poll(fds, ms)
	local set = ffi.new("char[128]")
	local tv = ffi.new("long[2]")

	ffi.fill(set, 128, 0)
	local maxfd = 0
	for _, fd in ipairs(fds) do
		ffi.cast("uint8_t*", set)[math.floor(fd / 8)] = bit.bor(ffi.cast("uint8_t*", set)[math.floor(fd / 8)],
			bit.lshift(1, fd % 8))
		if fd > maxfd then maxfd = fd end
	end
	tv[0] = math.floor(ms / 1000)
	tv[1] = (ms % 1000) * 1000
	return C.select(maxfd + 1, set, nil, nil, tv)
end

-- 阻塞读一个事件（调试用）
function M.one(fd)
	local ev = ffi.new("struct input_event")

	if C.read(fd, ev, M.SIZE) == M.SIZE then return ev.type, ev.code, ev.value end
end

function M.sleep(ms)
	local ts = ffi.new("struct ev_timespec")

	ts.tv_sec = math.floor(ms / 1000)
	ts.tv_nsec = (ms % 1000) * 1000000
	C.nanosleep(ts, nil)
end

-- 单调时钟毫秒（os.time 只到秒，os.clock 是 CPU 时间，都不能用来算按键间隔）
function M.now_ms()
	local ts = ffi.new("struct ev_timespec")

	C.clock_gettime(1, ts)   -- CLOCK_MONOTONIC
	return tonumber(ts.tv_sec) * 1000 + math.floor(tonumber(ts.tv_nsec) / 1e6)
end


-- —— uinput 虚拟键盘 ——
-- keybd 以 EVIOCGRAB 独占遥控器后，合成器（cage/chromium）就再也读不到按键。
-- 这里在 /dev/uinput 上造一个虚拟键盘，把独占设备的按键原样转发回内核，
-- 于是 keybd 既保留自己的派发能力，外部合成器也能拿到方向键。
local UI_DEV_CREATE = 0x5501
local UI_SET_EVBIT  = 0x40045564
local UI_SET_KEYBIT = 0x40045565
local UI_SET_RELBIT = 0x40045566
local UI_DEV_SETUP  = 0x405c5503
local O_WRONLY = 1

ffi.cdef [[
struct uinput_input_id { uint16_t bustype, vendor, product, version; };
struct uinput_setup { struct uinput_input_id id; char name[80]; uint32_t ff_effects_max; };
long write(int fd, const void *buf, unsigned long count);
]]

function M.uinput_create(name)
	local fd = C.open("/dev/uinput", O_WRONLY + O_NONBLOCK)

	if fd < 0 then fd = C.open("/dev/input/uinput", O_WRONLY + O_NONBLOCK) end
	if fd < 0 then return nil, "open /dev/uinput failed" end
	for _, t in ipairs({ 0, 1, 2, 20 }) do   -- SYN/KEY/REL/REP
		C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", t))
	end
	for c = 0, 255 do C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", c)) end
	for _, c in ipairs({ 0, 1, 6, 8 }) do    -- REL_X/Y/HWHEEL/WHEEL
		C.ioctl(fd, UI_SET_RELBIT, ffi.cast("int", c))
	end
	local us = ffi.new("struct uinput_setup")

	us.id.bustype, us.id.vendor, us.id.product, us.id.version = 0x03, 0x4b42, 0x0001, 1
	ffi.copy(us.name, name)
	if C.ioctl(fd, UI_DEV_SETUP, us) ~= 0 then
		C.close(fd)
		return nil, "UI_DEV_SETUP failed"
	end
	if C.ioctl(fd, UI_DEV_CREATE) ~= 0 then
		C.close(fd)
		return nil, "UI_DEV_CREATE failed"
	end
	return fd
end

local ubuf = ffi.new("struct input_event[2]")

function M.uinput_emit(fd, t, code, value)
	if not fd or fd < 0 then return end
	ubuf[0].type, ubuf[0].code, ubuf[0].value = t, code, value
	ubuf[1].type, ubuf[1].code, ubuf[1].value = 0, 0, 0
	C.write(fd, ubuf, M.SIZE * 2)
end

return M
