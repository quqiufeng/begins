-- 文字：把当前页（单页 / 双页）导出为 Markdown 到 ~。
-- PDF 一律走 OCR（版式还原更稳）；EPUB/MOBI/AZW3/TXT/CHM 直接取解析出的文本层。
-- 两条路互为兜底：PDF 的 OCR 不可用/失败时回落文本层，其它格式无文字层时回落 OCR。
local M = {}
M.__index = M

local function now_str()
    local t = os.date("*t")
    return string.format("%04d-%02d-%02d %02d:%02d",
        t.year, t.month, t.day, t.hour, t.min)
end

local function book_title(path)
    local name = (path or "reader"):match("([^/]+)$") or "reader"
    name = name:gsub("%.[%w]+$", "")
    name = name:gsub('[\\/:*?"<>|%c]', "_")
    if name == "" then name = "reader" end
    return name
end

-- 规整纯文本：去行尾空白、把英文硬换行接回段落、压缩连续空行。
local function tidy(text)
    local lines = {}
    for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("[ \t\r]+$", ""))
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end

    local out, i = {}, 1
    while i <= #lines do
        local line = lines[i]
        while line ~= "" and i < #lines do
            local nxt = lines[i + 1]
            -- 仅拼接明显的英文续行，中文逐行保留（版式信息更多）。
            if nxt ~= "" and line:find("[%a,;:%-]$") and nxt:match("^[%l]") then
                line = line .. " " .. nxt
                i = i + 1
            else
                break
            end
        end
        out[#out + 1] = line
        i = i + 1
    end

    local res, prev_blank = {}, false
    for _, l in ipairs(out) do
        local blank = (l == "")
        if not (blank and prev_blank) then res[#res + 1] = l end
        prev_blank = blank
    end
    return (table.concat(res, "\n"):gsub("^%s*\n+", ""):gsub("\n+%s*$", ""))
end

function M.new(ctx)
    return setmetatable({ ctx = ctx }, M)
end

-- 0 基页号 -> 纯文本
function M:text_of(idx)
    local ctx = self.ctx
    if ctx.get_is_txt() then
        local pages = ctx.get_pages()
        local p = pages and pages[idx + 1]
        if not p then return "" end
        return table.concat(p, "\n")
    end
    local doc = ctx.get_doc()
    if not doc then return "" end
    return ctx.rd.page_text(doc, idx) or ""
end

-- 无文字层时把页面渲染成临时 PNG 交给 OCR；失败返回 nil。
local function ocr_page(ctx, idx)
    local ok, res = pcall(function()
        local ocr = require("ffi.ocr")
        if not ocr.available() then return nil end
        local doc = ctx.get_doc()
        if not doc then return nil end
        local pw = ctx.rd.page_size(doc, idx)
        if not pw or pw <= 0 then return nil end
        local scale = math.max(1.0, 1400 / pw)
        local pixels, w, h = ctx.rd.render_page(doc, idx, scale)
        if not pixels then return nil end
        local tmp = string.format("/tmp/reader-ocr-%d-%d.png", os.time(), idx)
        local saved = ctx.rd.save_png(tmp, w, h, pixels)
        ctx.rd.free(pixels)
        if not saved then return nil end
        local txt = ocr.text(tmp)
        os.remove(tmp)
        return txt
    end)
    if not ok then return nil, tostring(res) end
    return res
end

function M:path()
    local ctx = self.ctx
    local home = os.getenv("HOME") or "/tmp"
    local v = ctx.v
    local p1 = ctx.get_page() + 1
    local p2 = v.p2 and (p1 + 1) or nil
    local label = p2 and string.format("%d_%d", p1, p2) or string.format("%d", p1)
    local base = string.format("%s/%s_%s", home, book_title(ctx.get_book()), label)
    local path = base .. ".md"
    local i = 1
    while true do
        local f = io.open(path, "rb")
        if not f then break end
        f:close()
        path = string.format("%s-%d.md", base, i)
        i = i + 1
    end
    return path
end

-- 生成 Markdown 正文；返回 text, pages(导出的页号列表), ocr_used
function M:build()
    local ctx = self.ctx
    local v, R = ctx.v, ctx.reader
    local page = ctx.get_page()
    local total = ctx.get_total()
    local idxs = { page }
    local dual = v.p2 and (page + 1 < total)
    if dual then idxs[2] = page + 1 end

    local title = book_title(ctx.get_book())
    local out = { "# " .. title, "" }
    local span = dual and string.format("%d–%d", page + 1, page + 2) or string.format("%d", page + 1)
    local meta = {}
    if R and R.chapter_mode then
        meta[1] = string.format("- 页码：第 %s 页（本章共 %d 页）", span, total)
    else
        meta[1] = string.format("- 页码：%s / %d", span, total)
    end
    if R and R.chapter_mode and R.chapters and R.chapters[R.chapter_idx] then
        local ch = R.chapters[R.chapter_idx]
        meta[#meta + 1] = string.format("- 章节：%s（%d / %d）",
            ch.title or string.format("第 %d 章", R.chapter_idx), R.chapter_idx, #R.chapters)
    end
    meta[#meta + 1] = "- 来源：" .. (ctx.get_book() or "")
    meta[#meta + 1] = "- 导出：" .. now_str()
    out[#out + 1] = table.concat(meta, "  \n")
    out[#out + 1] = ""

    -- PDF（fmt == 1）默认 OCR；其余格式默认文本层；两条路互为兜底。
    local prefer_ocr = (R and R.fmt == 1) or false
    local ocr_used = false
    for _, idx in ipairs(idxs) do
        local body, tried = "", false
        if prefer_ocr then
            tried = true
            local alt = ocr_page(ctx, idx)
            if alt and alt ~= "" then
                body, ocr_used = tidy(alt), true
            end
        end
        if body == "" then body = tidy(self:text_of(idx)) end
        if body == "" and not tried then
            local alt = ocr_page(ctx, idx)
            if alt and alt ~= "" then
                body, ocr_used = tidy(alt), true
            end
        end
        if body == "" then body = "_（本页无可提取文字）_" end
        out[#out + 1] = string.format("## 第 %d 页", idx + 1)
        out[#out + 1] = ""
        out[#out + 1] = body
        out[#out + 1] = ""
    end
    return table.concat(out, "\n"), idxs, ocr_used
end

function M:save(path)
    local ctx = self.ctx
    path = path or self:path()
    local body, idxs, ocr_used = self:build()
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(body, "\n")
    f:close()
    return true, path, idxs, ocr_used
end

function M:take(path)
    local ctx = self.ctx
    local ok, path, _, ocr_used = self:save(path)
    if ok then
        print("markdown: " .. path)
        ctx.show_toast((ocr_used and "文字已保存（OCR）：" or "文字已保存：") .. path, 4)
    else
        ctx.show_toast("文字导出失败：" .. tostring(path), 3)
    end
    return ok, path
end

return M
