-- ui/window.lua — SDL 窗口/渲染器生命周期（含"把屏幕让出去"）
--
-- 桌面上要起外部 app（reader / 播放器）时，它们也要抢 DRM/KMS：
-- 所以必须先 suspend()：清纹理 → 销毁 renderer/window → SDL_QuitSubSystem(VIDEO)，
-- 等外部 app 退出再 resume() 重新 init。hooks 用来在两侧清缓存。

local M = {}
M.__index = M

function M.new(cfg, sdl, ttf)
	local self = setmetatable({ cfg = cfg, sdl = sdl, ttf = ttf, hooks = {} }, M)

	return self
end

function M:open()
	local cfg, sdl = self.cfg, self.sdl

	if not sdl.init() then return nil, "SDL_Init: " .. sdl.err() end
	-- TTF 也要 init：不然 TTF_OpenFont 全返回 nil，文字静默不画
	if self.ttf then
		local ok, e = self.ttf.init()
		if not ok then sdl.quit(); return nil, e end
	end
	-- kmsdrm 上不要独占键盘（keybd 才是遥控的主人），只当普通输入源
	if sdl.video_driver() == "KMSDRM" then sdl.set_hint("SDL_HINT_KMSDRM_REQUIRE_DRM_MASTER", "0") end
	local win = sdl.create_window(cfg.title, cfg.width, cfg.height, {
		fullscreen = cfg.fullscreen, resizable = not cfg.fullscreen,
	})

	if not win then sdl.quit(); return nil, "SDL_CreateWindow: " .. sdl.err() end
	local ren = sdl.create_renderer(win, false)

	if not ren then
		sdl.destroy(nil, win); sdl.quit()
		return nil, "SDL_CreateRenderer: " .. sdl.err()
	end
	local w, h = sdl.output_size(ren)

	self.win, self.ren = win, ren
	self.W = w or cfg.width
	self.H = h or cfg.height
	self.driver = sdl.video_driver()
	if not cfg.windowed then sdl.show_cursor(false) end
	return true
end

function M:suspend()
	if not self.ren and not self.win then return end
	if self.hooks.before_suspend then pcall(self.hooks.before_suspend) end
	if self.ttf then self.ttf.clear() end
	self.sdl.destroy(self.ren, self.win)
	self.ren, self.win = nil, nil
	self.sdl.quit_video()
end

function M:resume()
	local ok, err = self:open()

	if not ok then return false, err end
	if self.hooks.after_resume then pcall(self.hooks.after_resume) end
	return true
end

-- 窗口尺寸（resize 后要通知 grid 重算）
function M:refresh_size()
	if not self.ren then return false end
	local w, h = self.sdl.output_size(self.ren)

	if not w then return false end
	if w == self.W and h == self.H then return false end
	self.W, self.H = w, h
	return true
end

function M:present() if self.ren then self.sdl.present(self.ren) end end

function M:close()
	self:suspend()
	self.sdl.quit()
end

return M
