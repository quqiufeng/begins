-- ffi/gif.lua — 纯 Lua 的 GIF 首帧解码（只取第一帧，够做缩略图）
--
-- 系统里通常既没有 libSDL2_image 也没有 giflib，所以 GIF 自己解：
-- LZW 解码 + 调色板 → RGBA（逻辑画布大小，透明像素 alpha=0）。
-- 对外只有 decode(path) → (w, h, rgba_buffer)，失败一律 nil。

local bit = require("bit")
local ffi = require("ffi")

local byte, sub, char = string.byte, string.sub, string.char
local band, rshift, lshift = bit.band, bit.rshift, bit.lshift

local M = {}

-- 读子块链（0x00 结束），拼成一个字符串
local function read_subblocks(data, pos)
	local parts, n = {}, 0

	while true do
		local sz = byte(data, pos)

		if not sz or sz == 0 then
			pos = pos + 1
			break
		end
		parts[n + 1] = sub(data, pos + 1, pos + sz)
		n = n + 1
		pos = pos + sz + 1
	end
	return table.concat(parts), pos
end

-- LZW 解出调色板索引序列（每个像素一个字节，写进 out[0..count-1]）
local function lzw_decode(data, mcs, count, out)
	local clear = lshift(1, mcs)
	local eoi = clear + 1
	local prefix, suffix = {}, {}
	local next_code = eoi + 1
	local code_size = mcs + 1
	local i

	for i2 = 0, clear - 1 do
		suffix[i2] = i2
		prefix[i2] = -1
	end

	local pos, bitbuf, bitcnt = 1, 0, 0
	local len = #data
	local o, prev, firstc = 0, nil, 0
	local stack = {}

	local function read_code()
		while bitcnt < code_size do
			if pos > len then return nil end
			bitbuf = bitbuf + lshift(byte(data, pos), bitcnt)
			pos = pos + 1
			bitcnt = bitcnt + 8
		end
		local c = band(bitbuf, lshift(1, code_size) - 1)

		bitbuf = rshift(bitbuf, code_size)
		bitcnt = bitcnt - code_size
		return c
	end

	while o < count do
		local code = read_code()

		if code == nil then break end
		if code == clear then
			next_code, code_size = eoi + 1, mcs + 1
			prev = nil
		elseif code == eoi then
			break
		else
			local sp = 0

			if prev == nil then
				if code >= clear then break end
				firstc = code
				out[o] = code
				o = o + 1
				prev = code
			else
				local c

				if code < next_code then
					c = code
					-- 顺着前缀链回溯，再倒序写出
					while prefix[c] and prefix[c] >= 0 do
						sp = sp + 1
						stack[sp] = suffix[c]
						c = prefix[c]
					end
					sp = sp + 1
					stack[sp] = suffix[c]
					firstc = suffix[c]
				elseif code == next_code then
					-- KwKwK 特例：先按 prev 展开，再补上 prev 的首字节
					c = prev
					while prefix[c] and prefix[c] >= 0 do
						sp = sp + 1
						stack[sp] = suffix[c]
						c = prefix[c]
					end
					sp = sp + 1
					stack[sp] = suffix[c]
					firstc = suffix[c]
					sp = sp + 1
					stack[sp] = firstc
				else
					break
				end
				for k = sp, 1, -1 do
					if o < count then
						out[o] = stack[k]
						o = o + 1
					end
				end
				-- 新词条 = prev + 当前首字节
				if next_code < 4096 then
					prefix[next_code], suffix[next_code] = prev, firstc
					next_code = next_code + 1
					if next_code == lshift(1, code_size) and code_size < 12 then
						code_size = code_size + 1
					end
				end
				prev = code
			end
		end
	end
	return true
end

