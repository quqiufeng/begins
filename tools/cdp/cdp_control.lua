#!/opt/reader/bin/luajit
-- cdp_control.lua —— 纯 LuaJIT 单文件 CDP 客户端（零外部依赖）
--   * TCP  : LuaJIT FFI 直接调 libc socket/connect/send/recv
--   * WS   : 手写 RFC6455 握手 + frame 编解码（含 SHA-1 / Base64）
--   * JSON : 手写 encode / decode
-- 用法: luajit cdp_control.lua [url] [port]
local bit  = require("bit")
local ffi  = require("ffi")
local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift

local TARGET_URL = arg[1] or "https://www.baidu.com"
local PORT       = tonumber(arg[2]) or 9222
local HOST       = "127.0.0.1"

local function log(...) io.stdout:write(table.concat({...}, " "), "\n"); io.stdout:flush() end

------------------------------------------------------------------ FFI
ffi.cdef[[
typedef long ssize_t;
typedef unsigned int socklen_t;
struct sockaddr_in { unsigned short sin_family; unsigned short sin_port;
                     unsigned int sin_addr; unsigned char sin_zero[8]; };
struct timeval { long tv_sec; long tv_usec; };
int     socket(int, int, int);
int     connect(int, const void *, socklen_t);
ssize_t send(int, const void *, size_t, int);
ssize_t recv(int, void *, size_t, int);
int     close(int);
int     setsockopt(int, int, int, const void *, socklen_t);
int     usleep(unsigned int);
]]
local C = ffi.C
local AF_INET, SOCK_STREAM = 2, 1
local SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO = 1, 20, 21

local function tcp_connect(port, timeout_s)
  local fd = C.socket(AF_INET, SOCK_STREAM, 0)
  if fd < 0 then return nil, "socket() 失败" end
  local tv = ffi.new("struct timeval", { tonumber(timeout_s), 0 })
  C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof("struct timeval"))
  C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof("struct timeval"))
  local sa = ffi.new("struct sockaddr_in")
  sa.sin_family = AF_INET
  sa.sin_port   = bit.bor(lshift(band(port, 0xFF), 8), rshift(band(port, 0xFF00), 8))
  sa.sin_addr   = 0x0100007F  -- 小端写入 = 网络序 127.0.0.1
  if C.connect(fd, sa, ffi.sizeof(sa)) ~= 0 then
    C.close(fd); return nil, "connect 127.0.0.1:" .. port .. " 失败"
  end
  return fd
end

