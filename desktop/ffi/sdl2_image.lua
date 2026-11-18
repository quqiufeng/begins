-- ffi/sdl2_image.lua — 图片解码（纹理）加载
--
-- 两条路：
--   1. 有 libSDL2_image 就用它（IMG_Load 支持 png/jpg/webp 一大票格式）；
--   2. 没有（很多发行版只装运行时、不装 -dev，或者盒子干脆没这个包）就自己解：
--      PNG 走 libpng 的 simplified API（png_image_finish_read），JPEG 走
--      libturbojpeg 的 tjDecompress2，解成 RGBA 再塞进 SDL 纹理。
--      两者的解码库都缺、或者格式不认识，就返回 nil 让上层退回类型徽章。
--
-- 对外只有两个东西：M.available、M.texture(ren, path)。失败一律返回 nil，
-- 调用方退回文字徽章，保证没图也能跑。

local ffi = require("ffi")
local sdl = require("ffi.sdl2")
local gif = require("ffi.gif")

local M = { available = false, backend = nil }

-- ---------- 路径 1：SDL2_image ----------

local ok_img = pcall(function()
	ffi.cdef [[
	SDL_Surface *IMG_Load(const char *file);
	const char *IMG_GetError(void);
	int IMG_Init(int flags);
	void IMG_Quit(void);
	]]
end)

-- 有的发行版只装了带版本号的 so（没 -dev 包时没有 libSDL2_image.so 这个软链），
-- 所以按候选名依次试；装哪个都能用。
local img_names = { "SDL2_image", "libSDL2_image-2.0.so.0", "SDL2_image-2.0.so.0" }

if ok_img then
	for _, n in ipairs(img_names) do
		local okl, lib = pcall(ffi.load, n)

		if okl then
			M.lib, M.available, M.backend = lib, true, "sdl2_image"
			-- 0 = IMG_INIT_PNG|IMG_INIT_JPG，失败也无所谓，IMG_Load 会自己再试
			pcall(function() lib.IMG_Init(0x00000002 + 0x00000001) end)
			break
		end
	end
end

-- ---------- 路径 2：libpng ----------
-- simplified API 的结构体是 ABI 稳定的（opaque + 若干 u32 + 64 字节 message），
-- 所以不用碰 setjmp 那套 goto 回调，代码量差了十倍。

local png = nil

if not M.available then
	-- PNG 文件魔数：89 50 4E 47 0D 0A 1A 0A
	local function is_png(path)
		local f = io.open(path, "rb")

		if not f then return false end
		local magic = f:read(8)

		f:close()
		return magic == "\137PNG\r\n\26\n"
	end
	M.is_png = is_png
	local ok_png = pcall(function()
		ffi.cdef [[
		typedef struct png_image {
			void *opaque;
			uint32_t version;
			uint32_t width, height;
			uint32_t format, flags, colormap_entries;
			uint32_t warning_or_error;
			char message[64];
		} png_image;

		int png_image_begin_read_from_file(png_image *image, const char *file_name);
		int png_image_finish_read(png_image *image, const void *background,
			void *buffer, int row_stride, void *colormap);
		void png_image_free(png_image *image);
		]]
	end)

	if ok_png then
		for _, n in ipairs({ "png16", "libpng16.so.16", "png" }) do
			local okl, lib = pcall(ffi.load, n)

			if okl then
				png = lib
				M.available, M.backend = true, "libpng"
				break
			end
		end
	end
end

local PNG_IMAGE_VERSION = 1
local PNG_FORMAT_RGBA = 0x03

-- libpng 解一张 PNG → 返回 (w, h, RGBA 缓冲) 或 nil
local function decode_png(path)
	if not png then return nil end
	local im = ffi.new("png_image")

	im.version = PNG_IMAGE_VERSION
	im.format = PNG_FORMAT_RGBA
	if png.png_image_begin_read_from_file(im, path) == 0 then return nil end

	local w, h = tonumber(im.width), tonumber(im.height)

	if w <= 0 or h <= 0 then
		png.png_image_free(im)
		return nil
	end
	local buf = ffi.new("uint8_t[?]", w * h * 4)

	if png.png_image_finish_read(im, nil, buf, w * 4, nil) == 0 then
		png.png_image_free(im)
		return nil
	end
	png.png_image_free(im)
	return w, h, buf
end

-- ---------- 对外 ----------

-- 解码成 SDL_Surface（只有 SDL2_image 路径有 surface；libpng 直出纹理）
function M.load(path)
	if not (M.lib and M.lib.IMG_Load) then return nil end
	return M.lib.IMG_Load(path)
