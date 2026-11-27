-- 渲染区域分发。只有 content 需要 layout/raster；其余区域直接绘制。
local M = {}

local ORDER = {
    { "browser", "browser" },
    { "toc", "toc" },
    { "bookmarks", "bookmarks" },
    { "settings", "settings" },
    { "library", "library" },
}

function M.kind(state)
    for _, it in ipairs(ORDER) do
        if state[it[1]] then return it[2] end
    end
    return "content"
end

function M.draw(kind, handlers)
    local fn = handlers[kind] or handlers.content
    assert(fn, "no renderer for " .. tostring(kind))
    fn()
    return kind
end

return M
