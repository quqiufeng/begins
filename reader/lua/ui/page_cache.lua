-- 页纹理 LRU 缓存。entry = { tex, w, h }
local M = {}
M.__index = M

function M.new(sdl, max)
    return setmetatable({ sdl = sdl, max = max or 4, map = {}, order = {} }, M)
end

function M:clear()
    for _, e in pairs(self.map) do
        if e.tex then self.sdl.destroy_texture(e.tex) end
    end
    self.map = {}
    self.order = {}
end

function M:put(key, entry)
    if not key or not entry or not entry.tex then return end
    if self.map[key] then
        local old = self:take(key)
        if old and old.tex then self.sdl.destroy_texture(old.tex) end
    end
    self.map[key] = entry
    self.order[#self.order + 1] = key
    while #self.order > self.max do
        local old = table.remove(self.order, 1)
        local e = self.map[old]
        if e then
            self.map[old] = nil
            if e.tex then self.sdl.destroy_texture(e.tex) end
        end
    end
end

function M:take(key)
    local e = self.map[key]
    if not e then return nil end
    self.map[key] = nil
    for i, k in ipairs(self.order) do
        if k == key then table.remove(self.order, i); break end
    end
    return e
end

return M
