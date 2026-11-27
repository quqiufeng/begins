-- ui/chrome.lua — 顶栏 / 底栏 / toast
--
-- 顶栏：当前目录 + 条目数 + 时钟；底栏：当前选中的名字、类别、大小 + 按键提示。
-- toast：右下角浮一条，2.5 秒淡出（打开失败、启动外部 app 时反馈用）。

local M = {}
M.__index = M

function M.new(cfg, theme, ttf)
	-- config.font_path 是函数（多候选挑第一个存在的），这里解析一次存成路径
	local font = (type(cfg.font_path) == "function") and cfg.font_path() or cfg.font_path

	return setmetatable({ cfg = cfg, theme = theme, ttf = ttf, msg = nil, until_ = 0,
		font = font }, M)
end

function M:toast(msg, seconds, color)
	self.msg = tostring(msg or "")
	self.until_ = os.time() + (seconds or 2.5)
	self.color = color
end

function M:tick(now)
	if self.msg == nil then return false end
	now = now or os.time()
	if now > math.floor(self.until_) then
		self.msg = nil
		return true
	end
	return false
end

local function clock_text()
	-- 秒也要，主循环按 "%H:%M:%S" 判 dirty，屏幕上就是秒秒在走
	return os.date("%H:%M:%S")
end

-- ---------- 盒子 IP ----------
-- 顶栏中央要显示这台盒子拿到的地址：走默认路由的源地址最可靠（也能反映
-- 换网/VPN），其次是 hostname -I / ip addr 里第一块非回环网卡。
-- io.popen 有进程开销，所以结果缓存 IP_TTL 秒；拿不到时短一点再试。
local IP_TTL = 15
local ip_cache, ip_at, ip_err = nil, -100, nil

local function sh(cmd)
	local f = io.popen(cmd .. " 2>/dev/null")

	if not f then return nil end
	local s = f:read("*a") or ""

	f:close()
	return s
end

-- 虚拟网卡前缀：这些地址对"让别人连上盒子"没用，只是本机内部转发
-- （本机实测最坑的是 digilink/tun 的 198.18.0.1 — 它是 fake-ip 网段的
--  路由源地址，ip route get 优先吐它，但那个地址外部根本连不进来）
local VIF = { "^lo", "^lxc", "^docker", "^veth", "^br%-", "^virbr", "^tun",
	"^tap", "^wg", "^digilink", "^meta", "^clash", "^tailscale", "^zt" }

local function virtual_if(name)
	for _, pat in ipairs(VIF) do
		if name:lower():find(pat) then return true end
	end
	return false
end

-- 私有 LAN 段的优先级：192.168 > 10 > 172.16-31；198.18/15 是 fake-ip，直接丢
local function lan_rank(ip)
	if ip:find("^198%.18%.") or ip:find("^198%.19%.") then return nil end
	if ip:find("^127%.") or ip:find("^169%.254%.") then return nil end
	if ip:find("^192%.168%.") then return 1 end
	if ip:find("^10%.") then return 2 end
	local b = tonumber(ip:match("^172%.(%d+)%."))

	if b and b >= 16 and b <= 31 then return 3 end
	if ip:find("^100%.") then return 5 end   -- CGNAT/tailscale 一类，最后才用
	return 4
end

local function probe_ip()
	-- 先把每块网卡的地址按"能不能被别人连"排个序
	local best, best_rank = nil, 99

	for name, ip in (sh("ip -4 -o addr show scope global") or "")
		:gmatch("%d+:%s+(%S+)%s+inet%s+(%d+%.%d+%.%d+%.%d+)") do
		local r = lan_rank(ip)

		if r and not virtual_if(name) and r < best_rank then
			best, best_rank = ip, r
		end
	end
	if best then return best end

	-- 兜底一：默认路由源地址（上面都被过滤光了才用）
	local ip = sh("ip route get 1.1.1.1"):match("src%s+(%d+%.%d+%.%d+%.%d+)")

	if ip and lan_rank(ip) then return ip end

	-- 兜底二：hostname -I 里第一个合法的
	for cand in (sh("hostname -I") or ""):gmatch("%d+%.%d+%.%d+%.%d+") do
		if lan_rank(cand) then return cand end
	end
	return nil
end

-- 现在（或缓存里）的 IP；nil 表示还没拿到
function M:ip(now)
	now = now or os.time()
	local ttl = ip_cache and IP_TTL or 3

	if now - ip_at >= ttl then
		ip_at = now
		ip_cache = probe_ip()
	end
	return ip_cache
end

