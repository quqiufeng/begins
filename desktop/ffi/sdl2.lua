-- ffi/sdl2.lua — SDL2 × LuaJIT FFI 绑定（只包桌面用到的那一小撮）
--
-- 和 reader 的 ffi/sdl2.lua 同源，另外补了桌面必需的三样：
--   * SDL_InitSubSystem / QuitSubSystem —— 起外部 app（reader/播放器）前要先
--     把显示子系统放掉，否则 KMSDRM 的 DRM master 在我们手里，别人上不了屏；
--   * SDL_RenderCopyEx —— 缩略图/图片预览要能缩放；
--   * SDL_RenderSetClipRect + RenderDrawLines —— 网格裁剪和装饰线。
--
-- 一律 ffi.load("SDL2")：盒子/开发机都是 libSDL2-2.0.so，经 ld 的 soname 链过去。

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;
typedef struct SDL_Surface SDL_Surface;
typedef struct SDL_RWops SDL_RWops;
typedef struct SDL_Cursor SDL_Cursor;
typedef struct SDL_Rect { int x, y, w, h; } SDL_Rect;
typedef struct SDL_Point { int x, y; } SDL_Point;

typedef union SDL_Event {
    uint32_t type;
    struct {
        uint32_t type, timestamp, windowID;
        uint8_t state, repeat, padding2, padding3;
        int32_t scancode, sym;
        uint16_t mod;
        uint32_t unused;
    } key;
    struct {
        uint32_t type, timestamp, windowID, which;
        uint8_t button, state, clicks, padding;
        int32_t x, y;
    } button;
    struct {
        uint32_t type, timestamp, windowID;
        char text[32];
    } text;
    struct {
        uint32_t type, timestamp, windowID, which;
        int32_t x, y;
        uint32_t direction;
    } wheel;
    struct {
        uint32_t type, timestamp, windowID, which, state;
        int32_t x, y, xrel, yrel;
    } motion;
    struct {
        uint32_t type, timestamp, windowID;
        uint8_t event, padding1, padding2, padding3;
        int32_t data1, data2;
    } window;
    uint8_t padding[56];
} SDL_Event;

int SDL_Init(uint32_t flags);
int SDL_InitSubSystem(uint32_t flags);
void SDL_QuitSubSystem(uint32_t flags);
void SDL_Quit(void);
const char *SDL_GetError(void);
int SDL_SetHint(const char *name, const char *value);
const char *SDL_GetCurrentVideoDriver(void);
SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
void SDL_DestroyWindow(SDL_Window *w);
void SDL_SetWindowTitle(SDL_Window *w, const char *title);
void SDL_GetWindowSize(SDL_Window *w, int *width, int *height);
int SDL_SetWindowFullscreen(SDL_Window *w, uint32_t flags);
uint32_t SDL_GetWindowFlags(SDL_Window *w);
void SDL_ShowCursor(int toggle);

SDL_Renderer *SDL_CreateRenderer(SDL_Window *win, int index, uint32_t flags);
void SDL_DestroyRenderer(SDL_Renderer *r);
int SDL_GetRendererOutputSize(SDL_Renderer *r, int *w, int *h);
int SDL_SetRenderDrawColor(SDL_Renderer *r, uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha);
int SDL_SetRenderDrawBlendMode(SDL_Renderer *r, int mode);
int SDL_RenderClear(SDL_Renderer *r);
int SDL_RenderFillRect(SDL_Renderer *r, const SDL_Rect *rect);
int SDL_RenderDrawRect(SDL_Renderer *r, const SDL_Rect *rect);
int SDL_RenderDrawLine(SDL_Renderer *r, int x1, int y1, int x2, int y2);
int SDL_RenderDrawLines(SDL_Renderer *r, const SDL_Point *pts, int count);
int SDL_RenderCopy(SDL_Renderer *r, SDL_Texture *t, const SDL_Rect *src, const SDL_Rect *dst);
int SDL_RenderCopyEx(SDL_Renderer *r, SDL_Texture *t, const SDL_Rect *src,
                     const SDL_Rect *dst, double angle, const SDL_Point *center, int flip);
