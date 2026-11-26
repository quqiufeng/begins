
local function main()
  math.randomseed(os.time() % 100000)
  local status, body = http_get_json_list()
  local list = jdec(body)
  local target
  for _, t in ipairs(list) do if t.type == "page" and t.webSocketDebuggerUrl then target = t break end end
  local wpath = target.webSocketDebuggerUrl:match("^ws://[^/]+(/.*)$")
  local ws = ws_open(wpath)
  local id = 0
  local function rpc(method, params)
    id = id + 1
    local myid = id
    ws.send_frame(jenc({ id = myid, method = method, params = params or {} }))
    for _ = 1, 4000 do
      local f = ws.recv_frame()
      if not f then return nil end
      if f.op == 1 and #f.payload > 0 then
        local msg = jdec(f.payload)
        if type(msg) == "table" and msg.id == myid then return msg end
      elseif f.op == 8 then return nil end
    end
  end
  rpc("DOM.enable"); rpc("CSS.enable"); rpc("Runtime.enable")
  local doc = rpc("DOM.getDocument", { depth = 1 })
  local root = doc.result.root.nodeId
  -- 找文本命中关键字的元素，取平台字体 + computed font-family
  local words = { "全部关注", "最新微博", "首页", "表情", "好友圈" }
  for _, w in ipairs(words) do
    local q = rpc("DOM.querySelectorAll", {
      nodeId = root,
      selector = "a, span, li, div, strong, p" })
    local ids = q and q.result and q.result.nodeIds or {}
    local found
    for _, nid in ipairs(ids) do
      local t = rpc("Runtime.callFunctionOn", {
        objectId = nil })  -- placeholder
    end
    break
  end
  -- 更简单：用 Runtime.evaluate 找元素，再用 DOM.requestNode 拿 nodeId
  for _, w in ipairs(words) do
    local r = rpc("Runtime.evaluate", { expression = string.format([[
      (function(){var all=document.querySelectorAll('a,span,li,div,strong,p,b');
       for(var i=0;i<all.length;i++){var e=all[i];
         if(e.children.length===0 && (e.innerText||'').trim()===%q){
           return e.tagName+'|'+getComputedStyle(e).fontFamily+'|'+getComputedStyle(e).fontSize}}})()

    ]], w), returnByValue = true })
    local v = r and r.result and r.result.result and r.result.result.value
    log(string.format("%-6s %s", w, tostring(v)))
  end
  ws.close()
end
local ok, err = xpcall(main, debug.traceback)
if not ok then io.stderr:write("ERROR: "..tostring(err).."\n"); os.exit(1) end
