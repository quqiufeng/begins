
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
  local words = { "全部关注", "最新微博", "好友圈", "表情", "有什么新鲜事想分享给大家？", "韩路" }
  for _, w in ipairs(words) do
    local ev = rpc("Runtime.evaluate", { expression = string.format([[
      (function(){var all=document.querySelectorAll('body *');
       for(var i=0;i<all.length;i++){var e=all[i];
         if(e.children.length===0 && (e.innerText||'').trim()===%q) return e;}
       return null})()
    ]], w) })
    local oid = ev and ev.result and ev.result.result and ev.result.result.objectId
    if not oid then
      log(string.format("%-12s [未找到]", w))
    else
      local rn = rpc("DOM.requestNode", { objectId = oid })
      local nid = rn and rn.result and rn.result.nodeId
      local pf = nid and rpc("CSS.getPlatformFontsForNode", { nodeId = nid })
      local fonts = pf and pf.result and pf.result.fonts
      local parts = {}
      if fonts then
        for _, fo in ipairs(fonts) do
          parts[#parts+1] = string.format("%s(%d)", fo.familyName or "?", fo.glyphCount or 0)
        end
      end
      log(string.format("%-12s %s", w, #parts > 0 and table.concat(parts, " + ") or "[无 glyph]"))
    end
  end
  ws.close()
end
local ok, err = xpcall(main, debug.traceback)
if not ok then io.stderr:write("ERROR: "..tostring(err).."\n"); os.exit(1) end
