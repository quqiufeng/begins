-- core/peer.lua — 客户端：向别的进程的自动化口问一句话
--
-- desktop 自己是「服务端」（core/automation.lua），但 agent 只有一扇门时，
-- 它得能替 agent 去问外面的 reader / 播放器：
--   reader  /tmp/native-reader-automation.sock  一行 JSON 请求 → 一行 JSON 应答
--   player  /tmp/play.sock                      一行文本命令（status/pos/…）→ 一行 JSON
--
-- 关键约束：桌面主循环是 30fps 的，这里绝不能出现「对端没应答就卡死画面」。
-- 所以 connect/send/recv 全部非阻塞 + poll 带截止时间，超时就返回 nil, "timeout"。

local ffi = require("ffi")
local bit = require("bit")
local json = require("util.json")

pcall(ffi.cdef, [[
typedef struct { int fd; short events; short revents; } peer_pollfd;
typedef struct {
	unsigned short sun_family;
	char sun_path[108];
} peer_sockaddr_un;

int socket(int domain, int type, int protocol);
int connect(int fd, const void *addr, unsigned int len);
long send(int fd, const void *buf, size_t len, int flags);
long recv(int fd, void *buf, size_t len, int flags);
int close(int fd);
int shutdown(int fd, int how);
int fcntl(int fd, int cmd, int arg);
int poll(void *fds, unsigned long nfds, int timeout);
int kill(int pid, int sig);
int usleep(unsigned int usec);
int getsockopt(int fd, int level, int optname, void *optval, unsigned int *optlen);
typedef struct { long tv_sec; long tv_nsec; } peer_timespec;
int clock_gettime(int clk, void *tp);
]])

local C = ffi.C
local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL, F_SETFD, FD_CLOEXEC = 3, 4, 2, 1
local O_NONBLOCK = 0x800
local POLLIN, POLLOUT, POLLERR, POLLHUP = 1, 4, 8, 0x10
local MSG_NOSIGNAL = 0x4000
local BUF = 65536
-- clock_gettime(CLOCK_MONOTONIC)：os.clock() 是 CPU 时间，poll 阻塞期间不走，
-- 渲染吃 CPU 时又跑得飞快，用它算截止时间两头都是错的。
local CLOCK_MONOTONIC = 1
local SOL_SOCKET, SO_ERROR = 1, 4
local EINTR, EAGAIN, EINPROGRESS = 4, 11, 115

local M = {}

local TS = ffi.new("peer_timespec[1]")

local function now_ms()
	C.clock_gettime(CLOCK_MONOTONIC, TS)
	return tonumber(TS[0].tv_sec) * 1000 + tonumber(TS[0].tv_nsec) / 1e6
end

-- unix socket 路径在手：不用再 access()，直接连。ENOENT/ECONNREFUSED 就是「不在」。
local ABSENT = { [2] = true, [111] = true }

-- 单调时钟毫秒（外部模块算 TTL/截止时间用，别用 os.time 的秒粒度）
M.now_ms = now_ms

-- pid 还活着？（launcher 那边用的是同一招：kill(pid, 0)）
-- EPERM = 进程在、只是不归我们管，别当成死
function M.alive(pid)
	pid = tonumber(pid)

	if not pid or pid <= 0 then return false end
	if C.kill(pid, 0) == 0 then return true end
	return ffi.errno() == 1
end

local function wait_fd(fd, events, deadline)
	local pfd = ffi.new("peer_pollfd[1]")

	pfd[0].fd, pfd[0].events, pfd[0].revents = fd, events, 0
	while true do
		local left = deadline - now_ms()

		if left <= 0 then return nil, "timeout" end
		pfd[0].revents = 0
		local n = C.poll(pfd, 1, math.floor(left + 0.5))

		if n < 0 then
			if ffi.errno() == EINTR then goto continue end
			return nil, "poll failed"
		end
		if n == 0 then return nil, "timeout" end
		if pfd[0].revents ~= 0 then return true end
		::continue::
	end
end

