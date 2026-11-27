-- EPUB 解包后的章节解析工具（纯函数，不依赖 UI）。
local M = {}

function M.read_text(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- MuPDF 对空行内锚点 (<a id="x"></a>) 解析到页首；把 id 移到紧随其后的
-- 标签上，锚点才能落到真实位置。行内 font-style: italic/oblique 还会让
-- MuPDF 把整章渲染成斜体（用户 CSS 也压不住），一并去掉。
-- 按文件加标记，只处理一次。
local function strip_italic(style)
    style = style:gsub("font%-style%s*:%s*[Ii][Tt][Aa][Ll][Ii][Cc]%s*;?", "")
    style = style:gsub("font%-style%s*:%s*[Oo][Bb][Ll][Ii][Qq][Uu][Ee]%s*;?", "")
    return style
end

local function normalize(data)
    local out = data
    out = out:gsub(
        '<a id="([^"]+)"></a>(%s*)<([%a][%w:_.-]*)([^>]*)>',
        function(id, ws, tag, attrs)
            if attrs:find("id=", 1, true) then return nil end
            return '<a></a>' .. ws .. "<" .. tag .. ' id="' .. id .. '"' .. attrs .. ">"
        end)
    out = out:gsub('style="([^"]*)"', function(style)
        return 'style="' .. strip_italic(style) .. '"'
    end)
    out = out:gsub("style='([^']*)'", function(style)
        return "style='" .. strip_italic(style) .. "'"
    end)
    return out
end

function M.fix_anchors(path)
    if not path then return false end
    local ext = path:lower():match("%.([%w]+)$")
    if ext ~= "html" and ext ~= "xhtml" and ext ~= "htm" then return false end
    local marker = path .. ".normalize-v2"
    local mf = io.open(marker, "rb")
    if mf then mf:close(); return false end
    local data = M.read_text(path)
    if not data then return false end
    local out = normalize(data)
    if out ~= data then
        local tmp = path .. ".tmp"
        local w = io.open(tmp, "wb")
        if not w then return false end
        w:write(out)
        w:close()
        local ok = os.rename(tmp, path)
        if not ok then return false end
    end
    local mk = io.open(marker, "wb")
    if mk then mk:write("1\n"); mk:close() end
    os.remove(path .. ".anchors-v1")
    return out ~= data
end

function M.unescape(s)
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
         :gsub("&apos;", "'"):gsub("&nbsp;", " ")
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        if n and n < 128 then return string.char(n) end
        return ""
    end)
    return (s:gsub("&amp;", "&"))
end

function M.strip(s)
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.join(base, rel)
    if not rel or rel == "" then return base end
    if rel:sub(1, 1) == "/" then return rel end
    local parts = {}
    for seg in (base .. "/" .. rel):gmatch("[^/]+") do
        if seg == ".." then
            table.remove(parts)
        elseif seg ~= "." and seg ~= "" then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

function M.hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

function M.chapter_title(path)
    local s = M.read_text(path)
    if not s then return nil end
    local t = s:match("<h1[^>]*>(.-)</h1>")
        or s:match("<h2[^>]*>(.-)</h2>")
        or s:match("<h3[^>]*>(.-)</h3>")
    if not t then return nil end
    t = M.strip(M.unescape(t))
    if t == "" or #t > 60 then return nil end
    return t
end

function M.parse(root)
    local container = M.read_text(root .. "/META-INF/container.xml")
    local opf_rel = container and container:match('full%-path="([^"]+)"')
    if not opf_rel then return nil end
    local opf_path = M.join(root, opf_rel)
    local opf = M.read_text(opf_path)
    if not opf then return nil end
    local opf_dir = opf_path:match("^(.*)/[^/]*$") or root

    local manifest, ncx_href = {}, nil
    for tag in opf:gmatch("<item%s+[^>]*>") do
        local id = tag:match('id="([^"]*)"')
        local href = tag:match('href="([^"]*)"')
        local mt = tag:match('media%-type="([^"]*)"')
        if href then
            href = M.unescape(href)
            if id then manifest[id] = href end
            if (mt and mt:find("dtbncx", 1, true)) or href:lower():match("%.ncx$") then
                ncx_href = href
            end
        end
    end

    local spine = opf:match("<spine[^>]*>(.-)</spine>") or ""
    local list = {}
    for idref in spine:gmatch('<itemref[^>]-idref="([^"]-)"') do
        local href = manifest[idref]
        if href then
            local clean = href:gsub("#.*$", "")
            list[#list + 1] = { href = clean, path = M.join(opf_dir, clean) }
        end
    end
    if #list == 0 then return nil end

    local titles = {}
    if ncx_href then
        local ncx = M.read_text(M.join(opf_dir, ncx_href))
        if ncx then
            local nav = ncx:match("<navMap[^>]*>(.*)</navMap>") or ncx
            nav = nav:gsub("%s+", " ")
            for text, src in nav:gmatch("<text[^>]*>(.-)</text>.-<content[^>]-src=\"([^\"]*)\"") do
                local href = M.unescape(src):gsub("#.*$", "")
                titles[href] = M.strip(M.unescape(text))
            end
        end
    end

    for i, ch in ipairs(list) do
        ch.title = titles[ch.href]
        if not ch.title or ch.title == "" then
            ch.title = M.chapter_title(ch.path)
        end
        if not ch.title or ch.title == "" then
            ch.title = string.format("第 %d 章", i)
        end
    end
    return list
end

return M
