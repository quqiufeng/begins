-- desktop/config.lua — 一处配置，全部可被环境变量覆盖
--
-- 设计原则和 keybord/reader 一致：所有路径都能从 env 改，方便在开发机上用
-- dummy/x11 驱动跑自动化，到盒子上换成 kmsdrm 真屏。

local M = {}

local function env(k, d)
	local v = os.getenv(k)

	if v == nil or v == "" then return d end
	return v
end

local function exists(p)
	local f = io.open(p, "rb")

	if not f then return false end
	f:close()
	return true
end

function M.exists(p) return exists(p) end

-- 文件系统
M.home = env("DESKTOP_HOME", env("HOME", "/root"))

-- 资源目录（本文件所在目录下的 assets），图标 PNG 由 tools/gen-icons.sh 生成
local self_dir = (debug.getinfo(1, "S").source:match("^@(.*)/") or ".")
M.assets_dir = env("DESKTOP_ASSETS", self_dir .. "/assets")
M.icons_dir = env("DESKTOP_ICONS", M.assets_dir .. "/icons")

-- ---------- NAS（WebDAV）----------
-- 桌面开机就显示 NAS 上的文件，所以默认目录 = NAS。
-- 路径是虚拟的：dav:/<远端绝对路径>，由 core/dav.lua 用 curl 走 PROPFIND。
-- 凭据优先 env（DESKTOP_NAS_* → WEBDAV_*），否则读 .env（cwd 向上 → ~/.env）。
local function env_file(key)
	local dir = os.getenv("PWD") or "."
	local candidates = { dir .. "/.env",
		(os.getenv("HOME") or "") .. "/.env",
		"/opt/desktop/.env" }

	for _, p in ipairs(candidates) do
		local f = io.open(p, "rb")

		if f then
			for line in f:lines() do
				local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")

				if k == key and v then
					f:close()
					v = v:gsub("^'(.*)'$", "%1"):gsub('^"(.*)"$', "%1")
					return (v:gsub("%s+#.*$", ""))
				end
			end
			f:close()
		end
	end
	return nil
end

local function cfgv(name, key, d)
	return env(name, (key and env_file(key)) or d)
end

M.nas = {
	label = cfgv("DESKTOP_NAS_LABEL", nil, "NAS"),
	url = cfgv("DESKTOP_NAS_URL", "WEBDAV_URL", ""),
	user = cfgv("DESKTOP_NAS_USER", "WEBDAV_USER", ""),
	pass = cfgv("DESKTOP_NAS_PASS", "WEBDAV_PASS", ""),
	-- 根目录：NAS 上的共享路径（极空间 = /sata11-<账号>）
	base = cfgv("DESKTOP_NAS_BASE", "WEBDAV_MOVIES", "/sata11-18072858035"),
	cache = env("DESKTOP_NAS_CACHE", "/tmp/desktop-cache"),
}
M.nas.enabled = M.nas.url ~= ""
-- 桌面的起始虚拟路径；NAS 没配就退回本地 home
M.nas.start = M.nas.enabled and ("dav:" .. M.nas.base) or nil

M.start_dir = env("DESKTOP_START", M.nas.start or M.home)

-- 侧栏/根：NAS 永远排第一，本地只留 home 和真正的外接点
M.roots = {}
if M.nas.start then M.roots[#M.roots + 1] = { path = M.nas.start, label = M.nas.label,
	kind = "nas" } end
for _, p in ipairs({ M.home, "/mnt", "/media", "/sata" }) do
	if exists(p) then
		M.roots[#M.roots + 1] = { path = p, label = (p == M.home and "本机" or p),
			kind = "local" }
	end
end
M.show_hidden = env("DESKTOP_HIDDEN", "") ~= ""

-- 自动化口（和 reader 同协议）
M.sock = env("DESKTOP_SOCK", "/tmp/desktop-automation.sock")
M.log = env("DESKTOP_LOG", "/tmp/desktop.log")
M.state_file = env("DESKTOP_STATE", (env("HOME", "/root")) .. "/.config/desktop/state.lua")

-- 窗口
M.title = "Desktop"
M.width = tonumber(env("DESKTOP_W", "1280")) or 1280
M.height = tonumber(env("DESKTOP_H", "720")) or 720
M.windowed = env("DESKTOP_WINDOWED", "") ~= "" or env("SDL_VIDEODRIVER", "") == "dummy"
M.fullscreen = not M.windowed
M.fps = tonumber(env("DESKTOP_FPS", "30")) or 30

