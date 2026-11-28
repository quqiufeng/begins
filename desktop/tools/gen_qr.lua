#!/usr/bin/env luajit
-- gen_qr.lua — 桌面「更新 Key」二维码：LuaJIT FFI 直接调系统 libqrencode.so + libz
--
-- 为什么不用 qrencode CLI：盒子上已经有 libqrencode.so.4（qrencode 包带），
-- 出图只是「调一个函数 + 拼 PNG 头」，开子进程毫无收益，而且 CLI 版本差异
-- （-s/-m 语义）会让 QR 尺寸随发行版漂移。这里 encode 与 PNG 编码都在进程内，
-- 一个文件搞定，换个盒子只要 libqrencode.so.4 在就能跑。
--
-- 内容优先级：argv[1]（位置参数）> $DESKTOP_QR_URL > http://<第一个非回环 IPv4>:8080/
-- IP 用 getifaddrs 直接从 libc 取，不 shell 出去问 `ip`。
--
-- 图标必须白底黑块：反色（暗底亮块）一半以上手机扫不出来，别为了配暗色主题反色。
--
-- 用法：
--   luajit tools/gen_qr.lua                      # 写到 <root>/assets/icons/qr.png
--   luajit tools/gen_qr.lua http://1.2.3.4:8080/
--   luajit tools/gen_qr.lua --out /tmp/q.png --scale 16 --margin 4 URL
--   luajit tools/gen_qr.lua --ascii URL           # 终端出矩阵，对拍用

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
typedef struct { int version; int width; unsigned char *data; } QRcode;
QRcode *QRcode_encodeString(const char *string, int version, int level, int hint,
                            int casesensitive);
void QRcode_free(QRcode *qrcode);

unsigned long compressBound(unsigned long sourceLen);
int compress2(unsigned char *dest, unsigned long *destLen, const unsigned char *source,
              unsigned long sourceLen, int level);
unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);

struct sockaddr { unsigned short sa_family; char sa_data[14]; };
struct ifaddrs {
	struct ifaddrs *ifa_next;
	char *ifa_name;
	unsigned int ifa_flags;
	struct sockaddr *ifa_addr;
	struct sockaddr *ifa_netmask;
	struct sockaddr *ifa_dstaddr;
	void *ifa_data;
};
struct sockaddr_in { unsigned short sin_family; unsigned short sin_port; unsigned int sin_addr; char pad[8]; };
int getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);
]]

-- 系统只装运行时库时没有 libqrencode.so 这个 dev 软链，按 .so.N 兜底。
local function load_any(names, what)
	for _, n in ipairs(names) do
		local ok, lib = pcall(ffi.load, n)
		if ok then return lib end
	end
	error(("%s 找不到（试过 %s）"):format(what, table.concat(names, ", ")), 0)
end

local qr = load_any({ "libqrencode.so.4", "libqrencode.so", "qrencode" }, "libqrencode")
local z = load_any({ "libz.so.1", "libz.so", "z" }, "libz")

local floor = math.floor

--------------------------------------------------------------------------- 矩阵

local LEVEL = { L = 0, M = 1, Q = 2, H = 3 }
local MODE_8 = 3 -- QR_MODE_8

local function encode(text, level)
	local code = qr.QRcode_encodeString(text, 0, LEVEL[level] or LEVEL.M, MODE_8, 1)
	if code == nil then error("QRcode_encodeString 失败（内容过长？）", 0) end
	local m = { width = code.width, ver = code.version, data = {} }
	for i = 0, code.width * code.width - 1 do
		m.data[i] = code.data[i]
	end
	qr.QRcode_free(code)
	return m
end

-- 位 0 = 黑模块（qrencode 约定）
local function is_black(m, x, y) return bit.band(m.data[y * m.width + x], 1) == 1 end

--------------------------------------------------------------------------- 本机 IP

local function first_ipv4()
	local head = ffi.new("struct ifaddrs *[1]")
	if ffi.C.getifaddrs(head) ~= 0 then return nil end
	local out
	local p = head[0]
	while p ~= nil do
		local fam = p.ifa_addr ~= nil and p.ifa_addr.sa_family or 0
		-- AF_INET=2, IFF_UP=1, IFF_LOOPBACK=8
		local up = bit.band(p.ifa_flags, 1) ~= 0
		local lo = bit.band(p.ifa_flags, 8) ~= 0
		if fam == 2 and up and not lo then
			local sin = ffi.cast("struct sockaddr_in *", p.ifa_addr)
			local a = sin.sin_addr -- 网络字节序，按字节取
			out = ("%d.%d.%d.%d"):format(bit.band(a, 255), bit.band(bit.rshift(a, 8), 255),
				bit.band(bit.rshift(a, 16), 255), bit.rshift(a, 24))
			break
		end
		p = p.ifa_next
	end
	ffi.C.freeifaddrs(head[0])
	return out
