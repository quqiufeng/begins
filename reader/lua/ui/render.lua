-- 页面渲染层：页纹理、页缓存、链接与分页加载。
local M = {}
local PROF_TS = os.getenv("READER_PROF") ~= nil
local tnow = PROF_TS and require("core.clock").now or nil
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:content_sig()
    local ctx = self.ctx
    local v, s = ctx.v, ctx.settings
    local spread, _, _, avail_h, target_w = v.view_metrics()
    return v.view.signature({
        spread = spread, target_w = target_w, reflow = v.reflow,
        avail_h = avail_h, zoom = v.zoom,
        font_size = s.font_size, line_factor = s.line_factor, margin = s.margin,
        dark = s.theme == "dark",
        page_bg = (v.reflow and s.theme ~= "dark") and s.theme or 0,
    })
end

function M:max_scroll()
    local v = self.ctx.v
    local _, _, _, avail_h = v.view_metrics()
    local mh = math.max(v.tex_h or 0, v.p2h or 0)
    return math.max(0, mh - avail_h)
end

function M:relayout(frac)
    local ctx = self.ctx
    local v, s, R = ctx.v, ctx.settings, ctx.get_reader()
    if not v.reflow or not R.doc then return end
    local _, _, _, avail_h, target_w = v.view_metrics()
    local layout_w = v.view.layout_width(target_w)
    local margin = math.min(s.margin, math.floor(layout_w / 8))
    local nt, hit = v.layout:apply(R.doc, layout_w, avail_h,
        s.font_size, s.line_factor, margin)
    if hit then
        local seek = v.seek_page
        if seek then
            v.seek_page = nil
            R.page = math.max(0, math.min((R.total or 1) - 1, seek))
        end
        return
    end
    if nt and nt > 0 then
        R.total = nt
        local seek = v.seek_page            -- 开章时指定的页，布局完再夹取
        if seek then
            v.seek_page = nil
            R.page = math.max(0, math.min(R.total - 1, seek))
        else
            R.page = math.max(0, math.min(R.total - 1,
                math.floor((frac or 0) * R.total)))
        end
    end
end

function M:load_links(idx)
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local arr = {}
    local raw = ctx.rd.page_links(R.doc, idx)
    if raw then
        for line in raw:gmatch("[^\n]+") do
            local x0, y0, x1, y1, tp, ty = line:match(
                "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%-?%d+)\t([^\t]+)")
            if tp then
                arr[#arr + 1] = {
                    x0 = tonumber(x0), y0 = tonumber(y0),
                    x1 = tonumber(x1), y1 = tonumber(y1),
                    page = tonumber(tp), y = tonumber(ty) or 0,
                }
            end
        end
    end
    v.links[idx] = arr
end

function M:load_images(idx)
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local arr = {}
    local raw = ctx.rd.page_images(R.doc, idx)
    if raw then
        for line in raw:gmatch("[^\n]+") do
            local x0, y0, x1, y1 = line:match("([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)")
            if x0 then
                arr[#arr + 1] = {
                    x0 = tonumber(x0), y0 = tonumber(y0),
                    x1 = tonumber(x1), y1 = tonumber(y1),
                }
            end
        end
    end
    v.images[idx] = arr
end

function M:preview(page, img)
    local ctx = self.ctx
    local v, R = ctx.v, ctx.get_reader()
    local W, H, S = ctx.get_w(), ctx.get_h(), ctx.S
    local maxw = W - S(96)
    local maxh = H - S(160)
    local px, w, h, stride = ctx.rd.render_region(R.doc, page,
        img.x0, img.y0, img.x1, img.y1, maxw, maxh)
    if not px then return false end
    self:close_preview()
    local t = ctx.sdl.create_texture(ctx.ren, w, h)
    if not t then ctx.rd.free(px); return false end
    ctx.sdl.update_texture(t, px, stride)
    ctx.rd.free(px)
    v.preview = { tex = t, w = w, h = h, zoom = 1, pan_x = 0, pan_y = 0 }
    v.dirty = true
    return true
end

function M:close_preview()
    local v = self.ctx.v
    if v.preview then
        if v.preview.tex then self.ctx.sdl.destroy_texture(v.preview.tex) end
        v.preview = nil
        v.preview_drag = false
        v.dirty = true
    end
end

