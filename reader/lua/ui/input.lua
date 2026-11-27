-- 输入事件：键盘、鼠标、光标、窗口事件分发。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:set_cursor(hand)
    local v = self.ctx.v
    if v.hover == hand then return end
    v.hover = hand
    local c = hand and v.cursor_hand or v.cursor_arrow
    if c then self.ctx.sdl.set_cursor(c) end
end

function M:update_cursor(x, y)
    local ctx = self.ctx
    local v, S = ctx.v, ctx.S
    if v.preview then self:set_cursor(false); return end
    local hand = false
    if ctx.browser.open then
        local browser = ctx.browser
        if y >= browser.top and y < browser.top + browser.visible * browser.line_h then
            local idx = browser.first + math.floor((y - browser.top) / browser.line_h)
            hand = idx >= 1 and idx <= #browser.items
        end
    elseif ctx.toc.open then
        local toc = ctx.toc
        if y >= toc.top and y < toc.top + toc.visible * toc.line_h then
            local idx = toc.first + math.floor((y - toc.top) / toc.line_h)
            hand = idx >= 1 and idx <= #toc.items
        end
    elseif ctx.bm.open then
        local bm = ctx.bm
        if y >= bm.top and y < bm.top + bm.visible * bm.line_h then
            local idx = bm.first + math.floor((y - bm.top) / bm.line_h)
            hand = idx >= 1 and idx <= #bm.items
        end
    elseif ctx.st.open then
        local toc = ctx.toc
        if y >= toc.top and y < toc.top + 4 * toc.line_h then
            hand = true
        end
    elseif ctx.lib.open then
        local lib = ctx.lib
        if y >= S(30) and y <= S(80) and x >= lib.open_x - S(12) then
            hand = true
        elseif y >= S(30) and y <= S(80) and x >= lib.clear_x - S(8) then
            hand = true
        elseif y >= lib.top and y < lib.top + lib.visible * lib.line_h then
            local idx = lib.first + math.floor((y - lib.top) / lib.line_h)
            hand = idx >= 1 and idx <= #lib.items
        end
    elseif not v.fs and y <= 58 then
        hand = ctx.header:any(x)
    elseif ctx.get_doc() and not ctx.get_is_txt() then
        for _, r in ipairs(v.rects) do
            if x >= r.x and x < r.x + r.w and
               y >= r.y and y < r.y + r.h then
                local nx = (x - r.x) / r.w
                local ny = (y - r.y) / r.h
                for _, l in ipairs(v.links[r.page] or {}) do
                    if nx >= l.x0 and nx <= l.x1 and
                       ny >= l.y0 and ny <= l.y1 then
                        hand = true
                        break
                    end
                end
                break
            end
        end
    end
    self:set_cursor(hand)
end

function M:content_click(x, y)
    local ctx = self.ctx
    local v = ctx.v
    local doc = ctx.get_doc()
    local page, W = ctx.get_page(), ctx.get_w()

    -- 链接优先：图片可能覆盖整页，不能先弹图片预览而吞掉章节跳转。
    for _, r in ipairs(v.rects) do
        if x >= r.x and x < r.x + r.w and
           y >= r.y and y < r.y + r.h then
            if doc then
                local nx = (x - r.x) / r.w
                local ny = (y - r.y) / r.h
                for _, l in ipairs(v.links[r.page] or {}) do
                    if nx >= l.x0 and nx <= l.x1 and
                       ny >= l.y0 and ny <= l.y1 then
                        local tp, _, oy = ctx.rd.link_at(doc, r.page, nx, ny)
                        tp = tp or l.page
                        v.load_page(tp)
                        if oy and oy > 0 then
                            local h = ctx.get_tex_h()
                            if v.spread_mode() and tp == page + 1 then
                                h = v.p2h
                            end
                            v.sy = math.max(0, math.min(v.max_scroll(),
                                math.floor(oy * h) - 60))
                        end
                        v.save_progress()
                        return
                    end
                end
            end
            break
        end
    end

    for _, r in ipairs(v.rects) do
        if x >= r.x and x < r.x + r.w and
           y >= r.y and y < r.y + r.h then
            local nx = (x - r.x) / r.w
            local ny = (y - r.y) / r.h
            local imgs = (v.images and v.images[r.page]) or {}
            for _, im in ipairs(imgs) do
                if nx >= im.x0 and nx <= im.x1 and
                   ny >= im.y0 and ny <= im.y1 then
                    ctx.show_image(r.page, im)
                    return
                end
            end
            break
        end
    end

    if x < W / 3 then
        ctx.turn(-1)
    elseif x > W * 2 / 3 then
        ctx.turn(1)
    end
