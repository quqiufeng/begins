-- SDL2 KMSDRM 全屏冒烟测试（LuaJIT FFI，无编译、无 X11）
local ffi = require("ffi")

ffi.cdef[[
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;
typedef struct SDL_Surface SDL_Surface;

typedef struct { int x, y, w, h; } SDL_Rect;
typedef struct { unsigned char r, g, b, a; } SDL_Color;
typedef struct { unsigned int format; int w, h, refresh_rate; void *driverdata; } SDL_DisplayMode;

int    SDL_Init(unsigned int flags);
void   SDL_Quit(void);
const char *SDL_GetError(void);
int    SDL_GetDesktopDisplayMode(int displayIndex, SDL_DisplayMode *mode);
SDL_Window   *SDL_CreateWindow(const char *title, int x, int y, int w, int h, unsigned int flags);
SDL_Renderer *SDL_CreateRenderer(SDL_Window *w, int index, unsigned int flags);
void   SDL_DestroyWindow(SDL_Window *w);
void   SDL_DestroyRenderer(SDL_Renderer *r);
void   SDL_DestroyTexture(SDL_Texture *t);
int    SDL_RenderSetLogicalSize(SDL_Renderer *r, int w, int h);
int    SDL_SetRenderDrawColor(SDL_Renderer *r, unsigned char R, unsigned char G, unsigned char B, unsigned char A);
int    SDL_RenderClear(SDL_Renderer *r);
int    SDL_RenderFillRect(SDL_Renderer *r, const SDL_Rect *rect);
int    SDL_RenderPresent(SDL_Renderer *r);
int    SDL_RenderCopy(SDL_Renderer *r, SDL_Texture *t, const SDL_Rect *src, const SDL_Rect *dst);
SDL_Texture *SDL_CreateTextureFromSurface(SDL_Renderer *r, SDL_Surface *s);
void   SDL_FreeSurface(SDL_Surface *s);
void   SDL_Delay(unsigned int ms);
unsigned int SDL_GetTicks(void);
const char *SDL_GetCurrentVideoDriver(void);

/* SDL2_ttf */
int    TTF_Init(void);
void   TTF_Quit(void);
void  *TTF_OpenFontIndex(const char *file, int ptsize, long index);
void   TTF_CloseFont(void *font);
SDL_Surface *TTF_RenderUTF8_Blended(void *font, const char *text, SDL_Color fg);
]]

local SDL = ffi.load("SDL2")
local TTF = ffi.load("SDL2_ttf")

local function die(msg) io.stderr:write("ERR: " .. msg .. "\n"); os.exit(1) end
local function err() return ffi.string(SDL.SDL_GetError()) end

if SDL.SDL_Init(0x00000020) ~= 0 then die("SDL_Init: " .. err()) end   -- SDL_INIT_VIDEO
print("videodriver = " .. ffi.string(SDL.SDL_GetCurrentVideoDriver()))

local dm = ffi.new("SDL_DisplayMode")
if SDL.SDL_GetDesktopDisplayMode(0, dm) ~= 0 then die("GetDesktopDisplayMode: " .. err()) end
print(string.format("desktop mode = %dx%d @%dHz", dm.w, dm.h, dm.refresh_rate))
local W, H = dm.w, dm.h

local win = SDL.SDL_CreateWindow("sdltest", 0, 0, W, H, 0x00001001)  -- FULLSCREEN_DESKTOP
if win == nil then die("CreateWindow: " .. err()) end
print("window ok")

local ren = SDL.SDL_CreateRenderer(win, -1, 0x00000002 + 0x00000004)  -- ACCELERATED|PRESENTVSYNC
if ren == nil then
  print("accelerated renderer failed (" .. err() .. "), retry software")
  ren = SDL.SDL_CreateRenderer(win, -1, 0)
end
if ren == nil then die("CreateRenderer: " .. err()) end
print("renderer ok")

local t0 = SDL.SDL_GetTicks()
local frames = 0
local seconds = tonumber(os.getenv("TEST_SECONDS") or "5")

-- 尝试加载 CJK 字体
local font
pcall(function()
  if TTF.TTF_Init() ~= 0 then return end
  for _, p in ipairs({
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc",
  }) do
    local f = TTF.TTF_OpenFontIndex(p, 64, 0)
    if f ~= nil then print("font = " .. p); font = f; return end
  end
end)

local text_tex
if font ~= nil then
  local fg = ffi.new("SDL_Color", 255, 255, 255, 255)
  local surf = TTF.TTF_RenderUTF8_Blended(font, "阅读器 A53 2560x1440 OK", fg)
  if surf ~= nil then
    text_tex = SDL.SDL_CreateTextureFromSurface(ren, surf)
    SDL.SDL_FreeSurface(surf)
    print("cjk text texture ok")
  else
    print("text render failed: " .. err())
  end
end

local rect = ffi.new("SDL_Rect")
local textdst = ffi.new("SDL_Rect")
local start = SDL.SDL_GetTicks()
local done = false
while not done do
  local ms = SDL.SDL_GetTicks() - start
  if ms > seconds * 1000 then done = true end
  local phase = (ms % 2000) / 2000
  SDL.SDL_SetRenderDrawColor(ren, math.floor(20 + 60 * phase), 24, math.floor(60 + 40 * phase), 255)
  SDL.SDL_RenderClear(ren)
  local cols = { {220, 60, 60}, {60, 200, 90}, {70, 120, 230} }
  for i = 1, 3 do
    local c = cols[i]
    SDL.SDL_SetRenderDrawColor(ren, c[1], c[2], c[3], 255)
    rect.x, rect.y, rect.w, rect.h = (i - 1) * math.floor(W / 3), 0, math.floor(W / 3), 40
    SDL.SDL_RenderFillRect(ren, rect)
  end
  SDL.SDL_SetRenderDrawColor(ren, 255, 200, 40, 255)
  local bx = math.floor(phase * (W - 200))
  rect.x, rect.y, rect.w, rect.h = bx, math.floor(H / 2) - 60, 200, 120
  SDL.SDL_RenderFillRect(ren, rect)
  if text_tex ~= nil then
    textdst.x, textdst.y, textdst.w, textdst.h = 80, H - 180, 900, 90
    SDL.SDL_RenderCopy(ren, text_tex, nil, textdst)
  end
  SDL.SDL_RenderPresent(ren)
  frames = frames + 1
end

local el = SDL.SDL_GetTicks() - t0
print(string.format("frames=%d elapsed=%dms fps=%.1f", frames, el, frames / (el / 1000)))

if text_tex ~= nil then SDL.SDL_DestroyTexture(text_tex) end
if font ~= nil then TTF.TTF_CloseFont(font); TTF.TTF_Quit() end
SDL.SDL_DestroyRenderer(ren)
SDL.SDL_DestroyWindow(win)
SDL.SDL_Quit()
print("OK")
