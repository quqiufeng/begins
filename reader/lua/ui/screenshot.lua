-- 截图：命名、内容页合成、状态提示。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:path()
    local ctx = self.ctx
    local v = ctx.v
    local home = os.getenv("HOME") or "/tmp"
    local book = ctx.get_book()
    local name = book and book:match("([^/]+)$") or "reader"
    name = name:gsub("%.[%w]+$", "")
    name = name:gsub('[\\/:*?"<>|%c]', "_")
    if name == "" then name = "reader" end

    local p1 = ctx.get_page() + 1
    local p2 = v.p2 and (p1 + 1) or nil
    local label = p2 and string.format("%d_%d", p1, p2) or string.format("%d", p1)
    local base = string.format("%s/%s_%s", home, name, label)
    local path = base .. ".png"
    local i = 1
    while true do
        local f = io.open(path, "rb")
        if not f then break end
        f:close()
        path = string.format("%s-%d.png", base, i)
        i = i + 1
    end
    return path
end

function M:save_content(path)
    local ctx = self.ctx
    local v, rd, sdl, S = ctx.v, ctx.rd, ctx.sdl, ctx.S
    local W = ctx.get_w()
    local H = ctx.get_h()
    local settings = ctx.settings

    if ctx.get_is_txt() then
        local card_x = math.max(S(24), S(settings.margin - 24))
        local card_top = v.fs and S(24) or S(72)
        local w = W - 2 * card_x
        local h = H - card_top - S(64)
        return sdl.capture_rect(ctx.ren, card_x, card_top, w, h, path, rd)
    end

    local doc = ctx.get_doc()
    local page = ctx.get_page()
    local tex, tex_w = ctx.get_tex()
    if not doc or not tex then return false end

    local function shot(idx, target_w)
        if not target_w or target_w <= 0 then return nil end
        local pw = rd.page_size(doc, idx)
        if not pw or pw <= 0 then return nil end
        local br, bg, bb = v.page_bg_rgb()
        local pixels, w, h, stride = rd.render_page(doc, idx, target_w / pw, br, bg, bb)
        if not pixels then return nil end
        if settings.theme == "dark" then
            ctx.invert_rgba(pixels, w, h, stride or (w * 4))
        end
        return pixels, w, h
    end

    local a, aw, ah = shot(page, tex_w)
    if not a then return false end
    local b, bw, bh
    if v.p2 then b, bw, bh = shot(page + 1, v.p2w) end
    local ok = rd.save_pages_png(path, a, aw, ah, b, bw, bh, ctx.get_theme().paper, 0)
    rd.free(a)
    if b then rd.free(b) end
    return ok
end

function M:take()
    local ctx = self.ctx
    local path = self:path()
    ctx.draw()
    local ok = self:save_content(path)
    if ok then
        print("snapshot: " .. path)
        ctx.show_toast("截图已保存：" .. path, 4)
    else
        ctx.show_toast("截图失败", 3)
    end
    return ok, path
end

return M