end

function M:mouse_down(x, y, button)
    local ctx = self.ctx
    local v, S = ctx.v, ctx.S
    local browser, toc, bm, st, lib = ctx.browser, ctx.toc, ctx.bm, ctx.st, ctx.lib
    if v.preview then
        if button == 3 then
            ctx.close_preview()
        else
            local p = v.preview
            local W, H = ctx.get_w(), ctx.get_h()
            local dw, dh = p.w * p.zoom, p.h * p.zoom
            local ix = (W - dw) / 2 + (p.pan_x or 0)
            local iy = (H - dh) / 2 + (p.pan_y or 0)
            if x < ix or x > ix + dw or y < iy or y > iy + dh then
                ctx.close_preview()
            else
                v.preview_drag = true
                v.preview_dx, v.preview_dy = x, y
            end
        end
        return
    end
    if button == 3 then
        ctx.go_back(false)
    elseif browser.open then
        if y >= browser.top and y < browser.top + browser.visible * browser.line_h then
            local idx = browser.first + math.floor((y - browser.top) / browser.line_h)
            if idx >= 1 and idx <= #browser.items then
                browser.selected = idx
                browser:rebuild()
                browser:activate()
            end
        end
    elseif toc.open then
        if y >= toc.top and y < toc.top + toc.visible * toc.line_h then
            local idx = toc.first + math.floor((y - toc.top) / toc.line_h)
            if idx >= 1 and idx <= #toc.items then
                toc.selected = idx
                toc:rebuild()
                toc:activate()
            end
        end
    elseif bm.open then
        if y >= bm.top and y < bm.top + bm.visible * bm.line_h then
            local idx = bm.first + math.floor((y - bm.top) / bm.line_h)
            if idx >= 1 and idx <= #bm.items then
                bm.selected = idx
                bm:rebuild()
                bm:activate()
            end
        end
    elseif st.open then
        if y >= toc.top and y < toc.top + 4 * toc.line_h then
            local idx = math.floor((y - toc.top) / toc.line_h) + 1
            if idx >= 1 and idx <= 4 then
                st.selected = idx
                st:rebuild()
                st:adjust(1)
            end
        end
    elseif lib.open then
        if y >= S(30) and y <= S(80) and x >= lib.open_x - S(12) then
            ctx.choose_book()
        elseif y >= S(30) and y <= S(80) and x >= lib.clear_x - S(8) then
            lib:clear_history()
        elseif y >= lib.top and y < lib.top + lib.visible * lib.line_h then
            local idx = lib.first + math.floor((y - lib.top) / lib.line_h)
            if idx >= 1 and idx <= #lib.items then
                lib.selected = idx
                lib:rebuild()
                lib:activate()
            end
        end
    else
        if not v.fs and y <= 58 then
            local id = ctx.header:hit(x)
            if id == "fs" then v.toggle_fs()
            elseif id == "max" then v.toggle_max()
            elseif id == "eye" then ctx.toggle_eye()
            elseif id == "dual" then ctx.toggle_dual()
            elseif id == "shot" then ctx.take_snapshot()
            elseif id == "text" then ctx.save_page_markdown()
            elseif id == "open" then ctx.choose_book()
            elseif id == "bm" then bm:show()
            elseif id == "st" then st:show()
            end
        else
            self:content_click(x, y)
        end
    end
end

