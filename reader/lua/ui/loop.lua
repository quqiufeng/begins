-- 主事件循环：输入、启动同步、尺寸适配、预取与重绘。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

local PROF = os.getenv("READER_PROF") ~= nil
local tnow = PROF and require("core.clock").now or nil

function M:run()
    local ctx = self.ctx
    local sdl, ffi, v = ctx.sdl, ctx.ffi, ctx.v
    local ev = ffi.new("SDL_Event[1]")

    while ctx.is_running() do
        local server = ctx.get_server()
        if server then server:poll() end

        while sdl.poll_event(ev) ~= 0 do
            if ev[0].type ~= sdl.MOUSEMOTION then v.had_event = true end
            -- 单个事件处理失败（例如某个按钮回调报错）不该让整个应用退出。
            local ok_ev, err_ev = pcall(ctx.input.handle, ctx.input, ev[0])
            if not ok_ev then
                io.stderr:write("[reader] input error: " .. tostring(err_ev) .. "\n")
            end
        end

        local now = v.now()
        ctx.toast:tick(now)
        if ctx.filedialog:poll(now) then v.dirty = true end
        if v.save_pending and now >= v.save_due then
            ctx.save_state()
            v.save_pending = false
            v.save_due = 0
        end

        if v.startup_sync and now >= v.startup_at then
            v.startup_sync = false
            local nw, nh = v.window_target_size()
            if nw and nh and nw > 0 and nh > 0 then ctx.set_wh(nw, nh) end
            ctx.rebuild_header()
            local pending = v.pending_initial
            v.pending_initial = nil
            if pending then
                if pending.book and pending.book ~= "" then
                    local ok, err = ctx.open_book(pending.book, pending.page)
                    if not ok then error("open failed: " .. tostring(err)) end
                else
                    ctx.lib:show()
                end
            else
                if ctx.lib and ctx.lib.open then ctx.lib:refresh() end
                v.sy = 0
                v.pending_layout = v.reflow
                local R = ctx.get_reader()
                if R.book then ctx.load_page(R.page) end
                ctx.refresh_text()
            end
            v.dirty = true
        end

        if not v.resize_pending and now >= (v.sync_at or 0) then
            v.sync_at = now + 0.5
            if ctx.apply_resize() then v.dirty = true end
            if v.ensure_content_size() then v.dirty = true end
        end

        if v.resize_pending and v.now() >= v.resize_due then
            local nw, nh = v.resize_target_w, v.resize_target_h
            if not nw or not nh then nw, nh = v.window_target_size() end
            if nw and nh and nw > 0 and nh > 0 then
                if v.resize_last_w ~= nw or v.resize_last_h ~= nh then
                    v.resize_target_w, v.resize_target_h = nw, nh
                    v.resize_last_w, v.resize_last_h = nw, nh
                    v.resize_due = v.now() + 0.10
                else
                    v.resize_pending = false
                    ctx.apply_resize(nw, nh)
                    v.dirty = true
                end
            else
                v.resize_pending = false
            end
        end

        if v.had_event then
            v.dirty = true
            v.had_event = false
        end

        if not v.dirty and v.prefetch then
            local P = v.prefetch
            v.prefetch = nil
            local R = ctx.get_reader()
            if R.doc and not R.is_txt and P.sig == v.content_sig() then
                for _, pg in ipairs(P.pages or {}) do
                    local key = P.sig .. ":" .. pg
                    if pg < R.total and not v.pcache.map[key] then
                        local t_pf = PROF and tnow() or 0
                        local t, w, h = v.render_into(pg, P.target_w)
                        if t then v.pcache:put(key, { tex = t, w = w, h = h }) end
                        if PROF then
                            io.stderr:write(string.format(
                                "[prof] prefetch page %d %.1f ms ok=%s\n",
                                pg, (tnow() - t_pf) * 1000, tostring(t and true or false)))
                        end
                    end
                end
            end
        end

        -- 章末空闲时预打开下一章：切换章节省掉现场解析（大章节 100~200ms）
        if not v.dirty and not v.chapter_prefetch_done then
            local R = ctx.get_reader()
            if R and R.chapter_mode and R.doc and R.next_chapter_idx then
                local spread = v.view_metrics()
                local step = spread and 2 or 1
                if (R.page or 0) + step >= (R.total or 0) - 1 then
                    local nx = R:next_chapter_idx()
                    if nx and R:prefetch_chapter(nx) then
                        v.chapter_prefetch_done = true
                    end
                end
            end
        end

        v.drew = false
        if v.dirty then
            local t_draw = PROF and tnow() or 0
            ctx.draw()
            if PROF then
                io.stderr:write(string.format("[prof] draw %.1f ms\n",
                    (tnow() - t_draw) * 1000))
            end
            v.dirty = false
            v.drew = true
        end
        -- 帧间隔切成 2ms 小片：有自动化命令在等就立刻醒来，
        -- 否则命令往返最多白等一整帧（16ms），翻页手感直接受影响。
        local wait = v.drew and 16 or 30
        local step = 2
        while wait > 0 do
            local server2 = ctx.get_server()
            if server2 and server2.has_pending and server2:has_pending() then break end
            local d = wait < step and wait or step
            sdl.delay(d)
            wait = wait - d
        end
    end
end

return M
