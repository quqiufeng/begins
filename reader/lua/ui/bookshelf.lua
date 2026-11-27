-- 书库面板：阅读历史扫描、列表渲染、打开与清理。
local M = {}

local list = require("ui.list")
M.__index = M

local FMT_MAP = {
    pdf = "PDF", epub = "EPUB", mobi = "MOBI", azw3 = "AZW3",
    txt = "TXT", chm = "CHM", cbz = "CBZ", cbr = "CBR",
}

local function clear_fields(rec)
    if not rec then return end
    rec.page = 0
    rec.chapter = nil
    rec.updated = nil
end

local function has_history(rec)
    return rec and ((rec.updated or 0) > 0 or (rec.page or 0) > 0)
end

function M.new(ctx)
    local S = ctx.S
    return setmetatable({
        ctx = ctx,
        open = false,
        items = {},
        selected = 1,
        first = 1,
        texs = {},
        dir = "",
        line_h = S(44),
        visible = 12,
        top = S(120),
        open_tex = nil, open_w = 0, open_h = 0, open_x = 0,
        clear_tex = nil, clear_w = 0, clear_h = 0, clear_x = 0,
        ui_w = 0, ui_h = 0,
    }, M)
end

function M:destroy()
    local sdl = self.ctx.sdl
    for _, t in ipairs(self.texs) do sdl.destroy_texture(t.tex) end
    self.texs = {}
    for _, k in ipairs({ "title", "count", "hint", "empty", "open", "clear" }) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
end