function M.decode(path)
	local f = io.open(path, "rb")

	if not f then return nil end
	local data = f:read("*a")

	f:close()
	if not data or #data < 14 then return nil end

	local sig = sub(data, 1, 6)

	if sig ~= "GIF87a" and sig ~= "GIF89a" then return nil end

	local sw = byte(data, 7) + byte(data, 8) * 256
	local sh = byte(data, 9) + byte(data, 10) * 256
	local packed = byte(data, 11)
	local bg = byte(data, 12)
	local pos = 14
	local gct = nil

	if band(packed, 0x80) ~= 0 then
		local n = 3 * lshift(1, band(packed, 0x07) + 1)

		gct = sub(data, pos, pos + n - 1)
		pos = pos + n
	end
	if sw <= 0 or sh <= 0 then return nil end

	local transparent = nil
	local frame = nil

	while pos <= #data do
		local b = byte(data, pos)

		pos = pos + 1
		if b == 0x3B then break end -- trailer
		if b == 0x21 then -- extension
			local label = byte(data, pos)

			pos = pos + 1
			if label == 0xF9 then -- graphic control：拿透明色索引
				local sz = byte(data, pos)
				local p2 = byte(data, pos + 1)

				if sz == 4 and band(p2, 0x01) ~= 0 then
					transparent = byte(data, pos + 4)
				end
			end
			pos = select(2, read_subblocks(data, pos))
		elseif b == 0x2C then -- image descriptor
			local left = byte(data, pos) + byte(data, pos + 1) * 256
			local top = byte(data, pos + 2) + byte(data, pos + 3) * 256
			local iw = byte(data, pos + 4) + byte(data, pos + 5) * 256
			local ih = byte(data, pos + 6) + byte(data, pos + 7) * 256
			local ip = byte(data, pos + 8)
			local p = pos + 9
			local ct = gct

			if band(ip, 0x80) ~= 0 then
				local n = 3 * lshift(1, band(ip, 0x07) + 1)

				ct = sub(data, p, p + n - 1)
				p = p + n
			end
			local mcs = byte(data, p)

			p = p + 1
			local lzw, npos = read_subblocks(data, p)

			pos = npos
			if ct and iw > 0 and ih > 0 and lzw and #lzw > 0 then
				frame = { left = left, top = top, w = iw, h = ih, ct = ct,
					mcs = mcs, lzw = lzw, interlace = band(ip, 0x40) ~= 0 }
			end
			break -- 只要首帧
		else
			break -- 不认识的块，放弃
		end
	end

	if not frame then return nil end

	-- 索引缓冲（按帧大小解，再贴到逻辑画布上）
	local idx = ffi.new("uint8_t[?]", frame.w * frame.h)
	local tmp = {}
	local ok = pcall(lzw_decode, frame.lzw, frame.mcs, frame.w * frame.h, tmp)

	if not ok then return nil end
	for i = 0, frame.w * frame.h - 1 do
		idx[i] = tmp[i] or 0
	end

	local ct = frame.ct
	local buf = ffi.new("uint8_t[?]", sw * sh * 4)
	local bgc = { 0, 0, 0 }

	if gct and bg * 3 + 1 <= #gct then
		bgc = { byte(gct, bg * 3 + 1), byte(gct, bg * 3 + 2), byte(gct, bg * 3 + 3) }
	end
	-- 背景先铺底色（GIF 的透明是"露出画布"，缩略图里铺成不透明更好看）
	local p4 = buf

	for i = 0, sw * sh - 1 do
		p4[i * 4], p4[i * 4 + 1], p4[i * 4 + 2], p4[i * 4 + 3] =
			bgc[1], bgc[2], bgc[3], 255
	end

	-- 隔行 GIF 的行序
	local function row_at(row)
		if not frame.interlace then return row end
		local pass, base = 1, 0
		local steps = { 8, 8, 4, 2 }
		local starts = { 0, 4, 2, 1 }

		for i = 1, 4 do
			local n = math.ceil((frame.h - starts[i]) / steps[i])

			if row < base + n then return starts[i] + (row - base) * steps[i] end
			base = base + n
			pass = pass + 1
		end
		return row
	end

	local blen = #ct

	for y = 0, frame.h - 1 do
		local sy = frame.top + row_at(y)
		local dy = sy * sw + frame.left

		if sy < sh then
			for x = 0, frame.w - 1 do
				local v = idx[y * frame.w + x]

				if v * 3 + 3 <= blen and (transparent == nil or v ~= transparent) then
					local q = (dy + x) * 4

					p4[q], p4[q + 1], p4[q + 2], p4[q + 3] =
						byte(ct, v * 3 + 1), byte(ct, v * 3 + 2), byte(ct, v * 3 + 3), 255
				end
			end
		end
	end
	return sw, sh, buf
end

return M
