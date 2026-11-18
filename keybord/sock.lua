-- sock.lua — unix socket 小工具（LuaJIT FFI，不依赖 socat/nc）
--
-- 盒子上两个控制口都是「连上→写一行→读回一行/到 EOF」：
--   /tmp/play.sock                    播放器 pctl：纯文本命令 status/pause/vol +5/seek 30
--   /tmp/native-reader-automation.sock 阅读器：{"cmd":"call","fn":"reader.next","args":{}}
--
--   local sock = require("sock")
--   local ok, reply = sock.req("/tmp/play.sock", "status")      -- 文本协议
--   local ok, json  = sock.req(url, '{"cmd":"state"}')          -- 同一条路
--   socket 不存在/拒绝连接 → ok=false, err（调用方据此判断 app 是否在跑）

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
struct kb_sockaddr_un { uint16_t sun_family; char sun_path[108]; };
struct kb_timeval { long tv_sec; long tv_usec; };
int socket(int domain, int type, int protocol);
int connect(int fd, const struct kb_sockaddr_un *addr, unsigned int len);
long write(int fd, const void *buf, unsigned long n);
long read(int fd, void *buf, unsigned long n);
int close(int fd);
int select(int nfds, void *rd, void *wr, void *ex, struct kb_timeval *tv);
int unlink(const char *path);
int bind(int fd, const struct kb_sockaddr_un *addr, unsigned int len);
int listen(int fd, int backlog);
int accept(int fd, void *addr, unsigned int *len);
int fcntl(int fd, int cmd, int arg);
int getsockopt(int fd, int level, int optname, void *optval, unsigned int *optlen);
int shutdown(int fd, int how);
]]

local C = ffi.C
local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 0x800
local SOL_SOCKET, SO_ERROR = 1, 4
local EINPROGRESS, ECONNREFUSED = 115, 111
local M = {}

local function addr(path)
	local sa = ffi.new("struct kb_sockaddr_un")

	sa.sun_family = AF_UNIX
	if #path > 107 then return nil, "path too long" end
	ffi.copy(sa.sun_path, path, #path + 1)
	return sa, 2 + 8 + #path + 1
end

-- 连一个 unix socket，返回 fd 或 nil, err
-- ms：连接超时。对端 accept 队列满了（桌面卡在打开视频里就是这种情况）时，
-- 阻塞式 connect 会一直挂着——keybd 主循环跟着冻死，全部按键失灵。所以默认
-- 走非阻塞 connect + select 等可写，超时就报错返回。
function M.connect(path, ms)
	local sa, len = addr(path)

	if not sa then return nil, len end
	local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)

	if fd < 0 then return nil, "socket() failed" end
	local fl = C.fcntl(fd, F_GETFL, 0)

	if fl >= 0 then C.fcntl(fd, F_SETFL, bit.bor(fl, O_NONBLOCK)) end
	if C.connect(fd, sa, len) ~= 0 then
		if ffi.errno() ~= EINPROGRESS then
			local e = ffi.errno()

			C.close(fd)
			return nil, "connect failed: " .. path .. (e == ECONNREFUSED and " (refused)" or "")
		end
		if not M.wait_w(fd, ms or 800) then
			C.close(fd)
			return nil, "connect timeout: " .. path
		end
		local so = ffi.new("int[1]")
		local sl = ffi.new("unsigned int[1]", 4)

		if C.getsockopt(fd, SOL_SOCKET, SO_ERROR, so, sl) ~= 0 or so[0] ~= 0 then
			C.close(fd)
			return nil, "connect failed: " .. path
		end
	end
	if fl >= 0 then C.fcntl(fd, F_SETFL, fl) end
	return fd
end

-- 等 fd 可读，毫秒超时
function M.wait(fd, ms)
	local tv = ffi.new("struct kb_timeval")
	local set = ffi.new("char[16]")   -- fd_set 在 64 位上是 128B

	if ffi.abi("64bit") then set = ffi.new("char[128]") end
	ffi.fill(set, ffi.sizeof(set), 0)
	local b = bit.lshift(1, fd % 64)
	local off = math.floor(fd / 64) * 8
	ffi.cast("uint64_t*", set)[off / 8] = b
	tv.tv_sec = math.floor(ms / 1000)
	tv.tv_usec = (ms % 1000) * 1000
	return C.select(fd + 1, set, nil, nil, tv) > 0
end

-- 等 fd 可写（connect 进度），毫秒超时
function M.wait_w(fd, ms)
	local tv = ffi.new("struct kb_timeval")
	local set = ffi.new("char[128]")

	ffi.fill(set, 128, 0)
	ffi.cast("uint64_t*", set)[math.floor(fd / 64)] = bit.lshift(1, fd % 64)
	tv.tv_sec = math.floor(ms / 1000)
	tv.tv_usec = (ms % 1000) * 1000
	return C.select(fd + 1, nil, set, nil, tv) > 0
