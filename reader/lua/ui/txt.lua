local M = {}

function M.line_height(font_size, line_factor)
    return math.max(1, math.floor(font_size * line_factor + 0.5))
end

function M.wrap_line(text, maxw, ttf, font, utf8_chars)
    local out = {}
    if text == "" then out[1] = ""; return out end
    local buf = ""
    for ch in utf8_chars(text) do
        local candidate = buf .. ch
        if ttf.size(font, candidate) > maxw and buf ~= "" then
            out[#out + 1] = buf
            buf = ch
        else
            buf = candidate
        end
    end
    if buf ~= "" or #out == 0 then out[#out + 1] = buf end
    return out
end

function M.paginate(path, o)
    local f, err = io.open(path, "rb")
    if not f then return nil, nil, err end

    local top, bottom = o.top or 96, o.bottom or 80
    local maxw = o.width - 2 * o.margin
    local line_h = M.line_height(o.font_size, o.line_factor)
    local lines_per_page = math.max(1,
        math.floor((o.height - top - bottom - 8) / line_h))

    local pages = { {} }
    local used = 0
    local first = true
    local function push(line)
        if used >= lines_per_page then
            pages[#pages + 1] = {}
            used = 0
        end
        local p = pages[#pages]
        p[#p + 1] = line
        used = used + 1
    end

    for para in f:lines() do
        para = para:gsub("\r$", "")
        if first then
            para = para:gsub("^\239\187\191", "")
            first = false
        end
        if para ~= "" then para = "　　" .. para end
        for _, line in ipairs(M.wrap_line(para, maxw, o.ttf, o.font, o.utf8_chars)) do
            push(line)
        end
    end
    f:close()

    if #pages == 1 and #pages[1] == 0 then pages[1][1] = "" end
    return pages, #pages
end

return M
