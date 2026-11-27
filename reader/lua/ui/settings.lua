-- 设置面板：主题 / 字号 / 行距 / 边距。
local themes = require("ui.themes")

local M = {}

local list = require("ui.list")
M.__index = M

local function cycle(list, value, delta)
    local idx = 1
    for i, x in ipairs(list) do
        if x == value then idx = i end
    end
    idx = ((idx - 1 + delta) % #list) + 1
    return list[idx]
end

function M.new(ctx)
    return setmetatable({
        ctx = ctx,
        open = false,
        selected = 1,
        texs = {},
    }, M)
end

function M:destroy()
    local sdl = self.ctx.sdl
    for _, t in ipairs(self.texs) do sdl.destroy_texture(t.tex) end
    self.texs = {}
    for _, k in ipairs({ "title", "hint" }) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
end

function M:close()
    self:destroy()
    self.open = false
end

function M:rows()
    local s = self.ctx.get_settings()
    return {
        "主题    " .. (themes.NAMES[s.theme] or s.theme),
        string.format("字号    %d", s.font_size),
        string.format("行距    %.1f", s.line_factor),
        string.format("边距    %d", s.margin),
    }
end

function M:rebuild()
    local ctx = self.ctx
    for _, t in ipairs(self.texs) do ctx.sdl.destroy_texture(t.tex) end
    local rows = self:rows()
    self.texs, self.selected = list.rebuild({
        ttf = ctx.ttf, ren = ctx.ren, font = ctx.get_fonts(),
        theme = ctx.get_theme(), items = rows,
        selected = self.selected, visible = math.max(1, #rows),
        text = function(row) return row end,
    })
end

function M:build_texts()
    local ctx = self.ctx
    local v = ctx.v
    local _, f_title, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()
    if self.title_tex then ctx.sdl.destroy_texture(self.title_tex); self.title_tex = nil end
    if self.hint_tex then ctx.sdl.destroy_texture(self.hint_tex); self.hint_tex = nil end
    self.title_tex, self.title_w, self.title_h = v.make_text("设置", f_title, theme.ink)
    self.hint_tex, self.hint_w, self.hint_h = v.make_text(
        "↑/↓ 选择 · ←/→ 调整 · S/Esc 关闭", f_page, theme.muted)
end

function M:show()
    local ctx = self.ctx
    ctx.close_others()
    self.open = true
    self.selected = 1
    self:build_texts()
    self:rebuild()
end

function M:toggle()
    if self.open then self:close() else self:show() end
end

function M:refresh()
    if not self.open then return end
    self:build_texts()
    self:rebuild()
end

function M:move(delta)
    self.selected = math.max(1, math.min(4, self.selected + delta))
    self:rebuild()
end

function M:adjust(delta)
    local ctx = self.ctx
    local s = ctx.get_settings()
    if self.selected == 1 then
        s.theme = cycle(themes.ORDER, s.theme, delta)
    elseif self.selected == 2 then
        s.font_size = cycle(themes.FONT_ORDER, s.font_size, delta)
    elseif self.selected == 3 then
        s.line_factor = cycle(themes.LINE_ORDER, s.line_factor, delta)
    elseif self.selected == 4 then
        s.margin = cycle(themes.MARGIN_ORDER, s.margin, delta)
    end
    if self.selected >= 2 then ctx.v.pending_layout = ctx.v.reflow end
    ctx.apply()
end

function M:draw()
    local ctx = self.ctx
    local W, H = ctx.get_wh()
    local theme = ctx.get_theme()
    local top, line_h = ctx.get_list_layout()
    ctx.panel.frame(ctx.ren, W, H, theme, ctx.v.ui_scale,
        self.title_tex, self.title_w, self.title_h, nil, 0, 0)
    ctx.panel.items(ctx.ren, W, theme, ctx.v.ui_scale, top, line_h,
        self.texs, self.selected, nil, 0, 0)
    ctx.panel.hint(ctx.ren, H, ctx.v.ui_scale, self.hint_tex, self.hint_w, self.hint_h)
end

return M