end

-- 往 fd 写整个字符串（短写要循环）
function M.write(fd, s)
	local buf = ffi.cast("const char*", s)
	local n = #s

	while n > 0 do
		local w = C.write(fd, buf, n)

		if w <= 0 then return false end
		buf = buf + w
		n = n - tonumber(w)
	end
	return true
end

-- 读到 EOF 或超时；返回字符串（可能为空）
function M.read(fd, ms)
	local out, total = {}, 0
	local buf = ffi.new("char[65536]")

	while true do
		if not M.wait(fd, ms) then break end
		local n = C.read(fd, buf, 65536)

		if n <= 0 then break end
		out[#out + 1] = ffi.string(buf, n)
		total = total + tonumber(n)
		if total > 8 * 1024 * 1024 then break end
	end
	return table.concat(out)
end

-- 一次性请求：连上 → 写 req(+换行) → 读回 → 关
-- 返回 ok, 回复文本 | ok, nil, 错误
function M.req(path, req, ms, half_close)
	ms = ms or 1000
	local fd, err = M.connect(path, math.min(ms, 800))

	if not fd then return false, nil, err end
	if half_close == nil then half_close = true end
	if req and #req > 0 then
		if req:sub(-1) ~= "\n" then req = req .. "\n" end
		if not M.write(fd, req) then
			C.close(fd)
			return false, nil, "write failed"
		end
		-- 阅读器的自动化口按「读到 EOF」判定请求结束，不半关就一直不回应
		if half_close then C.shutdown(fd, 1) end
	end
	local r = M.read(fd, ms)

	C.close(fd)
	return true, r
end

-- 建服务端 socket（控制口）
-- 注意：socket 文件已存在时先 unlink，否则 bind 会 EADDRINUSE
function M.listen(path)
	local sa, len = addr(path)

	if not sa then return nil, len end
	local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)

	if fd < 0 then return nil, "socket() failed" end
	C.unlink(path)
	if C.bind(fd, sa, len) ~= 0 then
		C.close(fd)
		return nil, "bind failed: " .. path
	end
	if C.listen(fd, 8) ~= 0 then
		C.close(fd)
		return nil, "listen failed"
	end
	return fd
end

function M.accept(fd)
	local c = C.accept(fd, nil, nil)

	return c >= 0 and c or nil
end

M.close = function(fd) if fd and fd >= 0 then C.close(fd) end end

-- JSON 编解码：盒子自带 cjson，主机也有；都没有时退化到极简实现（够控制口用）
local ok, cjson = pcall(require, "cjson")

if ok and cjson then
	M.json_ok = true
	M.decode = function(s)
		local r = cjson.decode(s)
		return r
	end
	M.encode = function(t) return cjson.encode(t) end
else
	M.json_ok = false
	-- 极简 JSON：只吃 {"k":v,"k2":[1,2]} 这种扁平结构，控制口够用
	local function unescape(s)
		return (s:gsub('\\(["\\/bfnrt])', function(c)
			return ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
			          f = "\f", n = "\n", r = "\r", t = "\t" })[c]
		end):gsub("\\u(%x%x%x%x)", function(h)
			return string.char(tonumber(h, 16))
		end))
	end

	M.decode = function(s)
		local t = {}

		for k, v in s:gmatch('"([^"]+)"%s*:%s*"(.-)"%s*[,}]') do t[k] = unescape(v) end
		for k, v in s:gmatch('"([^"]+)"%s*:%s*(-?%d+%.?%d*)%s*[,}]') do t[k] = tonumber(v) end
		for k, v in s:gmatch('"([^"]+)"%s*:%s*(%a+)%s*[,}]') do
			if v == "true" then t[k] = true elseif v == "false" then t[k] = false end
		end
		return t
	end
	M.encode = function(t)
		local p = {}

		for k, v in pairs(t) do
			if type(v) == "string" then p[#p + 1] = ('"%s":"%s"'):format(k, (v:gsub('"', '\\"')))
			elseif type(v) == "number" or type(v) == "boolean" then p[#p + 1] = ('"%s":%s'):format(k, tostring(v)) end
		end
		return "{" .. table.concat(p, ",") .. "}"
	end
end

-- 便捷：请求并解 JSON（失败返回 nil, err）
function M.json_req(path, req, ms)
	local ok2, r, err = M.req(path, req, ms)

	if not ok2 then return nil, err end
	if not r or r == "" then return nil, "empty reply" end
	local pok, v = pcall(M.decode, r)

	if not pok then return nil, "bad json: " .. tostring(v):sub(1, 120) end
	return v
end

return M
