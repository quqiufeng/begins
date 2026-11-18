-- tools/ask.lua — 自动化口客户端：发一行 JSON，收一行应答
--
--   luajit tools/ask.lua '{"cmd":"state"}'
--   luajit tools/ask.lua '{"cmd":"key","name":"RIGHT"}'
--   luajit tools/ask.lua '{"cmd":"call","fn":"app.capture","args":{"path":"/tmp/a.png"}}'
--
-- sock 路径取 DESKTOP_SOCK，默认 /tmp/desktop-automation.sock

package.path = "./?.lua;../?.lua;" .. package.path

local ffi = require("ffi")

ffi.cdef [[
typedef struct {
	unsigned short sun_family;
	char sun_path[108];
} ask_sockaddr_un;

int socket(int domain, int type, int protocol);
int connect(int fd, const ask_sockaddr_un *addr, unsigned int len);
long send(int fd, const void *buf, size_t len, int flags);
long recv(int fd, void *buf, size_t len, int flags);
int shutdown(int fd, int how);
int close(int fd);
]]

local req = arg[1]
if not req then
	io.stderr:write("用法: luajit tools/ask.lua '<json>'\n")
	os.exit(2)
end

local path = os.getenv("DESKTOP_SOCK") or "/tmp/desktop-automation.sock"
if not path:match("^/") then error("sock 路径必须是绝对路径: " .. path) end
if #path > 100 then error("sock 路径太长: " .. path) end

local fd = ffi.C.socket(1, 1, 0)   -- AF_UNIX, SOCK_STREAM
if fd < 0 then error("socket() failed") end

local addr = ffi.new("ask_sockaddr_un")
addr.sun_family = 1
ffi.copy(addr.sun_path, path)

if ffi.C.connect(fd, addr, ffi.sizeof(addr)) ~= 0 then
	error("connect " .. path .. " 失败：桌面没在跑，或者 DESKTOP_SOCK 不一致")
end

-- 空串 = 只读一行（ping/state）；给了就用它
local line = req .. "\n"
ffi.C.send(fd, line, #line, 0)
ffi.C.shutdown(fd, 1)              -- 半关，服务端读到 EOF 收包

local buf = ffi.new("char[?]", 1048576)
local n, out = 0, {}
while true do
	local r = ffi.C.recv(fd, buf, 1048576, 0)
	if r <= 0 then break end
	local s = ffi.string(buf, r)
	out[#out + 1] = s
	-- 应答是一行 JSON，收全了就走，别等 EOF：子进程万一还攥着这个 fd
	-- （CLOEXEC 漏掉的老进程），等 EOF 就是无限挂。
	if s:find("\n") or (s:find("}$") and table.concat(out):match("^%s*{.*}%s*$")) then break end
end
ffi.C.close(fd)

io.write(table.concat(out))
