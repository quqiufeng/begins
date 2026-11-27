-- 阅读导航与视图控制：翻页、滚动、缩放、平移、双页/主题、返回。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:turn(delta)
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local n
    if v.spread_mode() then
        if R.chapter_mode then
            n = (delta > 0) and (R.page + 2) or (R.page - 2)
        elseif delta > 0 then
            n = (R.page == 0) and 1 or (R.page + 2)
        else
            n = (R.page <= 1) and 0 or (R.page - 2)
        end
    else
        n = R.page + delta
    end

    if R.chapter_mode and R.chapters then
        if delta > 0 and n >= R.total then
            if R.chapter_idx < #R.chapters then
                v.open_chapter(R.chapter_idx + 1, 0)
                v.save_progress()
            end
            return
        elseif delta < 0 and n < 0 then
            if R.chapter_idx > 1 then
                v.open_chapter(R.chapter_idx - 1, -1)
                v.save_progress()
            end
            return
        end
    end

    if n < 0 then n = 0 end
    if n >= R.total then return end
    if n ~= R.page then
        v.load_page(n)
        v.save_progress()
    end
end

function M:scroll(dy)
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    if R.is_txt or not v.tex then return end
    local maxs = v.max_scroll()
    if maxs <= 0 then
        if dy > 0 then self:turn(1) elseif dy < 0 then self:turn(-1) end
        return
    end
    if dy > 0 and v.sy >= maxs then
        self:turn(1)
    elseif dy < 0 and v.sy <= 0 then
        self:turn(-1)
    else
        v.sy = math.max(0, math.min(maxs, v.sy + dy))
    end
end

function M:zoom(z)
    local v, R = self.ctx.v, self.ctx.get_reader()
    z = math.max(0.5, math.min(3.0, z))
    if math.abs(z - v.zoom) < 0.001 then return end
    v.zoom = z
    v.pan_x = 0
    v.sy = 0
    if R.book then v.load_page(R.page) end
    v.dirty = true
end

function M:pan(dx)
    local ctx = self.ctx
    local v = ctx.v
    local total_w = v.tex_w + (v.p2 and (ctx.S(5) + v.p2w) or 0)
    local maxp = math.max(0, math.floor((total_w - ctx.get_w()) / 2))
    v.pan_x = math.max(-maxp, math.min(maxp, (v.pan_x or 0) + dx))
    v.dirty = true
end

function M:toggle_dual()
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    v.dual = not v.dual
    ctx.rebuild_header()
    if ctx.lib and ctx.lib.open then ctx.lib:refresh() end
    v.sy = 0
    v.pending_layout = v.reflow
    if R.book then v.load_page(R.page) end
    v.refresh_text()
end

function M:toggle_eye()
    local ctx = self.ctx
    ctx.settings.theme = ctx.cycle(ctx.theme_order, ctx.settings.theme, 1)
    ctx.apply_settings()
end

function M:go_back(allow_window)
    local ctx = self.ctx
    local v = ctx.v
    if ctx.browser.open then
        ctx.browser:close()
    elseif ctx.toc.open then
        ctx.toc:close()
    elseif ctx.bm.open then
        ctx.bm:close()
    elseif ctx.st.open then
        ctx.st:close()
    elseif allow_window and v.fs then
        v.toggle_fs()
    elseif allow_window and v.max then
        v.toggle_max()
    elseif ctx.get_reader().book then
        ctx.lib:show()
    end
end

return M
