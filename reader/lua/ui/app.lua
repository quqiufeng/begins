package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local ffi = require("ffi")
ffi.cdef[[
unsigned int getuid(void);
]]
local sdl = require("ffi.sdl2")
local ttf = require("ffi.sdl2_ttf")
local rd = require("ffi.reader")
local automation = require("core.automation")
local library = require("core.library")

local initial_book = READER_BOOK or ""
local shot = READER_SCREENSHOT or ""
local initial_page = tonumber(READER_PAGE or "")
local zoom = tonumber(READER_ZOOM or "1.2") or 1.2
local frames = tonumber(READER_FRAMES or "0") or 0
local forced_ui_scale = tonumber(os.getenv("READER_UI_SCALE") or "")

sdl.set_hint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1")
if not sdl.init() then error("SDL_Init failed") end
if not ttf.init() then error("TTF_Init failed") end

local W, H = 900, 1200
local v = {
    win_w = W, win_h = H, win_x = 0, win_y = 0,
    fs = false, max = false, dual = true, auto_dual = false, sy = 0,
    reflow = false, pending_layout = false,
    zoom = 1.0, pan_x = 0,
    scale_x = 1, scale_y = 1, ui_scale = nil,
    dragging = false, drag_x = 0, drag_y = 0,
    cursor_arrow = nil, cursor_hand = nil, hover = false, hover_t = 0,
    dirty = true, had_event = false, drew = false,
    resize_pending = false, resize_due = 0, sync_at = 0,
    resize_last_w = nil, resize_last_h = nil, force_reload = false,
    startup_sync = false, startup_at = 0,
    resize_target_w = nil, resize_target_h = nil, scale_ready = false,
    p2 = nil, p2w = 0, p2h = 0,
    last_browse_dir = nil,
    toast = nil, toast_tex = nil, toast_w = 0, toast_h = 0, toast_until = 0,
    dialog = nil,
    rects = {}, links = {},
    tex = nil, tex_w = 0, tex_h = 0, line_texs = {},
    save_pending = false, save_due = 0,
}
-- 4 屏纹理：当前屏 + 预热的下一屏（双栏各 2 页），留余量翻回上一屏
v.pcache = require("ui.page_cache").new(sdl, 8)

-- kmsdrm 下窗口尺寸决定 SDL 挑哪个显示模式：小窗会被匹到 1080p 等非桌面模式。
-- 建窗前 sdl.get_current_display_mode() 返回的还是 kmsdrm 初始化默认值（1080p），
-- 用它建窗会先拿 1080p 的 fb 去配 2560x1440，内核 check 失败回 -ENOSPC
-- （fb 尺寸与请求模式不符）。这里取 connector 首选模式（索引 0），
-- 保证首次 SetCrtc 的 fb 与模式一致。
local video_driver = sdl.get_current_video_driver and sdl.get_current_video_driver() or nil
-- SDL 返回的是大写的 "KMSDRM"；原来跟小写比永远不相等，整段 kmsdrm 逻辑变死代码，
-- 窗口退回 900x1200 让 SDL 自己匹模式（常匹到 1080p/1536），画面就被上采样发虚。
local kmsdrm = type(video_driver) == "string" and video_driver:lower() == "kmsdrm"
if kmsdrm then
    -- 注意：不能写 `local dw, dh = f and f()`，`and` 只返回第一个值，dh 恒为 nil
    local dw, dh
    if sdl.get_preferred_display_mode then dw, dh = sdl.get_preferred_display_mode() end
    if not (dw and dh and dw > 0 and dh > 0) then
        dw, dh = sdl.get_current_display_mode()
    end
    if dw and dh and dw > 0 and dh > 0 then W, H = dw, dh end
end

local win = assert(sdl.create_window("reader", W, H), "SDL_CreateWindow failed")
v.win_x, v.win_y = sdl.get_window_position(win)
local icon = sdl.load_bmp("assets/icons/native-reader.bmp")
if icon ~= nil then
    sdl.set_window_icon(win, icon)
    sdl.free_surface(icon)
