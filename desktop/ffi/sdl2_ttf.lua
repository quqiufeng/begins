-- ffi/sdl2_ttf.lua — SDL2_ttf 绑定 + 纹理缓存
--
-- 桌面每帧都在画文字（文件名/路径/提示），逐帧 TTF_RenderUTF8 太贵：
-- 这里按 (文本, 字号, 颜色) 缓存纹理，最多 800 条，超了整表清空（桌面上文字
-- 集合本来就小，清空一次也就几十毫秒）。

local ffi = require("ffi")
local sdl = require("ffi.sdl2")

ffi.cdef [[
typedef struct _TTF_Font TTF_Font;
typedef struct SDL_Color { uint8_t r, g, b, a; } SDL_Color;

int TTF_Init(void);
void TTF_Quit(void);
TTF_Font *TTF_OpenFont(const char *file, int ptsize);
void TTF_CloseFont(TTF_Font *font);
SDL_Surface *TTF_RenderUTF8_Blended(TTF_Font *font, const char *text, SDL_Color fg);
int TTF_SizeUTF8(TTF_Font *font, const char *text, int *w, int *h);
const char *TTF_GetError(void);
]]

local lib = ffi.load("SDL2_ttf")
local M = { lib = lib, cache = {}, fonts = {}, count = 0, max = 800 }

local Surface = ffi.typeof("struct SDL_Surface")

function M.init()
	if lib.TTF_Init() ~= 0 then return false, "TTF_Init: " .. ffi.string(lib.TTF_GetError()) end
	return true
end

function M.quit()
	lib.TTF_Quit()
end

function M.font(path, size)
	local key = path .. "@" .. size
	local f = M.fonts[key]

	if f then return f end
	f = lib.TTF_OpenFont(path, size)
	if f == nil then
		-- .ttc 一般第一面就够；开不到就报错，让上层换字体
		return nil, "TTF_OpenFont failed: " .. path .. " " .. tostring(size)
	end
	M.fonts[key] = f
	return f
end

function M.measure(font, text)
	local w, h = ffi.new("int[1]"), ffi.new("int[1]")

	if lib.TTF_SizeUTF8(font, text, w, h) ~= 0 then return 0, 0 end
	return tonumber(w[0]), tonumber(h[0])
end

-- 返回纹理，调用方自己决定画在哪（不缓存）
function M.render(ren, font, text, rgb, alpha)
	local c = ffi.new("SDL_Color")

	c.r = math.floor(rgb / 65536) % 256
	c.g = math.floor(rgb / 256) % 256
	c.b = rgb % 256
	c.a = alpha or 255
	if text == nil or text == "" then return nil end
	local surf = lib.TTF_RenderUTF8_Blended(font, text, c)

	if surf == nil then return nil end
	local tex = sdl.texture_from_surface(ren, surf)

	sdl.free_surface(surf)
	return tex
end

-- 带缓存渲染；返回 texture, w, h
function M.get(ren, path, text, size, rgb)
	if text == nil or text == "" then return nil end
	local key = size .. "|" .. rgb .. "|" .. text
	local e = M.cache[key]

	if e then return e.tex end
	local f = M.font(path, size)

	if not f then return nil end
	local tex = M.render(ren, f, text, rgb)

	if tex == nil then return nil end
	if M.count >= M.max then
		for _, v in pairs(M.cache) do sdl.destroy_texture(v.tex) end
		M.cache, M.count = {}, 0
	end
	M.cache[key] = { tex = tex }
	M.count = M.count + 1
	return tex
end

function M.clear()
	for _, v in pairs(M.cache) do sdl.destroy_texture(v.tex) end
	M.cache, M.count = {}, 0
end

-- 画一段文字；align: "left" | "center" | "right"（相对 x）
function M.draw(ren, path, text, size, x, y, rgb, align, alpha)
	local tex = M.get(ren, path, text, size, rgb)

	if not tex then return false end
	local w, h = sdl.tex_size(tex)
	local dx = x

	if align == "center" then dx = x - math.floor(w / 2)
	elseif align == "right" then dx = x - w end
	local r = ffi.new("SDL_Rect")
	r.x, r.y, r.w, r.h = math.floor(dx), math.floor(y), w, h
	sdl.lib.SDL_RenderCopy(ren, tex, nil, r)
	return true, w, h
end

function M.width(path, text, size)
	local f = M.font(path, size)

	if not f then return 0 end
	local w = M.measure(f, text)

	return w
end

return M