function M:draw_top(ren, fs, W, sdl)
	local t = self.theme
	local h = t.top_bar_h

	sdl.fill(ren, 0, 0, W, h, t.bar, 255)
	sdl.fill(ren, 0, h - 1, W, 1, t.border, 255)

	-- 目录图标（小方块）+ 名字
	local badge = 30
	local bx, by = t.padding, math.floor((h - badge) / 2)

	sdl.fill(ren, bx, by, badge, badge, t.kind_color.dir, 60)
	sdl.frame(ren, bx, by, badge - 1, badge - 1, t.kind_color.dir, 180)
	sdl.fill(ren, bx + 3, by + 4, 10, 3, t.kind_color.dir, 220)

	local name = fs:display_name()

	local bold = self.cfg.font_bold_path()

	self.ttf.draw(ren, bold, name, t.font_title,
		bx + badge + 12, math.floor((h - t.font_title) / 2) - 2, t.text, "left")

	local namew = self.ttf.width(bold, name, t.font_title)
	local path_x = bx + badge + 12 + namew + 14
	local path_y = math.floor(h / 2) - t.font_small / 2
	-- 右侧：条目数
	local cnt = ("%d 项"):format(fs:count())
	local cntw = self.ttf.width(self.font, cnt, t.font_small)

	self.ttf.draw(ren, self.font, cnt, t.font_small,
		W - t.padding, path_y, t.text_dim, "right")

	-- 中央：盒子 IP + 当前时间（秒级，动态）
	local ip = self:ip() or "无网络"
	local cip = self.ttf.width(self.font, ip, t.font_small)
	local ctm = self.ttf.width(self.font, clock_text(), t.font_small)
	local csep = 16
	local cx = math.floor((W - (cip + csep + ctm)) / 2)
	local cy = path_y
	-- 窄屏（720/800 宽那种小显示器）三块会叠在一起：中间块先让位，
	-- 再不够就砍路径面包屑，最后连 IP/时钟都不画——宁可不显示，不要叠字。
	local center_right = cx + cip + csep + ctm

	if cx < path_x then
		-- 中间块挤到左边了：先试右对齐摆放
		cx = W - t.padding - cntw - 12 - (cip + csep + ctm)
		center_right = cx + cip + csep + ctm
	end

	local show_center = cx > path_x and center_right < W - t.padding - cntw - 12
	-- 首页的虚拟路径（home:）不是给人看的，显示成「应用」
	local shown_dir = fs.is_home and fs.is_home(self.cfg, fs.dir) and "应用" or fs.dir
	local show_path = path_x + self.ttf.width(self.font, shown_dir, t.font_small) + 12 <
		(show_center and cx or (W - t.padding - cntw - 12))

	if show_path then
		self.ttf.draw(ren, self.font, shown_dir, t.font_small,
			path_x, path_y, t.text_dim, "left")
	end
	if not show_center then return end

	self.ttf.draw(ren, self.font, ip, t.font_small, cx, cy, t.text_dim, "left")
	-- 中间一道竖线分隔，别用中文字符占宽
	sdl.fill(ren, cx + cip + math.floor(csep / 2), cy + 2, 1,
		t.font_small - 2, t.border, 255)
	self.ttf.draw(ren, self.font, clock_text(), t.font_small,
		cx + cip + csep, cy, t.text, "left")
end

local HINTS = {
	{ "◀▲▼▶", "移动" },
	{ "OK", "打开" },
	{ "BACK", "上一级" },
	{ "MENU", "刷新·换色" },
}

function M:draw_bottom(ren, fs, W, H, sdl)
	local t = self.theme
	local y = H - t.bottom_bar_h

	sdl.fill(ren, 0, y, W, t.bottom_bar_h, t.bar, 255)
	sdl.fill(ren, 0, y, W, 1, t.border, 255)

	local item = fs:current()
	local left = t.padding
	local ty = y + math.floor((t.bottom_bar_h - t.font_small) / 2)

	if item then
		local label = ("%s · %s"):format(item.name,
			self.cfg.KIND_LABEL[item.kind] or "文件")
		local info = item.dir and "" or ("  " .. fs.human_size(item.size))

		self.ttf.draw(ren, self.font, label, t.font_small, left, ty,
			t.text, "left")
		local w = self.ttf.width(self.font, label, t.font_small)

		if info ~= "" then
			self.ttf.draw(ren, self.font, info, t.font_small,
				left + w + 6, ty, t.text_dim, "left")
		end
	else
		self.ttf.draw(ren, self.font, "空目录", t.font_small, left, ty,
			t.text_dim, "left")
	end

	-- 右侧按键提示：从右往左排
	local x = W - t.padding

	for i = #HINTS, 1, -1 do
		local hint = HINTS[i]
		local kw = self.ttf.width(self.font, hint[1], t.font_small)
		local dw = self.ttf.width(self.font, hint[2], t.font_small)

		self.ttf.draw(ren, self.font, hint[2], t.font_small, x, ty,
			t.text_dim, "right")
		x = x - dw - 6
		self.ttf.draw(ren, self.font, hint[1], t.font_small, x, ty,
			t.accent, "right")
		x = x - kw - 22
	end
end

function M:draw_toast(ren, W, H, sdl)
	if not self.msg then return end
	local t = self.theme
	local pad = 16
	local tw = self.ttf.width(self.font, self.msg, t.font_small)
	local box_w = tw + pad * 2
	local box_h = t.font_small + pad
	local x = math.floor((W - box_w) / 2)
	local y = H - t.bottom_bar_h - box_h - 18

	sdl.fill(ren, x, y, box_w, box_h, t.panel, 240)
	sdl.frame(ren, x, y, box_w - 1, box_h - 1, self.color or t.accent, 200)
	self.ttf.draw(ren, self.font, self.msg, t.font_small,
		x + math.floor(box_w / 2), y + math.floor(pad / 2) + 1,
		self.color or t.text, "center")
end

return M