end
local ren = assert(sdl.create_renderer(win), "SDL_CreateRenderer failed")
local function sync_scale()
    if v.scale_ready then return end
    local ww, wh = sdl.get_window_size(win)
    local ow, oh = sdl.get_renderer_output_size(ren)
    if ww and wh and ww > 0 and wh > 0 and ow and oh then
        v.scale_x, v.scale_y = ow / ww, oh / wh
        if forced_ui_scale and forced_ui_scale > 0 then
            v.ui_scale = forced_ui_scale
        elseif not v.ui_scale then
            v.ui_scale = v.scale_x
        end
        v.scale_ready = true
    end
end
sync_scale()
v.window_target_size = function()
    return v.view.target_size(win, sdl, v.scale_x, v.scale_y, W, H)
end
ffi.cdef[[
typedef struct { long tv_sec; long tv_usec; } reader_timeval;
int gettimeofday(reader_timeval *tv, void *tz);
]]
v.now = function()
    local tv = ffi.new("reader_timeval")
    ffi.C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1000000
end
local function S(n)
    return math.floor(n * (v.ui_scale or 1) + 0.5)
end
v.cursor_arrow = sdl.create_system_cursor(sdl.SYSTEM_CURSOR_ARROW)
v.cursor_hand = sdl.create_system_cursor(sdl.SYSTEM_CURSOR_HAND)
if v.cursor_arrow then sdl.set_cursor(v.cursor_arrow) end

local font_regular = os.getenv("READER_FONT")
    or "assets/fonts/TsangerJinKai02-W04.ttf"
local font_bold = os.getenv("READER_FONT_BOLD")
    or "assets/fonts/TsangerJinKai02-W05.ttf"

local home = os.getenv("HOME") or "."
local data_base = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
local data_dir = data_base .. "/native-reader"
os.execute(("mkdir -p %q"):format(data_dir))
local state_file = data_dir .. "/state.lua"
local settings_file = data_dir .. "/settings.lua"

local themes = require("ui.themes")
local store = require("ui.store")
local panel = require("ui.panel")
local renderer = require("ui.renderer")
v.view = require("ui.view")
v.layout = require("ui.layout").new(rd)
v.content = require("ui.content")
local window_file = data_dir .. "/window.lua"
local wgeo = store.load(window_file)
if wgeo and wgeo.w and wgeo.h and wgeo.w >= 480 and wgeo.h >= 480 then
    if not kmsdrm then
        W, H = math.floor(wgeo.w), math.floor(wgeo.h)
        v.win_w, v.win_h = W, H
        sdl.set_window_size(win, W, H)
        if wgeo.x and wgeo.y and not (wgeo.x == 0 and wgeo.y == 0) then
            sdl.set_window_position(win, math.floor(wgeo.x), math.floor(wgeo.y))
            v.win_x, v.win_y = math.floor(wgeo.x), math.floor(wgeo.y)
        end
    end
    if wgeo.full and wgeo.full ~= 0 then
        v.fs = true
        -- kmsdrm 下再叫一次 SDL_SetWindowFullscreen(FULLSCREEN_DESKTOP) 会把显示
        -- 模式打回 display->desktop_mode —— 那是 SDL 初始化时从上一个进程留下的
        -- crtc 模式读来的（常年 1080p），整屏就降到 1080p 再被显示器上采样，发虚。
        -- 窗口建立时已按 connector 首选模式占满屏幕，这里只需置逻辑全屏状态。
        if not kmsdrm then sdl.set_window_fullscreen(win, true) end
    elseif wgeo.max and wgeo.max ~= 0 then
        v.max = true
        v.dual = true
        sdl.maximize_window(win)
    end
    if (v.fs or v.max) then
        v.startup_sync = true
        v.startup_at = v.now() + 0.30
    end
end
local THEMES = themes.THEMES
local THEME_ORDER = themes.ORDER
local THEME_NAMES = themes.NAMES
local FONT_ORDER = themes.FONT_ORDER
local LINE_ORDER = themes.LINE_ORDER
local MARGIN_ORDER = themes.MARGIN_ORDER