function M:scan()
    local ctx = self.ctx
    local env = os.getenv("READER_LIBRARY")
    local home = ctx.get_home()
    local candidates = {}
    if env and env ~= "" then candidates[#candidates + 1] = env end
    candidates[#candidates + 1] = home .. "/Books"
    candidates[#candidates + 1] = home .. "/Downloads/book"

    local scanned = {}
    self.dir = env or ""
    for _, d in ipairs(candidates) do
        local items = ctx.library.scan(d)
        if items and #items > 0 then
            scanned = items
            self.dir = d
            break
        end
    end

    local progress = ctx.get_progress()
    self.items = {}
    local seen = {}
    for _, it in ipairs(scanned) do
        seen[it.path] = true
        local rec = progress[it.path]
        if has_history(rec) then
            it.updated = (rec.updated and rec.updated > 0) and rec.updated or 0
            self.items[#self.items + 1] = it
        end
    end

    -- 文件选择器/DAV 打开的书可能不在扫描目录里，也要进入历史列表。
    for path, rec in pairs(progress) do
        if not seen[path] and has_history(rec) then
            local f = io.open(path, "rb")
            if f then
                f:close()
                local ext = path:match("%.([%w]+)$")
                ext = ext and ext:lower() or ""
                self.items[#self.items + 1] = {
                    path = path,
                    name = path:match("([^/]+)$") or path,
                    format = FMT_MAP[ext] or ext:upper(),
                    updated = (rec.updated and rec.updated > 0) and rec.updated or 0,
                }
            end
        end
    end

    table.sort(self.items, function(a, b)
        if (a.updated or 0) ~= (b.updated or 0) then
            return (a.updated or 0) > (b.updated or 0)
        end
        return (a.name or "") < (b.name or "")
    end)
end

function M:rebuild()
    local ctx = self.ctx
    for _, t in ipairs(self.texs) do ctx.sdl.destroy_texture(t.tex) end
    self.texs, self.selected, self.first = list.rebuild({
        ttf = ctx.ttf, ren = ctx.ren, font = ctx.get_fonts(),
        theme = ctx.get_theme(), items = self.items,
        selected = self.selected, visible = self.visible,
        text = function(it) return string.format("%s   %s", it.format, it.name) end,
    })
end

function M:refresh()
    local ctx = self.ctx
    local v = ctx.v
    local sdl, S = ctx.sdl, ctx.S
    local W, H = ctx.get_wh()
    local f_body, f_title, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()
    for _, k in ipairs({ "title", "count", "hint", "empty", "open", "clear" }) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end

    self.title_tex, self.title_w, self.title_h = v.make_text("书库", f_title, theme.ink)
    self.count_tex, self.count_w, self.count_h = v.make_text(
        string.format("%d 本", #self.items), f_page, theme.muted)
    self.open_tex, self.open_w, self.open_h = v.make_text("＋ 打开新书", f_page, theme.ink)
    self.clear_tex, self.clear_w, self.clear_h = v.make_text("清空历史", f_page, theme.muted)
    self.open_x = W - S(48) - self.count_w - S(24) - self.open_w
    self.clear_x = self.open_x - S(16) - self.clear_w
    self.hint_tex, self.hint_w, self.hint_h = v.make_text(
        "↑/↓ 选择 · Enter 打开 · Delete 清历史 · Shift+Delete 清空 · O 新书 · Esc 退出",
        f_page, theme.muted)
    if #self.items == 0 then
        self.empty_tex, self.empty_w, self.empty_h = v.make_text(
            "暂无阅读历史 · 打开新书开始阅读", f_body, theme.muted)
    end
    self.ui_w, self.ui_h = W, H
    self:rebuild()
end

function M:show()
    local ctx = self.ctx
    ctx.close_others()
    ctx.save_progress()
    ctx.close_book()
    self.open = true
    self:scan()
    self.selected = 1
    self.first = 1
    self:refresh()
    ctx.sdl.stop_text_input()
end

function M:close()
    self.open = false
    self:destroy()
end

function M:move(delta)
    if #self.items == 0 then return end
    self.selected = math.max(1, math.min(#self.items, self.selected + delta))
    self:rebuild()
end

function M:activate()
    local it = self.items[self.selected]
    if not it then return end
    local ctx = self.ctx
    self.open = false
    self:destroy()
    local ok, err = ctx.open_book(it.path, nil)
    if not ok then
        self.open = true
        self:scan()
        self:refresh()
        print("open failed: " .. tostring(err))
    end
end

function M:remove_history(index)
    local it = self.items[index]
    if not it then return false end
    clear_fields(self.ctx.get_progress()[it.path])
    self.ctx.save_state()
    local rd = self.ctx.rd
    if rd and rd.cache_remove_book then rd.cache_remove_book(it.path) end
    self:scan()
    self:refresh()
    print("history removed: " .. tostring(it.path))
    return true
end

function M:clear_history()
    local progress = self.ctx.get_progress()
    for _, rec in pairs(progress) do
        clear_fields(rec)
    end
    self.ctx.save_state()
    local rd = self.ctx.rd
    if rd and rd.cache_clear then rd.cache_clear() end
    self:scan()
    self:refresh()
    print("history cleared")
    return true
end

function M:draw()
    local ctx = self.ctx
    local ffi, sdl, S = ctx.ffi, ctx.sdl, ctx.S
    local W, H = ctx.get_wh()
    local theme = ctx.get_theme()
    ctx.panel.frame(ctx.ren, W, H, theme, ctx.v.ui_scale,
        self.title_tex, self.title_w, self.title_h,
        self.count_tex, self.count_w, self.count_h)
    if self.open_tex then
        local r = ffi.new("SDL_Rect")
        r.x, r.y, r.w, r.h = self.open_x, S(50), self.open_w, self.open_h
        sdl.render_copy(ctx.ren, self.open_tex, nil, r)
    end
    if self.clear_tex then
        local r = ffi.new("SDL_Rect")
        r.x, r.y, r.w, r.h = self.clear_x, S(50), self.clear_w, self.clear_h
        sdl.render_copy(ctx.ren, self.clear_tex, nil, r)
    end

    if #self.items == 0 then
        if self.empty_tex then
            local r = ffi.new("SDL_Rect")
            r.x, r.y, r.w, r.h = S(56), self.top, self.empty_w, self.empty_h
            sdl.render_copy(ctx.ren, self.empty_tex, nil, r)
        end
    else
        local y = self.top
        for _, t in ipairs(self.texs) do
            if t.index == self.selected then
                ctx.set_color(theme.sel)
                local row = ffi.new("SDL_Rect")
                row.x, row.y, row.w, row.h = S(40), y - S(4), W - S(80), self.line_h
                sdl.render_fill_rect(ctx.ren, row)
                ctx.set_color(theme.ink)
                local accent = ffi.new("SDL_Rect")
                accent.x, accent.y, accent.w, accent.h = S(40), y - S(4), S(4), self.line_h
                sdl.render_fill_rect(ctx.ren, accent)
            end
            local r = ffi.new("SDL_Rect")
            r.x, r.y, r.w, r.h = S(56), y, t.w, t.h
            sdl.render_copy(ctx.ren, t.tex, nil, r)
            ctx.set_color(theme.line)
            local line = ffi.new("SDL_Rect")
            line.x, line.y, line.w, line.h = S(40), y + self.line_h - 1, W - S(80), 1
            sdl.render_fill_rect(ctx.ren, line)
            y = y + self.line_h
        end
    end

    ctx.panel.hint(ctx.ren, H, ctx.v.ui_scale, self.hint_tex, self.hint_w, self.hint_h)
end

function M:key(k, mod)
    local ctx = self.ctx
    local sdl = ctx.sdl
    if k == sdl.SDLK_UP then self:move(-1)
    elseif k == sdl.SDLK_DOWN then self:move(1)
    elseif k == sdl.SDLK_PAGEUP then self:move(-10)
    elseif k == sdl.SDLK_PAGEDOWN then self:move(10)
    elseif k == sdl.SDLK_RETURN or k == sdl.SDLK_RIGHT then self:activate()
    elseif k == sdl.SDLK_ESCAPE or k == sdl.SDLK_Q then ctx.quit()
    elseif k == sdl.SDLK_S then ctx.open_settings()
    elseif k == sdl.SDLK_O then ctx.choose_book()
    elseif k == sdl.SDLK_DELETE then
        if require("bit").band(mod or 0, 3) ~= 0 then
            self:clear_history()
        else
            self:remove_history(self.selected)
        end
    end
end

return M
