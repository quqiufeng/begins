-- 窗口尺寸与全屏/最大化适配。
local bit = require("bit")

local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:toggle_fs()
    local ctx = self.ctx
    local v, sdl, win = ctx.v, ctx.sdl, ctx.win
    if not v.fs and v.max then
        v.max = false
        sdl.restore_window(win)
        sdl.delay(40)
    end
    v.fs = not v.fs
    sdl.set_window_fullscreen(win, v.fs)
    sdl.delay(60)
    v.resize_pending = true
    v.resize_due = v.now() + 0.05
    v.resize_target_w, v.resize_target_h = v.window_target_size()
    v.resize_last_w, v.resize_last_h = nil, nil
    -- 全屏/最大化会改变可用高度，强制让内容按新尺寸重排重渲染
    v.content_sig_value = nil
    ctx.rebuild_header()
    if ctx.lib and ctx.lib.open then ctx.lib:refresh() end
    v.dirty = true
end

function M:toggle_max()
    local ctx = self.ctx
    local v, sdl, win = ctx.v, ctx.sdl, ctx.win
    if v.fs then
        v.fs = false
        sdl.set_window_fullscreen(win, false)
        sdl.delay(60)
    end
    v.max = not v.max
    v.dual = v.max
    v.auto_dual = v.max
    if v.max then
        sdl.maximize_window(win)
    else
        sdl.restore_window(win)
    end
    sdl.delay(80)
    v.resize_pending = true
    v.resize_due = v.now() + 0.05
    v.resize_target_w, v.resize_target_h = v.window_target_size()
    v.resize_last_w, v.resize_last_h = nil, nil
    -- 全屏/最大化会改变可用高度，强制让内容按新尺寸重排重渲染
    v.content_sig_value = nil
    ctx.rebuild_header()
    if ctx.lib and ctx.lib.open then ctx.lib:refresh() end
    v.dirty = true
end

function M:ensure_content_size()
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local W, H = ctx.get_w(), ctx.get_h()
    local dirty = false
    if ctx.lib.open and (ctx.lib.ui_w ~= W or ctx.lib.ui_h ~= H) then
        ctx.lib:refresh()
        dirty = true
    end
    if R.book and not R.is_txt and v.tex then
        local spread, _, _, _, tw = v.view_metrics()
        if spread and R.page == 0 then tw = math.max(160, W - ctx.S(48)) end
        local expected = math.floor(tw * (v.zoom or 1) + 0.5)
        if math.abs((v.tex_w or 0) - expected) > 2 or
           (v.p2 and math.abs((v.p2w or 0) - expected) > 2) then
            v.pending_layout = v.reflow
            v.load_page(R.page)
            dirty = true
        end
    end
    return dirty
end

function M:apply_resize(nw, nh)
    local ctx = self.ctx
    local v, R, sdl, win = ctx.v, ctx.get_reader(), ctx.sdl, ctx.win
    local W, H = ctx.get_w(), ctx.get_h()
    local mode_changed = false

    if not v.fs then
        local flags = sdl.get_window_flags(win)
        local ismax = bit.band(flags, sdl.WINDOW_MAXIMIZED) ~= 0
        if ismax then
            if not v.max then
                v.auto_dual = not v.dual
                mode_changed = true
            end
            v.max = true
            v.dual = true
        else
            if v.max then
                if v.auto_dual then v.dual = false end
                v.auto_dual = false
                mode_changed = true
            end
            v.max = false
        end
    end

    if not nw or not nh or nw <= 0 or nh <= 0 then
        nw, nh = v.window_target_size()
    end
    if not nw or nw <= 0 or nh <= 0 then
        if not mode_changed then return false end
        nw, nh = W, H
    end
    local size_changed = nw ~= W or nh ~= H
    if not size_changed and not mode_changed and not v.pending_layout then
        return false
    end

    ctx.set_wh(nw, nh)
    ctx.sync_scale()
    if not v.fs and not v.max then
        local ww, wh = sdl.get_window_size(win)
        v.win_w, v.win_h = ww or nw, wh or nh
        v.win_x, v.win_y = sdl.get_window_position(win)
    end

    if R.is_txt and R.book and size_changed then
        R:build_txt(R.book)
        R.page = math.max(0, math.min(R.total - 1, R.page))
    end
    local sig = v.content_sig()
    local content_changed = sig ~= v.content_sig_value or v.pending_layout
    ctx.rebuild_header()
    if ctx.lib and ctx.lib.open then ctx.lib:refresh() end
    v.sy = 0
    if R.book and content_changed then
        v.pending_layout = v.reflow
        v.load_page(R.page)
    else
        v.content_sig_value = sig
        v.refresh_text()
    end
    return true
end

return M