void SDL_RenderPresent(SDL_Renderer *r);
int SDL_RenderSetClipRect(SDL_Renderer *r, const SDL_Rect *rect);
int SDL_RenderReadPixels(SDL_Renderer *r, const SDL_Rect *rect, uint32_t format,
                         void *pixels, int pitch);
int SDL_SetTextureBlendMode(SDL_Texture *t, int mode);

SDL_Surface *SDL_CreateRGBSurfaceWithFormat(uint32_t flags, int w, int h, int depth, uint32_t format);
void SDL_FreeSurface(SDL_Surface *s);
SDL_Texture *SDL_CreateTexture(SDL_Renderer *r, uint32_t format, int access, int w, int h);
SDL_Texture *SDL_CreateTextureFromSurface(SDL_Renderer *r, SDL_Surface *s);
void SDL_DestroyTexture(SDL_Texture *t);
int SDL_UpdateTexture(SDL_Texture *t, const SDL_Rect *rect, const void *pixels, int pitch);
int SDL_QueryTexture(SDL_Texture *t, uint32_t *format, int *access, int *w, int *h);

SDL_RWops *SDL_RWFromFile(const char *file, const char *mode);
SDL_Surface *SDL_LoadBMP_RW(SDL_RWops *src, int freesrc);

int SDL_PollEvent(SDL_Event *e);
int SDL_WaitEventTimeout(SDL_Event *e, int timeout);
void SDL_Delay(uint32_t ms);
uint32_t SDL_GetTicks(void);
]]

local lib = ffi.load("SDL2")
local M = { lib = lib }

-- ---- 常量 ----
M.INIT_VIDEO = 0x20
M.INIT_EVENTS = 0x4000

M.WINDOWPOS_CENTERED = 0x2FFF0000
M.WINDOW_SHOWN = 0x4
M.WINDOW_RESIZABLE = 0x20
M.WINDOW_FULLSCREEN = 0x1
M.WINDOW_FULLSCREEN_DESKTOP = 0x1001
M.WINDOW_MAXIMIZED = 0x80
M.WINDOW_BORDERLESS = 0x10

M.RENDERER_SOFTWARE = 0x1
M.RENDERER_ACCELERATED = 0x2
M.RENDERER_PRESENTVSYNC = 0x4

M.TEXTUREACCESS_STATIC = 0
M.TEXTUREACCESS_STREAMING = 1
M.BLENDMODE_NONE = 0
M.BLENDMODE_BLEND = 1

M.PIXELFORMAT_RGBA8888 = 376840200
M.PIXELFORMAT_ABGR8888 = 376840196
M.PIXELFORMAT_ARGB8888 = 372645892

M.QUIT = 0x100
M.WINDOWEVENT = 0x200
M.WINDOWEVENT_RESIZED = 5
M.WINDOWEVENT_SIZE_CHANGED = 6
M.WINDOWEVENT_EXPOSED = 3
M.WINDOWEVENT_RESTORED = 9
M.WINDOWEVENT_MAXIMIZED = 8
M.WINDOWEVENT_CLOSE = 14
M.KEYDOWN = 0x300
M.KEYUP = 0x301
M.REPEAT = 0x400
M.TEXTINPUT = 0x303
M.MOUSEMOTION = 0x400
M.MOUSEBUTTONDOWN = 0x401
M.MOUSEBUTTONUP = 0x402
M.MOUSEWHEEL = 0x403

