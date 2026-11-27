-- 设置应用：字体、主题、布局刷新与持久化。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

function M:apply()
    local ctx = self.ctx
    local v, settings, R = ctx.v, ctx.settings, ctx.get_reader()
    local font_changed = ctx.get_body_size() ~= settings.font_size
    local line_changed = v.last_line ~= settings.line_factor
    local margin_changed = v.last_margin ~= settings.margin
    local old_dark = ctx.get_theme() == ctx.themes.dark
    local old_theme = v.last_theme

    if font_changed then
        local nf = ctx.ttf.open(ctx.font_regular, ctx.S(settings.font_size)) or ctx.get_font_page()
        local old = ctx.get_font_body()
        ctx.set_font_body(nf)
        ctx.set_body_size(settings.font_size)
        if old and old ~= ctx.get_font_page() and old ~= nf then ctx.ttf.close(old) end
    end
    ctx.set_theme(ctx.themes[settings.theme] or ctx.themes.light)
    local theme = ctx.get_theme()
    local new_dark = theme == ctx.themes.dark
    v.last_line = settings.line_factor
    v.last_margin = settings.margin
    v.last_theme = settings.theme

    ctx.rebuild_header()
    ctx.save_settings()

    local style_changed = font_changed or line_changed or margin_changed
    if R.total > 0 then
        if R.is_txt then
            R:build_txt(R.book)
            R.page = math.max(0, math.min(R.total - 1, R.page))
            v.load_page(R.page)
        elseif R.reflow and style_changed then
            R:restyle()
        elseif v.pending_layout or old_dark ~= new_dark
            or (v.reflow and old_theme ~= settings.theme) then
            v.load_page(R.page)
        end
    end
    v.refresh_text()

    local st = ctx.get_st()
    if st and st.open then st:refresh() end
    local lib = ctx.get_lib()
    if lib and lib.open then lib:refresh() end
end

return M
