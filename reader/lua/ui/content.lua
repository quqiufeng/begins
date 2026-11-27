-- 内容页绘制：PDF/EPUB/MOBI/AZW3/TXT。只读 ctx，不负责 layout/事件。
local M = {}

function M.draw(c)
    local sdl, ffi, ren = c.sdl, c.ffi, c.ren
    local set_color = c.set_color
    local W, H, S = c.W, c.H, c.S
    local is_txt, settings, theme = c.is_txt, c.settings, c.theme
    local line_texs = c.line_texs
    local tex, tex_w, tex_h = c.tex, c.tex_w, c.tex_h
    local v, page, total = c.v, c.page, c.total
    local txt_line_height = c.txt_line_height
    local chrome = c.chrome

    set_color(theme.paper)
    sdl.render_clear(ren)
    v.rects = {}
    local spread, top, bottom, avail_h = v.view_metrics()

    if is_txt then
        local line_h = txt_line_height()
        local card_x = math.max(S(24), S(settings.margin - 24))
        local card_top = v.fs and S(24) or S(72)
        local card = ffi.new("SDL_Rect")
        card.x, card.y, card.w, card.h = card_x, card_top, W - 2 * card_x, H - card_top - S(64)
        set_color(theme.card)
        sdl.render_fill_rect(ren, card)
        set_color(theme.line)
        sdl.render_draw_rect(ren, card)

        for i, t in ipairs(line_texs) do
            local r = ffi.new("SDL_Rect")
            r.x, r.y, r.w, r.h = S(settings.margin), card_top + S(24) + (i - 1) * line_h, t.w, t.h
            sdl.render_copy(ren, t.tex, nil, r)
        end
    elseif tex then
        local clip = ffi.new("SDL_Rect")
        clip.x, clip.y, clip.w, clip.h = 0, top, W, avail_h
        sdl.set_clip_rect(ren, clip)

        local page_bottom = math.max(tex_h or 0, v.p2h or 0)
        local maxs = math.max(0, page_bottom - avail_h)
        v.sy = math.max(0, math.min(maxs, v.sy or 0))
        local total_w_now = tex_w + (v.p2 and (S(5) + v.p2w) or 0)
        local max_pan = math.max(0, math.floor((total_w_now - W) / 2))
        v.pan_x = math.max(-max_pan, math.min(max_pan, v.pan_x or 0))
        local ybase
        if maxs <= 0 then
            ybase = top + math.floor((avail_h - page_bottom) / 2)
        else
            ybase = top - math.floor(v.sy)
        end

        local framed = v.p2 ~= nil
        local function draw_one(t, tw, th, x, index)
            if not t then return end
            local dst = ffi.new("SDL_Rect")
            dst.x = math.floor(x)
            dst.y = ybase
            dst.w = tw
            dst.h = th
            v.rects[#v.rects + 1] = {
                x = dst.x, y = dst.y, w = dst.w, h = dst.h, page = index,
            }

            if framed then
                local shadow = ffi.new("SDL_Rect")
                shadow.x, shadow.y, shadow.w, shadow.h = dst.x + S(4), dst.y + S(4), dst.w, dst.h
                set_color(theme.shadow)
                sdl.render_fill_rect(ren, shadow)
            end

            sdl.render_copy(ren, t, nil, dst)

            if framed then
                set_color(theme.line)
                sdl.render_draw_rect(ren, dst)
            end
        end

        if spread then
            local gap = S(5)
            local x = math.floor((W - total_w_now) / 2 + v.pan_x)
            draw_one(tex, tex_w, tex_h, x, page)
            if v.p2 then
                draw_one(v.p2, v.p2w, v.p2h, x + tex_w + gap, page + 1)
            end
        else
            draw_one(tex, tex_w, tex_h, (W - tex_w) / 2 + v.pan_x, page)
        end
        sdl.set_clip_rect(ren, nil)
    end

    if not v.fs then
        chrome:draw_title(ren)
        c.header:draw(ren)
    end

    chrome:draw_footer(ren)

    local bar_x = v.fs and S(16) or S(24)
    local bar_w = W - 2 * bar_x
    local bar_y = H - S(7)

    local bar_bg = ffi.new("SDL_Rect")
    bar_bg.x, bar_bg.y, bar_bg.w, bar_bg.h = bar_x, bar_y, bar_w, math.max(2, S(3))
    set_color(theme.line)
    sdl.render_fill_rect(ren, bar_bg)

    local bar_fg = ffi.new("SDL_Rect")
    bar_fg.x, bar_fg.y, bar_fg.w, bar_fg.h = bar_x, bar_y,
        math.floor(bar_w * (page + 1) / math.max(1, total)), math.max(2, S(3))
    set_color(theme.ink)
    sdl.render_fill_rect(ren, bar_fg)

end

return M
