-- 自动化 API：state / click / call / actions。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:settings()
    local s = self.ctx.settings
    return {
        theme = s.theme,
        font_size = s.font_size,
        line_factor = s.line_factor,
        margin = s.margin,
    }
end

function M:state()
    local ctx = self.ctx
    local v, lib, bm, R = ctx.v, ctx.lib, ctx.bm, ctx.reader
    if lib.open then
        return {
            library = true, count = #lib.items, library_dir = lib.dir,
            selected = lib.selected,
            name = lib.items[lib.selected] and lib.items[lib.selected].name or nil,
            panel = ctx.get_panel and ctx.get_panel() or "library",
        }
    end
    local page, total = ctx.get_page(), ctx.get_total()
    local s = ctx.settings
    return {
        book = ctx.get_book(),
        page = page + 1,
        pages = total,
        chapter = R.chapter_mode and R.chapter_idx or nil,
        chapters = R.chapter_mode and R.chapters and #R.chapters or nil,
        chapter_pages = R.chapter_mode and total or nil,
        bookmarks = #bm:data(),
        panel = ctx.get_panel and ctx.get_panel() or nil,
        format = ctx.get_is_txt() and "txt" or "doc",
        theme = s.theme,
        font_size = s.font_size,
        zoom = v.zoom,
        fullscreen = v.fs,
        maximized = v.max,
        dual = v.dual,
        spread = v.spread_mode(),
        window_width = ctx.get_w(),
        window_height = ctx.get_h(),
    }
end

-- 返回键：一层层往回退，退无可退就退出程序。
-- 遥控器上只有 BACK/ESC 一个「后退」键，阅读器没有别的退出键，
-- 这里兜底，否则用户进了书库/内容页就没法回到桌面。
-- 返回 true = 已经退出。
function M:back()
    local ctx = self.ctx
    local v = ctx.v
    if v.preview then
        ctx.close_preview()
    elseif (ctx.browser and ctx.browser.open) or ctx.toc.open or ctx.bm.open
        or ctx.st.open then
        v.close_panels()
    elseif ctx.lib.open then
        ctx.quit()
        return true
    elseif v.fs then
        v.toggle_fs()
    elseif v.max then
        v.toggle_max()
    else
        ctx.lib:show()
    end
    return false
end

