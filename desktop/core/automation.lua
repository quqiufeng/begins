-- core/automation.lua — 进程内 Unix socket 自动化口（和 reader 同协议）
--
-- 一行 JSON 请求 → 一行 JSON 应答，客户端写完就半关、读到 EOF 收包：
--   {"cmd":"ping"}
--   {"cmd":"list"}                                   # actions
--   {"cmd":"state"}                                 # 嵌套，cjson 在才解得出
--   {"cmd":"brief"}                                 # 扁平摘要（控制端够用）
--   {"cmd":"click","id":"nav.right"}
--   {"cmd":"key","name":"RIGHT"}                     # 等价于按了一下遥控
--   {"cmd":"call","fn":"app.capture","args":{"path":"/tmp/a.png"}}
--
-- 主循环每帧 poll() 一次，accept/recv 全部非阻塞，单个慢客户端不会卡画面。

local ffi = require("ffi")
local bit = require("bit")
local json = require("util.json")

ffi.cdef [[
typedef struct {
	unsigned short sun_family;
	char sun_path[108];
} desk_sockaddr_un;

int socket(int domain, int type, int protocol);
int bind(int fd, const desk_sockaddr_un *addr, unsigned int len);
int listen(int fd, int backlog);
int accept(int fd, desk_sockaddr_un *addr, unsigned int *len);
long recv(int fd, void *buf, size_t len, int flags);
long send(int fd, const void *buf, size_t len, int flags);
int close(int fd);
int unlink(const char *path);
int fcntl(int fd, int cmd, int arg);
int chmod(const char *path, unsigned int mode);
]]

local C = ffi.C
local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL = 3, 4
local F_SETFD, FD_CLOEXEC = 2, 1
local O_NONBLOCK = 0x800
local MSG_NOSIGNAL = 0x4000

local BUF = 65536

local M = {}
M.__index = M

local function set_nonblock(fd)
	local fl = C.fcntl(fd, F_GETFL, 0)

	C.fcntl(fd, F_SETFL, bit.bor(fl, O_NONBLOCK))
	-- CLOEXEC：播放器/阅读器是 io.popen 起的，会继承我们所有裸 fd。
	-- 不关掉的话，客户端 socket 会一直留在子进程里，对方读到 EOF 永远等不到，
	-- 表现就是 "点开视频后 nav.ok 的应答到了但连接不收尾"。
	C.fcntl(fd, F_SETFD, FD_CLOEXEC)
end

function M.start(path, handlers)
	local self = setmetatable({
		path = path, handlers = handlers or {}, clients = {}, n = 0,
	}, M)

	C.unlink(path)
	local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)

	if fd < 0 then return nil, "socket() failed" end
	local sa = ffi.new("desk_sockaddr_un")

	sa.sun_family = AF_UNIX
	ffi.fill(sa.sun_path, 108, 0)
	ffi.copy(sa.sun_path, path)
	if C.bind(fd, sa, ffi.sizeof(sa)) ~= 0 then
		C.close(fd)
		return nil, "bind failed: " .. path
	end
	C.chmod(path, 0x1C0)   -- 0700
	if C.listen(fd, 8) ~= 0 then
		C.close(fd)
		return nil, "listen failed"
	end
	set_nonblock(fd)
	self.fd = fd
	return self
end