function M:motion(x, y)
    local ctx = self.ctx
    local v = ctx.v
    if v.preview then
        if v.preview_drag then
            ctx.preview_pan(x - v.preview_dx, y - v.preview_dy)
            v.preview_dx, v.preview_dy = x, y
        end
        return
    end
    if v.dragging then
        local dx = x - v.drag_x
        local dy = y - v.drag_y
        v.drag_x, v.drag_y = x, y
        v.pan(dx)
        v.sy = math.max(0, math.min(v.max_scroll(), v.sy - dy))
        v.dirty = true
        self:set_cursor(false)
    else
        self:update_cursor(x, y)
    end
end

function M:wheel(dy)
    local ctx = self.ctx
    if ctx.v.preview then
        ctx.preview_zoom(dy * 0.2)
        return
    end
    if not ctx.toc.open and not ctx.bm.open and not ctx.st.open and not ctx.lib.open then
        if dy ~= 0 then ctx.v.scroll_by(-dy * 90) end
    end
end

function M:window(we, ew, eh)
    local ctx = self.ctx
    local v, sdl = ctx.v, ctx.sdl
    if we == sdl.WINDOWEVENT_SIZE_CHANGED or
       we == sdl.WINDOWEVENT_MAXIMIZED or
       we == sdl.WINDOWEVENT_RESTORED then
        v.resize_pending = true
        if (we == sdl.WINDOWEVENT_SIZE_CHANGED or
            we == 5) and ew and eh and ew > 0 and eh > 0 then
            v.resize_target_w = math.floor(ew * (v.scale_x or 1) + 0.5)
            v.resize_target_h = math.floor(eh * (v.scale_y or 1) + 0.5)
        else
            v.resize_target_w, v.resize_target_h = v.window_target_size()
        end
        if we == sdl.WINDOWEVENT_MAXIMIZED or
           we == sdl.WINDOWEVENT_RESTORED then
            v.resize_last_w, v.resize_last_h = nil, nil
            v.resize_due = v.now() + 0.05
        else
            v.resize_due = v.now() + 0.20
        end
    end
end

function M:key(k, mod)
    local ctx = self.ctx
    local v, sdl = ctx.v, ctx.sdl
    if v.preview then
        if k == sdl.SDLK_ESCAPE or k == sdl.SDLK_Q or k == sdl.SDLK_RETURN then
            ctx.close_preview()
        elseif k == sdl.SDLK_PLUS or k == sdl.SDLK_EQUALS or
               k == sdl.SDLK_KP_PLUS then
            ctx.preview_zoom(0.25)
        elseif k == sdl.SDLK_MINUS or k == sdl.SDLK_KP_MINUS then
            ctx.preview_zoom(-0.25)
        elseif k == sdl.SDLK_0 then
            ctx.preview_reset()
        end
        return
    end
    if k == sdl.SDLK_F10 then v.toggle_max()
    elseif k == sdl.SDLK_F11 then v.toggle_fs()
    elseif ctx.browser.open then ctx.browser:key(k)
    elseif ctx.toc.open then self:key_toc(k)
    elseif ctx.bm.open then self:key_bm(k)
    elseif ctx.st.open then self:key_st(k)
    elseif ctx.lib.open then ctx.lib:key(k, mod)
    else self:key_content(k, mod)
    end
end

function M:key_toc(k)
    local toc, sdl = self.ctx.toc, self.ctx.sdl
    if k == sdl.SDLK_UP then toc:move(-1)
    elseif k == sdl.SDLK_DOWN then toc:move(1)
    elseif k == sdl.SDLK_PAGEUP then toc:move(-10)
    elseif k == sdl.SDLK_PAGEDOWN then toc:move(10)
    elseif k == sdl.SDLK_RETURN or k == sdl.SDLK_RIGHT then toc:activate()
    elseif k == sdl.SDLK_ESCAPE or k == sdl.SDLK_T then toc:close()
    end
end

function M:key_bm(k)
    local ctx = self.ctx
    local bm, sdl = ctx.bm, ctx.sdl
    if k == sdl.SDLK_UP then bm:move(-1)
    elseif k == sdl.SDLK_DOWN then bm:move(1)
    elseif k == sdl.SDLK_PAGEUP then bm:move(-10)
    elseif k == sdl.SDLK_PAGEDOWN then bm:move(10)
    elseif k == sdl.SDLK_RETURN or k == sdl.SDLK_RIGHT then bm:activate()
    elseif k == sdl.SDLK_DELETE or k == sdl.SDLK_BACKSPACE then bm:remove_current()
    elseif k == sdl.SDLK_ESCAPE or k == sdl.SDLK_B then bm:close()
    elseif k == sdl.SDLK_A then bm:add_and_refresh(nil)
    end
