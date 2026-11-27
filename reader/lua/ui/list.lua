-- 列表面板公共逻辑：可见窗口计算与行纹理重建。
local M = {}

function M.range(n, selected, visible)
    if n <= 0 then return 1, 1, 0 end
    selected = math.max(1, math.min(n, selected or 1))
    visible = math.max(1, visible or n)
    local first = math.max(1, selected - math.floor(visible / 2))
    if first + visible - 1 > n then
        first = math.max(1, n - visible + 1)
    end
    return selected, first, math.min(n, first + visible - 1)
end

-- o: ttf, ren, font, theme, items, selected, visible, text(item, index)
function M.rebuild(o)
    local items = o.items or {}
    local n = #items
    local selected, first, last = M.range(n, o.selected, o.visible)
    local texs = {}
    if n == 0 then return texs, selected, first end

    for i = first, last do
        local text = o.text(items[i], i)
        if text then
            local w, h = o.ttf.size(o.font, text)
            local c = (i == selected) and o.theme.ink or o.theme.text
            local t = o.ttf.render_texture(o.ren, o.font, text, c[1], c[2], c[3], 255)
            if t then
                texs[#texs + 1] = { tex = t, w = w, h = h, index = i }
            end
        end
    end
    return texs, selected, first
end

return M
