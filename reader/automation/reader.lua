-- reader.lua — native_reader UI 自动化控制面的 LuaJIT FFI 封装
--
-- 通过 libreader_ctl.so 连接阅读器的 Unix socket，用于 AI agent
-- 查询动作/状态、模拟点击。用法：
--
--   local R = require("reader")
--   local c = assert(R.open())
--   print(table.concat(c:actions(), ", "))  -- 列出可点击动作
--   c:click("reader.next")                  -- 模拟点击“下一页”
--   print(c:state())                        -- 读取界面状态
--   c:openBook("testdata/epub/min.epub")
--   c:next(); c:capture("/tmp/opencode/reader.png")
--   c:close()

local ffi = require("ffi")

ffi.cdef [[
typedef struct rdctl_t rdctl_t;
rdctl_t* rdctl_open(const char* path);
void     rdctl_close(rdctl_t* c);
int      rdctl_call(rdctl_t* c, const char* req, char* out, int outlen);
int      rdctl_list(rdctl_t* c, char* out, int outlen);
int      rdctl_state(rdctl_t* c, char* out, int outlen);
int      rdctl_ping(rdctl_t* c, char* out, int outlen);
int      rdctl_click(rdctl_t* c, const char* id, char* out, int outlen);
]]

local function _load()
  local root = os.getenv("READER_ROOT") or "."
  local candidates = {
    root .. "/build/libreader_ctl.so",
    root .. "/lib/libreader_ctl.so",
    root .. "/src/libreader_ctl.so",
    "libreader_ctl.so",
  }
  local env = os.getenv("RDCTL_LIB")
  if env then table.insert(candidates, 1, env) end
  local err
  for _, p in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, p)
    if ok then return lib end
    err = lib
  end
  error("cannot load libreader_ctl.so: " .. tostring(err))
end

local lib = _load()

local M = {}
M.__index = M
M.BUF = 1048576 -- 1 MiB

function M.open(path)
  path = path or os.getenv("READER_AUTOMATION_SOCK")
      or "/tmp/native-reader-automation.sock"
  local h = lib.rdctl_open(path)
  if h == nil then return nil, "cannot connect: " .. path end
  return setmetatable({ h = h }, M)
end

function M:raw(req)
  local out = ffi.new("char[?]", M.BUF)
  local n = lib.rdctl_call(self.h, req, out, M.BUF)
  if n < 0 then return nil end
  return ffi.string(out, n)
end

function M:list() return self:raw('{"cmd":"list"}') end
function M:state() return self:raw('{"cmd":"state"}') end
function M:ping() return self:raw('{"cmd":"ping"}') end
function M:click(id)
  return self:raw(('{"cmd":"click","id":"%s"}'):format(id))
end

-- 调用带参数的 API 函数。args_json 为 JSON 对象字符串（默认 "{}"）。
function M:call(fn, args_json)
  return self:raw(('{"cmd":"call","fn":"%s","args":%s}'):format(fn, args_json or '{}'))
end

-- 常用便捷方法（返回原始 JSON 字符串）
local function jstr(s)
  s = tostring(s or ''):gsub('\\', '\\\\'):gsub('"', '\\"')
       :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

function M:openBook(path, page)
  local args = ('{"path":%s'):format(jstr(path))
  if page then args = args .. (',"page":%d'):format(page) end
  args = args .. '}'
  return self:call('reader.open', args)
end
function M:closeBook() return self:call('reader.close') end
function M:next() return self:call('reader.next') end
function M:prev() return self:call('reader.prev') end
function M:goto(pos) return self:call('reader.goto', pos or '{}') end
function M:toc() return self:call('reader.toc') end
function M:text(page)
  if page then
    return self:call('reader.text', ('{"page":%d}'):format(page))
  end
  return self:call('reader.text')
end
function M:bookmarkAdd(note)
  return self:call('reader.bookmark.add', ('{"note":%s}'):format(jstr(note)))
end
function M:bookmarks() return self:call('reader.bookmark.list') end
function M:settings() return self:call('settings.get') end
function M:setSettings(args) return self:call('settings.set', args or '{}') end
function M:appState() return self:call('app.state') end
-- —— 原生窗口控制（LuaJIT FFI libxdo；不启动 xdotool/wmctrl）——
-- c:window() 返回窗口对象：activate/center/move/click/key/type/capture。
-- 仅保留这一套实现，不再提供 shell / socket 窗口 API。
function M:window(title)
  local x11 = require("x11")
  local custom = title or os.getenv("READER_WINDOW_TITLE")
  local name = custom or "reader"
  -- 优先 WM_CLASS，避免把终端/其他窗口误认成主窗口
  local w
  if custom then
    w = x11.window(name, { exact = true })
  else
    w = x11.window_class(os.getenv("READER_WINDOW_CLASS") or "native-reader")
    if not w then w = x11.window(name, { exact = true }) end
  end
  assert(w, "native_reader window not found: " .. name)
  return w
end

function M:activate() self:window():activate(); return true end
function M:center() self:window():center(); return true end
function M:move(x, y) self:window():move(x, y); return true end
function M:capture(path)
  path = path or "/tmp/opencode/native_reader.png"
  local r = self:call('app.capture', ('{"path":%s}'):format(jstr(path)))
  if r ~= nil then return true, path end
  return self:window():capture(path)
end

function M:quit() return self:call('app.quit') end

-- 解析 list 响应，返回动作 id 数组
function M:actions()
  local s = self:list() or ""
  local arr = s:match('"actions":%s*%[(.-)%]')
  local t = {}
  if arr then
    for id in arr:gmatch('"([^"]+)"') do t[#t + 1] = id end
  end
  return t
end

function M:close()
  if self.h ~= nil then
    lib.rdctl_close(self.h)
    self.h = nil
  end
end

return M
