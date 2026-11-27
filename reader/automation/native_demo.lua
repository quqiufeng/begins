-- native_demo.lua — native_reader 窗口定位/截图演示（X11 兜底）
--
--   luajit automation/native_demo.lua
--
-- 依次：定位窗口 → 激活 → 居中 → 读取几何 → 截图。
-- 注意：主路径优先 app.capture（SDL_RenderReadPixels）；本脚本是 X11 兜底。

local dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = dir .. "/?.lua;" .. package.path

local R = require("reader")
local c = assert(R.open())

local w = assert(c:window(), "native-reader 窗口未找到")
print(("窗口 id=%d  %dx%d @ %d,%d"):format(w.id, w.w, w.h, w.x, w.y))

w:activate():center()
print(("居中后 @ %d,%d"):format(w.x, w.y))

local ok, path = w:capture("/tmp/opencode/native_reader.png")
print(ok and ("截图: " .. path) or "截图失败")

c:close()
