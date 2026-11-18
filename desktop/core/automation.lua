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
local POLL_BUF = ffi.new("char[?]", BUF)

local M = {}
M.__index = M

-- ---------- 能力白名单 ----------
--
-- 协议通了不等于什么都该能做：agent 的自由度不等于 root 自由度。
-- handlers.caps 给了就按它裁，没给（老调用方/测试）则全放行。
--   caps.cmds   = { ping=true, state=true, click=true, ... }   允许的顶层命令
--   caps.click  = { "^nav%.[a-z]+$", "^select%." }             允许的动作 id（表 == 字面名，含正则元字符的按模式）
--   caps.keys   = { LEFT=true, OK=true }                      允许的键名
--   caps.calls  = { "^app%." , "^reader%." }                  允许的 call fn
local function name_match(s, p)
	if s == p then return true end
	-- 带正则元字符的当模式；纯名字把点号转义（app.capture 不该匹配 appXcapture）
	if p:find("[%%%^%$%*%+%?%[%(]") then return s:match(p) ~= nil end
	return s:match((p:gsub("%.", "%%."))) ~= nil
end

local function any_match(list, s)
	if not list then return true end
	for i = 1, #list do
		if name_match(s, list[i]) then return true end
	end
	return false
end

function M:allowed(cmd, req)
	local caps = self.handlers.caps

	if not caps then return true end
	if caps.cmds and not caps.cmds[cmd] then return false, cmd end
	if cmd == "click" then
		local id = tostring(req.id or "")

		if not any_match(caps.click, id) then return false, "click " .. id end
	elseif cmd == "key" then
		local n = tostring(req.name or ""):upper()

		if caps.keys and not caps.keys[n] then return false, "key " .. n end
	elseif cmd == "call" then
		local fn = tostring(req.fn or "")

		if not any_match(caps.calls, fn) then return false, "call " .. fn end
	end
	return true
end

-- ---------- 状态指纹（动作幂等 + 可验证） ----------
--
-- 每个动作应答都带 state_digest + changed：模型据此判断「按了到底有没有起作用」，
-- 而不是发完 nav.ok 就假设成功。digest 只覆盖控制面（路径/选中/前后台/页码），
-- 不含 pos_ms 这种每秒都变的量，否则 changed 永远是 true，等于没有。
local function fnv1a(s)
	local h = 2166136261

	for i = 1, #s do
		h = bit.bxor(h, s:byte(i))
		-- h * 16777619 mod 2^32，用 32 位乘法拆开算（Lua 数字是 double）
		h = (h * 16777619) % 4294967296
	end
	return ("%08x"):format(h)
end

function M:digest()
	local H = self.handlers
	local ok, s = pcall(function()
		if H.digest then return H.digest() end
		return json.encode(H.state and H.state() or {})
	end)

	if not ok or type(s) ~= "string" then s = tostring(s) end
	return fnv1a(s)
end

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

-- 动作应答统一包一层：digest 前后对比 → changed。
-- 延迟执行的动作（会阻塞主循环的那种，比如开播放器）只回当前 digest，
-- changed 由调用方下一轮 state/digest 自己看。
function M:mutate(fn)
	local before = self:digest()
	local ok, r = pcall(fn)

	if not ok then
		return json.encode({ ok = false, error = tostring(r), state_digest = before })
	end
	r = type(r) == "table" and r or { ok = true }
	r.ok = r.ok ~= false
	if r.deferred then
		r.state_digest = before
	else
		local after = self:digest()

		r.state_digest = after
		-- 转发给 reader/player 的动作自己知道「变了没」（页码/暂停位），
		-- 它们给了 changed 就用它们的，别被桌面本地指纹盖成 false
		if r.changed == nil then r.changed = after ~= before end
	end
	return json.encode(r)
end

-- 处理一条请求，返回应答字符串
function M:handle(line)
	local req, perr = json.decode(line)

	if not req then
		return json.encode({ ok = false, error = "bad json: " .. tostring(perr) })
	end
	local H = self.handlers
	local cmd = req.cmd or ""

	-- 白名单在最前面裁：被拒的请求不该有任何副作用
	local pass, deny = self:allowed(cmd, req)

	if not pass then
		return json.encode({
			ok = false, denied = true,
			error = "capability denied: " .. tostring(deny),
		})
	end

	if cmd == "ping" then return json.encode({ ok = true, pong = true }) end
	if cmd == "list" then
		return json.encode({ ok = true, actions = H.actions and H.actions() or {} })
	end
	if cmd == "state" then
		return json.encode({ ok = true, state = H.state and H.state() or {} })
	end
	if cmd == "digest" then
		return json.encode({ ok = true, state_digest = self:digest() })
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
			sel_kind = it.kind, sel_size = it.size_h,
			pos = st.pos, total = st.count,
			-- 现在前台是谁、在播什么：agent/keybd 判断"该发什么键"的依据
			app = st.screen and st.screen.app or "desktop",
			file = st.screen and st.screen.file or it.name,
			media_pos = st.media and st.media.pos_ms or nil,
			media_dur = st.media and st.media.dur_ms or nil,
			book_page = st.book and st.book.page or nil,
			book_pages = st.book and st.book.pages or nil,
			cols = st.cols, rows = st.rows,
			reader = st.reader and true or false,
			player = st.player and true or false,
		})
	end
	if cmd == "click" then
		local id = tostring(req.id or "")

		return self:mutate(function()
			if self.busy then
				-- 外部 app 独占屏幕期间只有一件事还能做：返回 = 收掉它回桌面。
				if H.busy then
					local ok2, r2 = pcall(H.busy, id, "click")

					if ok2 and type(r2) == "table" then return r2 end
				end
				return { ok = false, error = "busy: 外部 app 正在独占屏幕" }
			end
			return H.click(id)
		end)
	end
	if cmd == "key" then
		local name = tostring(req.name or "")

		return self:mutate(function()
			if self.busy then
				if H.busy then
					local ok2, r2 = pcall(H.busy, name, "key")

					if ok2 and type(r2) == "table" then return r2 end
				end
				return { ok = false, error = "busy: 外部 app 正在独占屏幕" }
			end
			local ok, r = pcall(H.key, name)

			if not ok then return { ok = false, error = tostring(r) } end
			return type(r) == "table" and r or { ok = true }
		end)
	end
	if cmd == "call" then
		local fn = tostring(req.fn or "")

		return self:mutate(function()
			local ok, r = pcall(H.call, fn, req.args or {})

			if not ok then return { ok = false, error = tostring(r) } end
			return type(r) == "table" and r or { ok = true }
		end)
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
	-- 缓冲区复用：每帧 new 一块 64KB 的 ffi 数组纯属给 GC 找事；
	-- recv 之后立刻 ffi.string 拷出来，嵌套调用（launcher 的 pump）也不会串味。
	local buf = POLL_BUF

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
