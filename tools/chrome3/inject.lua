-- inject.lua —— 三站合一：把 Lua 表里的 cookie 逐条 Network.setCookie 注入当前 chromium，再导航+验登录
--   用法: luajit inject.lua <yt|wb|gm> [cookies.lua] [url] [port]
--   依赖盒上 /root/cdplib.lua（= tools/cdp/cdp_do.lua 的库部分 + 导出表）
--   前置: cage.sh <站> 已起，9222 可访问
local site = select(1, ...) or "yt"

local SITES = {
  yt = {
    name = "YouTube",
    cookies = "/root/ytcookies.lua",
    url = "https://www.youtube.com/",
    warm = 3,                 -- 导航后等多久再验（YouTube 靠 XHR 填充，别急）
    shot = false,
    -- 登录态指纹：#avatar-btn 存在 = 已登录；signin_btn 存在 = 未登录
    check = [[(function(){
      var b=document.querySelector('#avatar-btn');
      return JSON.stringify({
        title: document.title,
        href: location.href,
        avatar: !!b,
        signin_btn: !!document.querySelector('a[href*="ServiceLogin"], ytd-button-renderer a[href*="passive"]'),
        vids: document.querySelectorAll('ytd-rich-item-renderer, ytd-video-renderer').length,
        thumbs: document.querySelectorAll('img[src^="https://i.ytimg"]').length,
        name: (document.querySelector('#account-name, ytd-account-item-section-renderer #channel-title')||{}).textContent
      })})()]],
  },
  wb = {
    name = "微博",
    cookies = "/root/wbcookies.lua",
    url = "https://weibo.com/",
    warm = 6,                 -- 微博首屏骨架屏，等 6s 才出真内容
    shot = false,
    -- 微博页面自带 window.$CONFIG = {uid=..., nick=...}，登录态看它最准
    check = [[(function(){
      var c = window.$CONFIG || {};
      var nav = document.querySelector('.gn_name .S_txt1, .woo-box-flex .woo-box-item-inlineBlock a[href*="/u/"]');
      return JSON.stringify({
        title: document.title,
        href: location.href,
        uid: c.uid || null,
        nick: c.nick || null,
        login_nav: !!nav,
        name: (nav && nav.textContent || '').trim().slice(0, 20),
        signin_btn: !!document.querySelector('a[href*="login"], .LoginBtn, [node-type="loginBtn"]'),
        feeds: document.querySelectorAll('[action-type="feed_list_item"], .Feed_wrap, article').length
      })})()]],
  },
  gm = {
    name = "Gmail",
    cookies = "/root/gm-cookies.lua",
    url = "https://mail.google.com/mail/u/0/",
    warm = 12,                -- Gmail SPA 首屏慢，且要过代理
    shot = true,              -- 顺带截图落 /tmp/gm.png
    check = [[(function(){
      var q = function(s){ try { return document.querySelector(s); } catch(e){ return null; } };
      var rows = document.querySelectorAll('tr.zA, div[role="main"] tr, [gh="tl"] tr').length;
      var acct = q('a[aria-label*="@"], [aria-label*="Google 账号"], [aria-label*="Google Account"]');
      var compose = q('div[gh="cm"], [role="button"][gh="cm"]');
      return JSON.stringify({
        title: document.title, href: location.href, rows: rows,
        compose: !!compose,
        acct_label: (acct && (acct.getAttribute('aria-label')||acct.textContent)||'').trim().slice(0,60),
        signin_link: !!q('a[href*="ServiceLogin"], a[href*="accounts.google.com/ServiceLogin"]'),
        body_len: (document.body && document.body.innerText || '').length
      })})()]],
  },
}

local cfg = SITES[site]
if not cfg then
  io.stderr:write("用法: luajit inject.lua <" .. table.concat((function() local t = {} for k in pairs(SITES) do t[#t+1] = k end return t end)(), "|") .. "> [cookies.lua] [url] [port]\n")
  os.exit(2)
end

local cookiefile = select(2, ...) or cfg.cookies
local url = select(3, ...) or cfg.url
-- cdplib 在加载时读全局 arg[3] 定 CDP 端口，所以要在 dofile 之前塞好
arg = { [3] = select(4, ...) or "9222" }

local lib = dofile("/root/cdplib.lua")
local cookies = dofile(cookiefile)

local status, body = lib.http_get_json_list()
if status ~= "200" then print("ERROR /json/list HTTP " .. tostring(status)); os.exit(1) end
local list = lib.jdec(body)
local target
for _, t in ipairs(list) do
  if t.type == "page" and t.webSocketDebuggerUrl then target = t break end
end
if not target then print("ERROR 没有 page 目标"); os.exit(1) end
print("[page] " .. tostring(target.url))
local ws, werr = lib.ws_open(target.webSocketDebuggerUrl:match("^ws://[^/]+(/.*)$"))
if not ws then print("ERROR WS 握手失败 " .. tostring(werr)); os.exit(1) end

local id = 0
local function rpc(method, params)
  id = id + 1
  local myid = id
  ws.send_frame(lib.jenc({ id = myid, method = method, params = params or {} }))
  for _ = 1, 6000 do
    local f = ws.recv_frame()
    if not f then return nil end
    if f.op == 1 and #f.payload > 0 then
      local msg = lib.jdec(f.payload)
      if type(msg) == "table" and msg.id == myid then return msg end
    elseif f.op == 8 then return nil end
  end
end

local function js(expr)
  local r = rpc("Runtime.evaluate", { expression = expr, returnByValue = true, awaitPromise = true })
  if not r then return nil end
  if r.error then return "CDP:" .. lib.jenc(r.error) end
  local inner = r.result and r.result.result
  if not inner then return nil end
  return inner.value ~= nil and inner.value or inner.description
end

rpc("Network.enable")
rpc("Page.enable")
local ok, fail, errs = 0, 0, {}
for _, c in ipairs(cookies) do
  local host = c.domain
  local p = {
    name = c.name, value = c.value, path = c.path or "/",
    secure = c.secure, httpOnly = c.httpOnly, sameSite = c.sameSite,
    expires = c.expires,
  }
  -- 带前导点的域必须用 domain；不带点的用 url 更稳
  if host:sub(1, 1) == "." then p.domain = host
  else p.url = "https://" .. host .. (c.path or "/") end
  local r = rpc("Network.setCookie", p)
  if r and r.result and r.result.success then ok = ok + 1
  else
    fail = fail + 1
    if #errs < 5 then errs[#errs + 1] = host .. ":" .. c.name .. " => " .. lib.jenc(r and (r.error or r.result) or {}) end
  end
end
print(string.format("[%s][cookie] 注入成功 %d / 失败 %d", cfg.name, ok, fail))
for _, e in ipairs(errs) do print("  " .. e) end

rpc("Page.navigate", { url = url })
for _ = 1, 120 do
  if js("document.readyState") == "complete" then break end
  os.execute("sleep 0.5")
end
os.execute("sleep " .. cfg.warm)

print("[check] " .. tostring(js(cfg.check)))

if cfg.shot then
  local shot = rpc("Page.captureScreenshot", { format = "png" })
  local data = shot and shot.result and shot.result.data
  if data then
    local f = io.open("/tmp/inject.b64", "w"); f:write(data); f:close()
    os.execute("base64 -d /tmp/inject.b64 > /tmp/inject.png && rm -f /tmp/inject.b64")
    print("[shot] /tmp/inject.png " .. tostring(io.open("/tmp/inject.png"):seek("end")) .. " B")
  else print("ERROR 截图失败") end
end
ws.close()
