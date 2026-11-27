-- agent_demo.lua — 演示外部 Agent 自动阅读 native-reader。
--
--   luajit automation/agent_demo.lua [/path/book] [start_page]
--
-- 需要 native-reader 已在运行并开启 automation socket。

local dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/../lua/?.lua;" .. package.path

local Agent = require("agent")
local a = assert(Agent.new())

local book = arg[1]
local page = tonumber(arg[2])
if book and book ~= "" then
    local r = a:openBook(book, page)
    print("open: " .. tostring(r and "ok" or "failed"))
end

local st = a:state()
if st and st.state then
    print(string.format("book=%s page=%d/%d %.1f%% spread=%s",
        st.state.book or "", st.state.page or 0, st.state.pages or 0,
        st.state.percent or 0, tostring(st.state.spread)))
end

local toc = a:toc()
if toc and toc.toc then
    print(string.format("toc: %d 条", #toc.toc))
    for i = 1, math.min(8, #toc.toc) do
        local it = toc.toc[i]
        print(string.format("  %d. p%d %s", i, (it.page or 0) + 1, it.title or ""))
    end
end

print("== read 3 pages ==")
for _, pageInfo in ipairs(a:read(3)) do
    print(string.format("--- p%d/%d %.1f%% ---",
        pageInfo.page, pageInfo.pages, pageInfo.percent or 0))
    for _, part in ipairs(pageInfo.content) do
        local text = (part.text or ""):gsub("%s+", " ")
        print(string.format("p%d: %s", part.page, text:sub(1, 180)))
    end
end

a:close()