------------------------------------------------------------------ Base64
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
  local out, n = {}, #s
  for i = 1, n, 3 do
    local a, b, c = s:byte(i, i + 2)
    a = a or 0; b = b or 0; c = c or 0
    local v = a * 65536 + b * 256 + c
    out[#out+1] = B64:sub(math.floor(v/262144)%64+1, math.floor(v/262144)%64+1)
      .. B64:sub(math.floor(v/4096)%64+1, math.floor(v/4096)%64+1)
      .. (i+1 <= n and B64:sub(math.floor(v/64)%64+1, math.floor(v/64)%64+1) or "=")
      .. (i+2 <= n and B64:sub(v%64+1, v%64+1) or "=")
  end
  return table.concat(out)
end

------------------------------------------------------------------ SHA-1
local function be32(v)
  return string.char(band(rshift(v,24),255), band(rshift(v,16),255),
                     band(rshift(v,8),255),  band(v,255))
end
local function sha1(msg)
  local h0,h1,h2,h3,h4 = 0x67452301,0xEFCDAB89,0x98BADCFE,0x10325476,0xC3D2E1F0
  local ml  = #msg * 8
  local pad = (56 - 1 - #msg % 64) % 64
  msg = msg .. "\128" .. string.rep("\0", pad)
        .. be32(math.floor(ml / 4294967296) % 4294967296) .. be32(ml % 4294967296)
  local w = {}
  for i = 1, #msg, 64 do
    for j = 0, 15 do
      local a,b,c,d = msg:byte(i + j*4, i + j*4 + 3)
      w[j+1] = a * 16777216 + b * 65536 + c * 256 + d
    end
    for j = 17, 80 do
      local x = bxor(bxor(w[j-3], w[j-8]), bxor(w[j-14], w[j-16]))
      w[j] = (band(lshift(x,1), 0xFFFFFFFE) + band(rshift(x,31), 1)) % 4294967296
    end
    local a,b,c,d,e = h0,h1,h2,h3,h4
    for j = 1, 80 do
      local f, k
      if j <= 20 then      f = bxor(d, band(b, bxor(c,d))); k = 0x5A827999
      elseif j <= 40 then  f = bxor(bxor(b,c), d);          k = 0x6ED9EBA1
      elseif j <= 60 then  f = bxor(band(b,c), band(d, bxor(b,c))); k = 0x8F1BBCDC
      else                 f = bxor(bxor(b,c), d);          k = 0xCA62C1D6 end
      local rol = band(lshift(a,5), 0xFFFFFFE0) + band(rshift(a,27), 0x1F)
      local T   = (rol + f + e + k + w[j]) % 4294967296
      e = d; d = c
      c = band(lshift(b,30), 0xC0000000) + band(rshift(b,2), 0x3FFFFFFF)
      b = a; a = T
    end
    h0=(h0+a)%4294967296; h1=(h1+b)%4294967296; h2=(h2+c)%4294967296
    h3=(h3+d)%4294967296; h4=(h4+e)%4294967296
  end
  return be32(h0)..be32(h1)..be32(h2)..be32(h3)..be32(h4)
end

------------------------------------------------------------------ JSON encode
local esc_map = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f',
                  ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function jesc(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    return esc_map[c] or string.format("\\u%04x", c:byte())
  end))
end
local function is_array(t)
  if type(t) ~= "table" then return false end
  if t[1] == nil then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end
local function jenc(v)
  local tv = type(v)
  if tv == "nil"     then return "null"
  elseif tv == "boolean" then return tostring(v)
  elseif tv == "number"  then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif tv == "string"  then return '"' .. jesc(v) .. '"'
  elseif tv == "table"   then
    if is_array(v) then
      local out = {}
      for i = 1, #v do out[i] = jenc(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local out = {}
    for k, val in pairs(v) do out[#out+1] = '"' .. jesc(tostring(k)) .. '":' .. jenc(val) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

------------------------------------------------------------------ JSON decode
local function jdec(str)
  local pos = 1
  local function skip()
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
    end
  end
  local parse_val
  local function parse_string()
    pos = pos + 1
    local buf = {}
    while true do
      local c = str:sub(pos, pos)
      if c == "" then error("json: 字符串未结束") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = str:sub(pos+1, pos+1)
        if e == '"' then buf[#buf+1] = '"'  pos = pos + 2
        elseif e == "\\" then buf[#buf+1] = "\\" pos = pos + 2
        elseif e == "/" then buf[#buf+1] = "/"  pos = pos + 2
        elseif e == "b" then buf[#buf+1] = "\b" pos = pos + 2
        elseif e == "f" then buf[#buf+1] = "\f" pos = pos + 2
        elseif e == "n" then buf[#buf+1] = "\n" pos = pos + 2
        elseif e == "r" then buf[#buf+1] = "\r" pos = pos + 2
        elseif e == "t" then buf[#buf+1] = "\t" pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(str:sub(pos+2, pos+5), 16) or 63
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF then
            local lo = tonumber(str:sub(pos+2, pos+5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          if cp < 0x80 then buf[#buf+1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf+1] = string.char(0xC0 + math.floor(cp/64), 0x80 + cp%64)
          elseif cp < 0x10000 then
            buf[#buf+1] = string.char(0xE0 + math.floor(cp/4096),
              0x80 + math.floor(cp/64)%64, 0x80 + cp%64)
          else
            buf[#buf+1] = string.char(0xF0 + math.floor(cp/262144),
              0x80 + math.floor(cp/4096)%64, 0x80 + math.floor(cp/64)%64, 0x80 + cp%64)
          end
        else buf[#buf+1] = e pos = pos + 2 end
      else buf[#buf+1] = c pos = pos + 1 end
    end
    return table.concat(buf)
  end
  parse_val = function()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip()
      if str:sub(pos,pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip()
        local k = parse_string()
        skip()
        if str:sub(pos,pos) ~= ":" then error("json: 缺冒号 @"..pos) end
        pos = pos + 1
        obj[k] = parse_val()
        skip()
        local d = str:sub(pos,pos)
        pos = pos + 1
        if d == "}" then break elseif d ~= "," then error("json: 对象分隔符 @"..pos) end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip()
      if str:sub(pos,pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr+1] = parse_val()
        skip()
        local d = str:sub(pos,pos)
        pos = pos + 1
        if d == "]" then break elseif d ~= "," then error("json: 数组分隔符 @"..pos) end
      end
      return arr
    elseif c == '"' then return parse_string()
    elseif str:sub(pos, pos+3) == "true"  then pos = pos + 4; return true
    elseif str:sub(pos, pos+4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos+3) == "null"  then pos = pos + 4; return nil
    else
      local s = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not s or s == "" then error("json: 非法字符 '"..c.."' @"..pos) end
      pos = pos + #s
      return tonumber(s)
    end
  end
  return parse_val()
end

------------------------------------------------------------------ socket 读写缓冲
local RBUF = ffi.new("uint8_t[?]", 262144)
local function make_conn(fd)
  local self = { fd = fd, acc = "" }
  function self.recv_some()
    local n = C.recv(fd, RBUF, 262144, 0)
    if n <= 0 then return nil end
    self.acc = self.acc .. ffi.string(RBUF, n)
    return tonumber(n)
  end
  function self.take(n)
    while #self.acc < n do
      if not self.recv_some() then return nil end
    end
    local s = self.acc:sub(1, n)
    self.acc = self.acc:sub(n + 1)
    return s
  end
  function self.take_until(delim)
    while true do
      local s, e = self.acc:find(delim, 1, true)
      if s then
        local out = self.acc:sub(1, e)
        self.acc = self.acc:sub(e + 1)
        return out
      end
      if not self.recv_some() then return nil end
    end
  end
  function self.drain()
    local parts = { self.acc }
    self.acc = ""
    while self.recv_some() do
      parts[#parts+1] = self.acc
      self.acc = ""
    end
    return table.concat(parts)
  end
  function self.send(s)
    local buf = ffi.cast("const uint8_t *", s)
    local off, total = 0, #s
    while off < total do
      local n = C.send(fd, buf + off, total - off, 0)
      if n <= 0 then return false end
      off = off + tonumber(n)
    end
    return true
  end
  function self.close() C.close(fd) end
  return self
end

------------------------------------------------------------------ HTTP GET /json/list
local function http_get_json_list()
  local fd, err = tcp_connect(PORT, 5)
  if not fd then error(err) end
  local c = make_conn(fd)
  c.send("GET /json/list HTTP/1.1\r\nHost: "..HOST..":"..PORT..
         "\r\nConnection: close\r\n\r\n")
  local head = c.take_until("\r\n\r\n")
  if not head then c.close(); error("/json/list 无响应") end
  local status = head:match("^HTTP/%d%.%d (%d+)") or "?"
  local chunked = head:lower():find("transfer%-encoding:%s*chunked") ~= nil
  local parts = {}
  if chunked then
    -- 逐块解析：先用已有 acc，缺了再 recv
    while true do
      local line = c.take_until("\r\n")
      if not line then break end
      local sz = tonumber(line:sub(1, -3), 16)
      if not sz or sz == 0 then break end
      local data = c.take(sz)
      if not data then break end
      parts[#parts+1] = data
      c.take(2)  -- 丢弃 \r\n
    end
  else
    parts[#parts+1] = c.drain()
  end
  c.close()
  return status, table.concat(parts)
end

------------------------------------------------------------------ WebSocket
local function ws_open(path)
  local fd, err = tcp_connect(PORT, 10)
  if not fd then return nil, err end
  local c = make_conn(fd)
  local rnd = {}
  for i = 1, 16 do rnd[i] = string.char(math.random(0,255)) end
  local key = b64(table.concat(rnd))
  c.send("GET "..path.." HTTP/1.1\r\n"
    .."Host: "..HOST..":"..PORT.."\r\n"
    .."Upgrade: websocket\r\n"
    .."Connection: Upgrade\r\n"
    .."Sec-WebSocket-Key: "..key.."\r\n"
    .."Sec-WebSocket-Version: 13\r\n\r\n")
  local head = c.take_until("\r\n\r\n")
  if not head then c.close(); return nil, "握手无响应" end
  local status = head:match("^HTTP/%d%.%d (%d+)")
  if status ~= "101" then
    c.close(); return nil, "握手失败 HTTP "..tostring(status).."\n"..head:sub(1,400)
  end
  local accept
  for line in head:gmatch("[^\r\n]+") do
    local k, v = line:match("^(.-):%s*(.-)%s*$")
    if k and k:lower() == "sec-websocket-accept" then accept = v break end
  end
  local expect = b64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  if accept and (accept:gsub("%s", "") ~= expect) then
    c.close(); return nil, "accept 不匹配: "..accept.." != "..expect
  end

  local ws = { fd = fd }
  function ws.send_frame(payload, opcode)
    opcode = opcode or 1
    local len = #payload
    local mask = {math.random(0,255), math.random(0,255), math.random(0,255), math.random(0,255)}
    local hdr
    if len < 126 then
      hdr = string.char(0x80 + opcode, 0x80 + len)
    elseif len < 65536 then
      hdr = string.char(0x80 + opcode, 0x80 + 126, math.floor(len/256)%256, len%256)
    else
      hdr = string.char(0x80 + opcode, 0x80 + 127, 0, 0, 0, 0,
        math.floor(len/16777216)%256, math.floor(len/65536)%256,
        math.floor(len/256)%256, len%256)
    end
    local body = {}
    for i = 1, len do body[i] = string.char(bxor(payload:byte(i), mask[(i-1)%4+1])) end
    return c.send(hdr .. string.char(mask[1], mask[2], mask[3], mask[4]) .. table.concat(body))
  end
  function ws.recv_frame()
    local h = c.take(2)
    if not h then return nil end
    local b1, b2 = h:byte(1, 2)
    local op, masked = band(b1, 0x0F), band(b2, 0x80) ~= 0
    local len = band(b2, 0x7F)
    if len == 126 then
      local e = c.take(2); if not e then return nil end
      len = e:byte(1) * 256 + e:byte(2)
    elseif len == 127 then
      local e = c.take(8); if not e then return nil end
      len = 0
      for i = 1, 8 do len = len * 256 + e:byte(i) end
    end
    local mask
    if masked then
      local m = c.take(4); if not m then return nil end
      mask = { m:byte(1, 4) }
    end
    local payload = ""
    if len > 0 then
      payload = c.take(len)
      if not payload then return nil end
    end
    if mask then
      local b = {}
      for i = 1, #payload do
        b[i] = string.char(bxor(payload:byte(i), mask[(i-1)%4+1]))
      end
      payload = table.concat(b)
    end
    return { op = op, payload = payload }
  end
  function ws.close() c.close() end
  return ws
end

------------------------------------------------------------------ 主流程
local function main()
  math.randomseed(os.time() % 100000 + math.floor(os.clock() * 1000))

  log("=== [1] GET /json/list ===")
  local status, body = http_get_json_list()
  log("    HTTP " .. status .. "   " .. #body .. " bytes")
  if status ~= "200" then error("/json/list 返回 "..status..": "..body:sub(1, 200)) end
  local list = jdec(body)
  local target
  for _, t in ipairs(list) do
    if t.type == "page" then target = t; break end
  end
  if not target then error("没有 type==page 的 target") end
  log("    id : " .. target.id)
  log("    url: " .. tostring(target.url))
  log("    ws : " .. target.webSocketDebuggerUrl)
  local path = target.webSocketDebuggerUrl:match("^ws://[^/]+(/.*)$")
  assert(path, "ws url 解析失败")

  log("=== [2] WebSocket 握手 ===")
  local ws, werr = ws_open(path)
  if not ws then error(werr) end
  log("    101 Switching Protocols, Sec-WebSocket-Accept 校验通过")

  local msgid = 0
  local function send_cdp(method, params)
    msgid = msgid + 1
    if not ws.send_frame(jenc({ id = msgid, method = method, params = params or {} })) then
      return nil, "发送失败"
    end
    while true do
      local f = ws.recv_frame()
      if not f then return nil, "连接断开" end
      if f.op == 9 then ws.send_frame(f.payload, 10)
      elseif f.op == 1 then
        local okd, d = pcall(jdec, f.payload)
        if okd and type(d) == "table" and d.id == msgid then return d end
      elseif f.op == 8 then return nil, "服务端关闭" end
    end
  end

  local function eval_js(expr)
    local r, e = send_cdp("Runtime.evaluate", { expression = expr, returnByValue = true })
    if not r then return nil, e end
    local res = r.result
    if res and res.exceptionDetails then
      return nil, "JS 异常: " .. tostring(res.exceptionDetails.text)
    end
    return res and res.result and res.result.value
  end

  log("=== [3] Page.enable ===")
  local r, e = send_cdp("Page.enable")
  log("    -> " .. (r and jenc(r) or tostring(e)))

  log("=== [4] Page.navigate -> " .. TARGET_URL .. " ===")
  r, e = send_cdp("Page.navigate", { url = TARGET_URL })
  log("    -> " .. (r and jenc(r) or tostring(e)))

  log("=== [5] 等待加载完成 ===")
  local ready
  for i = 1, 24 do
    C.usleep(500000)
    ready = eval_js("document.readyState")
    if ready == "complete" then
      log("    readyState=complete  (" .. (i * 0.5) .. "s)")
      break
    end
  end
  if ready ~= "complete" then log("    警告 readyState=" .. tostring(ready)) end

  log("=== [6] Runtime.evaluate: 标题 / 视口 / 中文 ===")
  local info = eval_js([[
    JSON.stringify({
      title: document.title,
      href: location.href,
      ready: document.readyState,
      viewport: innerWidth + "x" + innerHeight,
      text: (document.body ? document.body.innerText : "").replace(/\s+/g, " ").slice(0, 150)
    })
  ]])
  log("    " .. tostring(info))

  log("=== [7] 自动填充搜索框并提交 ===")
  local act = eval_js([[
    (function(){
      var i = document.querySelector('#kw')
           || document.querySelector('input[name=wd]')
           || document.querySelector('input[type=text]');
      if (!i) return 'no-input';
      i.value = '\u673a\u9876\u76d2\u6d4f\u89c8\u5668\u76f4\u51fa';
      i.dispatchEvent(new Event('input', { bubbles: true }));
      var f = i.form;
      if (f) { f.submit(); return 'form-submit'; }
      var b = document.querySelector('#su');
      if (b) { b.click(); return 'btn-click'; }
      return 'filled-only';
    })()
  ]])
  log("    -> " .. tostring(act))

  log("=== [8] 2.5s 后确认已跳转 ===")
  C.usleep(2500000)
  local after = eval_js("location.href + ' || ' + document.title")
  log("    " .. tostring(after))

  ws.close()
  log("=== [9] WebSocket 已关闭，Chromium 继续运行 ===")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write("ERROR: " .. tostring(err) .. "\n")
  os.exit(1)
end
