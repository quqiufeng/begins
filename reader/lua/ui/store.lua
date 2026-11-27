-- 本地持久化：Lua 表读写 + 原子替换。
local ffi = require("ffi")
ffi.cdef[[
int chmod(const char *path, unsigned int mode);
]]
local M = {}

function M.load(path)
    local f = loadfile(path)
    if not f then return {} end
    if setfenv then setfenv(f, {}) end
    local ok, t = pcall(f)
    if ok and type(t) == "table" then return t end
    return {}
end

function M.save_settings(path, s)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(string.format(
        "return {theme=%q,font_size=%d,line_factor=%.1f,margin=%d}\n",
        s.theme, s.font_size, s.line_factor, s.margin))
    f:close()
    local ok = os.rename(tmp, path)
    if ok then ffi.C.chmod(path, 0x180) end -- 0600
    return ok and true or false
end

function M.save_state(path, progress)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write("return {\n")
    for p, rec in pairs(progress) do
        f:write(string.format("[%q]={page=%d,chapter=%s,updated=%d,bookmarks={\n",
            p, rec.page or 0, rec.chapter and tostring(rec.chapter) or "nil",
            rec.updated or 0))
        for _, b in ipairs(rec.bookmarks or {}) do
            f:write(string.format("{page=%d,chapter=%s,note=%q,created=%d},\n",
                b.page or 0, b.chapter and tostring(b.chapter) or "nil",
                b.note or "", b.created or 0))
        end
        f:write("}},\n")
    end
    f:write("}\n")
    f:close()
    local ok = os.rename(tmp, path)
    if ok then ffi.C.chmod(path, 0x180) end -- 0600
    return ok and true or false
end

function M.save_window(path, w)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(string.format(
        "return {w=%d,h=%d,x=%d,y=%d,max=%d,full=%d}\n",
        w.w or 900, w.h or 1200, w.x or 0, w.y or 0,
        w.max or 0, w.full or 0))
    f:close()
    local ok = os.rename(tmp, path)
    if ok then ffi.C.chmod(path, 0x180) end
    return ok and true or false
end

return M