local settings = {
    theme = "light",
    font_size = 22,
    line_factor = 1.6,
    margin = 72,
}
for k, val in pairs(store.load(settings_file)) do settings[k] = val end
if not THEMES[settings.theme] then settings.theme = "light" end
settings.font_size = tonumber(settings.font_size) or 22
settings.line_factor = tonumber(settings.line_factor) or 1.6
settings.margin = tonumber(settings.margin) or 72
v.last_line = settings.line_factor
v.last_margin = settings.margin
v.last_theme = settings.theme

local theme = THEMES[settings.theme]
local body_size = settings.font_size

local f_title = ttf.open(font_bold, S(26))
local f_page = ttf.open(font_regular, S(18))
local f_body = ttf.open(font_regular, S(body_size))
if not f_title then f_title = f_page end
if not f_page then f_page = f_title end
if not f_body then f_body = f_page end

local function set_color(c)
    sdl.set_draw_color(ren, c[1], c[2], c[3], c[4] or 255)
end

local progress = store.load(state_file)

local R
local render
local chrome
local settingsctl
local running = true

local title_text = ""

local function teardown_pages()
    if render then render:teardown() end
    if chrome then chrome:destroy() end
end

local toc

local bm

local st

local lib
local remote

local browser

local function book_rec()
    local rec = progress[R.book]
    if not rec then
        rec = {}
        progress[R.book] = rec
    end
    return rec
end

function v.save_progress(force)
    if not R.book then return end
    local rec = book_rec()
    rec.page = R.page
    rec.updated = os.time()
    if R.chapter_mode and R.chapters and #R.chapters > 0 then
        rec.chapter = R.chapter_idx
    else
        rec.chapter = nil
    end
    if force then
        store.save_state(state_file, progress)
        v.save_pending = false
        v.save_due = 0
    elseif not v.save_pending then
        v.save_pending = true
        v.save_due = v.now() + 1.0
    end
end

function v.make_text(text, font, c)
    if not font then return nil, 0, 0 end
    local w, h = ttf.size(font, text)
    local t = ttf.render_texture(ren, font, text, c[1], c[2], c[3], c[4] or 255)
    return t, w, h
end

local toast = require("ui.toast").new({
    sdl = sdl, ffi = ffi, ren = ren, S = S, set_color = set_color,
    make_text = v.make_text, f_page = f_page,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    now = v.now, v = v,
})
v.show_toast = function(text, seconds) toast:show(text, seconds) end

header = require("ui.header").new({
    v = v, sdl = sdl, ffi = ffi, S = S,
    get_theme = function() return theme end,
    get_font = function() return f_page end,
    get_w = function() return W end,
    get_wh = function() return W, H end,
    set_color = set_color,
})
local function rebuild_header_actions() header:rebuild() end
rebuild_header_actions()

local textutil = require("ui.text")
local utf8_chars = textutil.utf8_chars
local truncate_utf8 = textutil.truncate_utf8

chrome = require("ui.chrome").new({
    v = v, sdl = sdl, ffi = ffi, S = S, ttf = ttf, utf8_chars = utf8_chars,
    get_title = function() return title_text end,
    get_reader = function() return R end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_theme = function() return theme end,
    get_w = function() return W end,
    get_h = function() return H end,
    get_title_max_w = function()
        return (header.st_x or W) - S(24) - S(16)
    end,
})
v.refresh_text = function() chrome:refresh() end

local epub = require("ui.epub")
local txtmod = require("ui.txt")

local function txt_line_height()
    return txtmod.line_height(S(settings.font_size), settings.line_factor)
end

toc = require("ui.toc").new({
    v = v, rd = rd, sdl = sdl, ttf = ttf, panel = panel, S = S, ren = ren,
    get_reader = function() return R end,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_is_txt = function() return R.is_txt end,
    get_total = function() return R.total end,
    get_doc = function() return R.doc end,
    close_others = function() bm:close(); st:close() end,
})