end

-- ---------- 路径 2b：libturbojpeg（JPEG） ----------
-- tjDecompress2 一把梭，比 libjpeg 的 error_exit/setjmp 那套干净得多。

local tj = nil

-- 注意：这里是独立于 libpng 的，PNG 能解不代表 JPEG 也能解（反之亦然），
-- 所以不能拿 M.available 当开关。
if not M.lib then
	local ok_tj = pcall(function()
		ffi.cdef [[
		typedef void *tjhandle;
		tjhandle tjInitDecompress(void);
		int tjDestroy(tjhandle handle);
		int tjDecompressHeader3(tjhandle handle, const unsigned char *jpegBuf,
			unsigned long jpegSize, int *width, int *height,
			int *jpegSubsamp, int *jpegColorspace);
		int tjDecompress2(tjhandle handle, const unsigned char *jpegBuf,
			unsigned long jpegSize, unsigned char *dstBuf, int width,
			int pitch, int height, int pixelFormat, int flags);
		]]
	end)

	if ok_tj then
		for _, n in ipairs({ "turbojpeg.so.0", "turbojpeg", "libturbojpeg.so.0" }) do
			local okl, lib = pcall(ffi.load, n)

			if okl then
				tj = lib
				M.available = true
				M.jpeg = true
				if M.backend == nil then M.backend = "turbojpeg" end
				break
			end
		end
	end
end

local TJPF_RGBA = 9

-- 文件头判断：JPEG 以 FF D8 FF 开头
local function is_jpeg(path)
	local f = io.open(path, "rb")

	if not f then return false end
	local magic = f:read(3)

	f:close()
	return magic == "\255\216\255"
end

M.is_jpeg = is_jpeg

-- GIF 文件头 "GIF87a"/"GIF89a"
local function is_gif(path)
	local f = io.open(path, "rb")

	if not f then return false end
	local magic = f:read(6)

	f:close()
	return magic == "GIF87a" or magic == "GIF89a"
end

M.is_gif = is_gif

-- libturbojpeg 解一张 JPEG → 返回 (w, h, RGBA 缓冲) 或 nil
local function decode_jpeg(path)
	if not tj then return nil end

	local f = io.open(path, "rb")

	if not f then return nil end
	local data = f:read("*a")

	f:close()
	if not data or #data == 0 then return nil end

	local h = tj.tjInitDecompress()

	if h == nil then return nil end

	local src = ffi.cast("const unsigned char *", data)
	local w, ht = ffi.new("int[1]"), ffi.new("int[1]")
	local ss, cs = ffi.new("int[1]"), ffi.new("int[1]")

	if tj.tjDecompressHeader3(h, src, #data, w, ht, ss, cs) ~= 0 then
		tj.tjDestroy(h)
		return nil
	end

	local dw, dh = tonumber(w[0]), tonumber(ht[0])

	if dw <= 0 or dh <= 0 then
		tj.tjDestroy(h)
		return nil
	end

	local buf = ffi.new("uint8_t[?]", dw * dh * 4)
	local rc = tj.tjDecompress2(h, src, #data, buf, dw, dw * 4, dh, TJPF_RGBA, 0)

	tj.tjDestroy(h)
	if rc ~= 0 then return nil end
	return dw, dh, buf
end

M.decode_jpeg = decode_jpeg

local cache = {}

-- 直接出纹理；失败返回 nil
function M.texture(ren, path)
	if not M.available then return nil end
	if not path or path == "" then return nil end

	if M.lib then
		local surf = M.load(path)

		if surf == nil then return nil end
		local tex = sdl.texture_from_surface(ren, surf)

		sdl.free_surface(surf)
		return tex
	end

	-- 自己解：先看魔数再挑解码器（不认识的格式直接 nil，上层退回徽章）
	local w, h, buf

	if is_jpeg(path) then
		w, h, buf = decode_jpeg(path)
	else
		w, h, buf = decode_png(path)
		-- PNG 解不动就看是不是 GIF（系统一般没 giflib，走纯 Lua 首帧解码）
		if not w and is_gif(path) then
			local ok, gw, gh, gbuf = pcall(gif.decode, path)

			if ok and gw then w, h, buf = gw, gh, gbuf end
		end
	end

	if not w then return nil end
	local tex = sdl.create_texture(ren, w, h)

	if tex == nil then return nil end
	sdl.update_texture(tex, buf, w * 4)
	sdl.set_blend(tex)
	return tex
end

M.decode_png = decode_png
M.cache = cache

return M