end

function M:key_st(k)
    local st, sdl = self.ctx.st, self.ctx.sdl
    if k == sdl.SDLK_UP then st:move(-1)
    elseif k == sdl.SDLK_DOWN then st:move(1)
    elseif k == sdl.SDLK_LEFT then st:adjust(-1)
    elseif k == sdl.SDLK_RIGHT or k == sdl.SDLK_RETURN then st:adjust(1)
    elseif k == sdl.SDLK_ESCAPE or k == sdl.SDLK_S then st:close()
    end
end

function M:key_content(k, mod)
    local ctx = self.ctx
    local v, sdl = ctx.v, ctx.sdl
    if k == sdl.SDLK_ESCAPE then ctx.go_back(true)
    elseif k == sdl.SDLK_Q then ctx.quit()
    elseif k == sdl.SDLK_C then ctx.toggle_dual()
    elseif k == sdl.SDLK_E then ctx.toggle_eye()
    elseif (k == sdl.SDLK_RIGHT or k == sdl.SDLK_LEFT) and
           require("bit").band(mod, 3) ~= 0 then
        v.pan(k == sdl.SDLK_RIGHT and 120 or -120)
    elseif k == sdl.SDLK_RIGHT or k == sdl.SDLK_PAGEDOWN then ctx.turn(1)
    elseif k == sdl.SDLK_LEFT or k == sdl.SDLK_PAGEUP then ctx.turn(-1)
    elseif k == sdl.SDLK_PLUS or k == sdl.SDLK_EQUALS or
           k == sdl.SDLK_KP_PLUS then
        v.set_zoom(v.zoom * 1.25)
    elseif k == sdl.SDLK_MINUS or k == sdl.SDLK_KP_MINUS then
        v.set_zoom(v.zoom / 1.25)
    elseif k == sdl.SDLK_0 then v.set_zoom(1.0)
    elseif k == sdl.SDLK_DOWN then v.scroll_by(80)
    elseif k == sdl.SDLK_UP then v.scroll_by(-80)
    elseif k == sdl.SDLK_T then ctx.toc:show()
    elseif k == sdl.SDLK_O then ctx.choose_book()
    elseif k == sdl.SDLK_B then ctx.bm:show()
    elseif k == sdl.SDLK_S then ctx.st:show()
    elseif k == sdl.SDLK_A then ctx.bm:add_and_refresh(nil)
    elseif k == sdl.SDLK_F12 then ctx.take_snapshot()
    end
end

function M:handle(ev)
    local ctx = self.ctx
    local v, sdl = ctx.v, ctx.sdl
    local t = ev.type
    if t == sdl.QUIT then
        ctx.quit()
    elseif t == sdl.WINDOWEVENT then
        self:window(ev.window.event, ev.window.data1, ev.window.data2)
    elseif t == sdl.KEYDOWN then
        self:key(ev.key.sym, ev.key.mod)
    elseif t == sdl.MOUSEMOTION then
        self:motion(ev.motion.x * v.scale_x, ev.motion.y * v.scale_y)
    elseif t == sdl.MOUSEWHEEL then
        self:wheel(ev.wheel.y)
    elseif t == sdl.MOUSEBUTTONDOWN then
        local x = ev.button.x * v.scale_x
        local y = ev.button.y * v.scale_y
        local button = ev.button.button
        if button == 2 and not v.preview then
            v.dragging = true
            v.drag_x, v.drag_y = x, y
            self:set_cursor(false)
        else
            self:mouse_down(x, y, button)
        end
    elseif t == sdl.MOUSEBUTTONUP then
        if v.preview then
            v.preview_drag = false
        elseif ev.button.button == 2 then
            v.dragging = false
        end
    end
end

return M