-- 字体：仓耳今楷 02（W04 正文 / W05 标题粗），再退 CJK 黑体，最后 DejaVu
M.font_dir = env("DESKTOP_FONT_DIR", M.home .. "/.local/share/fonts/TsangerJinKai")
M.font_candidates = {
	env("DESKTOP_FONT", ""),
	M.font_dir .. "/TsangerJinKai02-W04.ttf",
	M.home .. "/.local/share/fonts/kami/TsangerJinKai02-W04.ttf",
	"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
}
-- 标题/强调用的粗一档（仓耳今楷 02 W05），找不到就回退到正文字体
M.font_bold_candidates = {
	env("DESKTOP_FONT_BOLD", ""),
	M.font_dir .. "/TsangerJinKai02-W05.ttf",
	M.home .. "/.local/share/fonts/kami/TsangerJinKai02-W05.ttf",
}
-- 行高：今楷字面比黑体矮一点，行距稍微放宽更好看
M.font_line_gap = tonumber(env("DESKTOP_FONT_LINE_GAP", "1.35")) or 1.35

local function first_existing(list)
	for _, p in ipairs(list) do
		if p ~= "" and exists(p) then return p end
	end
	return nil
end

function M.font_path()
	return first_existing(M.font_candidates)
end

function M.font_bold_path()
	return first_existing(M.font_bold_candidates) or M.font_path()
end

-- 打开外部 app
M.reader_cmd = env("DESKTOP_READER_CMD", "/opt/reader/build/native-reader")
M.reader_script = env("DESKTOP_READER_SCRIPT", "")   -- 整条命令模板，%s = 文件
M.play_cmd = env("DESKTOP_PLAY_CMD", "/root/play.sh")
M.play_script = env("DESKTOP_PLAY_SCRIPT", "")
M.launch_log = env("DESKTOP_LAUNCH_LOG", "/tmp/desktop-launch.log")
-- 播放器上屏看门狗：play.sh 自己打的 RENDER: <后端> (caps …) 是唯一可信判据
M.play_log = env("DESKTOP_PLAY_LOG", "/tmp/play.log")
M.play_onscreen_ms = tonumber(env("DESKTOP_PLAY_ONSCREEN_MS", "25000") or 25000)

-- 开发机上没有 /opt/reader：默认路径不存在时按顺序找本机构建，
-- 让同一份代码在盒子和开发机都能直接开书。env 显式给了就不猜。
if env("DESKTOP_READER_CMD", "") == "" then
	M.reader_cmd = first_existing({
		"/opt/reader/build/native-reader",
		env("HOME", "/root") .. "/Desktop/reader/build/native-reader",
		env("HOME", "/root") .. "/kernel/reader/build/native-reader",
	}) or M.reader_cmd
end

-- reader 用 READER_ROOT 找自己的 assets/fonts，默认取二进制所在的 build/.. 
M.reader_root = env("DESKTOP_READER_ROOT", "")
if M.reader_root == "" then
	local bin = M.reader_cmd:match("^(.*)/build/[^/]+$")

	M.reader_root = bin or "/opt/reader"
end

-- 文件分类：扩展名 → 类别。reader 支持 epub/pdf/txt/md/cbz/fb2/mobi…
local KIND = {
	ebook = {
		epub = true, pdf = true, txt = true, md = true, markdown = true,
		mobi = true, azw = true, azw3 = true, fb2 = true, cbz = true,
		cbr = true, chm = true, djvu = true, xps = true, ofd = true,
	},
	video = {
		mp4 = true, mkv = true, avi = true, ts = true, m2ts = true,
		mov = true, webm = true, flv = true, rmvb = true, wmv = true,
		mpg = true, mpeg = true, m4v = true, ["3gp"] = true,
	},
	audio = {
		mp3 = true, flac = true, wav = true, aac = true, m4a = true,
		ogg = true, ape = true, opus = true, wma = true, dts = true,
	},
	image = {
		jpg = true, jpeg = true, png = true, bmp = true, gif = true,
		webp = true, tif = true, tiff = true,
	},
}

M.KIND = KIND

function M.ext(name)
	local e = tostring(name):match("%.([%w]+)$")

	return e and e:lower() or ""
end

function M.kind_of(name, is_dir)
	if is_dir then return "dir" end
	local e = M.ext(name)

	for k, set in pairs(KIND) do
		if set[e] then return k end
	end
	return "other"
end

-- 类别 → 人类可读 / 图标色
M.KIND_LABEL = {
	dir = "文件夹", ebook = "电子书", video = "视频",
	audio = "音频", image = "图片", other = "文件",
}

return M