end

--------------------------------------------------------------------------- PNG

local function be32(n)
	n = tonumber(n)
	return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
		bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

local function chunk(typ, data)
	local crc = z.crc32(0, nil, 0)
	crc = z.crc32(crc, typ, #typ)
	if #data > 0 then crc = z.crc32(crc, data, #data) end
	return be32(#data) .. typ .. data .. be32(crc)
end

-- 灰度 8bit（0=黑 255=白），静区纯白，每行 filter=0。
-- 按「模块行」算一条 scanline 再 ffi.copy 重复 scale 次：528² 也就几百微秒。
local function png_bytes(m, scale, margin)
	local n = m.width
	local w = (n + margin * 2) * scale
	local h = w
	local stride = w + 1

	local raw = ffi.new("uint8_t[?]", h * stride)
	local line = ffi.new("uint8_t[?]", stride)
	line[0] = 0 -- filter: None

	local cur = -1000
	for y = 0, h - 1 do
		local my = floor(y / scale) - margin
		if my ~= cur then
			cur = my
			if my < 0 or my >= n then
				ffi.fill(line + 1, w, 255)
			else
				local base = my * n
				for x = 0, w - 1 do
					local mx = floor(x / scale) - margin
					line[1 + x] = (mx >= 0 and mx < n and bit.band(m.data[base + mx], 1) == 1)
						and 0 or 255
				end
			end
		end
		ffi.copy(raw + y * stride, line, stride)
	end

	local src_len = ffi.cast("unsigned long", h * stride)
	local zbuf = ffi.new("uint8_t[?]", z.compressBound(src_len) + 64)
	local zlen = ffi.new("unsigned long[1]", z.compressBound(src_len) + 64)
	local rc = z.compress2(zbuf, zlen, raw, src_len, 9)
	if rc ~= 0 then error("compress2 失败 rc=" .. rc, 0) end

	local idat = ffi.string(zbuf, tonumber(zlen[0]))
	local ihdr = be32(w) .. be32(h) .. string.char(8, 0, 0, 0, 0) -- 8bit 灰度
	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", ihdr)
		.. chunk("IDAT", idat)
		.. chunk("IEND", "")
end

--------------------------------------------------------------------------- main

local opt = { level = "M", scale = 16, margin = 4, ascii = false }
do
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if a == "--ascii" then
			opt.ascii = true
		elseif a == "--out" then
			i = i + 1; opt.out = arg[i]
		elseif a == "--scale" then
			i = i + 1; opt.scale = tonumber(arg[i]) or opt.scale
		elseif a == "--margin" then
			i = i + 1; opt.margin = tonumber(arg[i]) or opt.margin
		elseif a == "--level" then
			i = i + 1; opt.level = (arg[i] or "M"):upper()
		elseif a == "-h" or a == "--help" then
			opt.help = true
		else
			opt.url = a
		end
		i = i + 1
	end
end

if opt.help then
	print("用法: gen_qr.lua [--out PNG] [--scale N] [--margin N] [--level L|M|Q|H] [--ascii] [URL]")
	return
end

local url = opt.url or os.getenv("DESKTOP_QR_URL")
if not url or url == "" then
	url = ("http://%s:8080/"):format(first_ipv4() or "127.0.0.1")
end

local m = encode(url, opt.level)

if opt.ascii then
	for y = 0, m.width - 1 do
		local row = {}
		for x = 0, m.width - 1 do
			row[x + 1] = is_black(m, x, y) and "##" or "  "
		end
		print(table.concat(row))
	end
	return
end

local out = opt.out
if not out then
	-- <script dir>/../assets/icons/qr.png
	local dir = (arg[0] or ""):match("^(.*)/") or "."
	out = dir .. "/../assets/icons/qr.png"
end

local png = png_bytes(m, opt.scale, opt.margin)
local f = assert(io.open(out, "wb"))
f:write(png)
f:close()

local side = (m.width + opt.margin * 2) * opt.scale
print(("qr.png <- %s  (%dx%d, ver %d, %d bytes)"):format(url, side, side, m.ver, #png))
