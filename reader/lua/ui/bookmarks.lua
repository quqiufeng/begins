-- 书签面板：数据、列表渲染、增删与跳转。
local M = {}

local list = require("ui.list")
M.__index = M

function M.new(ctx)
    local S = ctx.S
    return setmetatable({
        ctx = ctx,
        open = false,
        items = {},
        selected = 1,
        first = 1,
        texs = {},
        line_h = S(34),
        visible = 20,
        top = S(120),
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

function M:close()
    self:destroy()
    self.open = false
    self.items = {}
end

function M:data()
    local ctx = self.ctx
    local rec = ctx.get_progress()[ctx.get_book()]
    return rec and rec.bookmarks or {}
end

function M:page(b)
    return b.page or 0
end

function M:refresh_count()
    local ctx = self.ctx
    local sdl = ctx.sdl
    if self.count_tex then sdl.destroy_texture(self.count_tex); self.count_tex = nil end
    local _, _, f_page = ctx.get_fonts()
    self.count_tex, self.count_w, self.count_h = ctx.v.make_text(
        string.format("%d 条", #self.items), f_page, ctx.get_theme().muted)
end

function M:add(note)
    local ctx = self.ctx
    local v = ctx.v
    local R = ctx.get_reader()
    if not ctx.get_book() then return false, "no book" end
    local rec = ctx.book_rec()
    rec.bookmarks = rec.bookmarks or {}
    local page = ctx.get_page()
    local total = ctx.get_total()
    local cur_ch = R.chapter_mode and R.chapter_idx or nil
    for _, b in ipairs(rec.bookmarks) do
        if b.page == page and (b.chapter or 1) == (cur_ch or 1) then
            return false, "bookmark exists"
        end
    end
    local label
    if R.chapter_mode then
        label = string.format("第 %d 章 · 第 %d 页", R.chapter_idx, page + 1)
    else
        label = string.format("第 %d 页", page + 1)
    end
    rec.bookmarks[#rec.bookmarks + 1] = {
        page = page,
        chapter = cur_ch,
        note = (note and note ~= "") and note or label,
        created = os.time(),
    }
    table.sort(rec.bookmarks, function(a, b)
        if (a.chapter or 1) ~= (b.chapter or 1) then
            return (a.chapter or 1) < (b.chapter or 1)
        end
        return (a.page or 0) < (b.page or 0)
    end)
    ctx.store.save_state(ctx.state_file, ctx.get_progress())
    return true
end

function M:add_and_refresh(note)
    local ok, err = self:add(note)
    local ctx = self.ctx
    self.items = self:data()
    self:refresh_count()
    if #self.items == 0 then
        if self.empty_tex then ctx.sdl.destroy_texture(self.empty_tex); self.empty_tex = nil end
        local f_body = ctx.get_fonts()
        self.empty_tex, self.empty_w, self.empty_h =
            ctx.v.make_text("（暂无书签）", f_body, ctx.get_theme().muted)
    end
    self:rebuild()
    return ok, err
end

function M:remove(index)
    local ctx = self.ctx
    local rec = ctx.get_progress()[ctx.get_book()]
    if not rec or not rec.bookmarks or not rec.bookmarks[index] then
        return false
    end
    table.remove(rec.bookmarks, index)
    ctx.store.save_state(ctx.state_file, ctx.get_progress())
    return true
end

function M:rebuild()
    local ctx = self.ctx
    for _, t in ipairs(self.texs) do ctx.sdl.destroy_texture(t.tex) end
    self.texs, self.selected, self.first = list.rebuild({
        ttf = ctx.ttf, ren = ctx.ren, font = ctx.get_fonts(),
        theme = ctx.get_theme(), items = self.items,
        selected = self.selected, visible = self.visible,
        text = function(b)
            local label = b.chapter
                and string.format("第 %d 章 · 第 %d 页", b.chapter, (b.page or 0) + 1)
                or string.format("第 %d 页", self:page(b) + 1)
            return string.format("%s  %s", label, b.note or "")
        end,
    })
end

function M:show()
    local ctx = self.ctx
    local v = ctx.v
    local f_body, f_title, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()
    ctx.close_others()
    self:destroy()
    self.items = self:data()
    self.open = true
    self.selected = 1
    self.title_tex, self.title_w, self.title_h = v.make_text("书签", f_title, theme.ink)
    self:refresh_count()
    self.hint_tex, self.hint_w, self.hint_h = v.make_text(
        "A 添加 · ↑/↓ 选择 · Enter 跳转 · Delete 删除 · B/Esc 关闭",
        f_page, theme.muted)
    if #self.items == 0 then
        self.empty_tex, self.empty_w, self.empty_h =
            v.make_text("（暂无书签）", f_body, theme.muted)
    end
    self:rebuild()
end

function M:toggle()
    if self.open then self:close() else self:show() end
end

function M:move(delta)
    if #self.items == 0 then return end
    self.selected = math.max(1, math.min(#self.items, self.selected + delta))
    self:rebuild()
end

function M:activate()
    local b = self.items[self.selected]
    if not b then return end
    self:close()
    local ctx = self.ctx
    local v = ctx.v
    local R = ctx.get_reader()
    if R.chapter_mode and R.chapters and b.chapter and R.chapters[b.chapter] then
        v.open_chapter(b.chapter, b.page or 0)
        v.save_progress()
        return
    end
    local p = self:page(b)
    if p >= 0 and p < ctx.get_total() then
        v.load_page(p)
        v.save_progress()
    end
end

function M:remove_current()
    local ctx = self.ctx
    if #self.items == 0 then return end
    self:remove(self.selected)
    self.items = self:data()
    self:refresh_count()
    self.selected = math.max(1, math.min(#self.items, self.selected))
    if #self.items == 0 then
        if self.empty_tex then ctx.sdl.destroy_texture(self.empty_tex); self.empty_tex = nil end
        local f_body = ctx.get_fonts()
        self.empty_tex, self.empty_w, self.empty_h =
            ctx.v.make_text("（暂无书签）", f_body, ctx.get_theme().muted)
    end
    self:rebuild()
end

function M:refresh()
    if not self.open then return end
    local ctx = self.ctx
    local v = ctx.v
    local f_body, f_title, f_page = ctx.get_fonts()
    local theme = ctx.get_theme()
    for _, k in ipairs({ "title", "count", "hint", "empty" }) do
        local tex = self[k .. "_tex"]
        if tex then ctx.sdl.destroy_texture(tex); self[k .. "_tex"] = nil end
    end
    self.title_tex, self.title_w, self.title_h = v.make_text("书签", f_title, theme.ink)
    self:refresh_count()
    self.hint_tex, self.hint_w, self.hint_h = v.make_text(
        "A 添加 · ↑/↓ 选择 · Enter 跳转 · Delete 删除 · B/Esc 关闭",
        f_page, theme.muted)
    if #self.items == 0 then
        self.empty_tex, self.empty_w, self.empty_h =
            v.make_text("（暂无书签）", f_body, theme.muted)
    end
    self:rebuild()
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

return M
