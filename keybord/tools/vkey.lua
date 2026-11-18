-- tools/vkey.lua — 造虚拟键盘往盒子里打按键（不用遥控器也能测 keybd）
--
--   luajit tools/vkey.lua back                 # 按一下「返回」
--   luajit tools/vkey.lua ok down ok           # 连按
--   luajit tools/vkey.lua ctrl+1               # 组合键
--   luajit tools/vkey.lua hold:right           # 模拟长按连发（value=2）
--   luajit tools/vkey.lua --list               # 看支持的键名
--
-- 纯 LuaJIT FFI，直连 libc 的 open/ioctl/write，不依赖 python。
-- 盒子上的 /dev/uinput 只吃 UI_DEV_SETUP 那套，老式 write(uinput_user_dev) 会 EINVAL。
-- 设备建好后要留几秒，等 keybd 下一次扫描（默认 2s）把它 grab 走，否则键白发。
local ffi = require("ffi")

ffi.cdef [[
	struct timeval { long tv_sec; long tv_usec; };
	struct timespec { long tv_sec; long tv_nsec; };
	struct input_event { struct timeval time; uint16_t type; uint16_t code; int32_t value; };
	struct input_id { uint16_t bustype; uint16_t vendor; uint16_t product; uint16_t version; };
	struct uinput_setup { struct input_id id; char name[80]; uint32_t ff_effects_max; };

	int open(const char *path, int flags, ...);
	int ioctl(int fd, unsigned long req, ...);
	long write(int fd, const void *buf, unsigned long n);
	int close(int fd);
	int nanosleep(const struct timespec *req, struct timespec *rem);
]]

local C = ffi.C

local O_WRONLY, O_NONBLOCK = 1, 0x800

-- _IOC(dir,type,nr,size) —— Linux 各架构一致（只有 s390 例外，盒子不是）
local function IOC(dir, typ, nr, size)
	return dir * 0x40000000 + size * 0x10000 + typ * 0x100 + nr
end

local function IOW(typ, nr, size) return IOC(1, typ, nr, size) end   -- _IOW
local function IO(typ, nr) return IOC(0, typ, nr, 0) end             -- _IO

local UI_SET_EVBIT = IOW(string.byte("U"), 100, 4)
local UI_SET_KEYBIT = IOW(string.byte("U"), 101, 4)
local UI_DEV_SETUP = IOW(string.byte("U"), 3, ffi.sizeof("struct uinput_setup"))
local UI_DEV_CREATE = IO(string.byte("U"), 1)
local UI_DEV_DESTROY = IO(string.byte("U"), 2)

local EV_SYN, EV_KEY = 0, 1
local EV_REP = 20                                            -- 想开自动重发才用得上

