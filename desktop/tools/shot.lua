-- tools/shot.lua — 离屏渲染一张网格截图（冒烟测试用，不依赖显示器）
--
-- 用法：SDL_VIDEODRIVER=dummy luajit tools/shot.lua [目录] [输出png]
-- 走的是和真机完全相同的 ui/grid 绘制路径，只是把结果从软件渲染器读回来存 PNG。

package.path = "./?.lua;../?.lua;" .. package.path

local ffi = require("ffi")
local cfg = require("config")
local theme = require("ui.theme")
local sdl = require("ffi.sdl2")
local img = require("ffi.sdl2_image")
local ttf = require("ffi.sdl2_ttf")
local txt = require("ui.text")
local grid = require("ui.grid")
local icons = require("ui.icons")
local png = require("util.png")
local fs = require("core.fs")

local dir = arg[1] or "."
local out = arg[2] or "/tmp/grid-shot.png"
local W, H = tonumber(os.getenv("SHOT_W") or 1280), tonumber(os.getenv("SHOT_H") or 800)

sdl.init()
sdl.init_video()
ttf.init()   -- 必须：否则 TTF_OpenFont 全失败，文字静默不画

local win = sdl.create_window("shot", W, H, { hidden = true })
local ren = sdl.create_renderer(win, false)

if ren == nil then error("renderer: " .. tostring(sdl.err())) end

local font = cfg.font_path()


local f = fs.new(cfg)
f:scan(dir)

local g = grid.new(cfg, theme, ttf, txt, img, icons.new(cfg, sdl, img), sdl)

g:layout(W, H)
g:draw(ren, f, W, H)

local buf = ffi.new("uint8_t[?]", W * H * 4)
local r = sdl.lib.SDL_RenderReadPixels(ren, nil, sdl.PIXELFORMAT_ARGB8888, buf, W * 4)

if r ~= 0 then error("readpixels: " .. tostring(sdl.err())) end

png.save(out, W, H, buf, W * 4)
print(("%s  %dx%d  项数=%d 列=%d 行=%d"):format(out, W, H, f:count(), g.cols, g.rows))
