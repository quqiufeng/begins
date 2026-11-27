-- ui/icons.lua — 类别图标（assets/icons/<kind>.png）
--
-- 主题图标是 SVG，SDL2_image 解不了，所以由 tools/gen-icons.sh 预先转成 PNG
-- 放在 assets/icons/。这里只做：懒加载 + 按 kind 缓存 + 等比缩放进框。
-- 缺图时返回 nil，调用方退回原来的文字徽章（保证没有 assets 也能跑）。
--
-- 两条必须守住的规矩（都踩过）：
--   1. 加载失败只算「暂时」，隔 RETRY_MS 再试一次。以前把 false 永久写进缓存，
--      文件晚到或者被 cp 写了一半，图标就再也不出来了。
--   2. 外部 app（阅读器/播放器）抢过 KMS 之后 renderer 被销毁重建，所有纹理
--      全部作废，必须由 window 的 before_suspend 钩子调 clear(false) 丢引用；
--      否则 cache 里留着死纹理，tex_size 返回 0 → 图标永久消失。

local M = {}
M.__index = M

local floor, min = math.floor, math.min
local RETRY_MS = 2000

function M.new(cfg, sdl, img)
	return setmetatable({ cfg = cfg, sdl = sdl, img = img, cache = {}, fail = {} }, M)
end

function M:get(ren, kind)
	if not self.img or not self.img.available then return nil end
	if not kind or kind == "" then return nil end

	local hit = self.cache[kind]

	if hit then return hit end

	-- 刚失败过就先别急着再 IO 一遍
	local at = self.fail[kind]

	if at and self.sdl and self.sdl.ticks and (self.sdl.ticks() - at) < RETRY_MS then
		return nil
	end

	local dir = self.cfg.icons_dir or (self.cfg.assets_dir and (self.cfg.assets_dir .. "/icons"))
	local tex = dir and self.img.texture(ren, dir .. "/" .. kind .. ".png") or nil

	if tex then
		self.cache[kind], self.fail[kind] = tex, nil
		return tex
	end
	self.fail[kind] = (self.sdl and self.sdl.ticks and self.sdl.ticks()) or 0
	return nil
end

-- 等比缩放到 (x,y,w,h) 框内并居中，返回是否画了
function M:draw(ren, kind, x, y, w, h)
	local tex = self:get(ren, kind)

	if not tex then return false end
	local tw, th = self.sdl.tex_size(tex)

	if tw <= 0 or th <= 0 then
		-- 纹理已死（renderer 重建过）：丢掉，下次重新加载
		self.cache[kind] = nil
		return false
	end

	local s = min(w / tw, h / th)
	local dw, dh = floor(tw * s), floor(th * s)

	self.sdl.copy(ren, tex, { x = x + floor((w - dw) / 2), y = y + floor((h - dh) / 2),
		w = dw, h = dh })
	return true
end

-- destroy=true 真正释放纹理；renderer 已经被销毁时只能 destroy=false 丢引用
function M:clear(destroy)
	for k, tex in pairs(self.cache) do
		if destroy and tex and self.sdl and self.sdl.destroy_texture then
			self.sdl.destroy_texture(tex)
		end
		self.cache[k] = nil
	end
	self.fail = {}
end

function M:destroy() self:clear(true) end

return M