-- 用得到的 SDLK（其它键按需要继续加）
M.SDLK = {
	ESCAPE = 27, RETURN = 13, KP_ENTER = 0x40000058, SPACE = 32,
	BACKSPACE = 8, DELETE = 127, TAB = 9,
	LEFT = 0x40000050, RIGHT = 0x4000004F, UP = 0x40000052, DOWN = 0x40000051,
	PAGEUP = 0x4000004B, PAGEDOWN = 0x4000004E,
	HOME = 0x4000004A, END = 0x4000004D,
	F1 = 0x4000003A, F2 = 0x4000003B, F5 = 0x4000003E, F6 = 0x4000003F,
	F10 = 0x40000043, F11 = 0x40000044, F12 = 0x40000045,
	MENU = 0x40000076, PRINTSCREEN = 0x40000046,
	A = 97, B = 98, C = 99, D = 100, E = 101, G = 103, H = 104,
	I = 105, L = 106, M = 109, N = 110, O = 111, P = 112, Q = 113,
	R = 114, S = 115, T = 116, U = 117, V = 118, W = 119, X = 120,
	Y = 121, Z = 122,
	K0 = 48, K1 = 49, K2 = 50, K3 = 51, K4 = 52,
	K5 = 53, K6 = 54, K7 = 55, K8 = 56, K9 = 57,
	SLASH = 47, PERIOD = 46, MINUS = 45, EQUALS = 61,
	-- 0x4000002B = SDLK_PLUS（shift+=）; 盒上这份头文件原来没这两项，
	-- main.lua 里 KEYSYM 用它做「字号+」，缺了会 table index nil
	PLUS = 0x4000002B, KP_PLUS = 0x40000057, KP_MINUS = 0x40000056,
}

local function ok(rc) return rc ~= nil and rc >= 0 end

-- ---- 生命周期 ----
function M.init()
	return lib.SDL_Init(M.INIT_VIDEO) == 0
end

function M.init_video()
	return lib.SDL_InitSubSystem(M.INIT_VIDEO) == 0
end

function M.quit_video()
	lib.SDL_QuitSubSystem(M.INIT_VIDEO)
end

function M.quit()
	lib.SDL_Quit()
end

function M.err()
	return ffi.string(lib.SDL_GetError())
end

function M.set_hint(k, v)
	return lib.SDL_SetHint(k, v) ~= 0
end

function M.video_driver()
	local p = lib.SDL_GetCurrentVideoDriver()

	if p == nil then return "?" end
	return ffi.string(p)
end

-- ---- 窗口 / 渲染器 ----
function M.create_window(title, w, h, opts)
	opts = opts or {}
	local flags = M.WINDOW_SHOWN

	if opts.resizable then flags = bit.bor(flags, M.WINDOW_RESIZABLE) end
	if opts.fullscreen then flags = bit.bor(flags, M.WINDOW_FULLSCREEN_DESKTOP) end
	if opts.borderless then flags = bit.bor(flags, M.WINDOW_BORDERLESS) end

	local win = lib.SDL_CreateWindow(title, M.WINDOWPOS_CENTERED,
		M.WINDOWPOS_CENTERED, w, h, flags)

	return win ~= nil and win or nil
end

function M.create_renderer(win, vsync)
	local flags = M.RENDERER_ACCELERATED

	if vsync then flags = bit.bor(flags, M.RENDERER_PRESENTVSYNC) end
	local r = lib.SDL_CreateRenderer(win, -1, flags)

	if r == nil then r = lib.SDL_CreateRenderer(win, -1, M.RENDERER_SOFTWARE) end
	if r ~= nil then lib.SDL_SetRenderDrawBlendMode(r, M.BLENDMODE_BLEND) end
	return r ~= nil and r or nil
end

function M.output_size(ren)
	local w, h = ffi.new("int[1]"), ffi.new("int[1]")

	if lib.SDL_GetRendererOutputSize(ren, w, h) ~= 0 then return nil, nil end
	return tonumber(w[0]), tonumber(h[0])
end

function M.window_size(win)
	local w, h = ffi.new("int[1]"), ffi.new("int[1]")

	lib.SDL_GetWindowSize(win, w, h)
	return tonumber(w[0]), tonumber(h[0])
end

function M.set_fullscreen(win, on)
	return lib.SDL_SetWindowFullscreen(win, on and M.WINDOW_FULLSCREEN_DESKTOP or 0) == 0
end

function M.show_cursor(on)
	lib.SDL_ShowCursor(on and 1 or 0)
end

function M.destroy(ren, win)
	if ren ~= nil then lib.SDL_DestroyRenderer(ren) end
	if win ~= nil then lib.SDL_DestroyWindow(win) end
