-- ui/icons.lua — 类别图标（assets/icons/<kind>.png）
--
-- 主题图标是 SVG，SDL2_image 解不了，所以由 tools/gen-icons.sh 预先转成 PNG
-- 放在 assets/icons/。这里只做：懒加载 + 按 kind 缓存 + 等比缩放进框。
-- 缺图时返回 nil，调用方退回原来的文字徽章（保证没有 assets 也能跑）。

local M = {}
M.__index = M

local floor, min = math.floor, math.min

function M.new(cfg, sdl, img)
	return setmetatable({ cfg = cfg, sdl = sdl, img = img, cache = {} }, M)
end

function M:get(ren, kind)
	if not self.img or not self.img.available then return nil end
	if not kind or kind == "" then return nil end

	local hit = self.cache[kind]

	if hit ~= nil then return hit or nil end

	local dir = self.cfg.icons_dir or (self.cfg.assets_dir and (self.cfg.assets_dir .. "/icons"))
	local tex = dir and self.img.texture(ren, dir .. "/" .. kind .. ".png") or nil

	self.cache[kind] = tex or false
	return tex
end

-- 等比缩放到 (x,y,w,h) 框内并居中，返回是否画了
function M:draw(ren, kind, x, y, w, h)
	local tex = self:get(ren, kind)

	if not tex then return false end
	local tw, th = self.sdl.tex_size(tex)

	if tw <= 0 or th <= 0 then return false end

	local s = min(w / tw, h / th)
	local dw, dh = floor(tw * s), floor(th * s)

	self.sdl.copy(ren, tex, { x = x + floor((w - dw) / 2), y = y + floor((h - dh) / 2),
		w = dw, h = dh })
	return true
end

function M:destroy()
	for k, tex in pairs(self.cache) do
		if tex then self.sdl.destroy_texture(tex) end
		self.cache[k] = nil
	end
end

return M
