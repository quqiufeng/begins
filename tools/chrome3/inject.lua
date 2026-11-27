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
  zh = {
    name = "知乎",
    cookies = "/root/zhcookies.lua",
    url = "https://www.zhihu.com/",
    warm = 5,                 -- 知乎首屏走 XHR，等 5s 再验
    shot = false,
    -- 登录态看 z_c0（会话票）+ 头部个人中心头像；没过登录会有 yidun 点选验证码
    check = [[(function(){
      var has=function(s){ try{ return !!document.querySelector(s); }catch(e){ return false; } };
      var ck=document.cookie||"";
      var nick=document.querySelector('.AppHeader-userInfo .UserLink-link, .AppHeader-profileEntry .UserLink-link');
      var av=has('img.Avatar, .AppHeader-profileEntry img');
      return JSON.stringify({
        title: document.title,
        href: location.href,
        /* z_c0 是 HttpOnly，document.cookie 读不到，只能看它生效后的界面（头像/个人中心） */
        z_c0_dom: av,
        d_c0: ck.indexOf('d_c0=') >= 0,
        profile: has('.AppHeader-profileEntry, .AppHeader-profile'),
        nick: (nick && nick.textContent || '').trim().slice(0, 20),
        signin: has('a[href*="/signin"], .AppHeader-login, button.SignFlow-submitButton'),
        captcha: has('.yidun_tips, .yidun_intelli-tips, .yidun_bg-img, .Captcha'),
        feeds: document.querySelectorAll('.TopstoryItem, .Feed, .ContentItem').length,
        body_len: (document.body && document.body.innerText || '').length
      })})()]],
  },
  dy = {
    name = "抖音",
    cookies = "/root/dycookies.lua",
    url = "https://www.douyin.com/",
    warm = 8,                 -- 抖音首屏是推荐流 XHR + 播放器起播，给足 8s
    -- 这站在 123(ARM) 上冷刷新要 ~77s 才把头像渲染出来（实测），所以等久一点；
    -- 判据放宽：头像出现、或私信入口出现，任一即说明登录态成立
    ok = nil,
    ok_any = { '"avatar":true', '"im_entry":true' },
    retries = 45,
    shot = false,
    -- 登录态：sessionid/sid_guard 是 HttpOnly 读不到，靠界面（右上头像 + 无登录按钮）判定
    check = [[(function(){
      var has=function(s){ try{ return !!document.querySelector(s); }catch(e){ return false; } };
      var ck=document.cookie||"";
      /* 抖音新版头像是 aweme-avatar 图，没有 user-avatar 这个 e2e；私信入口 im-entry 只有登录才渲染 */
      var av=document.querySelector('img[src*="aweme-avatar"], [data-e2e="user-avatar"] img, [data-e2e="something-button"] img');
      return JSON.stringify({
        title: document.title,
        href: location.href,
        avatar: !!av,
        im_entry: has('[data-e2e="im-entry"]'),
        /* ttwid 游客也有，只能当"页面通了"的旁证；tt_webid / passport_csrf_token 同理 */
        ttwid: ck.indexOf('ttwid=') >= 0,
        passport: ck.indexOf('passport_csrf_token') >= 0,
        uid_tt: ck.indexOf('uid_tt=') >= 0,
        login_btn: has('[data-e2e="login-button"]'),
        signin_text: /登录/.test(((document.querySelector('[data-e2e="login-button"]')||{}).textContent)||''),
        feeds: document.querySelectorAll('[data-e2e="feed-active-video"], [data-e2e="scroll-list-item"], li[data-e2e]').length,
        body_len: (document.body && document.body.innerText || '').length
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

-- 幂等保护：profile 里已有会话票就别再灌 cookie。
-- 知乎每次登录会轮换 z_c0，用旧的覆盖会立刻被判失效并踢下线（实测踩过）。
local already = {}
do
  local r = rpc("Network.getCookies", { urls = { "https://www.zhihu.com/", "https://weibo.com/", "https://mail.google.com/", "https://www.douyin.com/", "https://www.youtube.com/" } })
  local list = r and r.result and r.result.cookies
  if type(list) == "table" then
    for _, k in ipairs(list) do already[k.name] = true end
  end
end
-- 各站的"会话票"：一旦 profile 里已有，就不再灌（灌旧票会被服务端判失效踢下线）
local SESSION = {
  ["知乎"] = "z_c0", ["抖音"] = "sessionid", ["微博"] = "SUB",
  ["YouTube"] = "SAPISID", ["Gmail"] = "SID",
}
local TK = SESSION[cfg.name]
local SKIP_ALL = TK and already[TK]

local ok, fail, errs = 0, 0, {}
if SKIP_ALL then
  print(string.format("[%s][cookie] 已有会话票 %s，跳过注入（避免轮换后被判失效）", cfg.name, TK))
end
for _, c in ipairs(cookies) do
  if SKIP_ALL then goto continue end
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
  ::continue::
end
print(string.format("[%s][cookie] 注入成功 %d / 失败 %d%s", cfg.name, ok, fail, SKIP_ALL and "（跳过）" or ""))
for _, e in ipairs(errs) do print("  " .. e) end

rpc("Page.navigate", { url = url })
for _ = 1, 120 do
  if js("document.readyState") == "complete" then break end
  os.execute("sleep 0.5")
end
os.execute("sleep " .. cfg.warm)

-- 首屏渲染慢的站（抖音推荐流要十几秒）：check 里出现 cfg.ok 标记才算数，否则每 2s 重试
local function passed(r)
  if cfg.ok and r:find(cfg.ok, 1, true) then return true end
  for _, mark in ipairs(cfg.ok_any or {}) do
    if r:find(mark, 1, true) then return true end
  end
  return cfg.ok == nil and not cfg.ok_any
end
local res = tostring(js(cfg.check))
for _ = 1, (cfg.retries or 0) do
  if passed(res) then break end
  os.execute("sleep 2")
  res = tostring(js(cfg.check))
end
print("[check] " .. res)

-- 票会轮换：知乎登录后每次会话都会换 z_c0，微博换 SUB。
-- 不回写的话，cookie 文件里的那张票就死在旧值上，下次注入等于灌一张废票。
local function persist_tickets()
  local path = cfg.cookies
  local fh = path and io.open(path)
  if not fh then return end
  local src = fh:read("*a"); fh:close()
  local r = rpc("Network.getCookies", { urls = { url } })
  local live = {}
  for _, k in ipairs((r and r.result and r.result.cookies) or {}) do live[k.name] = k end
  local changed = 0
  src = src:gsub('({name="([^"]+)",value=")([^"]*)(")', function(a, name, old, tail)
    local k = live[name]
    if k and k.value and k.value ~= old then changed = changed + 1; return a .. k.value .. tail end
    return a .. old .. tail
  end)
  src = src:gsub('({name="([^"]+)",value="[^"]*"[^}]-expires=)(%d+)', function(a, name, old)
    local k = live[name]
    if k and k.expires and k.expires > 0 and math.floor(k.expires) ~= tonumber(old) then
      return a .. math.floor(k.expires)
    end
    return a .. old
  end)
  if changed > 0 then
    local out = io.open(path, "w"); out:write(src); out:close()
    print(string.format("[cookie] 回写 %d 条新票 -> %s", changed, path))
  end
end
persist_tickets()

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
