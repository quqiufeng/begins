-- 当前书籍会话：文档状态、打开/关章、TXT 分页与进度入口。
local ffi = require("ffi")
pcall(ffi.cdef, "unsigned int getuid(void);")

local M = {}
M.__index = M

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local DEFAULT_MAX_MB = 200

-- READER_PROF=1 时打印打开各阶段耗时（ms），用于冷开性能回归。
local PROF = os.getenv("READER_PROF") ~= nil
local prof_t0
local prof_now = PROF and require("core.clock").now or nil
local function prof_mark(stage, phase)
    if not PROF then return end
    local s = prof_now()
    io.stderr:write(string.format("[prof] open.%s %s %.1f ms\n",
        phase or "book", stage, (s - prof_t0) * 1000))
end

function M.max_book_mb()
    local mb = tonumber(os.getenv("READER_MAX_BOOK_MB") or "")
    if not mb or mb <= 0 then mb = DEFAULT_MAX_MB end
    return mb
end

function M.book_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

function M.exceeds_limit(size)
    return size ~= nil and size > M.max_book_mb() * 1024 * 1024
end

function M.new(ctx)
    return setmetatable({
        ctx = ctx,
        book = nil,
        doc = nil,
        total = 0,
        page = 0,
        pages = nil,
        is_txt = false,
        chapters = nil,
        chapter_idx = 1,
        chapter_mode = false,
    }, M)
end

-- 布局参数签名：换字号/行距/边距/版面尺寸都必须换 accel 缓存，
-- 否则 MuPDF 会用不同布局下算出的页数表。
local function layout_sig(s, w, h, margin)
    return string.format("%d-%d-%d-%dx%d",
        math.floor((s.font_size or 16) * 10 + 0.5),
        math.floor((s.line_factor or 1.6) * 100 + 0.5),
        math.floor((margin or s.margin or 72) + 0.5),
        math.floor(w + 0.5), math.floor(h + 0.5))
end

-- 目标布局尺寸，必须与 render.relayout 完全一致（含边距夹取）。
function M:layout_dims()
    local ctx = self.ctx
    local v, s = ctx.v, ctx.settings
    local avail_h, target_w
    if v.view_metrics then
        local _, _, _, ah, tw = v.view_metrics()
        avail_h, target_w = ah, tw
    end
    local layout_w = (avail_h and avail_h > 100)
        and v.view.layout_width(target_w) or 0
    if not layout_w or layout_w < 100 then layout_w = 0 end
    if not avail_h or avail_h < 100 then avail_h = 0 end
    local margin = layout_w > 0
        and math.min(s.margin or 72, math.floor(layout_w / 8))
        or (s.margin or 72)
    return layout_w, avail_h, margin
end

-- 重排格式的布局加速缓存路径（MuPDF accelerator）。
-- 放在解包缓存根下的 .accel/，文件名带 路径哈希 + 文件大小 + 布局参数，
-- 任一变化就自然失效，不会读到过期页数。
function M:accel_path(path, w, h, margin)
    local ctx = self.ctx
    if not ctx.v.reflow or not path then return nil end
    local root = ctx.rd.cache_dir and ctx.rd.cache_dir()
    if not root then return nil end
    if not self.accel_dir then
        local dir = root .. "/.accel"
        ctx.rd.mkdir_p(dir)
        self.accel_dir = dir
    end
    local size = M.book_size(path) or 0
    -- hash() 已经是 %08x 字符串，这里不能再按 %x 格式化。
    return string.format("%s/%s-%d-%s.bin", self.accel_dir,
        ctx.epub.hash(path), size, layout_sig(ctx.settings, w or 0, h or 0,
                                              margin))
end

