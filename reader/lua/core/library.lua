local ffi = require("ffi")

ffi.cdef [[
typedef struct __dirstream DIR;
struct dirent {
    uint64_t d_ino;
    int64_t d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};
DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
]]

local FORMATS = {
    pdf = "PDF",
    epub = "EPUB",
    mobi = "MOBI",
    azw3 = "AZW3",
    txt = "TXT",
}

local M = {}

function M.scan(dir)
    local d = ffi.C.opendir(dir)
    if d == nil then return nil end

    local items = {}
    while true do
        local ent = ffi.C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local ext = name:match("%.([%w]+)$")
            local fmt = ext and FORMATS[ext:lower()]
            if fmt then
                items[#items + 1] = {
                    name = name,
                    path = dir .. "/" .. name,
                    format = fmt,
                }
            end
        end
    end
    ffi.C.closedir(d)

    table.sort(items, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return items
end

return M
