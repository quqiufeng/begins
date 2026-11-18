-- ui/preview.lua — 图片全屏预览（桌面内自己画，不启外部 app）
--
-- 打开一张图 → 收集当前目录里的同类图片做播放列表，左右翻，ESC/BACK 退出。
-- 走 SDL2_image；库不在就退化成"不支持预览"的 toast。

local M = {}
M.__index = M

function M.new(cfg, sdl, img, ttf)
	local font = (type(cfg.font_path) == "function") and cfg.font_path() or cfg.font_path

	return setmetatable({
		cfg = cfg, sdl = sdl, img = img, ttf = ttf, font = font,
		list = {}, idx = 1, tex = nil, tex_path = nil, open = false,
	}, M)
end

function M:clear_tex()
	if self.tex then self.sdl.destroy_texture(self.tex) end
	self.tex, self.tex_path = nil, nil
end

function M:load()
	local item = self.list[self.idx]

	if not item then return end
	if self.tex_path == item.path then return end
	self:clear_tex()
	local tex = self.img.texture(self.ren, item.path)

	self.tex = tex
	self.tex_path = item.path
end

function M:show(fs, path)
	local list = {}

	for i = 1, fs:count() do
		local it = fs:at(i)

		if it and it.kind == "image" then list[#list + 1] = it end
	end
	if #list == 0 then return false, "当前目录没有图片" end
	self.list = list
	self.idx = 1
	for i, it in ipairs(list) do
		if it.path == path then self.idx = i; break end
	end
	self.open = true
	self.tex_path = nil
	return true
end

function M:close()
	self.open = false
	self:clear_tex()
	self.list, self.idx = {}, 1
end

function M:step(d)
	if #self.list == 0 then return false end
	self.idx = (self.idx - 1 + d) % #self.list + 1
	self.tex_path = nil
	return true
end

-- 返回 true 表示这个键被预览吃掉了
function M:key(name)
	if not self.open then return false end
	if name == "LEFT" or name == "PAGEUP" then self:step(-1); return true end
	if name == "RIGHT" or name == "PAGEDOWN" then self:step(1); return true end
	if name == "BACK" or name == "ESC" or name == "EXIT" or name == "ENTER" or name == "OK" then
		self:close()
		return true
	end
	return false
end

function M:draw(ren, W, H)
	if not self.open then return end
	local sdl, t = self.sdl, nil

	self.ren = ren
	self:load()
	sdl.fill(ren, 0, 0, W, H, 0x000000, 180)

	local item = self.list[self.idx]
	local title = ("%d/%d  %s"):format(self.idx, #self.list, item and item.name or "")

	if self.tex then
		local tw, th = sdl.tex_size(self.tex)
		local avail_w, avail_h = W - 80, H - 120
		local scale = math.min(avail_w / math.max(1, tw), avail_h / math.max(1, th))
		local dw, dh = math.floor(tw * scale), math.floor(th * scale)
		local dst = {
			x = math.floor((W - dw) / 2), y = math.floor((H - dh) / 2) - 10,
			w = dw, h = dh,
		}

		sdl.copy(ren, self.tex, dst)
	else
		self.ttf.draw(ren, self.font, "无法解码这张图", 20, W / 2, H / 2,
			0xE0644A, "center")
	end
	self.ttf.draw(ren, self.font, title, 16, W / 2, H - 52, 0xE6EDF3, "center")
	self.ttf.draw(ren, self.font, "◀▶ 切换    OK/BACK 关闭", 14, W / 2, H - 26,
		0x8B949E, "center")
end

return M
