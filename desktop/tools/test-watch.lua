-- 仓内自测：看门狗的三条路（上屏 / FAIL / 超时）都不需要真起播放器
package.path = "./?.lua;" .. package.path
local launcher = require("core.launcher")

local LOG = "/tmp/fake-play.log"

local function cfg(ms)
	return {
		play_log = LOG, launch_log = "/tmp/fake-launch.log",
		play_onscreen_ms = ms,
		reader_script = "", reader_cmd = "/nonexistent",
	}
end

local function stub()
	return {
		screen = { suspend = function() end, resume = function() return true end,
			sdl = { present = function() end } },
		chrome = { toast = function() end },
	}
end

local function fake(script) return ("sh -c %q"):format(script) end

local function run(name, script, ms, pre)
	os.remove(LOG)
	local f = io.open(LOG, "w")

	if f then if pre then f:write(pre) end; f:close() end
	local s = stub()
	local l = launcher.new(cfg(ms), s.screen, s.chrome)
	local t0 = os.time()
	local ok, err = l:run(name, fake(script), {
		watch = {
			log = LOG, pat = "RENDER: %a[%w_]* %(caps",
			fail = "\n(FAIL [^\n]*)", ms = ms,
		},
	})
	print(("%-8s ok=%-5s %.0fs  %s"):format(name, tostring(ok),
		os.time() - t0, tostring(err or "")))
end

-- 注意：真机上 play.sh 自己往 play_log 写，launch_log 只装包装脚本的输出，
-- 所以这里让假脚本自己 >> $LOG，别指望重定向。
local W = ">>" .. LOG

-- 1) 正常上屏：4 秒后才出 RENDER，宽限 8 秒 → 不该被杀，正常退出
run("上屏", "sleep 1; echo aout: x " .. W .. "; echo 'RENDER: miyoo (caps 1920x1080)' " .. W
	.. "; sleep 3", 8000)
-- 2) 播放器判死：日志里出现 FAIL → 立刻收，不等宽限
run("FAIL", "sleep 1; echo 'FAIL stream 空: Success' " .. W .. "; sleep 30", 30000)
-- 3) 一直没上屏也没 FAIL → 宽限到点收掉
run("超时", "sleep 30", 2000)
-- 4) 旧日志里残留的 FAIL/RENDER 不能算这一次的
run("旧FAIL", "sleep 30", 2000, "起播前旧内容\nFAIL 上一次的死局\nRENDER: miyoo (caps 旧)\n")