function M:preview_zoom(delta)
    local v = self.ctx.v
    if not v.preview then return end
    v.preview.zoom = math.max(0.5, math.min(6.0, (v.preview.zoom or 1) + delta))
    v.dirty = true
end

function M:preview_reset()
    local p = self.ctx.v.preview
    if not p then return end
    p.zoom = 1
    p.pan_x, p.pan_y = 0, 0
    self.ctx.v.dirty = true
end

function M:preview_pan(dx, dy)
    local v = self.ctx.v
    if not v.preview then return end
    v.preview.pan_x = (v.preview.pan_x or 0) + dx
    v.preview.pan_y = (v.preview.pan_y or 0) + dy
    v.dirty = true
end

function M:draw_preview(ren)
    local ctx = self.ctx
    local v = ctx.v
    local p = v.preview
    if not p then return end
    local ffi, sdl = ctx.ffi, ctx.sdl
    local W, H = ctx.get_w(), ctx.get_h()
    sdl.set_draw_color(ren, 0, 0, 0, 255)
    local bg = ffi.new("SDL_Rect")
    bg.x, bg.y, bg.w, bg.h = 0, 0, W, H
    sdl.render_fill_rect(ren, bg)

    local dw = math.floor(p.w * p.zoom)
    local dh = math.floor(p.h * p.zoom)
    local dst = ffi.new("SDL_Rect")
    dst.x = math.floor((W - dw) / 2 + (p.pan_x or 0))
    dst.y = math.floor((H - dh) / 2 + (p.pan_y or 0))
    dst.w, dst.h = dw, dh
    sdl.render_copy(ren, p.tex, nil, dst)

    local theme = ctx.get_theme()
    if theme and theme.line then
        sdl.set_draw_color(ren, theme.line[1], theme.line[2], theme.line[3], 255)
        sdl.render_draw_rect(ren, dst)
    end
end

function M:render_into(idx, target_w)
    local ctx = self.ctx
    local v, s, R = ctx.v, ctx.settings, ctx.get_reader()
    local rd = ctx.rd
    local pw = rd.page_size(R.doc, idx)
    local z = v.zoom or 1.2
    if pw and pw > 0 then z = target_w / pw end
    z = math.max(0.05, math.min(8.0, z))
    local br, bg, bb = v.page_bg_rgb()
    local t_rp = PROF_TS and tnow() or 0
    local pixels, w, h, stride = rd.render_page(R.doc, idx, z, br, bg, bb)
    if PROF_TS then
        io.stderr:write(string.format("[prof]   render_page %d %.1f ms %dx%d\n",
            idx, (tnow() - t_rp) * 1000, w or 0, h or 0))
    end
    if not pixels then return nil end
    if s.theme == "dark" then
        ctx.invert_rgba(pixels, w, h, stride or (w * 4))
    end
    local t_tx = PROF_TS and tnow() or 0
    local t = ctx.sdl.create_texture(ctx.ren, w, h)
    if not t then rd.free(pixels); return nil end
    ctx.sdl.update_texture(t, pixels, stride or (w * 4))
    if PROF_TS then
        io.stderr:write(string.format("[prof]   upload %d %.1f ms\n", idx, (tnow() - t_tx) * 1000))
    end
    rd.free(pixels)
    return t, w, h
end

function M:teardown()
    local ctx = self.ctx
    local v, sdl = ctx.v, ctx.sdl
    self:close_preview()
    if v.tex then sdl.destroy_texture(v.tex); v.tex = nil end
    if v.p2 then sdl.destroy_texture(v.p2); v.p2 = nil end
    if v.pcache then v.pcache:clear() end
    for _, t in ipairs(v.line_texs) do sdl.destroy_texture(t.tex) end
    v.line_texs = {}
    v.tex_w, v.tex_h = 0, 0
    v.p2w, v.p2h = 0, 0
end

local PROF = os.getenv("READER_PROF") ~= nil
local PROF_TS = PROF
local tnow = PROF and require("core.clock").now or nil