-- 处理一条请求，返回应答字符串
function M:handle(line)
	local req, perr = json.decode(line)

	if not req then
		return json.encode({ ok = false, error = "bad json: " .. tostring(perr) })
	end
	local H = self.handlers
	local cmd = req.cmd or ""

	if cmd == "ping" then return json.encode({ ok = true, pong = true }) end
	if cmd == "list" then
		return json.encode({ ok = true, actions = H.actions and H.actions() or {} })
	end
	if cmd == "state" then
		return json.encode({ ok = true, state = H.state and H.state() or {} })
	end
	if cmd == "brief" then
		-- 扁平摘要：控制端（keybord/sock.lua）在盒子上没有 cjson，极简解码
		-- 只认扁平对象，嵌套的 state 解不出子表，所以另给一条扁平应答。
		local st = (H.state and H.state()) or {}
		local it = st.item or {}

		return json.encode({
			ok = true, pong = true,
			name = st.name, dir = st.dir,
			count = st.count, selected = st.selected,
			preview = st.preview and true or false,
			sel = it.name, sel_dir = it.dir and true or false,
			cols = st.cols, rows = st.rows,
			reader = st.reader and true or false,
			player = st.player and true or false,
		})
	end
	if cmd == "click" then
		if self.busy then
			-- 外部 app 独占屏幕期间只有一件事还能做：返回 = 收掉它回桌面。
			-- 交给上层的 H.busy 判定（播放中按返回退出播放），其余照旧回 busy。
			if H.busy then
				local ok2, r2 = pcall(H.busy, tostring(req.id or ""), "click")

				if ok2 and type(r2) == "table" then return json.encode(r2) end
			end
			return json.encode({ ok = false, error = "busy: 外部 app 正在独占屏幕" })
		end
		local ok, r = pcall(H.click, tostring(req.id or ""))

		if not ok then return json.encode({ ok = false, error = tostring(r) }) end
		r = type(r) == "table" and r or { ok = true }
		r.ok = r.ok ~= false
		return json.encode(r)
	end
	if cmd == "key" then
		if self.busy then
			-- 同上：播放/阅读中，"返回"要能收掉外部 app（退出播放）
			if H.busy then
				local ok2, r2 = pcall(H.busy, tostring(req.name or ""), "key")

				if ok2 and type(r2) == "table" then return json.encode(r2) end
			end
			return json.encode({ ok = false, error = "busy: 外部 app 正在独占屏幕" })
		end
		local ok, r = pcall(H.key, tostring(req.name or ""))

		if not ok then return json.encode({ ok = false, error = tostring(r) }) end
		r = type(r) == "table" and r or { ok = true }
		r.ok = r.ok ~= false
		return json.encode(r)
	end
	if cmd == "call" then
		local ok, r = pcall(H.call, tostring(req.fn or ""), req.args or {})

		if not ok then return json.encode({ ok = false, error = tostring(r) }) end
		r = type(r) == "table" and r or { ok = true }
		r.ok = r.ok ~= false
		return json.encode(r)
	end
	return json.encode({ ok = false, error = "unknown cmd: " .. tostring(cmd) })
end

function M:accept_all()
	while true do
		local cfd = C.accept(self.fd, nil, nil)

		if cfd < 0 then return end
		set_nonblock(cfd)
		self.n = self.n + 1
		self.clients[self.n] = {
			fd = cfd, buf = {}, len = 0, done = false,
			deadline = os.time() + 2,
		}
	end
end

-- 每帧调用；返回处理过的请求数（自动化测试靠它判断"机器动了"）
function M:poll()
	if not self.fd then return 0 end
	self:accept_all()

	local handled = 0
	local buf = ffi.new("char[?]", BUF)

	for i = self.n, 1, -1 do
		local cl = self.clients[i]

		if cl.done then
			-- 已回包，等它自己关（或我们这边直接 close）
			C.close(cl.fd)
			table.remove(self.clients, i)
			self.n = self.n - 1
		else
			local got_eof = false

			while true do
				local n = C.recv(cl.fd, buf, BUF, 0)

				if n > 0 then
					local s = ffi.string(buf, n)

					cl.buf[#cl.buf + 1] = s
					cl.len = cl.len + tonumber(n)
					if s:find("\n") then break end
				elseif n == 0 then
					got_eof = true
					break
				else
					break
				end
			end
			local line = table.concat(cl.buf)

			if line:find("\n") or got_eof or cl.len >= BUF - 1 or os.time() > cl.deadline then
				line = line:gsub("%s+$", "")
				if line ~= "" then
					local reply = self:handle(line)

					if reply and #reply > 0 then
						local p, left = ffi.cast("const char*", reply), #reply

						while left > 0 do
							local w = C.send(cl.fd, p, left, MSG_NOSIGNAL)

							if w <= 0 then break end
							p = p + tonumber(w)
							left = left - tonumber(w)
						end
					end
					handled = handled + 1
				end
				-- 半关（shutdown WR）的客户端会继续读到 EOF，这里先把它标成 done，
				-- 下一轮再 close，确保应答已经进了内核缓冲。
				cl.done = true
			end
		end
	end
	return handled
end

function M:close()
	if self.fd then
		C.close(self.fd)
		self.fd = nil
		C.unlink(self.path)
	end
	for i = 1, self.n do
		if self.clients[i] then C.close(self.clients[i].fd) end
	end
	self.clients, self.n = {}, 0
end

return M