-- defer_layout：调用方随后一定会按真实尺寸布局（分章模式），
-- 这里就不要先按探测尺寸 reflow 一遍。
function M:open_doc(path, defer_layout)
    local ctx = self.ctx
    if ctx.epub and ctx.epub.fix_anchors then ctx.epub.fix_anchors(path) end
    local s = ctx.settings
    local w, h, margin = self:layout_dims()
    if defer_layout then w, h = -1, -1 end
    if PROF then
        io.stderr:write(string.format("[prof] open.layout %s w=%d h=%d em=%.1f mg=%d\n",
            path:match("[^/]*$") or "?", w, h, s.font_size or 0, margin))
    end
    return ctx.rd.open(path, s.font_size, s.line_factor, margin,
        self:accel_path(path, w, h, margin), w, h)
end

function M:restyle()
    if not self.doc or self.is_txt then return false end
    local ctx = self.ctx
    local path
    if self.chapter_mode and self.chapters and self.chapters[self.chapter_idx] then
        path = self.chapters[self.chapter_idx].path
    else
        path = self.book
    end
    if not path then return false end
    local h, err = self:open_doc(path)
    if not h then return false, err end
    ctx.rd.close(self.doc)
    self.doc = h
    self.total = ctx.rd.page_count(h)
    ctx.v.chapter_prefetch_done = nil
    ctx.teardown_pages()
    ctx.v.layout:reset()
    ctx.v.content_sig_value = nil
    ctx.v.pending_layout = true
    self.page = math.max(0, math.min(self.total - 1, self.page))
    return ctx.load_page(self.page)
end

function M:normalize(path)
    if not path or path == "" or path:sub(1, 1) == "/" then return path end
    local ctx = self.ctx
    local ffi = ctx.ffi
    local uid = tonumber(ffi.C.getuid()) or 1000
    local gvfs = string.format("/run/user/%d/gvfs/", uid)
    local p = path

    if p:sub(1, 7) == "file://" then
        local q = url_decode(p:sub(8))
        local f = io.open(q, "rb")
        if f then f:close(); return q end
        return path
    end

    local scheme, host, port, rest = p:match("^(davs?)://([^/:]+):?(%d*)(/.*)$")
    if scheme then
        local ssl = (scheme == "davs") and "true" or "false"
        local base
        if port and port ~= "" then
            base = string.format("%sdav:host=%s,port=%s,ssl=%s",
                gvfs, host, port, ssl)
        else
            base = string.format("%sdav:host=%s,ssl=%s", gvfs, host, ssl)
        end
        local q = base .. url_decode(rest)
        local f = io.open(q, "rb")
        if f then f:close(); return q end
    end

    local smb_host, share, srest = p:match("^smb://([^/]+)/([^/]+)(/.*)$")
    if smb_host then
        local q = string.format("%ssmb-share:server=%s,share=%s%s",
            gvfs, smb_host, share, url_decode(srest))
        local f = io.open(q, "rb")
        if f then f:close(); return q end
    end

    local shost, srest2 = p:match("^sftp://([^/]+)(/.*)$")
    if shost then
        local q = string.format("%ssftp:host=%s%s",
            gvfs, shost, url_decode(srest2))
        local f = io.open(q, "rb")
        if f then f:close(); return q end
    end
    return path
end

function M:close()
    if self.doc then
        self.ctx.rd.close(self.doc)
        self.doc = nil
    end
    self.book = nil
    self.total = 0
    self.page = 0
    self.pages = nil
    self.is_txt = false
    self:drop_chapter_prefetch()
    self.chapters = nil
    self.chapter_idx = 1
    self.chapter_mode = false
end

function M:build_txt(path)
    local ctx = self.ctx
    local S = ctx.S
    local settings = ctx.settings
    local pgs, tot, err = ctx.txtmod.paginate(path, {
        ttf = ctx.ttf, font = ctx.get_font_body(),
        width = ctx.get_w(), height = ctx.get_h(), top = S(96), bottom = S(80),
        margin = S(settings.margin), font_size = S(settings.font_size),
        line_factor = settings.line_factor, utf8_chars = ctx.utf8_chars,
    })
    if not pgs then return false, err end
    self.pages = pgs
    self.total = tot
    return true
