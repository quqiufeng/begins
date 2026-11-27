-- 自动翻页：N 次数（0=无限），DELAY 间隔秒
local Agent = require("agent")
local a = assert(Agent.new())
local n     = tonumber(os.getenv("N") or "0")
local delay = tonumber(os.getenv("DELAY") or "8")

local function st()
  local s = a:state() or {}
  return s.state or s
end
local function log(fmt, ...)
  print(string.format("[%s] " .. fmt, os.date("%H:%M:%S"), ...))
  io.stdout:flush()
end

local s = st()
log("start page=%s/%s book=%s", tostring(s.page), tostring(s.pages), tostring(s.book))

local i = 0
while true do
  i = i + 1
  a:next()
  local c = st()
  log("turn %d -> page %s/%s", i, tostring(c.page), tostring(c.pages))
  if n > 0 and i >= n then break end
  os.execute("sleep " .. delay)
end
local e = st()
log("done at page %s", tostring(e.page))
a:close()
