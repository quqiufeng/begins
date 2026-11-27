-- 文件浏览器面板：目录读取、列表渲染、打开书籍。
local M = {}

local list = require("ui.list")
M.__index = M

local EXTS = {
    pdf = true, epub = true, mobi = true, azw3 = true,
    txt = true, chm = true, cbz = true, cbr = true,
}

function M.new(ctx)
    local S = ctx.S
    return setmetatable({
        ctx = ctx,
        open = false,
        dir = "",
        items = {},
        selected = 1,
        first = 1,
        texs = {},
        line_h = S(40),
        visible = 14,
        top = S(120),
        title_tex = nil, title_w = 0, title_h = 0,
        count_tex = nil, count_w = 0, count_h = 0,
        hint_tex = nil, hint_w = 0, hint_h = 0,
        empty_tex = nil, empty_w = 0, empty_h = 0,
    }, M)
end

function M:destroy()
    local sdl = self.ctx.sdl
    for _, t in ipairs(self.texs) do sdl.destroy_texture(t.tex) end
    self.texs = {}
    for _, k in ipairs({ "title", "count", "hint", "empty" }) do
        local tex = self[k .. "_tex"]
        if tex then sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
end

function M:rebuild()
    local ctx = self.ctx
    for _, t in ipairs(self.texs) do ctx.sdl.destroy_texture(t.tex) end
    self.texs, self.selected, self.first = list.rebuild({
        ttf = ctx.ttf, ren = ctx.ren, font = ctx.get_fonts(),
        theme = ctx.get_theme(), items = self.items,
        selected = self.selected, visible = self.visible,
        text = function(it) return (it.is_dir and "[目录] " or "") .. it.name end,
    })
end

function M:load(dir)
    local ctx = self.ctx
    local rd, sdl = ctx.rd, ctx.sdl
    local home = ctx.get_home()
    dir = tostring(dir or home)
    dir = dir:gsub("/+$", "")
    if dir == "" then dir = "/" end
    self.dir = dir
    self.items = {}
    self.selected = 1

    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        self.items[#self.items + 1] = { name = "..", is_dir = true, path = parent }
    end

    local gvfs = string.format("/run/user/%d/gvfs", tonumber(ctx.ffi.C.getuid()) or 1000)
    if dir == home and rd.list_dir(gvfs) ~= "" then
        self.items[#self.items + 1] = {
            name = "[网络位置] " .. gvfs, is_dir = true, path = gvfs,
        }
    end
    local dl = home .. "/Downloads/book"
    if dir == home and rd.list_dir(dl) ~= "" then
        self.items[#self.items + 1] = {
            name = "[书库] " .. dl, is_dir = true, path = dl,
        }
    end

    local raw = rd.list_dir(dir)
    for line in raw:gmatch("[^\n]+") do
        local typ, name = line:match("^(%a)\t(.+)$")
        if typ and name and name:sub(1, 1) ~= "." then
            if typ == "d" then
                self.items[#self.items + 1] = {
                    name = name, is_dir = true, path = dir .. "/" .. name,
                }
            else
                local ext = name:match("%.([%w]+)$")
                ext = ext and ext:lower() or ""
                if EXTS[ext] then
                    self.items[#self.items + 1] = {
                        name = name, is_dir = false, path = dir .. "/" .. name,
                    }
                end
            end
        end
    end

    table.sort(self.items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    self:destroy()
    local v = ctx.v
    local f_body, _, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()
    self.title_tex, self.title_w, self.title_h =
        v.make_text("打开书籍 · " .. dir, f_page, theme.ink)
    self.count_tex, self.count_w, self.count_h =
        v.make_text(string.format("%d 项", #self.items), f_page, theme.muted)
    self.hint_tex, self.hint_w, self.hint_h = v.make_text(
        "↑/↓ 选择 · Enter 打开/进入 · Backspace 上级 · Esc 关闭", f_page, theme.muted)
    if #self.items == 0 then
        self.empty_tex, self.empty_w, self.empty_h =
            v.make_text("目录为空或无法读取", f_body, theme.muted)
    end
    self:rebuild()
end

function M:show(start)
    local ctx = self.ctx
    ctx.close_others()
    self.open = true
    local dir = start or ctx.get_last_dir()
    if not dir or dir == "" then
        local book = ctx.get_book()
        if book then dir = book:match("^(.*)/[^/]*$") end
    end
    if not dir or dir == "" then dir = ctx.get_home() end
    self:load(dir)
    ctx.sdl.stop_text_input()
end

function M:close()
    self.open = false
    self:destroy()
    self.ctx.mark_dirty()
end

function M:move(delta)
    if #self.items == 0 then return end
    self.selected = math.max(1, math.min(#self.items, self.selected + delta))
    self:rebuild()
end

function M:activate()
    local it = self.items[self.selected]
    if not it then return end
    if it.is_dir then
        self:load(it.path)
        return
    end
    local ctx = self.ctx
    ctx.set_last_dir(self.dir)
    self.open = false
    self:destroy()
    local ok, err = ctx.open_book(it.path, nil)
    if not ok then
        print("open failed: " .. tostring(err))
        self.open = true
        self:load(ctx.get_last_dir())
    else
        ctx.close_library()
    end
end

function M:draw()
    local ctx = self.ctx
    local W, H = ctx.get_wh()
    local theme = ctx.get_theme()
    ctx.panel.frame(ctx.ren, W, H, theme, ctx.v.ui_scale,
        self.title_tex, self.title_w, self.title_h,
        self.count_tex, self.count_w, self.count_h)
    ctx.panel.items(ctx.ren, W, theme, ctx.v.ui_scale, self.top, self.line_h,
        self.texs, self.selected, self.empty_tex, self.empty_w, self.empty_h)
    ctx.panel.hint(ctx.ren, H, ctx.v.ui_scale, self.hint_tex, self.hint_w, self.hint_h)
end

function M:key(k)
    local sdl = self.ctx.sdl
    if k == sdl.SDLK_UP then self:move(-1)
    elseif k == sdl.SDLK_DOWN then self:move(1)
    elseif k == sdl.SDLK_PAGEUP then self:move(-10)
    elseif k == sdl.SDLK_PAGEDOWN then self:move(10)
    elseif k == sdl.SDLK_RETURN or k == sdl.SDLK_RIGHT then self:activate()
    elseif k == sdl.SDLK_BACKSPACE then
        local parent = self.dir:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then self:load(parent) end
    elseif k == sdl.SDLK_ESCAPE then self:close()
    end
end

return M
