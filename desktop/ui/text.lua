-- ui/text.lua — 文本排版小工具（UTF-8 安全）
--
-- 桌面上最难受的是文件名：中文 + 长英文混排，还得两行内放下并省略。
-- 这里只提供三件东西：
--   text.chars(s)                按 UTF-8 字符切
--   text.fit(s, size, maxw)      单行裁到 maxw，末尾加 …
--   text.wrap(s, size, maxw, n)  折成最多 n 行，最后一行裁到 maxw
-- 宽度一律走 TTF_SizeUTF8 的逐字测量并缓存（按字号），不做等宽假设。

local M = {}

local floor = math.floor
M.char_cache = {}

function M.chars(s)
	local out, i, n = {}, 1, #s

	while i <= n do
		local c = s:byte(i)
		local len = 1

		if c >= 0xF0 then len = 4
		elseif c >= 0xE0 then len = 3
		elseif c >= 0xC0 then len = 2 end
		out[#out + 1] = s:sub(i, i + len - 1)
		i = i + len
	end
	return out
end

function M.char_width(ttf, font_path, ch, size)
	local key = size .. "|" .. ch
	local c = M.char_cache[key]

	if c then return c end
	local w = ttf.width(font_path, ch, size)

	M.char_cache[key] = w
	return w
end

-- 单行裁剪
function M.fit(ttf, font_path, s, size, maxw)
	if not s or s == "" then return "" end
	local full = ttf.width(font_path, s, size)

	if full <= maxw then return s end
	local ell = "…"
	local ellw = ttf.width(font_path, ell, size)
	local budget = maxw - ellw
	local acc, out = 0, {}

	for _, ch in ipairs(M.chars(s)) do
		local w = M.char_width(ttf, font_path, ch, size)

		if acc + w > budget then break end
		acc = acc + w
		out[#out + 1] = ch
	end
	return table.concat(out) .. ell
end

-- 折行：返回 { 行1, 行2, ... }，最多 maxlines 行（最后一行裁到 maxw）
function M.wrap(ttf, font_path, s, size, maxw, maxlines)
	maxlines = maxlines or 2
	local chars = M.chars(s)
	local lines, cur, acc, i = {}, {}, 0, 1

	while i <= #chars do
		local ch = chars[i]
		local w = M.char_width(ttf, font_path, ch, size)

		if acc + w > maxw and #cur > 0 then
			lines[#lines + 1] = table.concat(cur)
			if #lines >= maxlines - 1 then
				-- 剩下的一股脑交给 fit 去裁，保证省略号在行尾
				lines[#lines + 1] = M.fit(ttf, font_path,
					table.concat(chars, "", i), size, maxw)
				return lines
			end
			cur, acc = {}, 0
		end
		cur[#cur + 1] = ch
		acc = acc + w
		i = i + 1
	end
	if #cur > 0 then lines[#lines + 1] = table.concat(cur) end
	if #lines > maxlines then lines = { unpack(lines, 1, maxlines) } end
	return lines
end

return M