function M:click(id)
    local ctx = self.ctx
    local v, lib, toc, bm, st = ctx.v, ctx.lib, ctx.toc, ctx.bm, ctx.st
    if id == "reader.next" then
        -- 书库（阅读历史）开着时，翻页键就是「上下选择」
        if lib.open then lib:move(1) else ctx.turn(1) end
        return { ok = true, state = self:state() }
    elseif id == "reader.prev" then
        if lib.open then lib:move(-1) else ctx.turn(-1) end
        return { ok = true, state = self:state() }
    elseif id == "app.toc" or id == "app.ok" then
        if lib.open then lib:activate() else toc:toggle() end
        return { ok = true, open = toc.open, library = lib.open, state = self:state() }
    elseif id == "app.bookmarks" then
        bm:toggle()
        return { ok = true, open = bm.open }
    elseif id == "app.settings" then
        if st.open then st:close() else st:show() end
        return { ok = true, open = st.open }
    elseif id == "app.library" then
        lib:show()
        return { ok = true, library = true, count = #lib.items }
    elseif id == "app.fullscreen" then
        v.toggle_fs()
        return { ok = true, fullscreen = v.fs, state = self:state() }
    elseif id == "app.maximize" then
        v.toggle_max()
        return { ok = true, maximized = v.max, state = self:state() }
    elseif id == "app.dual" then
        ctx.toggle_dual()
        return { ok = true, dual = v.dual, state = self:state() }
    elseif id == "app.eye" then
        ctx.toggle_eye()
        return { ok = true, theme = ctx.settings.theme, state = self:state() }
    elseif id == "app.back" then
        local quit = self:back()
        return { ok = true, quit = quit, state = quit and nil or self:state() }
    elseif id == "app.quit" then
        ctx.quit()
        return { ok = true }
    end
    return { ok = false, error = "unknown action: " .. tostring(id) }
end

function M:extra(fn, args)
    local ctx = self.ctx
    local v, lib, toc, bm, st = ctx.v, ctx.lib, ctx.toc, ctx.bm, ctx.st
    if fn == "app.state" then
        return { ok = true, state = self:state() }
    elseif fn == "shelf.up" or fn == "shelf.down" then
        if not lib.open then lib:show() end
        lib:move(fn == "shelf.up" and -1 or 1)
        return { ok = true, state = self:state() }
    elseif fn == "shelf.pageup" or fn == "shelf.pagedown" then
        if not lib.open then lib:show() end
        lib:move(fn == "shelf.pageup" and -10 or 10)
        return { ok = true, state = self:state() }
    elseif fn == "shelf.select" then
        if not lib.open then lib:show() end
        local n = tonumber(args.index or args.n)
        if n then lib:move(n - (lib.selected or 1)) end
        return { ok = true, state = self:state() }
    elseif fn == "shelf.open" then
        if not lib.open then lib:show() end
        local n = tonumber(args.index or args.n)
        if n then lib:move(n - (lib.selected or 1)) end
        lib:activate()
        return { ok = true, state = self:state() }
    elseif fn == "reader.scroll" then
        v.scroll_by(tonumber(args.dy or args.delta) or 0)
        return { ok = true, state = self:state() }
    elseif fn == "reader.zoom" then
        local z = tonumber(args.zoom or args.z)
        if z then v.set_zoom(z) end
        return { ok = true, zoom = v.zoom, state = self:state() }
    elseif fn == "reader.pan" then
        v.pan(tonumber(args.dx) or 0)
        return { ok = true, state = self:state() }
    elseif fn == "library.scan" then
        if not lib.open then lib:show() end
        lib:scan()
        lib:refresh()
        return { ok = true, count = #lib.items, items = lib.items }
    elseif fn == "library.select" then
        if not lib.open then lib:show() end
        local idx = tonumber(args.index or args.selected)
        if idx then
            lib.selected = math.max(1, math.min(#lib.items, idx))
        else
            lib:move(tonumber(args.delta) or 1)
        end
        lib:rebuild()
        return { ok = true, selected = lib.selected, item = lib.items[lib.selected] }
    elseif fn == "library.activate" then
        if not lib.open then lib:show() end
        local idx = tonumber(args.index or args.selected)
        if idx then
            lib.selected = math.max(1, math.min(#lib.items, idx))
            lib:rebuild()
        end
        lib:activate()
        return { ok = true, state = self:state() }
    elseif fn == "toc.open" then
        toc:show()
        return { ok = true, open = true, toc = toc.items }
    elseif fn == "toc.close" then
        toc:close()
        return { ok = true, open = false }
    elseif fn == "toc.select" then
        local idx = tonumber(args.index or args.selected)
        if idx then
            if #toc.items > 0 then
                toc.selected = math.max(1, math.min(#toc.items, idx))
                toc:rebuild()
            end
        else
            toc:move(tonumber(args.delta) or 1)
        end
        return { ok = true, selected = toc.selected, item = toc.items[toc.selected] }
    elseif fn == "toc.activate" then
        if not toc.open then toc:show() end
        local idx = tonumber(args.index or args.selected)
        if idx and #toc.items > 0 then
            toc.selected = math.max(1, math.min(#toc.items, idx))
            toc:rebuild()
        end
        toc:activate()
        return { ok = true, state = self:state() }
    elseif fn == "bookmark.open" then
        bm:show()
        return { ok = true, open = bm.open, bookmarks = bm.items }
    elseif fn == "bookmark.select" then
        if not bm.open then bm:show() end
        local idx = tonumber(args.index or args.selected)
        if idx then
            if #bm.items > 0 then
                bm.selected = math.max(1, math.min(#bm.items, idx))
                bm:rebuild()
            end
        else
            bm:move(tonumber(args.delta) or 1)
        end
        return { ok = true, selected = bm.selected, item = bm.items[bm.selected] }
    elseif fn == "bookmark.activate" then
        if not bm.open then bm:show() end
        local idx = tonumber(args.index or args.selected)
        if idx and #bm.items > 0 then
            bm.selected = math.max(1, math.min(#bm.items, idx))
            bm:rebuild()
        end
        bm:activate()
        return { ok = true, state = self:state() }
    elseif fn == "settings.open" then
        st:show()
        local row = tonumber(args.row or args.selected)
        if row then
            st.selected = math.max(1, math.min(4, row))
            st:rebuild()
        end
        return { ok = true, open = true, selected = st.selected, settings = self:settings() }
    elseif fn == "settings.adjust" then
        if not st.open then st:show() end
        local row = tonumber(args.row or args.selected)
        if row then
            st.selected = math.max(1, math.min(4, row))
            st:rebuild()
        end
        st:adjust(tonumber(args.delta) or 1)
        return { ok = true, selected = st.selected, settings = self:settings() }
    elseif fn == "settings.close" then
        st:close()
        return { ok = true, open = false }
    elseif fn == "bookmark.close" then
        bm:close()
        return { ok = true, open = false }
    elseif fn == "library.close" then
        lib:close()
        return { ok = true, library = false }
    elseif fn == "history.remove" then
        local idx = tonumber(args.index or args.selected)
        if not idx and args.path then
            for i, it in ipairs(lib.items) do
                if it.path == args.path then idx = i; break end
            end
        end
        if not idx then return { ok = false, error = "missing index/path" } end
        if not lib.open then lib:show() end
        local ok = lib:remove_history(idx)
        return { ok = ok, items = lib.items }
    elseif fn == "history.clear" then
        if not lib.open then lib:show() end
        lib:clear_history()
        return { ok = true, items = lib.items }
    end
    return nil
end

function M:call(fn, args)
    local ctx = self.ctx
    local v, lib, toc, bm, R = ctx.v, ctx.lib, ctx.toc, ctx.bm, ctx.reader
    local handled = self:extra(fn, args)
    if handled ~= nil then return handled end
    if fn == "reader.open" then
        lib:close()
        local ok, err = ctx.open_book(args.path or "", args.page)
        if not ok then return { ok = false, error = tostring(err) } end
        return { ok = true, state = self:state() }
    elseif fn == "reader.close" then
        ctx.close_book()
        return { ok = true }
    elseif fn == "reader.next" then
        if lib.open then lib:move(1) else ctx.turn(1) end
        return { ok = true, state = self:state() }
    elseif fn == "reader.prev" then
        if lib.open then lib:move(-1) else ctx.turn(-1) end
        return { ok = true, state = self:state() }
    elseif fn == "reader.state" then
        return { ok = true, state = self:state() }
    elseif fn == "reader.list" then
        if not lib.open then lib:scan() end
        return { ok = true, items = lib.items, library_dir = lib.dir }
    elseif fn == "app.library" or fn == "nav.books" then
        lib:show()
        return { ok = true, library = true, count = #lib.items }
    elseif fn == "app.fullscreen" then
        v.toggle_fs()
        return { ok = true, fullscreen = v.fs, state = self:state() }
    elseif fn == "app.maximize" then
        v.toggle_max()
        return { ok = true, maximized = v.max, state = self:state() }
    elseif fn == "app.dual" then
        ctx.toggle_dual()
        return { ok = true, dual = v.dual, state = self:state() }
    elseif fn == "app.eye" then
        ctx.toggle_eye()
        return { ok = true, theme = ctx.settings.theme, state = self:state() }
    elseif fn == "reader.text" then
        local total, page = ctx.get_total(), ctx.get_page()
        local n = tonumber(args.page)
        if n then
            n = math.max(0, math.min(total - 1, n - 1))
        else
            n = page
        end
        local txt = ""
        if ctx.get_is_txt() then
            local pages = ctx.get_pages()
            txt = table.concat((pages and pages[n + 1]) or {}, "\n")
        else
            local doc = ctx.get_doc()
            if doc then txt = ctx.rd.page_text(doc, n) or "" end
        end
        return { ok = true, page = n + 1, pages = total, text = txt }
    elseif fn == "reader.toc" then
        return { ok = true, toc = toc:load_data() }
    elseif fn == "reader.goto" then
        local total = ctx.get_total()
        local n = tonumber(args.page or args.index)
        local ch = tonumber(args.chapter)
        if R.chapter_mode and R.chapters then
            if ch and R.chapters[ch] then
                local ok, err = v.open_chapter(ch, n and (n - 1) or 0)
                if not ok then
                    return { ok = false, error = tostring(err), state = self:state() }
                end
            elseif n then
                v.load_page(math.max(0, math.min(total - 1, n - 1)))
            end
            v.save_progress()
        elseif n then
            v.load_page(math.max(0, math.min(total - 1, n - 1)))
            v.save_progress()
        end
        return { ok = true, state = self:state() }
    elseif fn == "reader.bookmark.add" then
        local ok, err = bm:add(args.note)
        return { ok = ok, error = err, bookmarks = bm:data() }
    elseif fn == "reader.bookmark.list" then
        return { ok = true, bookmarks = bm:data() }
    elseif fn == "reader.bookmark.remove" then
        local idx = tonumber(args.index)
        local ok = idx and bm:remove(idx) or false
        return { ok = ok, bookmarks = bm:data() }
    elseif fn == "settings.get" then
        return { ok = true, settings = self:settings() }
    elseif fn == "settings.set" then
        local s = ctx.settings
        if args.theme then s.theme = args.theme end
        if args.font_size then s.font_size = tonumber(args.font_size) or s.font_size end
        if args.line_factor then s.line_factor = tonumber(args.line_factor) or s.line_factor end
        if args.margin then s.margin = tonumber(args.margin) or s.margin end
        if not ctx.validate_theme(s.theme) then s.theme = "light" end
        if args.font_size or args.line_factor or args.margin then
            v.pending_layout = v.reflow
        end
        ctx.apply_settings()
        return { ok = true, settings = self:settings() }
    elseif fn == "app.toc" or fn == "app.ok" then
        if lib.open then
            lib:activate()
            return { ok = true, open = toc.open, library = lib.open, state = self:state() }
        end
        toc:toggle()
        return { ok = true, open = toc.open }
    elseif fn == "app.bookmarks" then
        bm:toggle()
        return { ok = true, open = bm.open }
    elseif fn == "app.settings" then
        local st = ctx.st
        if st.open then st:close() else st:show() end
        return { ok = true, open = st.open }
    elseif fn == "app.snapshot" then
        local path = args.path or v.snapshot_path()
        ctx.draw()
        local ok = v.save_content_snapshot(path)
        return { ok = ok, path = path }
    elseif fn == "app.markdown" then
        local ok, path = v.save_page_markdown(args.path)
        return { ok = ok, path = path }
    elseif fn == "app.capture" then
        local path = args.path or v.snapshot_path()
        local ok = ctx.capture(path)
        return { ok = ok, path = path }
    elseif fn == "app.back" then
        local quit = self:back()
        return { ok = true, quit = quit, state = quit and nil or self:state() }
    elseif fn == "app.quit" then
        ctx.quit()
        return { ok = true }
    end
    return { ok = false, error = "unknown fn: " .. tostring(fn) }
end

function M:actions()
    return {
        "reader.next", "reader.prev", "app.library", "app.toc",
        "app.bookmarks", "app.settings", "app.fullscreen",
        "app.maximize", "app.dual", "app.eye", "app.back", "app.quit",
        "shelf.up", "shelf.down", "shelf.pageup", "shelf.pagedown",
        "shelf.select", "shelf.open", "app.ok",
    }
end

return M
