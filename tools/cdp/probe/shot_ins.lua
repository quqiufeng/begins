  if js == "@shot" then
    local f_out = (arg[4] or "/tmp/shot.png")
    local r = rpc("Page.captureScreenshot", { format = "png" })
    local data = r and r.result and r.result.data
    if data then
      local f = io.open("/tmp/shot.b64", "wb"); f:write(data); f:close()
      os.execute("base64 -d /tmp/shot.b64 > " .. f_out)
      log("[shot] " .. f_out .. "  b64=" .. #data)
    else
      log("[shot:err] " .. jenc(r or {}))
    end
    js = nil
  end