function M:load_page(n, keep_scroll)
    local ctx = self.ctx
    local t_start = PROF and tnow() or 0
    local v, s, R = ctx.v, ctx.settings, ctx.get_reader()
    local W, H = ctx.get_w(), ctx.get_h()
    local S = ctx.S
    local sdl, ttf, ren = ctx.sdl, ctx.ttf, ctx.ren

    local sig = self:content_sig()
    local invalidate = v.pending_layout or sig ~= v.content_sig_value
    if invalidate then
        v.pcache:clear()
        if v.tex then sdl.destroy_texture(v.tex); v.tex = nil end
        if v.p2 then sdl.destroy_texture(v.p2); v.p2 = nil end
    else
        if v.tex then
            v.pcache:put(sig .. ":" .. R.page, { tex = v.tex, w = v.tex_w, h = v.tex_h })
            v.tex = nil
        end
        if v.p2 then
            v.pcache:put(sig .. ":" .. (R.page + 1),
                { tex = v.p2, w = v.p2w, h = v.p2h })
            v.p2 = nil
        end
    end
    for _, t in ipairs(v.line_texs) do sdl.destroy_texture(t.tex) end
    v.line_texs = {}
    v.tex_w, v.tex_h, v.p2w, v.p2h = 0, 0, 0, 0

    if R.is_txt then
        local lines = R.pages and R.pages[n + 1]
        if not lines then return false end
        local f_body = ctx.get_font_body()
        local theme = ctx.get_theme()
        for _, line in ipairs(lines) do
            local w, h = ttf.size(f_body, line)
            local t = ttf.render_texture(ren, f_body, line,
                theme.text[1], theme.text[2], theme.text[3], 255)
            if t then v.line_texs[#v.line_texs + 1] = { tex = t, w = w, h = h } end
        end
        v.tex_w, v.tex_h = W, H
        v.images = {}
        R.page = n
        v.sy = 0
        v.refresh_text()
        v.content_sig_value = self:content_sig()
        print(string.format("[reader] txt page %d/%d", R.page + 1, R.total))
        return true
    end

    if v.pending_layout and v.reflow then
        v.pending_layout = false
        local frac = R.total > 0 and (n / R.total) or 0
        self:relayout(frac)
        n = R.page
    end

    local spread, _, _, _, target_w = v.view_metrics()
    if spread and n == 0 and not R.chapter_mode then
        target_w = math.max(160, W - S(48))
    end
    target_w = math.floor(target_w * v.zoom)
    sig = self:content_sig()
    local ce = v.pcache:take(sig .. ":" .. n)
    if PROF then
        io.stderr:write(string.format("[prof] hit page %d %s\n", n, ce and "yes" or "no"))
    end
    if ce then
        v.tex, v.tex_w, v.tex_h = ce.tex, ce.w, ce.h
    else
        v.tex, v.tex_w, v.tex_h = self:render_into(n, target_w)
    end
    if not v.tex then return false end
    if spread and (n > 0 or R.chapter_mode) and n + 1 < R.total then
        local ce2 = v.pcache:take(sig .. ":" .. (n + 1))
        if ce2 then
            v.p2, v.p2w, v.p2h = ce2.tex, ce2.w, ce2.h
        else
            v.p2, v.p2w, v.p2h = self:render_into(n + 1, target_w)
        end
    end
    R.page = n
    v.pan_x = 0
    v.links = {}
    v.images = {}
    self:load_links(R.page)
    self:load_images(R.page)
    if v.p2 then
        self:load_links(R.page + 1)
        self:load_images(R.page + 1)
    end
    v.sy = keep_scroll and (v.sy or 0) or 0
    v.sy = math.max(0, math.min(self:max_scroll(), v.sy))
    v.refresh_text()
    v.content_sig_value = sig
    v.prefetch = nil
    if R.chapter_mode then
        local step = spread and 2 or 1
        local np = n + step
        -- 双栏时把下一屏的两页都预热：逐页预热只暖一半，
        -- 下一屏仍要现场渲染一页，翻页耗时居高不下。
        local pages = {}
        if np < R.total then pages[#pages + 1] = np end
        if spread and np + 1 < R.total then pages[#pages + 1] = np + 1 end
        if #pages > 0 then
            v.prefetch = { sig = sig, pages = pages, target_w = target_w }
        end
    end
    print(string.format("[reader] page %d/%d  %dx%d%s", R.page + 1, R.total,
        v.tex_w, v.tex_h, v.p2 and " (+1)" or ""))
    if PROF then
        io.stderr:write(string.format("[prof] load_page %.1f ms (page %d)\n",
            (tnow() - t_start) * 1000, R.page + 1))
    end
    return true
end

return M