local NAMES = {
	right = 106, left = 105, up = 103, down = 108, ok = 352,
	enter = 28, esc = 1, space = 57, tab = 15, backspace = 14, home = 172,
	volup = 115, voldn = 114, back = 158,
	blue = 371, green = 399, yellow = 400, red = 398,
	ctrl = 29, ["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5, ["5"] = 6,
	menu = 139, playpause = 164, mute = 113, info = 358,
	next = 163, prev = 165, power = 116,
}

-- 也认裸码：vkey.lua 158
local function code_of(s)
	local n = NAMES[s]

	if n then return n end
	n = tonumber(s)
	if n and n > 0 and n < 0x300 then return n end
	return nil
end

local function sleep_s(sec)
	local ts = ffi.new("struct timespec")
	local whole = math.floor(sec)                  -- 先用 Lua number 算完再写字段：
	local frac = math.floor((sec - whole) * 1e9)    -- 直接读 ts.tv_sec 会拿到 int64 cdata

	ts.tv_sec, ts.tv_nsec = whole, frac
	while C.nanosleep(ts, ts) ~= 0 do end          -- 被信号打断就补睡
end

-- 参数解析
local specs = {}

for i = 1, #arg do
	local a = arg[i]

	if a == "--list" or a == "-l" then
		local ks = {}

		for k, v in pairs(NAMES) do ks[#ks + 1] = ("%-10s %d"):format(k, v) end
		table.sort(ks)
		print("vkey.lua 支持的键名（也可直接给码，如 158）：\n" .. table.concat(ks, "\n"))
		os.exit(0)
	end
	if a:match("^%-") then io.stderr:write("未知参数: " .. a .. "\n") os.exit(2) end
	specs[#specs + 1] = a
end

if #specs == 0 then
	io.stderr:write("用法: luajit vkey.lua [hold:]<键名|码> [mod+键] ...\n")
	os.exit(2)
end

-- 先全部翻译成码，免得设备建好之后才发现键名写错
local plan = {}

for _, sp in ipairs(specs) do
	local hold, spec = false, sp

	if spec:sub(1, 5) == "hold:" then
		hold, spec = true, spec:sub(6)
	end

	local mod, k = spec:match("^(%w+)%+(.+)$")

	if mod then
		local m, c = code_of(mod), code_of(k)

		if not (m and c) then
			io.stderr:write("不认识的键: " .. sp .. "（--list 看键名）\n") os.exit(2)
		end
		plan[#plan + 1] = { hold = false, mod = m, code = c }
	else
		local c = code_of(spec)

		if not c then
			io.stderr:write("不认识的键: " .. sp .. "（--list 看键名）\n") os.exit(2)
		end
		plan[#plan + 1] = { hold = hold, code = c }
	end
end

local fd = C.open("/dev/uinput", O_WRONLY + O_NONBLOCK)

if fd < 0 then io.stderr:write("打不开 /dev/uinput（要 root，且内核有 uinput）\n") os.exit(1) end

local function must(rc, what)
	if rc < 0 then
		io.stderr:write(what .. " 失败\n")
		C.close(fd)
		os.exit(1)
	end
end

must(C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_KEY)), "UI_SET_EVBIT")
must(C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_REP)), "UI_SET_EVBIT(REP)")
for c in pairs(NAMES) do
	-- 把表里用到的码全放开，省得组合键时漏
	must(C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", NAMES[c])), "UI_SET_KEYBIT " .. NAMES[c])
end

local setup = ffi.new("struct uinput_setup")

setup.id.bustype = 3          -- BUS_USB
setup.id.vendor = 1
setup.id.product = 1
setup.id.version = 1
ffi.copy(setup.name, "vkeybd-test", 11)
must(C.ioctl(fd, UI_DEV_SETUP, setup), "UI_DEV_SETUP")
must(C.ioctl(fd, UI_DEV_CREATE), "UI_DEV_CREATE")

local evs = ffi.new("struct input_event")
local function emit(t, c, v)
	evs.type, evs.code, evs.value = t, c, v
	C.write(fd, evs, ffi.sizeof(evs))
end

-- 等 keybd 扫描到并 grab（默认 2s 一次）；设备建好就发键，抓不到就白发了
sleep_s(tonumber(os.getenv("VKEY_WAIT")) or 3)

local function press(code)
	emit(EV_KEY, code, 1)
	emit(EV_SYN, 0, 0)
	sleep_s(0.05)
	emit(EV_KEY, code, 0)
	emit(EV_SYN, 0, 0)
	sleep_s(0.35)
end

for _, p in ipairs(plan) do
	if p.mod then
		emit(EV_KEY, p.mod, 1)
		emit(EV_SYN, 0, 0)
		press(p.code)
		emit(EV_KEY, p.mod, 0)
		emit(EV_SYN, 0, 0)
	elseif p.hold then
		-- 长按：value=2 是内核的 autorepeat 语义，keybd 按连发算
		emit(EV_KEY, p.code, 1)
		emit(EV_SYN, 0, 0)
		for _ = 1, 10 do
			sleep_s(0.04)
			emit(EV_KEY, p.code, 2)
			emit(EV_SYN, 0, 0)
		end
		emit(EV_KEY, p.code, 0)
		emit(EV_SYN, 0, 0)
		sleep_s(0.35)
	else
		press(p.code)
	end
end
print("sent: " .. table.concat(specs, " "))

sleep_s(4)                    -- 设备留着，等 keybd 下一次扫描接手
C.ioctl(fd, UI_DEV_DESTROY)
C.close(fd)
