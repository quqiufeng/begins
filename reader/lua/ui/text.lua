local M = {}

function M.utf8_chars(s)
    local i = 1
    return function()
        if i > #s then return nil end
        local c = s:byte(i)
        local n = 1
        if c >= 0xF0 then n = 4
        elseif c >= 0xE0 then n = 3
        elseif c >= 0xC0 then n = 2 end
        local ch = s:sub(i, i + n - 1)
        i = i + n
        return ch
    end
end

function M.truncate_utf8(s, max_chars)
    local out = {}
    local n = 0
    for ch in M.utf8_chars(s) do
        if n >= max_chars then
            out[#out + 1] = "…"
            break
        end
        out[#out + 1] = ch
        n = n + 1
    end
    return table.concat(out)
end

return M