end

-- 分章模式下章节切换要现场解析 XHTML（大章节 100~200ms），
-- 这是连续翻页里最刺眼的停顿。空闲时提前把下一章的文档句柄打开，
-- 到章末只需要接管句柄，省掉解析开销。
local function ch_settings_sig(s)
    if not s then return "0" end
    return string.format("%.2f/%.2f/%d",
        s.font_size or 0, s.line_factor or 0, math.floor(s.margin or 0))
end

local PREFETCH_MAX_BYTES = 4 * 1024 * 1024

function M:next_chapter_idx()
    if not self.chapter_mode or not self.chapters or not self.chapter_idx then
        return nil
    end
    local n = self.chapter_idx + 1
    if self.chapters[n] then return n end
    return nil
end

function M:drop_chapter_prefetch()
    local pf = self.ch_prefetch
    self.ch_prefetch = nil
    if pf and pf.handle then self.ctx.rd.close(pf.handle) end
end

function M:prefetch_chapter(idx)
    if not idx then return false end
    if not self.chapters or not self.chapters[idx] then return false end
    local sig = ch_settings_sig(self.ctx.settings)
    local pf = self.ch_prefetch
    if pf and pf.idx == idx and pf.sig == sig then return false end
    self:drop_chapter_prefetch()
    local path = self.chapters[idx].path
    local sz = M.book_size(path) or 0
    if sz > PREFETCH_MAX_BYTES then
        if PROF then
            io.stderr:write(string.format(
                "[prof] chapter prefetch skip idx %d %.0f KB\n", idx, sz / 1024))
        end
        return false
    end
    -- 按真实尺寸打开并布局：章节切换时就不必再 fz_layout_document
    -- （大章节 30~40ms），这一步留在空闲帧里做。
    local ok, h = pcall(self.open_doc, self, path, false)
    if not ok or not h then return false end
    self.ch_prefetch = { idx = idx, handle = h, sig = sig }
    if PROF then
        io.stderr:write(string.format("[prof] chapter prefetch idx %d ok\n", idx))
    end
    return true
end

function M:open_chapter(idx, local_page)
    if not self.chapters or not self.chapters[idx] then return false, "no chapter" end
    local ctx = self.ctx
    local t_ch = PROF and prof_now() or 0
    local t_od = t_ch
    local h, err
    local pf = self.ch_prefetch
    if pf and pf.idx == idx and pf.handle
        and pf.sig == ch_settings_sig(ctx.settings) then
        h = pf.handle
        self.ch_prefetch = nil
        if PROF then io.stderr:write("[prof] chapter prefetch hit\n") end
    else
        self:drop_chapter_prefetch()
        h, err = self:open_doc(self.chapters[idx].path, ctx.v.reflow)
    end
    if PROF then
        io.stderr:write(string.format("[prof] chapter open_doc %.1f ms\n",
            (prof_now() - t_od) * 1000))
        t_od = prof_now()
    end
    if not h then return false, err end
    -- 重排格式的章页数由 layout 顺势算出：这里再 page_count 会先按一套
    -- 尺寸 reflow 一遍，load_page 里又按真实尺寸 reflow 一遍（翻倍开销）。
    -- 所以先挂起，让 load_page 的 relayout 一次到底。
    local nt = ctx.v.reflow and nil or ctx.rd.page_count(h)
    if nt and nt <= 0 then ctx.rd.close(h); return false, "no pages" end
    if self.doc then ctx.rd.close(self.doc) end
    self.doc = h
    self.chapter_idx = idx
    self.total = nt or 1
    ctx.v.chapter_prefetch_done = nil
    ctx.teardown_pages()
    ctx.v.layout:reset()
    ctx.v.content_sig_value = nil
    ctx.v.pending_layout = true
    local p = local_page or 0
    if p < 0 then p = math.max(0, self.total - 1) end
    p = math.max(0, p)
    self.page = p
    if ctx.v.reflow then ctx.v.seek_page = p end
    if PROF then
        io.stderr:write(string.format("[prof] chapter prep %.1f ms\n",
            (prof_now() - t_od) * 1000))
        t_od = prof_now()
    end
    local ok = ctx.load_page(p)
    if PROF then
        io.stderr:write(string.format("[prof] chapter total %.1f ms (idx %d)\n",
            (prof_now() - t_ch) * 1000, idx))
    end
    return ok
