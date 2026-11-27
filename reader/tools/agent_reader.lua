-- agent_reader.lua — 外部 Agent 通过命令行驱动 native-reader。
--
--   reader-agent state
--   reader-agent open /path/book.epub 1
--   reader-agent text            # 当前页正文
--   reader-agent read 5          # 连续读 5 页，输出 JSON
--   reader-agent next 2
--   reader-agent goto 3 | goto-chapter 5 1   # 章内页 / 第5章第1页
--   reader-agent toc | toc.open | toc.select 3 | toc.activate 3
--   reader-agent settings | settings.open 1 | settings.adjust 2 1
--   reader-agent capture /tmp/page.png
--
-- 输出默认是 JSON，方便外部 agent 直接解析。

local script = arg[0] or ""
local dir = script:match("^(.*)/[^/]+$") or "."
package.path = dir .. "/../automation/?.lua;" .. dir .. "/../lua/?.lua;" .. package.path

local ffi = require("ffi")
local json = require("cjson")
local Agent = require("agent")

ffi.cdef[[
int usleep(unsigned int usec);
]]
local function sleep_sec(v)
    local n = tonumber(v) or 0
    if n > 0 then ffi.C.usleep(math.floor(math.min(n, 60) * 1000000)) end
end

local function num(i) return tonumber(arg[i]) end
local function encode(v)
    return (json.encode(v):gsub("\\/", "/"))
end
local function emit(v) print(encode(v or {})) end
local cmd = arg[1] or "state"

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function launch_app(path)
    local launcher = os.getenv("READER_LAUNCH")
    if not launcher or launcher == "" then
        local root = os.getenv("READER_ROOT") or "."
        for _, p in ipairs({ root .. "/run.sh", root .. "/tools/run.sh" }) do
            local f = io.open(p, "rb")
            if f then f:close(); launcher = p; break end
        end
    end
    if not launcher then return false, "READER_LAUNCH not found" end
    local args = shq(launcher)
    if path and path ~= "" then args = args .. " " .. shq(path) end
    os.execute("setsid " .. args ..
        " >>/tmp/opencode/reader-agent-launch.log 2>&1 < /dev/null &")
    return true
end

local a, err = Agent.new()
if not a and (cmd == "open" or cmd == "launch") then
    local ok, lerr = launch_app(arg[2])
    if not ok then
        print(encode({ ok = false, error = tostring(lerr) }))
        os.exit(1)
    end
    for _ = 1, 60 do
        sleep_sec(0.1)
        a, err = Agent.new()
        if a then break end
    end
end
if not a then
    print(encode({ ok = false, error = tostring(err),
        hint = "reader not running; use: reader-agent open /path/book" }))
    os.exit(1)
end

if cmd == "state" then
    emit(a:state())
elseif cmd == "open" then
    if arg[2] and arg[2] ~= "" then
        emit(a:openBook(arg[2], num(3)))
    else
        emit(a:state())
    end
elseif cmd == "launch" then
    emit(a:state())
elseif cmd == "close" then
    emit(a:closeBook())
elseif cmd == "next" then
    emit(a:turn(num(2) or 1))
elseif cmd == "prev" then
    emit(a:turn(-(num(2) or 1)))
elseif cmd == "goto" then
    emit(a:goto(num(2)))
elseif cmd == "goto-chapter" then
    emit(a:gotoChapter(num(2), num(3)))
elseif cmd == "text" then
    local r = a:text(num(2))
    if r and r.text then
        io.write(r.text, "\n")
    else
        emit(r)
    end
elseif cmd == "read" then
    emit(a:read(num(2) or 1, { delay = arg[3] }))
elseif cmd == "actions" then
    emit({ ok = true, actions = a:actions() })
elseif cmd == "click" then
    emit(a:click(arg[2]))
elseif cmd == "toc" then
    emit(a:toc())
elseif cmd == "toc.open" then
    emit(a:tocOpen())
elseif cmd == "toc.close" then
    emit(a:tocClose())
elseif cmd == "toc.select" then
    emit(a:tocSelect(num(2), num(3)))
elseif cmd == "toc.activate" then
    emit(a:tocActivate(num(2)))
elseif cmd == "bookmarks" then
    emit(a:bookmarks())
elseif cmd == "bookmark" then
    emit(a:bookmarkAdd(arg[2] or ""))
elseif cmd == "bookmark.open" then
    emit(a:bookmarkOpen())
elseif cmd == "bookmark.close" then
    emit(a:bookmarkClose())
elseif cmd == "bookmark.toggle" then
    emit(a:toggleBookmarks())
elseif cmd == "bookmark.select" then
    emit(a:bookmarkSelect(num(2), num(3)))
elseif cmd == "bookmark.activate" then
    emit(a:bookmarkActivate(num(2)))
elseif cmd == "bookmark.remove" then
    emit(a:bookmarkRemove(num(2)))
elseif cmd == "library" then
    emit(a:library())
elseif cmd == "library.open" then
    emit(a:libraryOpen())
elseif cmd == "library.scan" then
    emit(a:libraryScan())
elseif cmd == "library.select" then
    emit(a:librarySelect(num(2), num(3)))
elseif cmd == "library.activate" then
    emit(a:libraryActivate(num(2)))
elseif cmd == "library.close" then
    emit(a:libraryClose())
elseif cmd == "history.remove" then
    emit(a:removeHistory(num(2), arg[3]))
elseif cmd == "history.clear" then
    emit(a:clearHistory())
elseif cmd == "settings" then
    emit(a:settings())
elseif cmd == "settings.open" then
    emit(a:settingsOpen(num(2)))
elseif cmd == "settings.close" then
    emit(a:settingsClose())
elseif cmd == "settings.toggle" then
    emit(a:toggleSettings())
elseif cmd == "settings.adjust" then
    emit(a:settingsAdjust(num(2), num(3) or 1))
elseif cmd == "set" then
    local ok, t = pcall(json.decode, arg[2] or "{}")
    emit(ok and a:setSettings(t) or { ok = false, error = "bad json" })
elseif cmd == "scroll" then
    emit(a:scroll(num(2) or 0))
elseif cmd == "zoom" then
    emit(a:zoom(num(2) or 1))
elseif cmd == "pan" then
    emit(a:pan(num(2) or 0))
elseif cmd == "eye" then
    emit(a:eye())
elseif cmd == "dual" then
    emit(a:dual())
elseif cmd == "maximize" then
    emit(a:maximize())
elseif cmd == "fullscreen" then
    emit(a:fullscreen())
elseif cmd == "capture" then
    emit(a:capture(arg[2] or "/tmp/opencode/reader_agent.png"))
elseif cmd == "snapshot" then
    emit(a:snapshot(arg[2]))
elseif cmd == "markdown" or cmd == "md" then
    emit(a:markdown(arg[2]))
elseif cmd == "raw" then
    print(a:raw(arg[2] or '{"cmd":"state"}') or "{}")
elseif cmd == "quit" then
    emit(a:quit())
else
    print("usage: reader-agent state|open|text|read|next|prev|goto|toc|bookmark|library|history|settings|scroll|zoom|pan|capture|snapshot|markdown|quit")
    os.exit(2)
end

a:close()
