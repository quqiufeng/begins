-- 书页外框：左上书名与右下页码。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({
        ctx = ctx,
        title_tex = nil, title_w = 0, title_h = 0,
        page_tex = nil, page_w = 0, page_h = 0,
    }, M)
end

function M:destroy()
    local sdl = self.ctx.sdl
    for _, k in ipairs({ "title", "page" }) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
end

local function fit_width(ctx, font, text, max_w)
    if not max_w or max_w <= 0 then return text end
    local ttf, utf8_chars = ctx.ttf, ctx.utf8_chars
    if not ttf or not utf8_chars or ttf.size(font, text) <= max_w then return text end
    local ell = "…"
    local ell_w = ttf.size(font, ell)
    local out, acc = {}, 0
    for ch in utf8_chars(text) do
        local cw = ttf.size(font, ch)
        if acc + cw + ell_w > max_w then break end
        out[#out + 1] = ch
        acc = acc + cw
    end
    return table.concat(out) .. ell
end

function M:refresh()
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local _, f_title, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()

    if self.title_tex then ctx.sdl.destroy_texture(self.title_tex); self.title_tex = nil end
    local title = ctx.get_title()
    local max_w = ctx.get_title_max_w and ctx.get_title_max_w()
    self.title_tex, self.title_w, self.title_h =
        v.make_text(fit_width(ctx, f_title, title, max_w), f_title, theme.ink)

    local ptxt
    if R.chapter_mode then
        if (v.fs or v.dual) and R.page + 2 <= R.total then
            ptxt = string.format("第 %d-%d 页", R.page + 1, R.page + 2)
        else
            ptxt = string.format("第 %d 页", R.page + 1)
        end
    elseif (v.fs or v.dual) and not R.is_txt and R.doc and R.page > 0 and R.page + 2 <= R.total then
        ptxt = string.format("%d-%d / %d", R.page + 1, R.page + 2, R.total)
    else
        ptxt = string.format("%d / %d", R.page + 1, R.total)
    end
    if v.zoom and v.zoom ~= 1 then
        ptxt = ptxt .. string.format(" · %d%%", math.floor(v.zoom * 100 + 0.5))
    end

    if self.page_tex then ctx.sdl.destroy_texture(self.page_tex); self.page_tex = nil end
    self.page_tex, self.page_w, self.page_h = v.make_text(ptxt, f_page, theme.muted)
end

function M:draw_title(ren)
    if not self.title_tex then return end
    local ctx = self.ctx
    local r = ctx.ffi.new("SDL_Rect")
    r.x, r.y, r.w, r.h = ctx.S(24), ctx.S(18), self.title_w, self.title_h
    ctx.sdl.render_copy(ren, self.title_tex, nil, r)
end

function M:draw_footer(ren)
    if not self.page_tex then return end
    local ctx = self.ctx
    local v = ctx.v
    local W, H = ctx.get_w(), ctx.get_h()
    local r = ctx.ffi.new("SDL_Rect")
    if v.fs then
        r.x, r.y = math.floor((W - self.page_w) / 2), H - self.page_h - ctx.S(12)
    else
        r.x, r.y = W - self.page_w - ctx.S(24), H - ctx.S(38)
    end
    r.w, r.h = self.page_w, self.page_h
    ctx.sdl.render_copy(ren, self.page_tex, nil, r)
end

return M
