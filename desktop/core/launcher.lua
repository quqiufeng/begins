-- core/launcher.lua — 按文件类型开 app（电子书 → reader，影音 → player）
--
-- 桌面自己就是 SDL 全屏的唯一持有者，所以套路固定：
--   screen:suspend()  →  跑外部命令（前台阻塞）  →  screen:resume()
-- 外部命令一律 </dev/null 并从 /tmp/desktop-launch.log 里留痕，出事可查。
--
-- 命令模板可用环境变量覆盖，方便开发机上用假命令验证流程：
--   DESKTOP_READER_CMD=/opt/reader/build/native-reader
--   DESKTOP_PLAY_CMD=/root/play.sh
--   DESKTOP_READER_SCRIPT="luajit /opt/reader/main.lua %s"   （%s = 文件路径）

local dav = require("core.dav")

local M = {}
M.__index = M

local function shq(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

M.shq = shq

function M.new(cfg, screen, chrome)
	return setmetatable({ cfg = cfg, screen = screen, chrome = chrome }, M)
end

local function apply_template(tpl, path)
	return (tpl:gsub("%%s", function() return shq(path) end))
end

function M:has_reader()
	local cfg = self.cfg

	if cfg.reader_script ~= "" then return true end
	local f = io.open(cfg.reader_cmd, "r")

	if f then f:close(); return true end
	return false
end

function M:has_player()
	local cfg = self.cfg

	if cfg.play_script ~= "" then return true end
	local f = io.open(cfg.play_cmd, "r")

	if f then f:close(); return true end
	return false
end

-- 外部命令一律 setsid 起在独立会话里：进程组独立，失败时能整组收掉。
-- 顺带拿到 pid，才能在等的时候做「到底上屏了没」看门狗 —— play.sh 碰到
-- 盒子硬解不认的编码（H.264）会卡在等播放器退出，前台阻塞就成了桌面假死。
local ffi = require("ffi")

pcall(ffi.cdef, [[
	int kill(int pid, int sig);
	int usleep(unsigned int usec);
]])

local SIGTERM, SIGKILL = 15, 9

local function alive(pid)
	return ffi.C.kill(pid, 0) == 0
end

-- 读日志尾部（上限 64KB）。不看 offset：play.sh 每次开播都会截断重写，
-- 新内容长度常和老内容几乎一样，按 offset 增量读会正好漏掉末尾那几行判据。
-- 日志本身只有几 KB，每 200ms 整读一遍最省心。
local function scan_log(path)
	local f = io.open(path, "rb")

	if not f then return "" end
	local size = f:seek("end") or 0
	local start = size > 65536 and size - 65536 or 0

	f:seek("set", start)
	local s = f:read("*a") or ""

	f:close()
	return s
end

local function group_kill(pid)
	ffi.C.kill(-pid, SIGTERM)
	for _ = 1, 10 do
		ffi.C.usleep(50000)
		if not alive(pid) then return true end
	end
	ffi.C.kill(-pid, SIGKILL)
	ffi.C.usleep(200000)
	return not alive(pid)
end

-- 收掉正在独占屏幕的外部 app（播放中按「返回」= 退出播放）。
-- 只在 M:run 的等待期内有意义：pid 不在就返回 false，让调用方照常回 busy。
function M:stop()
	local pid = self.pid

	if not pid or self.stopped or not alive(pid) then return false end
	self.stopped = true
	-- 进程组整组收：play.sh 的 trap 会跑 do_stop（放回 fbcon、清 state），
	-- 真卡死了 group_kill 自己会升级到 SIGKILL。
	group_kill(pid)
	return true
end

-- 有个外部 app 正在独占屏幕？（pump 里用来判"返回"该不该收掉它）
function M:busy()
	return self.pid ~= nil
end

-- opts.watch = { log, pat = 上屏判据, fail = 失败判据, ms = 宽限毫秒 }
-- 给了 watch 就边等边看：日志出现 fail 立刻收掉，宽限期内没出现 pat 也收掉。
function M:run(label, cmd, opts)
	local cfg, screen = self.cfg, self.screen

	opts = opts or {}
	self.chrome:toast("启动 " .. label .. " …（退出后自动回桌面）", 4)
	if screen.ren then screen.sdl.present(screen.ren) end
	screen:suspend()

	local rcfile = cfg.launch_log .. ".rc"
	local watch = opts.watch
	-- 起播前的日志基线：这条日志是复用的（play.sh 未必清空），
	-- 上一次的 FAIL/RENDER 行不能算这一次的，所以先记下旧内容，扫描时剥掉。
	local baseline = watch and watch.log and scan_log(watch.log) or ""
	-- rcfile 里落退出码：setsid 之后 shell 不再是我们等的那个子进程
	os.remove(rcfile)
	local full = ("setsid sh -c %s </dev/null >>%s 2>&1 & echo $!"):format(
		shq(cmd .. "; echo $? >" .. shq(rcfile)), shq(cfg.launch_log))
	local h = io.popen(full)
	local pid = h and tonumber(h:read("*l") or "") or nil

	if h then h:close() end

	local err, killed, why

	-- 外部 app 跑着的时候，"返回"只有一个含义：收掉它回桌面。
	-- 遥控器（keybd/自动化口）在 pump 里调 M:stop()，这里置 stopped，
	-- 等待循环随即结束，退出码/看门狗都不再当错误报。
	self.pid, self.stopped = pid, nil

	local t0 = os.time()

	if pid then
		local waited, grace = 0, math.floor((watch and watch.ms or 0) / 200)
		local onscreen = not watch  -- 没给看门狗就当已上屏

		while alive(pid) do
			-- 外部 app 独占屏幕期间桌面主循环是停的，但遥控器（keybd）还在每 800ms
			-- ping 一次。这里不伺候它，accept 队列一满，所有按键判定都会掉到兜底
			-- shell 上——表现就是"播放中按键全没反应"。所以边等边 pump 自动化口。
			if self.pump then pcall(self.pump) end
			if not onscreen then
				local s = scan_log(watch.log)

				if baseline ~= "" and s:sub(1, #baseline) == baseline then
					s = s:sub(#baseline + 1)
				end

				local bad = watch.fail and ("\n" .. s):match(watch.fail)

				if bad then
					group_kill(pid)
					killed, why = true, bad
					break
				end
				if s:find(watch.pat) then
					onscreen = true
				else
					waited = waited + 1
					if waited > grace then
						group_kill(pid)
						killed = true
						break
					end
				end
			end
			ffi.C.usleep(200000)
		end
	else
		-- 连 pid 都拿不到（setsid/io.popen 出事）就退回老路
		err = ("无法启动：%s"):format(cmd)
	end

	local ok, rerr = screen:resume()
	local stopped = self.stopped

	self.pid, self.stopped = nil, nil
	do
		local lf = io.open(cfg.launch_log, "a")

		if lf then
			lf:write(("[%s] %s pid=%s %s %.0fs\n"):format(
				os.date("%H:%M:%S"), label, tostring(pid),
				stopped and "stopped:user"
					or killed and ("killed:" .. tostring(why or "no-onscreen"))
					or "exit",
				os.time() - t0))
			lf:close()
		end
	end

	if not ok then return false, "恢复桌面失败：" .. tostring(rerr) end
	-- 用户按「返回」主动收掉的：算正常退出，别报成启动失败/退出码非 0
	if stopped then return true end
	if err then return false, err end
	if killed then
		if why then
			return false, ("%s 启动失败：%s（已收掉，看 %s）")
				:format(label, why, watch.log or cfg.launch_log)
		end
		return false, ("%s 没能上屏（%.0fs 内日志没有上屏判据，已收掉）— 看 %s")
			:format(label, (watch.ms or 0) / 1000, watch.log or cfg.launch_log)
	end
	local code = 0
	local f = io.open(rcfile, "r")

	if f then code = tonumber(f:read("*l") or "") or 0; f:close() end
	if code ~= 0 then
		return false, ("%s 退出码 %s（日志 %s）"):format(label, tostring(code),
			cfg.launch_log)
	end
	return true
end

-- NAS 上的文件不能直接给 reader/预览器（它们只认本地路径）：
-- 先按需下到缓存（同大小直接复用），返回本地路径。
function M:stage(item)
	local cfg = self.cfg

	if not dav.is_dav(item.path) then return item.path end
	local dest = dav.cache_path(cfg, item.path)

	self.chrome:toast(("从 NAS 取 %s …"):format(item.name), 3)
	if self.screen and self.screen.ren then self.screen.sdl.present(self.screen.ren) end
	local p, err = dav.download(cfg, item.path, dest)

	if not p then return nil, "NAS 下载失败：" .. tostring(err) end
	return p
end

function M:open_ebook(item)
	local cfg = self.cfg
	local cmd

	item = { path = self:stage(item) or item.path, name = item.name }
	if cfg.reader_script ~= "" then
		cmd = apply_template(cfg.reader_script, item.path)
	else
		-- reader（src/main.c）用相对路径 dofile("lua/ui/app.lua")，
		-- 所以必须先 cd 到它的根目录，否则从桌面目录启动必然找不到脚本。
		local root = cfg.reader_root or "/opt/reader"

		cmd = ("cd %s && READER_ROOT=%s %s %s"):format(shq(root), shq(root),
			shq(cfg.reader_cmd), shq(item.path))
	end
	return self:run("阅读器", cmd)
end

function M:open_media(item)
	local cfg = self.cfg
	local cmd
	-- 影音不用下载：play.sh 认 dav:// 地址，认证自己从 .env 补，边播边取
	local arg = item.path

	if dav.is_dav(item.path) and dav.conf(cfg) then
		arg = dav.play_arg(cfg.nas, item.path)
	end

	if cfg.play_script ~= "" then
		cmd = apply_template(cfg.play_script, arg)
	else
		cmd = ("%s %s"):format(shq(cfg.play_cmd), shq(arg))
	end
	-- 播放器要看「上屏判据」：play.sh 只认 RENDER:/PLAY: 两行，别靠屏幕亮没亮。
	-- 播放器起不来（片源/供流/参数任何一处挂掉）会让 play.sh 卡在等播放器退出，
	-- 没有看门狗时桌面就是全程假死。注意别把这归给「编码不支持」：H.264 硬解是通的
	-- （2026-11-19 实测 1080p 29.4fps），黑屏多是 spawn argv 被截断/空流。
	return self:run("播放器", cmd, {
		watch = {
			log = cfg.play_log,
			pat = "RENDER: %a[%w_]* %(caps", -- 不锚行首：RENDER 行前面还有 aout/AUDIO
			fail = "\n(FAIL [^\n]*)",  -- 播放器判的死局，立刻收
			ms = cfg.play_onscreen_ms,
		},
	})
end

-- 统一入口：返回 "into"（进目录）| "opened" | nil, err
function M:open(fs, preview, item)
	item = item or fs:current()

	if not item then return nil, "没有选中项" end
	if item.dir then
		local ok, err = fs:enter()

		if not ok then return nil, err end
		return "into"
	end
	local kind = item.kind

	if kind == "ebook" then
		if not self:has_reader() then
			return nil, "没找到阅读器：" .. tostring(self.cfg.reader_cmd)
		end
		return self:open_ebook(item) and "opened", nil
	elseif kind == "video" or kind == "audio" then
		if not self:has_player() then
			return nil, "没找到播放器：" .. tostring(self.cfg.play_cmd)
		end
		return self:open_media(item) and "opened", nil
	elseif kind == "image" then
		-- 播放列表里是 NAS 上的 dav 路径，解码器只认本地文件：
		-- 把 stage 注入预览器，翻到哪张就下哪张（同大小复用缓存）。
		preview.stage = function(it) return self:stage(it) end
		local ok, err = preview:show(fs, item.path)

		if not ok then return nil, err end
		return "opened"
	end
	return nil, ("不知道怎么打开：%s"):format(item.name)
end

return M
