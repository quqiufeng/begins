-- LayoutManager：按尺寸/字体/行距/边距去重，避免重复 fz_layout_document。
local M = {}
M.__index = M

function M.new(rd)
    return setmetatable({ rd = rd, key = nil, total = 0 }, M)
end

function M:reset()
    self.key = nil
    self.total = 0
end

function M:apply(doc, width, height, em, line_factor, margin)
    local key = string.format("%d:%d:%.2f:%.2f:%d",
        width, height, em, line_factor, margin)
    if self.key == key then
        return self.total, true
    end
    local t0
    if os.getenv("READER_PROF") then t0 = require("core.clock").now() end
    local total = self.rd.layout(doc, width, height, em, line_factor, margin)
    if t0 then
        io.stderr:write(string.format(
            "[prof] layout.apply %dx%d em=%.1f mg=%d %.1f ms\n",
            width, height, em, margin,
            (require("core.clock").now() - t0) * 1000))
    end
    if total and total > 0 then
        self.key = key
        self.total = total
        return total, false
    end
    return nil, false
end

return M
