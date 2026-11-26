
------------------------------------------------------------------ 平台字体统计
local function main()
  math.randomseed(os.time() % 100000)
  local status, body = http_get_json_list()
  if status ~= "200" or not body then log("ERROR: /json/list "..tostring(status)); os.exit(1) end
  local list = jdec(body)
  local target
  for _, t in ipairs(list) do if t.type == "page" and t.webSocketDebuggerUrl then target = t break end end
  if not target then log("ERROR: 没有 page"); os.exit(1) end
  log("[page] " .. tostring(target.url))
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
  rpc("DOM.enable"); rpc("CSS.enable")
  local doc = rpc("DOM.getDocument", { depth = 1 })
  local root = doc and doc.result and doc.result.root and doc.result.root.nodeId
  if not root then log("ERROR: 无 root"); os.exit(1) end
  local q = rpc("DOM.querySelectorAll", { nodeId = root, selector = "body, body *" })
  local ids = q and q.result and q.result.nodeIds or {}
  log("[nodes] " .. #ids)
  local MAX = tonumber(arg[1]) or 700
  local tally, samples = {}, {}
  for i = 1, math.min(#ids, MAX) do
    local r = rpc("CSS.getPlatformFontsForNode", { nodeId = ids[i] })
    local fonts = r and r.result and r.result.fonts
    if fonts then
      for _, fo in ipairs(fonts) do
        local n = fo.glyphCount or 0
        if n > 0 then
          local fam = fo.familyName or "?"
          tally[fam] = (tally[fam] or 0) + n
          if not samples[fam] then
            local s = rpc("Runtime.callFunctionOn", {
              functionDeclaration = "function(){return (this.innerText||'').replace(/\\s+/g,' ').slice(0,40)}",
              objectId = nil })
          end
        end
      end
    end
  end
  local arr = {}
  for k, v in pairs(tally) do arr[#arr+1] = { k, v } end
  table.sort(arr, function(a, b) return a[2] > b[2] end)
  local tot = 0
  for _, e in ipairs(arr) do tot = tot + e[2] end
  log("[glyphs] 合计 " .. tot)
  for _, e in ipairs(arr) do
    log(string.format("  %-28s %8d  %5.1f%%", e[1], e[2], tot > 0 and e[2]*100.0/tot or 0))
  end
  ws.close()
end
local ok, err = xpcall(main, debug.traceback)
if not ok then io.stderr:write("ERROR: "..tostring(err).."\n"); os.exit(1) end
