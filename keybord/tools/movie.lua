#!/usr/bin/env luajit
-- tools/movie.lua — 命令行演示：lua 脚本直接控播放（libpctl.so / FFI）
--
--   luajit tools/movie.lua play /sata11/av/a.mkv     起播（走 play.sh，立即返回）
--   luajit tools/movie.lua play /sata11/av/a.mkv -r gl
--   luajit tools/movie.lua status | pos | pause | resume | toggle
--   luajit tools/movie.lua seek -30 | seek 300        相对秒
--   luajit tools/movie.lua vol +10 | vol 60 | mute
--   luajit tools/movie.lua stop
--
-- 实际就是 require("pctl") 的薄壳；写自己的脚本时照抄那几行就行。

package.path = (arg[0]:gsub("tools/[^/]*$", "?.lua;"))
	.. "/opt/keybord/?.lua;./?.lua;" .. package.path

local pctl = require("pctl")
local act = arg[1] or "status"
local a2 = arg[2]

local function num(s)
	return tonumber((s or ""):match("^%s*([-+]?%d+%.?%d*)"))
end

if not pctl.ffi then
	io.stderr:write("提示：没找到 libpctl.so，退回 socket 实现（功能一样，多一次连接）\n")
end

local ok, err

if act == "play" then
	if not a2 then io.stderr:write("用法：movie.lua play <片源> [play.sh 选项]\n"); os.exit(2) end
	local opts = table.concat(arg, " ", 3)
	ok, err = pctl.play(a2, opts)
	if not ok then io.stderr:write("起播失败：" .. tostring(err) .. "\n"); os.exit(1) end
	print("起播：" .. a2 .. (opts ~= "" and (" " .. opts) or ""))
elseif act == "status" then
	local s = pctl.status()
	if not s then io.stderr:write("没在放（" .. pctl.err() .. "）\n"); os.exit(1) end
	print(s)
elseif act == "pos" then
	local ms = pctl.pos()
	if not ms then io.stderr:write("取不到位置：" .. pctl.err() .. "\n"); os.exit(1) end
	print(("%.1f s"):format(ms / 1000))
elseif act == "pause" then
	ok, err = pctl.pause() or nil, pctl.err()
elseif act == "resume" then
	ok, err = pctl.resume() or nil, pctl.err()
elseif act == "toggle" then
	local p = pctl.toggle()
	ok = true
	print(p and "已暂停" or "继续播放")
elseif act == "seek" then
	local n = num(a2)
	if not n then io.stderr:write("用法：movie.lua seek <±秒>\n"); os.exit(2) end
	ok, err = pctl.seek(n)
	print(("seek %+d s"):format(n))
elseif act == "vol" then
	local n = num(a2)
	if not n then io.stderr:write("用法：movie.lua vol <±N|0..150>\n"); os.exit(2) end
	local v
	if (a2 or ""):find("^%s*[+-]") then v = pctl.vol(n) else v = pctl.set_vol(n) end
	if not v then io.stderr:write("调音量失败：" .. pctl.err() .. "\n"); os.exit(1) end
	print("音量 " .. v)
elseif act == "mute" then
	ok = true
	print(pctl.mute() and "静音" or "取消静音")
elseif act == "stop" then
	ok, err = pctl.quit()
	print("已停播")
else
	io.stderr:write("未知动作：" .. act .. "\n")
	os.exit(2)
end

if ok == false then
	io.stderr:write("失败：" .. tostring(err or pctl.err()) .. "\n")
	os.exit(1)
end
