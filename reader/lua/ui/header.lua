-- 顶部工具栏：动作文字、布局与点击命中。
local M = {}
M.__index = M

local KEYS = { "bm", "st", "fs", "max", "eye", "dual", "shot", "text", "open" }
local DRAW_ORDER = { "st", "bm", "fs", "max", "eye", "dual", "shot", "text", "open" }

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:destroy()
    local sdl = self.ctx.sdl
    for _, k in ipairs(KEYS) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
end

function M:rebuild()
    local ctx = self.ctx
    local v = ctx.v
    local W = ctx.get_w()
    local S = ctx.S
    local f_page = ctx.get_font()
    local theme = ctx.get_theme()
    self:destroy()

    local labels = {
        bm = "书签", st = "设置", fs = "全屏",
        max = v.max and "还原" or "最大化", eye = "换色",
        dual = (v.fs or v.dual) and "单栏" or "双栏",
        shot = "截图", text = "文字", open = "打开",
    }
    for _, k in ipairs(KEYS) do
        local tex, w, h = v.make_text(labels[k], f_page, theme.muted)
        self[k .. "_tex"], self[k .. "_w"], self[k .. "_h"] = tex, w, h
    end

    self.fs_x = W - S(24) - (self.fs_w or 0)
    self.max_x = self.fs_x - S(14) - (self.max_w or 0)
    self.eye_x = self.max_x - S(14) - (self.eye_w or 0)
    self.dual_x = self.eye_x - S(14) - (self.dual_w or 0)
    self.shot_x = self.dual_x - S(14) - (self.shot_w or 0)
    self.text_x = self.shot_x - S(14) - (self.text_w or 0)
    self.open_x = self.text_x - S(14) - (self.open_w or 0)
    self.bm_x = self.open_x - S(14) - (self.bm_w or 0)
    self.st_x = self.bm_x - S(14) - (self.st_w or 0)
end

function M:draw(ren)
    local ctx = self.ctx
    local sdl, ffi, S = ctx.sdl, ctx.ffi, ctx.S
    local W, H = ctx.get_wh()
    local theme = ctx.get_theme()

    for _, k in ipairs(DRAW_ORDER) do
        local tex = self[k .. "_tex"]
        if tex then
            local r = ffi.new("SDL_Rect")
            r.x, r.y = self[k .. "_x"], S(20)
            r.w, r.h = self[k .. "_w"], self[k .. "_h"]
            sdl.render_copy(ren, tex, nil, r)
        end
    end

    ctx.set_color(theme.line)
    local line = ffi.new("SDL_Rect")
    line.x, line.y, line.w, line.h = S(24), S(58), W - S(48), 1
    sdl.render_fill_rect(ren, line)
    line.y = H - S(50)
    sdl.render_fill_rect(ren, line)
end

function M:hit(x)
    if x >= self.fs_x then return "fs"
    elseif x >= self.max_x then return "max"
    elseif x >= self.eye_x then return "eye"
    elseif x >= self.dual_x then return "dual"
    elseif x >= self.shot_x then return "shot"
    elseif x >= self.text_x then return "text"
    elseif x >= self.open_x then return "open"
    elseif x >= self.bm_x then return "bm"
    elseif x >= self.st_x then return "st"
    end
end

function M:any(x)
    return x >= self.st_x
end

return M
