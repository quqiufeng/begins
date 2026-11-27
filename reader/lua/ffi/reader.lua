local ffi = require("ffi")

ffi.cdef [[
void *rd_open(const char *path, int *err);
void *rd_open_styled(const char *path, float w, float h,
                     float em, float lf, float margin, int *err);
void  rd_close(void *handle);
int   rd_page_count(void *handle);
int   rd_page_size(void *handle, int page, float *w, float *h);
int   rd_layout(void *handle, float w, float h, float em,
                float line_factor, float margin);
int   rd_render_page(void *handle, int page, float zoom,
                     int bg_r, int bg_g, int bg_b,
                     uint8_t **out, int *w, int *h, int *stride);
void  rd_free(void *p);
int   rd_save_png(const char *path, int w, int h, const uint8_t *rgba);
int   rd_save_pages_png(const char *path,
                        const uint8_t *a, int aw, int ah,
                        const uint8_t *b, int bw, int bh,
                        int br, int bg, int bb, int gap);
int   rd_detect_format(const char *path);
int   rd_link_at(void *handle, int page, float nx, float ny,
                 int *out_page, float *out_x, float *out_y);
char *rd_toc(void *handle);
char *rd_page_text(void *handle, int page);
char *rd_list_dir(const char *path);
char *rd_page_fonts(void *handle, int page);
char *rd_page_links(void *handle, int page);
char *rd_page_images(void *handle, int page);
int   rd_render_region(void *handle, int page, float x0, float y0, float x1, float y1,
                       int max_w, int max_h, uint8_t **out, int *out_w, int *out_h, int *out_stride);
int   rd_extract_book(const char *path, const char *out_dir);
int   rd_touch_path(const char *path);
int   rd_cache_remove_book(const char *book_path);
int   rd_cache_clear(void);
const char *rd_cache_dir(void);
int   rd_mkdir_p(const char *path);
void *rd_open_accel(const char *path, const char *accel_path,
                    float w, float h, float em, float lf, float margin,
                    int *err);
]]

local root = os.getenv("READER_ROOT") or "."
local candidates = {
    root .. "/build/libreader_native.so",
    root .. "/lib/libreader_native.so",
    "libreader_native.so",
}
local lib, load_err
for _, p in ipairs(candidates) do
    local ok, h = pcall(ffi.load, p)
    if ok then
        lib = h
        break
    end
    load_err = h
end
if not lib then
    error("cannot load libreader_native.so: " .. tostring(load_err))
end

local M = {}

function M.detect(path)
    return tonumber(lib.rd_detect_format(path))
end

function M.extract_book(path, out_dir)
    return tonumber(lib.rd_extract_book(path, out_dir))
end

function M.touch_path(path)
    return tonumber(lib.rd_touch_path(path))
end

function M.cache_remove_book(path)
    return tonumber(lib.rd_cache_remove_book(path))
end

function M.cache_clear()
    return tonumber(lib.rd_cache_clear())
end

function M.cache_dir()
    local p = lib.rd_cache_dir()
    if p == nil then return nil end
    return ffi.string(p)
end

function M.mkdir_p(path)
    return tonumber(lib.rd_mkdir_p(path))
end

-- accel_path 非空时走 MuPDF 加速文档：同布局参数下复用上次的页数表，
-- 省掉整本 reflow（EPUB/MOBI 冷开的主因）。
-- w/h 为期望的布局尺寸；重排格式（EPUB/MOBI/AZW3）必须与阅览时一致，
-- 否则加速缓存里的分章页数表会被 MuPDF 作废。
function M.open(path, em, lf, margin, accel_path, w, hgt)
    local err = ffi.new("int[1]")
    local h
    if accel_path and accel_path ~= "" then
        h = lib.rd_open_accel(path, accel_path, w or 0, hgt or 0,
                              em or 16, lf or 1.6, margin or 72, err)
        if h == nil then
            -- 缓存坏了就退回普通打开，不让它挡住打开书。
            h = lib.rd_open_styled(path, 0, 0,
                                   em or 16, lf or 1.6, margin or 72, err)
        end
    elseif em and em > 0 then
        -- w = -1：先不布局（调用方会自己按真实尺寸布局）。
        h = lib.rd_open_styled(path, w or 0, hgt or 0,
                               em, lf or 1.6, margin or 72, err)
    else
        h = lib.rd_open(path, err)
    end
    return h
