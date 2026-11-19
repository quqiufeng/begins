-- util/fbcon.lua — 让出 DRM master 的空档里，别让 fbcon 把命令行推上屏
--
-- 桌面是 KMSDRM 全屏：只要它持有 master，内核就把 fbdev 客户端挡在外面。
-- 而打开阅读器/播放器时我们必须先 suspend()（销毁 window/renderer → 释放 master），
-- 这个空档里 fbcon（vtcon1，bind=1）会立刻把 tty1 的文本重新推上主 plane：
-- 屏幕闪一下命令行，然后子进程拿到 master 再 modeset → HDMI 重新锁存 → 电视
-- 弹「当前信号信息」黄条。play.sh 里 fbcon_hold/fbcon_release 是同一个道理，
-- 这里是桌面侧的对应实现（桌面自己也可能是那个「放手的进程」）。
--
-- 约定：谁 hold 谁 release；持有期间写 /tmp/desktop-fbcon.owner，
-- play.sh 见到这个文件就不在退出时 rebind（否则它会抢在桌面 resume 之前把
-- 命令行推上屏，闪回照旧）。

local M = {}

local OWNER = "/tmp/desktop-fbcon.owner"
M.OWNER = OWNER

local function read_file(p)
	local f = io.open(p, "rb")

	if not f then return nil end
	local s = f:read("*a")

	f:close()
	return s
end

local function write_file(p, s)
	local f = io.open(p, "wb")

	if not f then return false end
	f:write(s)
	f:close()
	return true
end

-- 找 fbcon 那个 vtcon 的 bind 文件（name 里带 frame / fbcon）
local function bind_path()
	local p = io.popen("ls -d /sys/class/vtconsole/vtcon*/bind 2>/dev/null")

	if not p then return nil end
	for line in p:lines() do
		local name = read_file((line:gsub("/bind$", "/name"))) or ""

		if name:lower():find("frame") or name:lower():find("fbcon") then
			p:close()
			return line
		end
	end
	p:close()
	return nil
end

local held = false

-- 解绑 fbcon：之后没人抢主 plane，master 空档里画面停在最后一帧。
function M.hold()
	if held then return true end
	local b = bind_path()

	if not b then return false end
	local owner = read_file(OWNER) or ""

	-- 别人（play.sh）已经挡着了也一样：只是把 owner 记成桌面
	write_file(OWNER, tostring(os.time()))
	held = true
	if (read_file(b) or ""):match("^%s*0") then return true end
	if not write_file(b, "0") then held = false; return false end
	return true
end

-- 重新绑定 fbcon。resume 成功之后再调（那时桌面已拿回 master，
-- rebind 不会真的扫出命令行）；resume 失败也必须调，否则命令行一直黑着。
function M.release()
	if not held then return false end
	held = false
	os.remove(OWNER)
	local b = bind_path()

	if not b then return false end
	if (read_file(b) or ""):match("^%s*1") then return true end
	return write_file(b, "1")
end

function M.is_held() return held end

return M
