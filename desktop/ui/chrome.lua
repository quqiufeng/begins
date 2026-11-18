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
	return os.date("%H:%M")
end

function M:draw_top(ren, fs, W, sdl)
	local t = self.theme
	local h = t.top_bar_h

	sdl.fill(ren, 0, 0, W, h, t.bar, 255)
	sdl.fill(ren, 0, h - 1, W, 1, t.border, 255)

	-- 目录图标（小方块）+ 名字
	local badge = 26
	local bx, by = t.padding, math.floor((h - badge) / 2)

	sdl.fill(ren, bx, by, badge, badge, t.kind_color.dir, 60)
	sdl.frame(ren, bx, by, badge - 1, badge - 1, t.kind_color.dir, 180)
	sdl.fill(ren, bx + 3, by + 4, 8, 3, t.kind_color.dir, 220)

	local name = fs:display_name()

	local bold = self.cfg.font_bold_path()

	self.ttf.draw(ren, bold, name, t.font_title,
		bx + badge + 10, math.floor((h - t.font_title) / 2) - 2, t.text, "left")

	local namew = self.ttf.width(bold, name, t.font_title)

	self.ttf.draw(ren, self.font, fs.dir, t.font_small,
		bx + badge + 12 + namew + 14, math.floor(h / 2) - t.font_small / 2,
		t.text_dim, "left")

	-- 右侧：条目数 + 时钟
	self.ttf.draw(ren, self.font, ("%d 项"):format(fs:count()), t.font_small,
		W - t.padding - 60, math.floor(h / 2) - t.font_small / 2, t.text_dim, "right")
	self.ttf.draw(ren, self.font, clock_text(), t.font_small,
		W - t.padding, math.floor(h / 2) - t.font_small / 2, t.text_dim, "right")
end

local HINTS = {
	{ "◀▲▼▶", "移动" },
	{ "OK", "打开" },
	{ "BACK", "上一级" },
	{ "MENU", "刷新" },
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
