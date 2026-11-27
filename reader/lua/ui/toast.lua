-- 轻量提示条：显示、绘制、超时清理。
local M = {}
M.__index = M

function M.new(deps)
    return setmetatable({ d = deps }, M)
end

function M:show(text, seconds)
    local d = self.d
    local v = d.v
    if v.toast_tex then d.sdl.destroy_texture(v.toast_tex); v.toast_tex = nil end
    v.toast = text
    v.toast_tex, v.toast_w, v.toast_h = d.make_text(text, d.f_page, d.get_theme().text)
    v.toast_until = d.now() + (seconds or 3)
    v.dirty = true
end

function M:draw()
    local d = self.d
    local v = d.v
    if not v.toast or not v.toast_tex then return end
    if d.now() >= (v.toast_until or 0) then return end
    local pad = d.S(18)
    local W, H = d.get_wh()
    local bw = v.toast_w + pad * 2
    local bh = v.toast_h + pad
    local x = math.floor((W - bw) / 2)
    local y = H - bh - d.S(70)
    local box = d.ffi.new("SDL_Rect")
    box.x, box.y, box.w, box.h = x, y, bw, bh
    local theme = d.get_theme()
    d.set_color(theme.card)
    d.sdl.render_fill_rect(d.ren, box)
    d.set_color(theme.line)
    d.sdl.render_draw_rect(d.ren, box)
    local tr = d.ffi.new("SDL_Rect")
    tr.x, tr.y, tr.w, tr.h = x + pad, y + math.floor(pad / 2), v.toast_w, v.toast_h
    d.sdl.render_copy(d.ren, v.toast_tex, nil, tr)
end

function M:tick(now)
    local d = self.d
    local v = d.v
    if v.toast and now >= (v.toast_until or 0) then
        v.toast = nil
        if v.toast_tex then d.sdl.destroy_texture(v.toast_tex); v.toast_tex = nil end
        v.dirty = true
    end
end

function M:clear()
    local d = self.d
    local v = d.v
    if v.toast_tex then d.sdl.destroy_texture(v.toast_tex); v.toast_tex = nil end
    v.toast = nil
end

return M