bm = require("ui.bookmarks").new({
    v = v, sdl = sdl, ttf = ttf, panel = panel, S = S, ren = ren,
    get_reader = function() return R end,
    store = store, state_file = state_file,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_book = function() return R.book end,
    get_page = function() return R.page end,
    get_total = function() return R.total end,
    get_progress = function() return progress end,
    book_rec = book_rec,
    close_others = function() toc:close(); st:close() end,
})

local function close_book()
    toc:close()
    bm:close()
    st:close()
    v.save_progress(true)
    R:close()
    teardown_pages()
    v.sy = 0
    v.prefetch = nil
    v.pending_layout = false
    v.reflow = false
    v.layout:reset()
    v.content_sig_value = nil
end

local function invert_rgba(pixels, w, h, stride)
    local p = ffi.cast("uint8_t*", pixels)
    for y = 0, h - 1 do
        local base = y * stride
        for x = 0, w - 1 do
            local i = base + x * 4
            p[i] = 255 - p[i]
            p[i + 1] = 255 - p[i + 1]
            p[i + 2] = 255 - p[i + 2]
        end
    end
end

v.spread_mode = function()
    return (v.fs or v.dual) and not R.is_txt and R.doc ~= nil
end

v.view_metrics = function()
    local spread = v.spread_mode()
    local top = v.fs and 0 or S(59)
    local bottom = v.fs and S(42) or S(50)
    local avail_h = H - top - bottom
    local target_w
    if spread then
        local side, gap = S(16), S(5)
        target_w = math.floor((W - 2 * side - gap) / 2)
    else
        target_w = math.max(160, W - S(48))
    end
    return spread, top, bottom, avail_h, target_w
end

v.page_bg_rgb = function()
    if not v.reflow or settings.theme == "dark" then return nil end
    local p = theme.paper
    return p[1], p[2], p[3]
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

R = require("ui.reader").new({
    v = v, rd = rd, ttf = ttf, ffi = ffi, S = S, settings = settings,
    epub = epub, txtmod = txtmod, utf8_chars = utf8_chars,
    truncate_utf8 = truncate_utf8,
    get_w = function() return W end,
    get_h = function() return H end,
    get_font_body = function() return f_body end,
    get_progress = function() return progress end,
    save_progress = function() v.save_progress() end,
    refresh_text = function() v.refresh_text() end,
    load_page = function(n, k) return v.load_page(n, k) end,
    close_panels = function() v.close_panels() end,
    reset_book = function() close_book() end,
    teardown_pages = function() teardown_pages() end,
    set_title = function(t) title_text = t end,
})
v.open_book = function(path, start)
    local ok, err = R:open_book(path, start)
    if not ok and err then v.show_toast(tostring(err), 5) end
    return ok, err
end
v.open_chapter = function(idx, p) return R:open_chapter(idx, p) end
v.normalize_book_path = function(path) return R:normalize(path) end

render = require("ui.render").new({
    v = v, rd = rd, sdl = sdl, ttf = ttf, ffi = ffi, ren = ren, S = S, settings = settings,
    get_reader = function() return R end,
    get_w = function() return W end,
    get_h = function() return H end,
    get_font_body = function() return f_body end,
    get_theme = function() return theme end,
    invert_rgba = function(pixels, w, h, stride) invert_rgba(pixels, w, h, stride) end,
})
v.content_sig = function() return render:content_sig() end
v.max_scroll = function() return render:max_scroll() end
v.relayout = function(frac) return render:relayout(frac) end
v.load_links = function(idx) return render:load_links(idx) end
v.render_into = function(idx, tw) return render:render_into(idx, tw) end
v.load_page = function(n, keep) return render:load_page(n, keep) end

local function draw_page()
    v.content.draw({
        sdl = sdl, ffi = ffi, ren = ren, W = W, H = H, S = S,
        set_color = set_color,
        is_txt = R.is_txt, settings = settings, theme = theme,
        line_texs = v.line_texs, tex = v.tex, tex_w = v.tex_w, tex_h = v.tex_h,
        v = v, page = R.page, total = R.total,
        txt_line_height = txt_line_height,
        chrome = chrome,
        header = header,
    })