end

-- ---- 画 ----
local rect = ffi.new("SDL_Rect")

local function set(r, x, y, w, h)
	r.x, r.y, r.w, r.h = x, y, w, h
	return r
end
M.rect = set
M._tmp = rect

function M.color(ren, rgb, a)
	local r = math.floor(rgb / 65536) % 256
	local g = math.floor(rgb / 256) % 256
	local b = rgb % 256

	return lib.SDL_SetRenderDrawColor(ren, r, g, b, a or 255)
end

function M.clear(ren, rgb)
	M.color(ren, rgb)
	return lib.SDL_RenderClear(ren)
end

function M.fill(ren, x, y, w, h, rgb, a)
	if w <= 0 or h <= 0 then return end
	M.color(ren, rgb, a)
	lib.SDL_RenderFillRect(ren, set(rect, x, y, w, h))
end

function M.frame(ren, x, y, w, h, rgb, a)
	M.color(ren, rgb, a)
	lib.SDL_RenderDrawRect(ren, set(rect, x, y, w, h))
end

function M.line(ren, x1, y1, x2, y2, rgb, a)
	M.color(ren, rgb, a)
	lib.SDL_RenderDrawLine(ren, x1, y1, x2, y2)
end

function M.clip(ren, x, y, w, h)
	if not x then return lib.SDL_RenderSetClipRect(ren, nil) end
	return lib.SDL_RenderSetClipRect(ren, set(rect, x, y, w, h))
end

function M.present(ren)
	lib.SDL_RenderPresent(ren)
end

function M.copy(ren, tex, dst)
	lib.SDL_RenderCopy(ren, tex, nil, set(rect, dst.x, dst.y, dst.w, dst.h))
end

function M.copy_ex(ren, tex, dst, angle)
	lib.SDL_RenderCopyEx(ren, tex, nil, set(rect, dst.x, dst.y, dst.w, dst.h),
		angle or 0, nil, 0)
end

function M.tex_size(tex)
	local w, h = ffi.new("int[1]"), ffi.new("int[1]")

	if lib.SDL_QueryTexture(tex, nil, nil, w, h) ~= 0 then return 0, 0 end
	return tonumber(w[0]), tonumber(h[0])
end

-- 流式纹理（一帧像素）
function M.create_texture(ren, w, h)
	return lib.SDL_CreateTexture(ren, M.PIXELFORMAT_ABGR8888,
		M.TEXTUREACCESS_STREAMING, w, h)
end

function M.texture_from_surface(ren, surf)
	return lib.SDL_CreateTextureFromSurface(ren, surf)
end

-- 直出纹理（libpng 这类自己解像素的路径）要开混合，否则图标 alpha 变黑底
function M.set_blend(tex, mode)
	if tex == nil then return end
	lib.SDL_SetTextureBlendMode(tex, mode or 1)   -- 1 = SDL_BLENDMODE_BLEND
end

function M.update_texture(tex, pixels, pitch)
	return lib.SDL_UpdateTexture(tex, nil, pixels, pitch)
end

function M.free_surface(surf) lib.SDL_FreeSurface(surf) end
function M.destroy_texture(tex)
	if tex ~= nil then lib.SDL_DestroyTexture(tex) end
end

function M.load_bmp(path)
	local rw = lib.SDL_RWFromFile(path, "rb")

	if rw == nil then return nil end
	return lib.SDL_LoadBMP_RW(rw, 1)
end

-- ---- 事件 ----
function M.poll(ev) return lib.SDL_PollEvent(ev) ~= 0 end
function M.wait(ev, ms) return lib.SDL_WaitEventTimeout(ev, ms) ~= 0 end
function M.delay(ms) lib.SDL_Delay(ms) end
function M.ticks() return tonumber(lib.SDL_GetTicks()) end

-- 抓当前渲染目标的一帧（RGBA，行距 w*4），交给 ffi 缓冲
M.FORMAT_RGBA = M.PIXELFORMAT_ABGR8888

return M
