#!/usr/bin/env luajit
-- tools/gen-music-playlist.lua — 扫 WebDAV 曲库目录，吐一份 m3u 歌单（stdout）
--
-- 为什么是 LuaJIT 而不是 python：桌面本体就是 LuaJIT，NAS 那一层已经有
-- core/dav.lua 用 libcurl FFI 直接打 PROPFIND（零 fork、零依赖、零二次实现）。
-- 这里只做「逐层递进 + 过滤音频后缀 + 拼 URL」，全部复用 dav.list，不再写一份
-- HTTP 客户端。盒子上没装 python3 也能跑。
--
-- 用法（/root/music.sh 起 mpv 之前跑）：
--   luajit /root/gen-music-playlist.lua 'dav://192.168.1.53:5005/sata11-.../mp3/无损' > /root/music.m3u
--
-- 参数：dav:/<path> | dav://host:port/path | http(s)://host:port/path | /path
--       全认；省略 = 取 env 的 WEBDAV_MUSIC。
-- 凭据：env WEBDAV_URL/USER/PASS 优先，缺了从 .env 补（和 play.sh 同一套）。
-- 歌单里只放不带凭据的 URL：认证由 mpv 的 --http-header-fields 带。
-- 退出码：0=有歌；2=目录读不到/没配置；3=一首音频都没有。

local ffi = require("ffi")

-- 盒子无 DISPLAY、脚本可能被 cron/systemd 拉起：按落点顺序找 core/dav.lua
local HERE = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
local function addpath(p) package.path = p .. "/?.lua;" .. package.path end

addpath(HERE)
addpath("/opt/desktop")
addpath("/root")

local dav = require("core.dav")

local AUDIO = {}
for ext in ([[
mp3 flac wav ape wma m4a aac ogg opus dsf dff aif aiff alac mpc wv tta
]]):gmatch("%S+") do
	AUDIO[ext] = true
end

local MAX_DIRS = 4000

-- ---------------- env ----------------

-- 极简 .env：KEY=VALUE，去引号，不执行任何东西；env 里已有的优先
local ENV = {}
local function env(k) return os.getenv(k) or ENV[k] end

local function load_env(path)
	local f = io.open(path, "r")

	if not f then return end
	for line in f:lines() do
		local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")

		if k and ENV[k] == nil then
			v = v:gsub("^(['\"])(.*)%1$", "%2")
			ENV[k] = v
		end
	end
	f:close()
end

do
	load_env("/root/.env")
	load_env(HERE .. "/.env")
	load_env("/opt/desktop/.env")
	if os.getenv("LITE_ENV_FILE") then load_env(os.getenv("LITE_ENV_FILE")) end
end

-- ---------------- 参数 → nas 配置 ----------------

local function split(spec)
	spec = (spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if spec:sub(1, 5) == "dav:/" then
		if spec:sub(1, 6) == "dav://" then
			local host, path = spec:match("^dav://([^/]+)(/.*)$")

			if host then
				return "http://" .. host, path or "/"
			end
			return nil, nil
		end
		return nil, spec:sub(5) -- 'dav:/a/b' → '/a/b'
	end
	if spec:match("^https?://") then
		local origin, path = spec:match("^(https?://[^/]+)(/.*)$")

		if origin then return origin, path end
		return spec:gsub("/+$", ""), "/"
	end
	if spec ~= "" then
		if spec:sub(1, 1) ~= "/" then spec = "/" .. spec end
		return nil, spec
	end
	local music = env("WEBDAV_MUSIC") or ""

	if music ~= "" then
		if music:sub(1, 1) ~= "/" then music = "/" .. music end
		return nil, music
	end
	return nil, nil
end

local origin, start = split(arg and arg[1] or "")
local base = origin or (env("WEBDAV_URL") or ""):gsub("/+$", "")

if base == "" then
	io.stderr:write("gen-music-playlist: 没有 WEBDAV_URL，也没给完整 dav:// 地址\n")
	os.exit(2)
end
if not start then
	io.stderr:write("gen-music-playlist: 没给目录（也没 WEBDAV_MUSIC）\n")
	os.exit(2)
end

local nas = {
	url = base,
	user = env("WEBDAV_USER") or "",
	pass = env("WEBDAV_PASS") or "",
	cache = env("LITE_MUSIC_CACHE") or "/tmp/lite-music-cache/",
}
local cfg = { nas = nas }

if not dav.available then
	io.stderr:write("gen-music-playlist: 加载不到 libcurl.so.4\n")
	os.exit(2)
end

-- ---------------- 递归扫 ----------------

-- dav.list 的 path 形如 'dav:/sata11-x/mp3/无损'
local function vpath(p) return "dav:" .. p end

local function is_audio(name)
	local ext = tostring(name or ""):match("%.([%w]+)$")

	return ext ~= nil and AUDIO[ext:lower()] == true
end

start = start:gsub("/+$", "")
if start == "" then start = "/" end

local queue, seen, urls = { start }, { [start] = true }, {}
local dirs, errs = 0, 0

while #queue > 0 and dirs < MAX_DIRS do
	local cur = table.remove(queue, 1)

	dirs = dirs + 1
	local list, err = dav.list(cfg, vpath(cur))

	if not list then
		errs = errs + 1
		io.stderr:write(("gen-music-playlist: %s → %s\n"):format(cur, tostring(err)))
	else
		for _, e in ipairs(list) do
			local child = cur .. "/" .. e.name

			if e.dir then
				if not seen[child] then
					seen[child] = true
					queue[#queue + 1] = child
				end
			elseif is_audio(e.name) then
				urls[#urls + 1] = base .. dav.enc(child)
			end
		end
	end
end

table.sort(urls)
local out = { "#EXTM3U\n" }

for _, u in ipairs(urls) do
	out[#out + 1] = u
	out[#out + 1] = "\n"
end
io.write(table.concat(out))

io.stderr:write(("gen-music-playlist: %s 目录 %d 个（失败 %d），音频 %d 首\n")
	:format(start, dirs, errs, #urls))
os.exit(#urls > 0 and 0 or 3)