end

local function cycle(list, value, delta)
    local idx = 1
    for i, v in ipairs(list) do
        if v == value then idx = i end
    end
    idx = ((idx - 1 + delta) % #list) + 1
    return list[idx]
end

local function apply_settings() return settingsctl:apply() end

st = require("ui.settings").new({
    v = v, sdl = sdl, ttf = ttf, panel = panel, ren = ren, S = S,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_settings = function() return settings end,
    get_list_layout = function() return toc.top, toc.line_h end,
    close_others = function() toc:close(); bm:close() end,
    apply = function() apply_settings() end,
})

lib = require("ui.bookshelf").new({
    v = v, sdl = sdl, ttf = ttf, panel = panel, ffi = ffi, ren = ren, S = S,
    set_color = set_color, library = library, rd = rd,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_home = function() return home end,
    get_progress = function() return progress end,
    save_state = function() store.save_state(state_file, progress) end,
    save_progress = function() v.save_progress() end,
    close_book = function() close_book() end,
    open_book = function(path, start) return v.open_book(path, start) end,
    close_others = function() toc:close(); bm:close(); st:close() end,
    open_settings = function() st:show() end,
    choose_book = function() v.choose_book() end,
    quit = function() running = false end,
})

settingsctl = require("ui.settings_apply").new({
    v = v, settings = settings, ttf = ttf, S = S,
    font_regular = font_regular, themes = THEMES,
    get_reader = function() return R end,
    get_body_size = function() return body_size end,
    set_body_size = function(n) body_size = n end,
    get_font_body = function() return f_body end,
    set_font_body = function(f) f_body = f end,
    get_font_page = function() return f_page end,
    get_theme = function() return theme end,
    set_theme = function(t) theme = t end,
    rebuild_header = function() rebuild_header_actions() end,
    save_settings = function() store.save_settings(settings_file, settings) end,
    get_st = function() return st end,
    get_lib = function() return lib end,
})

browser = require("ui.browser").new({
    v = v, rd = rd, sdl = sdl, ttf = ttf, panel = panel, ffi = ffi, ren = ren, S = S,
    get_theme = function() return theme end,
    get_wh = function() return W, H end,
    get_fonts = function() return f_body, f_title, f_page end,
    get_home = function() return home end,
    get_book = function() return R.book end,
    get_last_dir = function() return v.last_browse_dir end,
    set_last_dir = function(d) v.last_browse_dir = d end,
    open_book = function(path, start) return v.open_book(path, start) end,
    close_others = function() toc:close(); bm:close(); st:close() end,
    close_library = function() if lib.open then lib:close() end end,
    mark_dirty = function() v.dirty = true end,
})
v.open_browser = function(start) browser:show(start) end

local filedialog = require("ui.file_dialog").new({
    v = v, home = home,
    open_browser = function() v.open_browser() end,
    open_book = function(path, start) return v.open_book(path, start) end,
    show_toast = function(text, secs) v.show_toast(text, secs) end,
    now = function() return v.now() end,
})
v.choose_book = function() filedialog:choose() end

local nav = require("ui.nav").new({
    v = v, settings = settings, S = S,
    get_reader = function() return R end,
    get_w = function() return W end,
    apply_settings = function() apply_settings() end,
    rebuild_header = function() rebuild_header_actions() end,
    cycle = cycle, theme_order = THEME_ORDER,
    lib = lib, toc = toc, bm = bm, st = st, browser = browser,
})
local function turn(delta) return nav:turn(delta) end
v.scroll_by = function(dy) return nav:scroll(dy) end
v.set_zoom = function(z) return nav:zoom(z) end
v.pan = function(dx) return nav:pan(dx) end
local function toggle_dual() nav:toggle_dual() end
local function toggle_eye() nav:toggle_eye() end
local function go_back(allow_window) return nav:go_back(allow_window) end

local winmod = require("ui.window").new({
    v = v, sdl = sdl, win = win, lib = lib, S = S,
    get_reader = function() return R end,
    get_w = function() return W end,
    get_h = function() return H end,
    set_wh = function(w, h) W, H = w, h end,
    sync_scale = function() sync_scale() end,
    rebuild_header = function() rebuild_header_actions() end,
})
v.toggle_fs = function() return winmod:toggle_fs() end
v.toggle_max = function() return winmod:toggle_max() end
v.ensure_content_size = function() return winmod:ensure_content_size() end
local function apply_resize(nw, nh) return winmod:apply_resize(nw, nh) end

v.close_panels = function()
    if toc.open then toc:close() end
    if bm.open then bm:close() end
    if st.open then st:close() end
    if browser.open then browser:close() end
    if lib.open then
        lib:close()
    end
end

-- 当前最上层界面：给自动化 state 用的 panel 字段（顺序与渲染一致）
local function current_panel()
    return renderer.kind({
        browser = browser.open,
        toc = toc.open,
        bookmarks = bm.open,
        settings = st.open,
        library = lib.open,
    })
end

local function render_frame()
    local kind = current_panel()
    renderer.draw(kind, {
        browser = function() browser:draw() end,
        toc = function() toc:draw() end,
        bookmarks = function() bm:draw() end,
        settings = function() st:draw() end,
        library = function() lib:draw() end,
        content = draw_page,
    })
    render:draw_preview(ren)
    toast:draw()
end

local function draw()
    render_frame()
    sdl.render_present(ren)
end

if v.startup_sync and shot == "" then
    v.pending_initial = { book = initial_book, page = initial_page }
elseif initial_book ~= "" then
    local ok, err = v.open_book(initial_book, initial_page)
    if not ok then error("open failed: " .. tostring(err)) end
else
    lib:show()
end

local screenshot = require("ui.screenshot").new({
    v = v, rd = rd, sdl = sdl, ren = ren, S = S, settings = settings,
    get_w = function() return W end,
    get_h = function() return H end,
    get_page = function() return R.page end,
    get_tex = function() return v.tex, v.tex_w end,
    get_is_txt = function() return R.is_txt end,
    get_doc = function() return R.doc end,
    get_book = function() return R.book end,
    get_theme = function() return theme end,
    invert_rgba = function(pixels, w, h, stride) invert_rgba(pixels, w, h, stride) end,
    draw = function() draw() end,
    show_toast = function(text, secs) v.show_toast(text, secs) end,
})
local pagemd = require("ui.page_md").new({
    v = v, rd = rd, S = S, settings = settings, reader = R,
    get_page = function() return R.page end,
    get_total = function() return R.total end,
    get_is_txt = function() return R.is_txt end,
    get_pages = function() return R.pages end,
    get_doc = function() return R.doc end,
    get_book = function() return R.book end,
    show_toast = function(text, secs) v.show_toast(text, secs) end,
})
v.markdown_path = function() return pagemd:path() end
v.save_page_markdown = function(path) return pagemd:take(path) end

v.snapshot_path = function() return screenshot:path() end
v.save_content_snapshot = function(path) return screenshot:save_content(path) end
v.take_snapshot = function() return screenshot:take() end

local input = require("ui.input").new({
    v = v, sdl = sdl, rd = rd, S = S, header = header,
    browser = browser, toc = toc, bm = bm, st = st, lib = lib,
    get_page = function() return R.page end,
    get_tex_h = function() return v.tex_h end,
    get_is_txt = function() return R.is_txt end,
    get_doc = function() return R.doc end,
    get_w = function() return W end,
    get_h = function() return H end,
    turn = function(n) turn(n) end,
    go_back = function(allow) go_back(allow) end,
    toggle_dual = function() toggle_dual() end,
    toggle_eye = function() toggle_eye() end,
    choose_book = function() v.choose_book() end,
    take_snapshot = function() v.take_snapshot() end,
    save_page_markdown = function(path) return v.save_page_markdown(path) end,
    show_image = function(page, img)
        if render:preview(page, img) then
            v.show_toast("滚轮缩放 · 拖动平移 · Esc/右键关闭", 3)
        end
    end,
    close_preview = function() render:close_preview() end,
    preview_zoom = function(d) render:preview_zoom(d) end,
    preview_pan = function(dx, dy) render:preview_pan(dx, dy) end,
    preview_reset = function() render:preview_reset() end,
    quit = function() running = false end,
})

remote = require("ui.remote").new({
    v = v, rd = rd, settings = settings, lib = lib, toc = toc, bm = bm, st = st,
    reader = R,
    get_page = function() return R.page end,
    get_total = function() return R.total end,
    get_book = function() return R.book end,
    get_is_txt = function() return R.is_txt end,
    get_pages = function() return R.pages end,
    get_doc = function() return R.doc end,
    get_w = function() return W end,
    get_h = function() return H end,
    validate_theme = function(t) return THEMES[t] ~= nil end,
    turn = function(n) turn(n) end,
    toggle_dual = function() toggle_dual() end,
    toggle_eye = function() toggle_eye() end,
    close_book = function() close_book() end,
    open_book = function(path, pg) return v.open_book(path, pg) end,
    apply_settings = function() apply_settings() end,
    draw = function() draw() end,
    capture = function(path)
        render_frame()
        local ok = sdl.capture(ren, W, H, path, rd)
        sdl.render_present(ren)
        return ok
    end,
    quit = function() running = false end,
    get_panel = function() return current_panel() end,
})

local server = nil
if shot == "" then
    local sock = os.getenv("READER_AUTOMATION_SOCK")
        or "/tmp/native-reader-automation.sock"
    local ok_srv, s = pcall(automation.start, sock, {
        actions = function() return remote:actions() end,
        state = function() return remote:state() end,
        click = function(id)
            local r = remote:click(id)
            v.dirty = true
            return r
        end,
        call = function(fn, args)
            local r = remote:call(fn, args)
            v.dirty = true
            return r
        end,
    })
    if ok_srv then
        server = s
        print("[reader] automation: " .. sock)
    else
        io.stderr:write("[reader] automation disabled: " .. tostring(s) .. "\n")
    end
end

local function cleanup()
    if server then server:stop(); server = nil end
    if browser.open then browser:close() end
    close_book()
    if lib.open then lib:destroy() end
    header:destroy()
    toast:clear()
    local seen = {}
    for _, f in ipairs({ f_title, f_page, f_body }) do
        if f and not seen[f] then
            seen[f] = true
            ttf.close(f)
        end
    end
    local wx, wy = sdl.get_window_position(win)
    if v.fs or v.max then
        wx, wy = v.win_x, v.win_y
    end
    store.save_window(window_file, {
        w = v.win_w, h = v.win_h, x = wx, y = wy,
        max = v.max and 1 or 0, full = v.fs and 1 or 0,
    })
    ttf.quit()
    sdl.destroy_renderer(ren)
    sdl.destroy_window(win)
    sdl.free_cursor(v.cursor_hand); v.cursor_hand = nil
    sdl.free_cursor(v.cursor_arrow); v.cursor_arrow = nil
    sdl.quit()
end

if shot ~= "" then
    for _ = 1, math.max(1, frames) do
        draw()
        sdl.delay(16)
    end
    if sdl.capture(ren, W, H, shot, rd) then
        print("screenshot: " .. shot)
    else
        io.stderr:write("screenshot failed\n")
    end
    cleanup()
    os.exit(0)
end

local loop = require("ui.loop").new({
    sdl = sdl, ffi = ffi, v = v,
    input = input, filedialog = filedialog, toast = toast, lib = lib,
    get_reader = function() return R end,
    is_running = function() return running end,
    get_server = function() return server end,
    set_wh = function(w, h) W, H = w, h end,
    rebuild_header = function() rebuild_header_actions() end,
    open_book = function(path, page) return v.open_book(path, page) end,
    load_page = function(n, k) return v.load_page(n, k) end,
    refresh_text = function() v.refresh_text() end,
    apply_resize = function(nw, nh) return apply_resize(nw, nh) end,
    save_state = function() store.save_state(state_file, progress) end,
    draw = function() draw() end,
})
loop:run()
cleanup()
