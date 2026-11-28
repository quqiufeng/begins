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

-- 桌面首页：虚拟根，不放任何文件，只放 app 图标（NAS / 本机 / 浏览器 / 微信）。
-- 用户的要求是「NAS 目录不直接摊在首页，先点 NAS 图标才进去」，
-- 所以起始目录是这个虚拟根，扫描时由 core/fs.lua 直接生成 app 条目。
M.home_dir = "home:"
M.home_label = env("DESKTOP_HOME_LABEL", "桌面")

M.start_dir = env("DESKTOP_START", M.home_dir)

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
-- USB 热插拔：插上自动只读挂到 /media/<卷标>，拔了自动卸；TAB 在根之间切换
M.usb = {
	enabled = env("DESKTOP_USB", "1") ~= "0",
	root = env("DESKTOP_USB_ROOT", "/media"),
	rw = env("DESKTOP_USB_RW", "") ~= "",
	all = env("DESKTOP_USB_ALL", "") ~= "",
}

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

-- 音乐（纯音频）必须单开一条路。play.sh 是 V4L2 硬解视频链：mp3/flac/wav
-- 里没有视频流，喂进去只会 "没有视频流" 秒退，用户看到的就是「音乐格式不支持」。
-- vlc 优先（用户点名要的），没装就退回盒子自带的 mpv，两边都只是"纯音频出声"。
M.music_cmd = env("DESKTOP_MUSIC_CMD", "")
M.music_script = env("DESKTOP_MUSIC_SCRIPT", "")   -- 整条命令模板，%s = 文件
if M.music_cmd == "" and M.music_script == "" then
	M.music_cmd = first_existing({
		"/usr/bin/cvlc", "/usr/bin/vlc", "/usr/bin/mpv",
	}) or ""
