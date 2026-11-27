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
]]

local lib = ffi.load("SDL2_ttf")

local M = {}

function M.init()
    return lib.TTF_Init() == 0
end

function M.quit()
    lib.TTF_Quit()
end

function M.open(path, size)
    return lib.TTF_OpenFont(path, size)
end

function M.close(font)
    if font then lib.TTF_CloseFont(font) end
end

function M.size(font, text)
    local w = ffi.new("int[1]")
    local h = ffi.new("int[1]")
    if lib.TTF_SizeUTF8(font, text, w, h) ~= 0 then return 0, 0 end
    return tonumber(w[0]), tonumber(h[0])
end

function M.render_texture(ren, font, text, r, g, b, a)
    local color = ffi.new("SDL_Color")
    color.r, color.g, color.b, color.a = r, g, b, a or 255
    local surf = lib.TTF_RenderUTF8_Blended(font, text, color)
    if surf == nil then return nil end
    local tex = sdl.create_texture_from_surface(ren, surf)
    sdl.free_surface(surf)
    return tex
end

return M
