-- automation/agent.lua — 面向外部 Agent 的高层阅读接口。
--
-- 用法：
--   local Agent = require("agent")
--   local a = assert(Agent.new())
--   a:openBook("/path/book.epub", 1)
--   local page = a:text()
--   print(page.text)
--   a:next()
--   a:close()

local ffi = require("ffi")
local json = require("cjson")
local R = require("reader")

ffi.cdef[[
int usleep(unsigned int usec);
]]

local function sleep_sec(v)
    local n = tonumber(v)
    if n and n > 0 then
        if n > 60 then n = 60 end
        ffi.C.usleep(math.floor(n * 1000000))
    end
end

local Agent = {}
Agent.__index = Agent

local function encode(v)
    return (json.encode(v):gsub("\\/", "/"))
end

local function decode(s)
    if not s then return nil, "no response" end
    local ok, v = pcall(json.decode, s)
    if not ok then return nil, s end
    return v
end

function Agent.new(sock)
    local c, err = R.open(sock)
    if not c then return nil, err end
    return setmetatable({ c = c }, Agent)
end

function Agent:state() return decode(self.c:call("reader.state")) end
function Agent:openBook(path, page)
    local r = decode(self.c:openBook(path))
    if page and r and r.ok then
        return self:goto(page)
    end
    return r
end
function Agent:closeBook() return decode(self.c:call("reader.close")) end
function Agent:next() return decode(self.c:call("reader.next")) end
function Agent:prev() return decode(self.c:call("reader.prev")) end

function Agent:goto(page, chapter)
    if chapter then
        return decode(self.c:call("reader.goto",
            ('{"chapter":%d,"page":%d}'):format(chapter, page)))
    end
    return decode(self.c:call("reader.goto", ('{"page":%d}'):format(page)))
end

function Agent:gotoChapter(chapter, page)
    return decode(self.c:call("reader.goto",
        ('{"chapter":%d,"page":%d}'):format(chapter, page or 1)))
end

function Agent:text(page) return decode(self.c:text(page)) end
function Agent:toc() return decode(self.c:call("reader.toc")) end

function Agent:bookmarks() return decode(self.c:call("reader.bookmark.list")) end

function Agent:bookmarkAdd(note)
    return decode(self.c:call("reader.bookmark.add",
        ('{"note":%s}'):format(encode(note or ""))))
end

function Agent:settings() return decode(self.c:call("settings.get")) end

function Agent:setSettings(t)
    return decode(self.c:call("settings.set", encode(t or {})))
end

function Agent:capture(path)
    return decode(self.c:call("app.capture",
        ('{"path":%s}'):format(encode(path))))
end

function Agent:snapshot(path)
    local args = "{}"
    if path then
        args = ('{"path":%s}'):format(encode(path))
    end
    return decode(self.c:call("app.snapshot", args))
end

-- 当前页（单页/双页）导出 Markdown，默认落在 ~；返回 {ok, path}
function Agent:markdown(path)
    local args = "{}"
    if path then
        args = ('{"path":%s}'):format(encode(path))
    end
    return decode(self.c:call("app.markdown", args))
end

function Agent:raw(req) return self.c:raw(req) end
function Agent:ping() return decode(self.c:ping()) end
function Agent:actions() return self.c:actions() end
function Agent:click(id) return decode(self.c:click(id)) end

function Agent:call(fn, t)
    return decode(self.c:call(fn, t and encode(t) or "{}"))
end

-- 书库
function Agent:library() return decode(self.c:call("reader.list")) end
function Agent:libraryOpen() return self:call("app.library") end
function Agent:libraryScan() return self:call("library.scan") end
function Agent:librarySelect(index, delta)
    return self:call("library.select", { index = index, delta = delta })
end
function Agent:libraryActivate(index)
    return self:call("library.activate", { index = index })
end
function Agent:libraryClose() return self:call("library.close") end
function Agent:removeHistory(index, path)
    return self:call("history.remove", { index = index, path = path })
end
function Agent:clearHistory() return self:call("history.clear") end

-- 目录
function Agent:toggleToc() return decode(self.c:call("app.toc")) end
function Agent:tocOpen() return self:call("toc.open") end
function Agent:tocClose() return self:call("toc.close") end
function Agent:tocSelect(index, delta)
    return self:call("toc.select", { index = index, delta = delta })
end
function Agent:tocActivate(index)
    return self:call("toc.activate", { index = index })
end

-- 书签
function Agent:bookmarkOpen() return self:call("bookmark.open") end
function Agent:bookmarkClose() return self:call("bookmark.close") end
function Agent:toggleBookmarks() return decode(self.c:call("app.bookmarks")) end
function Agent:bookmarkSelect(index, delta)
    return self:call("bookmark.select", { index = index, delta = delta })
end
function Agent:bookmarkActivate(index)
    return self:call("bookmark.activate", { index = index })
end
function Agent:bookmarkRemove(index)
    return self:call("reader.bookmark.remove", { index = index })
end

-- 设置 / 视图
function Agent:settingsOpen(row) return self:call("settings.open", { row = row }) end
function Agent:settingsClose() return self:call("settings.close") end
function Agent:toggleSettings() return decode(self.c:call("app.settings")) end
function Agent:settingsAdjust(row, delta)
    return self:call("settings.adjust", { row = row, delta = delta })
end
function Agent:eye() return self:call("app.eye") end
function Agent:dual() return self:call("app.dual") end
function Agent:maximize() return self:call("app.maximize") end
function Agent:fullscreen() return self:call("app.fullscreen") end
function Agent:scroll(dy) return self:call("reader.scroll", { dy = dy }) end
function Agent:zoom(z) return self:call("reader.zoom", { zoom = z }) end
function Agent:pan(dx) return self:call("reader.pan", { dx = dx }) end

function Agent:quit() return decode(self.c:call("app.quit")) end
function Agent:close() self.c:close() end

-- 连续翻 n 页（正数向后，负数向前），返回最后一次 state。
function Agent:turn(n, delay)
    local last
    local step = n >= 0 and 1 or -1
    for _ = 1, math.abs(n) do
        last = step > 0 and self:next() or self:prev()
        sleep_sec(delay)
    end
    return last
end

-- 从当前页开始读 count 页，返回结构化内容；spread 模式会同时读取右页。
function Agent:read(count, opts)
    opts = opts or {}
    local out = {}
    for i = 1, (count or 1) do
        local st = self:state()
        local s = st and st.state
        if not s then break end
        local pages = {}
        local tx = self:text(s.page)
        pages[#pages + 1] = { page = s.page, text = tx and tx.text or "" }
        if s.spread and s.page < s.pages then
            local tx2 = self:text(s.page + 1)
            pages[#pages + 1] = { page = s.page + 1, text = tx2 and tx2.text or "" }
        end
        -- 后端已移除 state.percent，这里按 page/pages 兜底计算。
        local percent = s.percent
        if not percent and s.pages and s.pages > 0 then
            percent = math.floor(s.page * 1000 / s.pages) / 10
        end
        out[#out + 1] = {
            page = s.page, pages = s.pages, percent = percent,
            book = s.book, spread = s.spread, content = pages,
        }
        if i < count then self:next() end
        sleep_sec(opts.delay)
    end
    return out
end

return Agent