end
-- 直出 app：不是文件，是"空转启动"的外部程序。桌面把它们当虚拟条目插在
-- 书架最前面（图标取 assets/icons/<kind>.png，缺图自动退回文字徽章）。
-- 之所以按"能不能找到程序"决定是否出现，是为了让同一份代码在开发机上也能跑。
M.apps = {}
if env("DESKTOP_APPS", "1") ~= "0" then
	local function add_app(t) M.apps[#M.apps + 1] = t end
	-- 文件管理入口：goto = 点开就切到这个目录，不起外部进程。
	-- NAS 没配就不出现（否则点进去是一片「NAS 未配置」）。
	if M.nas.start then
		add_app({
			name = M.nas.label or "NAS", kind = "nas", meta = "网络存储",
			goto = M.nas.start,
		})
	end
	add_app({ name = "本机", kind = "host", meta = "本机文件", goto = M.home })
	-- 音乐：mpv 全屏（频谱 + 播放列表 OSD）放 NAS 曲库，遥控由 keybd 的
	-- apps/music.lua 走 mpv 的 IPC 口 /tmp/m.sock（键位见那个文件）。
	-- 脚本在 /root/music.sh（deploy/music.sh），歌单默认 /root/music.m3u。
	add_app({
		name = "音乐", kind = "music", meta = "音乐",
		app = true,
		cmd = env("DESKTOP_MUSIC_APP_CMD", "/root/music.sh"),
	})
	-- 浏览器：cage 独占 DRM + chromium kiosk。这台盒子上 cog/WPE 已经不在系统里了
	-- （dpkg 无 cog、全盘无 cog 二进制），cage+chromium 是还能跑通的直出路线。
	if exists("/usr/bin/cage") and exists("/usr/bin/chromium") then
		add_app({
			name = "浏览器", kind = "browser", meta = "网页",
			-- 首页：本地 /root/browser-home.html，没有这个文件就退回白页
			cmd = env("DESKTOP_BROWSER_CMD",
				-- 方向键选 URL / OK 进入：先把 navinject 拉起来（常驻，每 2s 把
				-- /root/browser-nav.js 注入每个 page target，见该脚本头注释）
				"(setsid nohup /opt/reader/bin/luajit /root/navinject.lua "
				.. ">>/tmp/navinject.log 2>&1 </dev/null &); "
				.. "exec dbus-run-session -- cage -- chromium --kiosk --no-sandbox "
				-- lang/translate：cage 直接起没有 locale，chromium 会判定页面是外语，
				-- 右上角弹「翻译成英语」气泡盖住页面，一并关掉
				.. "--lang=zh-CN --accept-lang=zh-CN,zh "
				.. "--disable-features=Translate,TranslateUI "
				.. "--disable-dev-shm-usage --ozone-platform=wayland "
				-- 代理：盒上 mihomo(127.0.0.1:7890) 在跑，走它才能开 youtube/github；
				-- 不加这段 chromium 是直连，连 SYN-SENT 卡死 → 用户看到「点了打不开」
				.. "--proxy-server=http://127.0.0.1:7890 "
				-- keybd 的 browser app 要读当前 url 才能判断「回首页 / 退出」：
				-- 只监听 127.0.0.1，不对外网暴露
				.. "--remote-debugging-port=9222 "
				
				.. (exists("/root/browser-home.html")
					and "file:///root/browser-home.html" or "about:blank")),
		})
	end
	-- 微信：sway + wayland（不再用 cage）。cage 0.2 的 view 只能贴左上角
	-- （lx/ly 写死 0，无配置项、无 IPC），窗口既不能居中也不会留壁纸背景；
	-- sway 走 /opt/desktop/wechat.conf：背景铺 assets/wallpaper.png，
	-- 窗口由 bin/wx-center.py 在 map 后 resize 到 1280x720 并居中。
	if exists("/opt/wechat/wechat") and exists("/usr/bin/sway") then
		add_app({
			name = "微信", kind = "wechat", meta = "聊天",
			cmd = env("DESKTOP_WECHAT_CMD",
				"exec dbus-run-session -- sway -c /opt/desktop/wechat.conf"),
		})
	elseif exists("/opt/wechat/wechat") then
		add_app({
			name = "微信", kind = "wechat", meta = "聊天",
			cmd = env("DESKTOP_WECHAT_CMD",
				"exec dbus-run-session -- cage -- /opt/wechat/wechat --no-sandbox "
				.. "--ozone-platform=wayland --disable-dev-shm-usage "
				.. "--window-size=1280,720 --start-maximized"),
		})
	end
	-- 二维码（书架最后一格）：扫一下就是 8080 那把「更新 API Key」页
	-- （lite setup --host 0.0.0.0 --port 8080，见 lite-setup.service）。
	-- 图标是 assets/icons/qr.png，由 tools/gen-qr.sh 按本机 IP 生成：
	-- 换 IP/端口就重跑那个脚本，桌面重开即生效（这里不写死 URL，免得两份真相）。
	-- last = true：core/fs.lua 把它排到最右边（U 盘图标也插在它前面）。
	add_app({ name = "更新Key", kind = "qr", last = true })
end
M.launch_log = env("DESKTOP_LAUNCH_LOG", "/tmp/desktop-launch.log")

-- 外部 app 的自动化口 / 状态文件：桌面把它们汇总成一份语义 state 给 agent，
-- 模型就不用自己挨个 socket 去问，也不用看截图猜"在播什么、播到第几秒"。
M.reader_sock = env("READER_AUTOMATION_SOCK", "/tmp/native-reader-automation.sock")
M.play_sock = env("PLAY_SOCK", "/tmp/play.sock")
M.play_state = env("DESKTOP_PLAY_STATE", "/tmp/play.state")

-- 能力白名单开关：默认不让 agent 关掉桌面/外部 app 这类动作
M.allow_quit = env("DESKTOP_ALLOW_QUIT", "") ~= ""
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
	-- 首页 fixture：底部状态栏用它代替「文件」
	nas = "网络存储", host = "本机", browser = "浏览器", wechat = "微信",
}

return M
