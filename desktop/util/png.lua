-- util/png.lua — 写 PNG（libz 做 deflate + crc32，零外部进程）
--
-- 只支持 8bit RGBA（color type 6），正好是 SDL_PIXELFORMAT_ABGR8888 在
-- 小端机上的字节序 R,G,B,A。用于 app.capture 落盘给自动化读图。
--
--   local png = require("util.png")
--   png.save("/tmp/a.png", w, h, buf[, stride])

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
int compress2(unsigned char *dest, unsigned long *destLen,
              const unsigned char *source, unsigned long sourceLen, int level);
unsigned long compressBound(unsigned long sourceLen);
unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);
]]

local z = ffi.load("z")
local band, rshift = bit.band, bit.rshift
local M = {}

local SIG = "\137PNG\r\n\26\n"
local CRC_T = {}
for i = 0, 255 do
	local c = i

	for _ = 1, 8 do
		if band(c, 1) == 1 then c = bit.bxor(0xEDB88320, rshift(c, 1))
		else c = rshift(c, 1) end
	end
	CRC_T[i] = c
end

local function crc_lua(s)
	local c = 0xFFFFFFFF

	for i = 1, #s do
		c = bit.bxor(CRC_T[band(bit.bxor(c, s:byte(i)), 0xFF)], rshift(c, 8))
	end
	return bit.bxor(c, 0xFFFFFFFF)
end

-- 整块数据走 libz 的 crc32（3.7MB 的 720p 帧纯 Lua 太慢）
local function crc(s)
	if #s == 0 then return 0 end
	local ok, r = pcall(function()
		return tonumber(z.crc32(0, ffi.cast("const unsigned char*", s), #s))
	end)

	if ok and r then return r end
	return crc_lua(s)
end

local function u32(n)
	return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255),
		band(rshift(n, 8), 255), band(n, 255))
end

local function chunk(kind, data)
	local body = kind .. data

	return u32(#data) .. body .. u32(crc(body))
end

-- pixels: 8bit RGBA，行距 stride（默认 w*4）
function M.encode(w, h, pixels, stride)
	stride = stride or (w * 4)
	local raw = ffi.new("uint8_t[?]", h * (stride + 1))
	local src = ffi.cast("const uint8_t*", pixels)

	for y = 0, h - 1 do
		local o = y * (stride + 1)

		raw[o] = 0   -- filter: none
		ffi.copy(raw + o + 1, src + y * stride, stride)
	end
	local n = h * (stride + 1)
	local bound = tonumber(z.compressBound(n))
	local dst = ffi.new("uint8_t[?]", bound)
	local dlen = ffi.new("unsigned long[1]", bound)
	local rc = z.compress2(dst, dlen, raw, n, 6)

	if rc ~= 0 then return nil, "compress2 failed: " .. tostring(rc) end

	local ihdr = u32(w) .. u32(h) .. string.char(8, 6, 0, 0, 0)
	local idat = ffi.string(dst, tonumber(dlen[0]))

	return SIG .. chunk("IHDR", ihdr) .. chunk("IDAT", idat) .. chunk("IEND", "")
end

function M.save(path, w, h, pixels, stride)
	local data, err = M.encode(w, h, pixels, stride)

	if not data then return false, err end
	local f = io.open(path, "wb")

	if not f then return false, "open failed: " .. path end
	f:write(data)
	f:close()
	return true
end

return M
