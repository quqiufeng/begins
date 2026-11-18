-- util/json.lua — 够用的 JSON（encode + decode）
--
-- automation 口的请求是嵌套对象（{"cmd":"call","fn":"…","args":{"path":"…"}}），
-- reader 里那套「正则抓字段」只够平铺，这里写成真解析器，省得以后加参数又卡住。
-- 约定：decode 的数组 = 从 1 开始的 table + n 字段；空对象/空数组都给 {}。

local M = {}

local ESC = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
	n = "\n", r = "\r", t = "\t",
}

local function jesc(s)
	s = tostring(s or "")
	s = s:gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' end
		if c == "\\" then return "\\\\" end
		if c == "\n" then return "\\n" end
		if c == "\r" then return "\\r" end
		if c == "\t" then return "\\t" end
		return ("\\u%04x"):format(c:byte())
	end)
	return s
end

local function is_array(t)
	local n = 0

	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	return n == #t and n > 0
end

function M.encode(v)
	local t = type(v)

	if v == nil then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v % 1 == 0 then return ("%d"):format(v) end
		return ("%.6f"):format(v):gsub("0+$", ""):gsub("%.$", "")
	end
	if t == "string" then return '"' .. jesc(v) .. '"' end
	if t == "table" then
		local out = {}

		if is_array(v) then
			for i = 1, #v do out[i] = M.encode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		for k, x in pairs(v) do
			out[#out + 1] = '"' .. jesc(k) .. '":' .. M.encode(x)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return "null"
end

-- ---------- decode ----------

local P

local function skip_ws()
	while true do
		local c = P.s:sub(P.i, P.i)

		if c == " " or c == "\t" or c == "\n" or c == "\r" then P.i = P.i + 1
		else return end
	end
end

local parse_value

local function parse_string()
	P.i = P.i + 1        -- 跳过开引号
	local out = {}

	while true do
		local c = P.s:sub(P.i, P.i)

		if c == "" then error("json: unterminated string") end
		if c == '"' then P.i = P.i + 1; break end
		if c == "\\" then
			local e = P.s:sub(P.i + 1, P.i + 1)
			local u = P.s:sub(P.i + 2, P.i + 5)

			if e == "u" and #u == 4 then
				local cp = tonumber(u, 16) or 63

				-- 代理对
				if cp >= 0xD800 and cp <= 0xDBFF then
					local lo = P.s:match("^\\u(%x%x%x%x)", P.i + 6)

					if lo then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(lo, 16) - 0xDC00)
						P.i = P.i + 6
					end
				end
				if cp < 0x80 then out[#out + 1] = string.char(cp)
				elseif cp < 0x800 then
					out[#out + 1] = string.char(0xC0 + math.floor(cp / 64),
						0x80 + cp % 64)
				elseif cp < 0x10000 then
					out[#out + 1] = string.char(0xE0 + math.floor(cp / 4096),
						0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
				else
					out[#out + 1] = string.char(0xF0 + math.floor(cp / 262144),
						0x80 + math.floor(cp / 4096) % 64,
						0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
				end
				P.i = P.i + 6
			else
				out[#out + 1] = ESC[e] or e
				P.i = P.i + 2
			end
		else
			local run = P.s:match('^[^"\\]+', P.i)

			out[#out + 1] = run
			P.i = P.i + #run
		end
	end
	return table.concat(out)
end

local function parse_number()
	local num = P.s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", P.i)

	if not num or num == "" then error("json: bad number") end
	P.i = P.i + #num
	return tonumber(num)
end

function parse_value()
	skip_ws()
	local c = P.s:sub(P.i, P.i)

	if c == "{" then
		P.i = P.i + 1
		local obj = {}

		skip_ws()
		if P.s:sub(P.i, P.i) == "}" then P.i = P.i + 1; return obj end
		while true do
			skip_ws()
			local k = parse_string()

			skip_ws()
			if P.s:sub(P.i, P.i) ~= ":" then error("json: expected :") end
			P.i = P.i + 1
			obj[k] = parse_value()
			skip_ws()
			local d = P.s:sub(P.i, P.i)

			P.i = P.i + 1
			if d == "}" then break end
			if d ~= "," then error("json: expected , or }") end
		end
		return obj
	elseif c == "[" then
		P.i = P.i + 1
		local arr = { n = 0 }

		skip_ws()
		if P.s:sub(P.i, P.i) == "]" then P.i = P.i + 1; return arr end
		while true do
			local v = parse_value()

			arr.n = arr.n + 1
			arr[arr.n] = v
			skip_ws()
			local d = P.s:sub(P.i, P.i)

			P.i = P.i + 1
			if d == "]" then break end
			if d ~= "," then error("json: expected , or ]") end
		end
		return arr
	elseif c == '"' then
		return parse_string()
	elseif c == "t" then
		if P.s:sub(P.i, P.i + 3) == "true" then P.i = P.i + 4; return true end
		error("json: bad literal")
	elseif c == "f" then
		if P.s:sub(P.i, P.i + 4) == "false" then P.i = P.i + 5; return false end
		error("json: bad literal")
	elseif c == "n" then
		if P.s:sub(P.i, P.i + 3) == "null" then P.i = P.i + 4; return nil end
		error("json: bad literal")
	else
		return parse_number()
	end
end

function M.decode(s)
	if type(s) ~= "string" or s == "" then return nil, "empty" end
	P = { s = s, i = 1 }
	local ok, v = pcall(parse_value)

	P = nil
	if not ok then return nil, tostring(v) end
	return v
end

-- 顶层数组的真长度（decode 出来的表带 n 字段，也不影响 #）
function M.len(t)
	if type(t) ~= "table" then return 0 end
	return t.n or #t
end

return M
