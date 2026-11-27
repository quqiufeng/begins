-- lua/ffi/ocr.lua — CPU OCR (PP-OCRv4) bound through the reader_ocr C ABI.
--
--   local ocr = require("ffi/ocr")     -- or require("ffi.ocr")
--   if ocr.available() then
--       local txt, err = ocr.text("/path/page.png")
--   end
--
-- The library is optional: when build/libreader_ocr.so is absent (no ONNX
-- Runtime at build time) available() returns false and text() returns nil+why,
-- so callers can fall back to the embedded text layer.

local ffi = require("ffi")

ffi.cdef [[
int         rd_ocr_init(const char *model_dir);
const char *rd_ocr_provider(void);
const char *rd_ocr_model_dir(void);
const char *rd_ocr_error(void);
char       *rd_ocr_text(const char *image_path);
char       *rd_ocr_boxes(const char *image_path);
void        rd_ocr_free(char *p);
]]

local root = os.getenv("READER_ROOT") or "."
local candidates = {
    root .. "/build/libreader_ocr.so",
    root .. "/lib/libreader_ocr.so",
    "libreader_ocr.so",
}
local lib, load_err
for _, p in ipairs(candidates) do
    local ok, h = pcall(ffi.load, p)
    if ok then
        lib = h
        break
    end
    load_err = tostring(h)
end

local M = { lib = lib, load_error = load_err }

function M.available()
    return lib ~= nil
end

function M.provider()
    if not lib then return nil end
    return ffi.string(lib.rd_ocr_provider())
end

function M.model_dir()
    if not lib then return nil end
    return ffi.string(lib.rd_ocr_model_dir())
end

function M.error()
    if not lib then return load_err end
    return ffi.string(lib.rd_ocr_error())
end

-- 0 on success; nil+err otherwise.
function M.init(model_dir)
    if not lib then return nil, load_err end
    if lib.rd_ocr_init(model_dir) ~= 0 then
        return nil, ffi.string(lib.rd_ocr_error())
    end
    return true
end

-- Recognized page text (lines joined with "\n"); nil+reason on failure.
function M.text(path)
    if not lib then return nil, load_err end
    local p = lib.rd_ocr_text(path)
    if p == nil then
        local e = ffi.string(lib.rd_ocr_error())
        if e == "" then e = "no text detected" end
        return nil, e
    end
    local s = ffi.string(p)
    lib.rd_ocr_free(p)
    return s
end

-- Raw JSON array of boxes: [{x,y,w,h,score,text}, ...]
function M.boxes_json(path)
    if not lib then return nil, load_err end
    local p = lib.rd_ocr_boxes(path)
    if p == nil then
        local e = ffi.string(lib.rd_ocr_error())
        if e == "" then e = "no text detected" end
        return nil, e
    end
    local s = ffi.string(p)
    lib.rd_ocr_free(p)
    return s
end

-- Minimal JSON decoder for the box array above (avoids a cjson dependency).
local function unescape(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return "\t" end
        return c
    end))
end

function M.boxes(path)
    local json, err = M.boxes_json(path)
    if not json then return nil, err end
    local out = {}
    for x, y, w, h, score, text in json:gmatch(
        '{"x":(%-?%d+),"y":(%-?%d+),"w":(%-?%d+),"h":(%-?%d+),"score":([%d%.%-]+),"text":"(.-)"}') do
        out[#out + 1] = {
            x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
            score = tonumber(score), text = unescape(text),
        }
    end
    return out
end

return M
