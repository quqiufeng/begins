-- cog.lua —— 本机 LuaJIT 遥控盒子上的 cog 直出浏览器（x96 / x98h）。
-- 走 SSH 到盒子执行 tools/cog/box-cog.sh（cog 无 CDP，控制面是 D-Bus org.gtk.Actions，cogctl 是它的 CLI）。
-- 用法：
--   luajit cog.lua <host> start [url]
--   luajit cog.lua <host> open <url>
--   luajit cog.lua <host> reload | previous | next | ping | status
--   luajit cog.lua <host> shot <out.png>      -- 抓 HDMI 画面并转 PNG
--   luajit cog.lua <host> stop
local host = assert(arg[1], "需要盒子别名，如 x98h / x96")
local sub  = arg[2] or "status"

local BOX = "/root/cog/box-cog.sh"
local GRAB = "/tmp/cogrt/shot.raw"
local W, H = 2560, 1440   -- 123/121 都接 2560x1440；别的分辨率时改这里

local function sh(cmd)                       -- 跑本地 shell，返回输出
  local p = io.popen(cmd .. " 2>&1")
  local out = p:read("*a"); p:close()
  return (out:gsub("%s+$", ""))
end

local function box(sub, ...)                 -- 在盒子上跑 box-cog.sh
  local t = { ... }
  for i, v in ipairs(t) do t[i] = "'" .. v:gsub("'", "'\\''") .. "'" end
  local args = #t > 0 and (" " .. table.concat(t, " ")) or ""
  local c = "ssh -o BatchMode=yes " .. host .. " " .. BOX .. " " .. sub .. args
  if os.getenv("COG_DEBUG") then io.stderr:write("CMD=[" .. c .. "]\n") end
  return sh(c)
end

local function shot_png(png)                 -- 抓屏 → 拉回本机 → ffmpeg 转 PNG
  local r = sh("ssh -o BatchMode=yes " .. host .. " " .. BOX .. " shot " .. GRAB)
  if not r:match("%d+$") or r:match("^" .. GRAB .. " 0$") then
    return false, "抓屏失败: " .. r
  end
  sh("scp -q " .. host .. ":" .. GRAB .. " /tmp/cog-shot.raw")
  -- 用 bgr0 而不是 bgra：grabscreen-aarch64 的 alpha 通道全是 0，
  -- 输出 rgb24 时 ffmpeg 会丢 alpha（两种写法实测字节相同），
  -- 但一旦改成保留 alpha 的格式（rgba/png-alpha），bgra 就会得到全透明→全白。
  -- bgr0 让 alpha 恒为不透明，任何输出格式都不会踩这个坑。
  local cmd = ("ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgr0 -s %dx%d -i /tmp/cog-shot.raw -pix_fmt rgb24 %s")
    :format(W, H, png)
  if sh(cmd) ~= "" then return false, "ffmpeg 失败" end
  return true, png
end

if sub == "start" then
  print(box("start", arg[3] or "file:///tmp/cogtest/a.html"))
elseif sub == "open" then
  local url = arg[3]
  if not url then io.stderr:write("open 需要 URL\n"); os.exit(2) end
  print(box("open", url))
elseif sub == "reload" or sub == "previous" or sub == "next" or sub == "ping" or sub == "status" then
  print(box(sub))
elseif sub == "quit" then
  print(box("quit"))
elseif sub == "stop" then
  print(box("stop"))
elseif sub == "shot" then
  local ok, err = shot_png(arg[3] or "/tmp/cog-shot.png")
  print(ok and ("已抓屏: " .. err) or ("错误: " .. tostring(err)))
else
  io.stderr:write("未知子命令: " .. sub .. "\n")
  os.exit(2)
end