end

function M.close(h)
    lib.rd_close(h)
end

function M.page_count(h)
    return tonumber(lib.rd_page_count(h))
end

function M.layout(h, w, hgt, em, line_factor, margin)
    return tonumber(lib.rd_layout(h, w, hgt, em, line_factor, margin))
end

function M.page_size(h, page)
    local w = ffi.new("float[1]")
    local hh = ffi.new("float[1]")
    local rc = lib.rd_page_size(h, page, w, hh)
    if rc ~= 0 then return nil, nil, rc end
    return tonumber(w[0]), tonumber(hh[0])
end

function M.link_at(h, page, nx, ny)
    local out = ffi.new("int[1]")
    local ox = ffi.new("float[1]")
    local oy = ffi.new("float[1]")
    local rc = lib.rd_link_at(h, page, nx, ny, out, ox, oy)
    if rc ~= 1 then return nil end
    return tonumber(out[0]), tonumber(ox[0]), tonumber(oy[0])
end

function M.render_page(h, page, zoom, bg_r, bg_g, bg_b)
    local out = ffi.new("uint8_t*[1]")
    local w = ffi.new("int[1]")
    local hh = ffi.new("int[1]")
    local stride = ffi.new("int[1]")
    local rc = lib.rd_render_page(h, page, zoom,
        bg_r or 255, bg_g or 255, bg_b or 255, out, w, hh, stride)
    if rc ~= 0 then return nil, rc end
    return out[0], tonumber(w[0]), tonumber(hh[0]), tonumber(stride[0])
end

function M.free(p)
    lib.rd_free(p)
end

function M.save_pages_png(path, a, aw, ah, b, bw, bh, bg, gap)
    return lib.rd_save_pages_png(path, a, aw, ah, b, bw or 0, bh or 0,
        bg[1], bg[2], bg[3], gap or 5) == 0
end

function M.save_png(path, w, h, pixels)
    return lib.rd_save_png(path, w, h, pixels)
end

function M.page_links(h, page)
    local p = lib.rd_page_links(h, page)
    if p == nil then return "" end
    local s = ffi.string(p)
    lib.rd_free(p)
    return s
end

function M.list_dir(path)
    local p = lib.rd_list_dir(path)
    if p == nil then return "" end
    local s = ffi.string(p)
    lib.rd_free(p)
    return s
end

function M.page_fonts(h, page)
    local p = lib.rd_page_fonts(h, page)
    if p == nil then return "" end
    local s = ffi.string(p)
    lib.rd_free(p)
    return s
end

function M.page_images(h, page)
    local p = lib.rd_page_images(h, page)
    if p == nil then return "" end
    local s = ffi.string(p)
    lib.rd_free(p)
    return s
end

function M.render_region(h, page, x0, y0, x1, y1, max_w, max_h)
    local out = ffi.new("uint8_t*[1]")
    local ow = ffi.new("int[1]")
    local oh = ffi.new("int[1]")
    local os = ffi.new("int[1]")
    local rc = lib.rd_render_region(h, page, x0, y0, x1, y1,
        max_w, max_h, out, ow, oh, os)
    if rc ~= 0 or out[0] == nil then return nil end
    return out[0], tonumber(ow[0]), tonumber(oh[0]), tonumber(os[0])
end

function M.page_text(h, page)
    local p = lib.rd_page_text(h, page)
    if p == nil then return nil end
    local s = ffi.string(p)
    lib.rd_free(p)
    return s
end

function M.toc(h)
    local p = lib.rd_toc(h)
    if p == nil then return {} end
    local s = ffi.string(p)
    lib.rd_free(p)
    local out = {}
    for page, level, title in s:gmatch("(%-?%d+)\t(%d+)\t([^\n]*)\n") do
        out[#out + 1] = {
            page = tonumber(page),
            level = tonumber(level),
            title = title,
        }
    end
    return out
end

return M
