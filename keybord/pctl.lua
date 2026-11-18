-- pctl.lua — 播放器控制（LuaJIT FFI 直连 libpctl.so）
--
-- 以前控播放是两条路：fork `player -c <命令>`，或者自己拼 /tmp/play.sock
-- 的文本协议（sock.lua）。现在 hevcdec/pctl_ffi.c 编成 libpctl.so，
-- 一个 FFI 调用就到播放器，不 fork、不拼 shell：
--
--   local pctl = require("pctl")
--   if pctl.ok() then
--       pctl.seek(-30)                 -- 回退 30s
--       pctl.toggle()                  -- 暂停/继续
--       pctl.vol(10)                   -- 音量 +10
--       print(pctl.pos())              -- 位置毫秒
--   end
--   pctl.play("/sata11/av/a.mkv")      -- 起播（fork play.sh，立刻返回）
--
-- 找不到 .so 时自动退回 sock.lua（行为不变，只是多一次 fork/连接）。
-- 库路径：PCTL_LIB > /opt/keybord/libpctl.so > 脚本同目录 > cwd。

local M = {}

-- 注意别用 {nil, ...} + ipairs：首元素是 nil 时 ipairs 当场停住，
-- 后面的候选路径一个都不会试（这个坑踩过）。
local CANDIDATES = {}
for _, p in ipairs({
	os.getenv("PCTL_LIB") or "",
	"/opt/keybord/libpctl.so",
	"/root/libpctl-aarch64.so",
	"/root/libpctl.so",
	"libpctl.so",
}) do
	if p ~= "" then CANDIDATES[#CANDIDATES + 1] = p end
end

local ffi, lib

local function tryload()
	local ok, f = pcall(require, "ffi")

	if not ok then return nil end
	ffi = f
	pcall(ffi.cdef, [[
		const char *pctl_version(void);
		const char *pctl_err(void);
		const char *pctl_sock(void);
		const char *pctl_cmd(const char *cmd);
		const char *pctl_status(void);
		int pctl_set_sock(const char *path);
		int pctl_ping(void);
		int pctl_paused(void);
		int pctl_pos_ms(void);
		double pctl_pos_sec(void);
		int pctl_pause(void);
		int pctl_resume(void);
		int pctl_toggle(void);
		int pctl_mute(void);
		int pctl_vol(int delta);
		int pctl_set_vol(int v);
		int pctl_seek(int sec);
		int pctl_quit(void);
		int pctl_run(const char *args);
		int pctl_play(const char *src, const char *opts);
		int pctl_play_wait(const char *src, const char *opts, int wait_ms);
	]])
	for _, p in ipairs(CANDIDATES) do
		if p and p ~= "" then
			local ok2, l = pcall(ffi.load, p)

			if ok2 then return l end
		end
	end
	return nil
end

lib = tryload()

M.ffi = lib ~= nil
M.version = lib and ffi.string(lib.pctl_version()) or nil

-- 最近一次失败原因（.so 没有就在 lua 侧记）
local last_err = ""

local function err()
	if lib then
		local e = lib.pctl_err()

		if e ~= nil then last_err = ffi.string(e) end
	end
	return last_err
end

M.err = err
M.socket = function()
	if lib then return ffi.string(lib.pctl_sock()) end
	return os.getenv("PCTL_SOCK") or os.getenv("PLAY_SOCK") or "/tmp/play.sock"
end

-- 允许切口（多实例/测试）：pctl.bind("/tmp/other.sock")
function M.bind(path)
	if lib then return lib.pctl_set_sock(path) == 0 end
	os.setenv("PLAY_SOCK", path)
	return true
end

-- 播放器是否在跑（有应答即活）
function M.ok()
	if lib then return lib.pctl_ping() == 1 end
	local ok, r = require("sock").req(M.socket(), "status")

	return ok and r ~= nil
end

-- 原始命令：pctl.cmd("vol +5") → json 字符串 或 nil, err
function M.cmd(c)
	if lib then
		local r = lib.pctl_cmd(c)

		if r == nil then return nil, err() end
		return ffi.string(r)
	end
	local ok, r = require("sock").req(M.socket(), c)

	if not ok then last_err = r or "no reply"; return nil, last_err end
	return r
end

function M.status()
	local r = M.cmd("status")

	return r
end

-- 位置毫秒，失败 nil
function M.pos()
	if lib then
		local ms = lib.pctl_pos_ms()

		return ms >= 0 and ms or nil
	end
	local r = M.status()
	local ms = r and tonumber(r:match('"pos_ms"%s*:%s*(-?%d+)'))

	return ms and ms >= 0 and ms or nil
end

function M.paused()
	if lib then
		local p = lib.pctl_paused()

		return p >= 0 and p == 1 or false
	end
	local r = M.status()
	local p = r and tonumber(r:match('"paused"%s*:%s*(%d)'))

	return p and p == 1 or false
end

function M.pause()
	return lib and lib.pctl_pause() == 0 or (M.cmd("pause") and true or false)
end

function M.resume()
	return lib and lib.pctl_resume() == 0 or (M.cmd("resume") and true or false)
end

-- 切换，返回切换后是否暂停
function M.toggle()
	if lib then
		local p = lib.pctl_toggle()

		return p >= 0 and p == 1 or false
	end
	local r = M.cmd("toggle")

	return r and r:find('"paused":1') ~= nil or false
end

function M.mute()
	if lib then
		local m = lib.pctl_mute()

		return m >= 0 and m == 1 or false
	end
	local r = M.cmd("mute")

	return r and r:find('"mute":1') ~= nil or false
end

-- 相对音量，返回调整后的音量或 nil
function M.vol(d)
	if lib then
		local v = lib.pctl_vol(d)

		return v >= 0 and v or nil
	end
	local r = M.cmd("vol " .. (d >= 0 and "+" or "") .. d)

	return r and tonumber(r:match('"vol"%s*:%s*(%d+)')) or nil
end

function M.set_vol(v)
	if lib then
		local nv = lib.pctl_set_vol(v)

		return nv >= 0 and nv or nil
	end
	-- 没有 .so：绝对音量不能带 +/-（带了就是相对量）
	local r = M.cmd("vol " .. math.floor(v))

	return r and tonumber(r:match('"vol"%s*:%s*(%d+)')) or nil
end

-- 相对跳播（秒）
function M.seek(sec)
	if lib then return lib.pctl_seek(sec) == 0 end
	return M.cmd("seek " .. tostring(sec)) ~= nil
end

function M.quit()
	if lib then return lib.pctl_quit() == 0 end
	return M.cmd("quit") ~= nil
end

-- 起播：等价 play.sh play <src> [opts]；wait=true 时等 socket 起来
function M.play(src, opts, wait)
	if lib then
		if wait then
			if lib.pctl_play_wait(src, opts, 8000) == 0 then return true end
			return false, err()
		end
		if lib.pctl_play(src, opts) < 0 then return false, err() end
		return true
	end
	-- 没有 .so：退回 play.sh
	local cmd = ("%s play %q %s >/dev/null 2>&1 &"):format(
		os.getenv("PLAY_SH") or "/root/play.sh", src, opts or "")
	return os.execute(cmd) ~= nil
end

-- 任意 play.sh 子命令：pctl.run("key fwd")
function M.run(args)
	if lib then
		local pid = lib.pctl_run(args)

		if pid < 0 then return false, err() end
		return true, pid
	end
	return os.execute(("%s %s >/dev/null 2>&1 &"):format(
		os.getenv("PLAY_SH") or "/root/play.sh", args)) ~= nil
end

return M