-- 连接一个 unix socket，返回 fd（非阻塞、CLOEXEC）
local function connect_to(path, timeout_ms)
	local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)

	if fd < 0 then return nil, "socket failed" end
	C.fcntl(fd, F_SETFL, bit.bor(C.fcntl(fd, F_GETFL, 0), O_NONBLOCK))
	C.fcntl(fd, F_SETFD, FD_CLOEXEC)

	local sa = ffi.new("peer_sockaddr_un")

	sa.sun_family = AF_UNIX
	ffi.fill(sa.sun_path, 108, 0)
	ffi.copy(sa.sun_path, path)

	local deadline = now_ms() + timeout_ms
	local rc = C.connect(fd, sa, ffi.sizeof(sa))

	if rc ~= 0 then
		local e = ffi.errno()

		-- EINPROGRESS：非阻塞 connect 还没结果，等可写；EINTR 同理再等一次
		if e ~= EINPROGRESS and e ~= EINTR then
			C.close(fd)
			if ABSENT[e] then return nil, "absent" end
			return nil, ("connect %s: errno %d"):format(path, e)
		end
		local ok, werr = wait_fd(fd, POLLOUT, deadline)

		if not ok then C.close(fd); return nil, "connect " .. tostring(werr) end
		-- 可写≠连上：结果在 SO_ERROR 里（EALREADY/ECONNREFUSED/ECONNRESET…）
		local soerr, olen = ffi.new("int[1]"), ffi.new("unsigned int[1]", 4)

		if C.getsockopt(fd, SOL_SOCKET, SO_ERROR, soerr, olen) ~= 0 then
			local ge = ffi.errno()

			C.close(fd)
			if ABSENT[ge] then return nil, "absent" end
			return nil, ("connect %s: errno %d"):format(path, ge)
		end
		if soerr[0] ~= 0 then
			C.close(fd)
			if ABSENT[soerr[0]] then return nil, "absent" end
			return nil, ("connect %s: errno %d"):format(path, soerr[0])
		end
	end
	return fd, deadline
end

-- 发一行、读到 EOF，返回原始应答（字符串）。timeout_ms 是总预算。
local function roundtrip(path, line, timeout_ms)
	local fd, deadline = connect_to(path, timeout_ms)

	if not fd then return nil, deadline end
	local p, left = ffi.cast("const char*", line), #line

	while left > 0 do
		local w = C.send(fd, p, left, MSG_NOSIGNAL)

		if w <= 0 then
			local e = ffi.errno()

			-- 非阻塞口可能一时塞满；EINTR 就当没发生，别把一条能发的请求判死
			if e == EAGAIN then
				local ok, werr = wait_fd(fd, POLLOUT, deadline)

				if not ok then
					C.close(fd)
					return nil, werr or "send timeout"
				end
				goto continue
			elseif e == EINTR then
				goto continue
			end
			C.close(fd)
			return nil, "send failed"
		end
		p = p + tonumber(w)
		left = left - tonumber(w)
		::continue::
	end
	-- 半关：服务端读到 EOF 就收尾（reader 的读循环靠这个判断一条请求结束）
	C.shutdown(fd, 1)

	local out, buf = {}, ffi.new("char[?]", BUF)

	while true do
		local ok, werr = wait_fd(fd, POLLIN, deadline)

		if not ok and #out == 0 then
			C.close(fd)
			return nil, werr or "no reply"
		end
		if not ok then break end
		local n = C.recv(fd, buf, BUF, 0)

		if n < 0 then
			local e = ffi.errno()

			if e == EINTR or e == EAGAIN then goto next end
			break
		end
		if n == 0 then break end
		out[#out + 1] = ffi.string(buf, n)
		if #out > 64 then break end
		::next::
	end
	C.close(fd)
	local s = table.concat(out)

	if s == "" then return nil, "empty reply" end
	return s
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- JSON 协议（desktop / reader）：发一张表，收回解码后的表
function M.req(path, tbl, timeout_ms)
	local line = type(tbl) == "string" and tbl or json.encode(tbl)

	line = trim(line) .. "\n"
	local raw, err = roundtrip(path, line, timeout_ms or 500)

	if not raw then return nil, err end
	-- 只取第一行（服务端一行一应答，多余的是它自己的日志误入）
	raw = trim(raw:match("^[^\n]*") or raw)
	local v = json.decode(raw)

	if not v then return nil, "bad json: " .. raw:sub(1, 120) end
	return v
end

-- 文本协议（播放器控制口）：发一条命令，回一行 JSON
function M.text(path, cmd, timeout_ms)
	local raw, err = roundtrip(path, trim(cmd) .. "\n", timeout_ms or 300)

	if not raw then return nil, err end
	raw = trim(raw:match("^[^\n]*") or raw)
	return json.decode(raw) or nil, raw
end

-- socket 在不在（不 connect）：access(2) 一个路径，0 = F_OK
pcall(ffi.cdef, "int access(const char *path, int mode);")

function M.present(path)
	local ok, rc = pcall(function() return C.access(path, 0) end)

	return ok and rc == 0
end

return M
