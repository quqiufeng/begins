local ffi = require("ffi")
local sdl = require("ffi.sdl2")

local M = {}

local function px(n, s) return math.floor(n * s + 0.5) end

local function color(ren, c)
    sdl.set_draw_color(ren, c[1], c[2], c[3], c[4] or 255)
end

function M.frame(ren, W, H, theme, s, title_tex, title_w, title_h,
                 count_tex, count_w, count_h)
    color(ren, theme.paper)
    sdl.render_clear(ren)

    local card = ffi.new("SDL_Rect")
    card.x, card.y, card.w, card.h = px(24, s), px(24, s), W - px(48, s), H - px(48, s)
    color(ren, theme.card)
    sdl.render_fill_rect(ren, card)
    color(ren, theme.line)
    sdl.render_draw_rect(ren, card)

    if title_tex then
        local r = ffi.new("SDL_Rect")
        r.x, r.y, r.w, r.h = px(48, s), px(44, s), title_w, title_h
        sdl.render_copy(ren, title_tex, nil, r)
    end
    if count_tex then
        local r = ffi.new("SDL_Rect")
        r.x = W - px(48, s) - count_w
        r.y, r.w, r.h = px(50, s), count_w, count_h
        sdl.render_copy(ren, count_tex, nil, r)
    end

    color(ren, theme.line)
    local line = ffi.new("SDL_Rect")
    line.x, line.y, line.w, line.h = px(40, s), px(96, s), W - px(80, s), 1
    sdl.render_fill_rect(ren, line)
end

function M.items(ren, W, theme, s, top, line_h, texs, selected,
                 empty_tex, empty_w, empty_h)
    if #texs == 0 then
        if empty_tex then
            local r = ffi.new("SDL_Rect")
            r.x, r.y, r.w, r.h = px(48, s), top, empty_w, empty_h
            sdl.render_copy(ren, empty_tex, nil, r)
        end
        return
    end

    local y = top
    for _, t in ipairs(texs) do
        if t.index == selected then
            color(ren, theme.sel)
            local row = ffi.new("SDL_Rect")
            row.x, row.y, row.w, row.h = px(40, s), y - px(4, s), W - px(80, s), line_h
            sdl.render_fill_rect(ren, row)

            color(ren, theme.ink)
            local accent = ffi.new("SDL_Rect")
            accent.x, accent.y, accent.w, accent.h = px(40, s), y - px(4, s), px(4, s), line_h
            sdl.render_fill_rect(ren, accent)
        end

        local r = ffi.new("SDL_Rect")
        r.x, r.y, r.w, r.h = px(56, s), y, t.w, t.h
        sdl.render_copy(ren, t.tex, nil, r)

        color(ren, theme.line)
        local line = ffi.new("SDL_Rect")
        line.x, line.y, line.w, line.h = px(40, s), y + line_h - 1, W - px(80, s), 1
        sdl.render_fill_rect(ren, line)

        y = y + line_h
    end
end

function M.hint(ren, H, s, tex, w, h)
    if not tex then return end
    local r = ffi.new("SDL_Rect")
    r.x, r.y, r.w, r.h = px(48, s), H - px(56, s), w, h
    sdl.render_copy(ren, tex, nil, r)
end

return M
