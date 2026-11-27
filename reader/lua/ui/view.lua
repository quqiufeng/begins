-- ViewState 纯函数：窗口目标尺寸、内容签名、layout key。
local M = {}

function M.target_size(win, sdl, sx, sy, W, H)
    local ww, wh = sdl.get_window_size(win)
    return math.floor((ww or W) * (sx or 1) + 0.5),
           math.floor((wh or H) * (sy or 1) + 0.5)
end

function M.signature(p)
    return table.concat({
        p.spread and 1 or 0,
        p.target_w or 0,
        p.reflow and (p.avail_h or 0) or 0,
        p.zoom or 1,
        p.font_size or 22,
        p.line_factor or 1.6,
        p.margin or 72,
        p.dark and 1 or 0,
        p.page_bg or 0,
    }, ":")
end

function M.layout_width(target_w)
    return math.max(600, target_w or 600)
end

return M
