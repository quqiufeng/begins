-- tools/gen-keynames.lua — 从 linux/input-event-codes.h 生成 keybord/keynames.lua
--
--   luajit tools/gen-keynames.lua > keynames.lua
--   luajit tools/gen-keynames.lua --check          # 只校验现有表有没有漏码/坏码
--   luajit tools/gen-keynames.lua <其它头文件路径>
--
-- 老表是手搓的，漏了 126 个码（KEY_BACK=158 / KEY_MENU=139 / KEY_INFO=358 /
-- KEY_EXIT=174 …）——遥控器的「返回」发的正是 158，漏掉就等于返回键失灵。
-- 这里一次全量生成：按码值排序，保留 [0]=RESERVED，方便肉眼对。
local HDR = "/usr/include/linux/input-event-codes.h"

local args, check, path = {}, false, nil

for i = 1, #arg do
	local a = arg[i]

	if a == "--check" then check = true
	elseif a:match("^%-") then io.stderr:write("未知参数: " .. a .. "\n") os.exit(2)
	else path = a end
	args[#args + 1] = a
end
path = path or HDR

local fh = io.open(path, "r")

if not fh then io.stderr:write(("读不到 %s\n"):format(path)) os.exit(1) end

-- KEY_FOO 0x160 /* ... */  /  KEY_FOO 352
-- 注意 Lua 模式没有 | 交替，十六进制/十进制要分开判
local pat = "^#define%s+KEY_([%w_]+)%s+([%w]+)"
local codes, dup = {}, 0

for line in fh:lines() do
	local name, val = line:match(pat)

	if name and (val:match("^0[xX]%x+$") or val:match("^%d+$")) then
		local v = tonumber(val)

		if v and v > 0 and v <= 0x2FF then
			if codes[v] and codes[v] ~= name then dup = dup + 1 end
			codes[v] = codes[v] or name   -- 同码多别名，取头文件里第一个
		end
	end
end
fh:close()

local n = 0

for _ in pairs(codes) do n = n + 1 end
if n == 0 then io.stderr:write(("没从 %s 解析出任何 KEY_ 码\n"):format(path)) os.exit(1) end

-- --check：对着已存在的 keynames.lua 比一遍
if check then
	local have, bad = {}, 0
	local cur = loadfile("keynames.lua")

	if not cur then io.stderr:write("keynames.lua 载入失败\n") os.exit(1) end
	have = cur() or {}
	for v, name in pairs(codes) do
		if have[v] ~= name then
			bad = bad + 1
			if bad <= 20 then
				io.stderr:write(("  缺/错 [%d] = %s（现有 %s）\n"):format(v, name, tostring(have[v])))
			end
		end
	end
	if bad == 0 then print(("OK  %d 个码全部对上"):format(n)) os.exit(0) end
	io.stderr:write(("FAIL  %d/%d 个码不一致（重跑不带 --check 重新生成）\n"):format(bad, n))
	os.exit(1)
end

local out = {}

local function w(s) out[#out + 1] = s end

w("-- keynames.lua — 由 tools/gen-keynames.lua 从 linux/input-event-codes.h 生成，勿手改")
w("-- KEY_ 码 → 名字（含 0x18e~ 那批遥控彩键）")
w("return {")
w('  [0]="RESERVED",')
local vs = {}

for v in pairs(codes) do vs[#vs + 1] = v end
table.sort(vs)
for _, v in ipairs(vs) do w(('  [%d]="%s",'):format(v, codes[v])) end
w("}")
print(table.concat(out, "\n"))

if dup > 0 then io.stderr:write(("注意：%d 个码有多别名，取了第一个\n"):format(dup)) end