end

function M:open_book(path, start_page)
    if not path or path == "" then return false, "empty path" end
    if PROF then prof_t0 = prof_now() end
    local ctx = self.ctx
    local v = ctx.v
    path = self:normalize(path)
    local size = M.book_size(path)
    if M.exceeds_limit(size) then
        return false, string.format("文件过大：%.1f MB（上限 %d MB）",
            size / 1024 / 1024, M.max_book_mb())
    end
    ctx.close_panels()
    ctx.reset_book()
    self.book = path
    v.layout:reset()
    v.content_sig_value = nil
    v.last_browse_dir = path:match("^(.*)/[^/]*$")
    local fmt = ctx.rd.detect(path)
    prof_mark("detect")
    self.fmt = fmt
    self.is_txt = fmt == 5
    v.reflow = fmt == 2 or fmt == 3 or fmt == 4

    local name = path:match("([^/]+)$") or path
    name = name:gsub("%.%w+$", "")
    ctx.set_title(name)
    v.zoom = 1.0
    v.pan_x = 0

    if self.is_txt then
        local ok, err = self:build_txt(path)
        if not ok then return false, err end
    elseif v.reflow then
        local root = "/dev/shm/native-reader-cache/book_" .. ctx.epub.hash(path)
        local probe = root .. "/META-INF/container.xml"
        local pf = io.open(probe, "rb")
        if pf then
            pf:close()
            ctx.rd.touch_path(root)
        else
            ctx.rd.extract_book(path, root)
            prof_mark("extract")
        end
        self.chapters = ctx.epub.parse(root)
        prof_mark("toc_parse")
        if self.chapters and #self.chapters > 0 then
            self.chapter_mode = true
            local rec = ctx.get_progress()[path]
            local sc, sp = 1, 0
            if start_page ~= nil then
                sp = start_page
            elseif rec and rec.chapter then
                sc, sp = rec.chapter, rec.page or 0
            elseif rec and rec.page then
                sp = rec.page
            end
            sc = math.max(1, math.min(#self.chapters, sc))
            local okc = self:open_chapter(sc, sp)
            prof_mark("chapter_open")
            if okc then
                ctx.refresh_text()
                ctx.save_progress()
                return true
            end
            self.chapter_mode = false
            self.chapters = nil
        end
        local err
        self.doc, err = self:open_doc(path)
        prof_mark("doc_open")
        if not self.doc then return false, "open failed: " .. tostring(err) end
        self.total = ctx.rd.page_count(self.doc)
        prof_mark("page_count")
        if self.total <= 0 then return false, "no pages" end
    else
        local err
        self.doc, err = self:open_doc(path)
        prof_mark("doc_open")
        if not self.doc then return false, "open failed: " .. tostring(err) end
        self.total = ctx.rd.page_count(self.doc)
        prof_mark("page_count")
        if self.total <= 0 then return false, "no pages" end
    end

    local start = start_page
    if start == nil then
        local rec = ctx.get_progress()[path]
        start = rec and rec.page or 0
    end
    start = math.max(0, math.min(self.total - 1, start or 0))
    v.pending_layout = v.reflow

    self.page = 0
    ctx.refresh_text()
    if not ctx.load_page(start) then return false, "render failed" end
    prof_mark("first_page")
    ctx.refresh_text()
    ctx.save_progress()
    return true
end

return M
