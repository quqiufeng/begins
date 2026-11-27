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

-- 收尾：默认**不再** bind 回 fbcon。
--
-- 以前这里 rebind，实测这就是「退出播放器/阅读器时电视弹信号信息条」的
-- 那一下：fbcon 绑回去会把主 plane 的 CRTC 模式改成它自己的 1920x1080，
-- 桌面紧接着 resume 又摆回 3840x2160 —— HDMI 一退一锁两次，电视机跟丢
-- 信号就弹黄条。rebind 换来的只是「tty1 能看到命令行」，盒子是常显设备，
-- 这个收益为零。
-- 需要命令行时手动来一句：echo 1 > /sys/class/vtconsole/vtcon1/bind
-- （或 FBCON_REBIND=1 起桌面）。
function M.release()
	if not held then return false end
	held = false
	os.remove(OWNER)
	if os.getenv("FBCON_REBIND") == "1" then
		local b = bind_path()

		if not b then return false end
		if (read_file(b) or ""):match("^%s*1") then return true end
		return write_file(b, "1")
	end
	return true
end

-- ---------- 壁纸 ----------
-- fbcon 解绑之后，主 plane 在「没人持有 DRM master」的空档里显示的是驱动
-- 注册的模拟 fbdev（/dev/fb0）那块内存 —— 里面是开机时 fbcon 画上去的
-- tty1 文本。返回上一级 / 退出 app 时露出「开机 shell 画面」就是这么来的。
-- 这里把壁纸直接铺进 fb0，之后无论谁释放 master，露出来的都是壁纸。
local WALL_BIN = os.getenv("DESKTOP_FBWALL") or "/opt/desktop/bin/fbwall"
local WALL_RAW = os.getenv("DESKTOP_WALLPAPER") or "/opt/desktop/assets/wallpaper.bgra"
local WALL_W = tonumber(os.getenv("DESKTOP_WALLPAPER_W") or "") or 2560
local WALL_H = tonumber(os.getenv("DESKTOP_WALLPAPER_H") or "") or 1440

-- 只探存在性：wallpaper.bgra 有 14MB，别整块读进来
local function exists(p)
	local f = io.open(p, "rb")

	if not f then return false end
	f:close()
	return true
end

local wall_at

-- 幂等：同一秒内重复调用直接返回（切 app 一次只需要铺一张）
function M.wall(force)
	local now = os.time()

	if not force and wall_at == now then return true end
	if not exists(WALL_BIN) then return false end
	if not exists(WALL_RAW) then return false end
	os.execute(("%s %s %d %d >/dev/null 2>&1"):format(WALL_BIN, WALL_RAW, WALL_W, WALL_H))
	wall_at = now
	return true
end

function M.is_held() return held end

return M
