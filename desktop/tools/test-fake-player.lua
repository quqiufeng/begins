-- tools/test-fake-player.lua — 测试用假播放器控制口（hevcdec/pctl.c 的文本协议）
-- 只实现 status/pos/pause/resume/toggle/mute/vol，够验证桌面 player.* 转发
package.path = "./?.lua;" .. package.path
local ffi = require("ffi")

ffi.cdef [[
typedef struct { unsigned short sun_family; char sun_path[108]; } fp_un;
int socket(int, int, int);
int bind(int, const void *, unsigned int);
int listen(int, int);
int accept(int, void *, unsigned int *);
long read(int, void *, size_t);
long write(int, const void *, size_t);
int close(int);
int unlink(const char *);
int fcntl(int, int, int);
]]

local C = ffi.C
local path = os.getenv("FAKE_PLAY_SOCK") or "/tmp/fake-play.sock"

C.unlink(path)
local srv = C.socket(1, 1, 0)
local sa = ffi.new("fp_un")

sa.sun_family = 1
ffi.fill(sa.sun_path, 108, 0)
ffi.copy(sa.sun_path, path)
assert(C.bind(srv, sa, ffi.sizeof(sa)) == 0, "bind " .. path)
assert(C.listen(srv, 8) == 0)

local paused, mute, vol, xrun = 0, 0, 90, 0
local t0 = os.time()

local function reply(fd, s)
	C.write(fd, s .. "\n", #s + 1)
end

while os.time() - t0 < 120 do
	local fd = C.accept(srv, nil, nil)

	if fd >= 0 then
		local buf = ffi.new("char[512]")
		local n = C.read(fd, buf, 511)

		if n > 0 then
			local line = ffi.string(buf, n):match("^[^\n]*") or ""
			local cmd, arg = line:match("^(%a+)%s*(%d*)")

			if cmd == "status" then
				reply(fd, ('{"ok":1,"paused":%d,"pos_ms":%d,"au":1,"audio":1,"vol":%d,"mute":%d,"xrun":%d}')
					:format(paused, 42000 + (os.time() - t0) * 1000, vol, mute, xrun))
			elseif cmd == "pos" then
				reply(fd, ('{"ok":1,"pos_ms":%d}'):format(42000))
			elseif cmd == "pause" then paused = 1; reply(fd, '{"ok":1}')
			elseif cmd == "resume" then paused = 0; reply(fd, '{"ok":1}')
			elseif cmd == "toggle" then paused = 1 - paused; reply(fd, '{"ok":1}')
			elseif cmd == "mute" then mute = 1 - mute; reply(fd, '{"ok":1,"mute":1}')
			elseif cmd == "vol" then vol = tonumber(arg) or vol; reply(fd, '{"ok":1}')
			else reply(fd, '{"ok":0,"error":"unknown"}') end
		end
		C.close(fd)
	end
end
C.close(srv)
C.unlink(path)
