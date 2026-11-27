-- core/dav.lua — NAS（WebDAV）文件系统后端
--
-- 桌面的「NAS」不是挂载点：盒子上没 davfs2/rclone，也没 root 去 mount，
-- 所以这里直接用 libcurl FFI 打 WebDAV 的 PROPFIND / GET，零 fork、零依赖。
--
-- 虚拟路径约定（和本地路径长得像，上层 fs/grid 不用改）：
--   dav:/<远端绝对路径>         例：dav:/sata11-18072858035/av
--   dav:/                       NAS 根（= cfg.nas.base 的上一级，通常不可读）
--
-- 凭据来自 env（WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS，或 DESKTOP_NAS_*），
-- 缺了就从 ~/.env 读 —— 和 play.sh / music 工具同一套。
--
-- 打开方式：
--   视频/音频 → 交给 play.sh，参数是 dav://host:port/<path>，认证它自己从 .env 补
--   电子书/图片 → 先下到缓存（cfg.nas.cache），再按本地文件开

local ffi = require("ffi")

local M = {}

-- ---------------- libcurl ----------------

local curl
do
	local ok, lib = pcall(ffi.load, "libcurl.so.4")

	if not ok then ok, lib = pcall(ffi.load, "libcurl.so") end
	if not ok then ok, lib = pcall(ffi.load, "curl") end

	if ok then
		pcall(ffi.cdef, [[
		typedef void CURL;
		typedef int CURLcode;
		typedef int CURLoption;
		typedef struct dav_slist { char *data; struct dav_slist *next; } dav_slist;
		dav_slist *curl_slist_append(dav_slist *list, const char *s);
		void curl_slist_free_all(dav_slist *list);
		CURL *curl_easy_init(void);
		void curl_easy_cleanup(CURL *handle);
		CURLcode curl_easy_setopt(CURL *handle, CURLoption option, ...);
		CURLcode curl_easy_perform(CURL *handle);
		const char *curl_easy_strerror(CURLcode code);
		int curl_easy_getinfo(CURL *handle, int info, ...);
		void curl_global_init(long flags);
		void curl_global_cleanup(void);
		int mkdir(const char *path, unsigned int mode);
		]])
		curl = lib
		pcall(curl.curl_global_init, 3) -- CURL_GLOBAL_ALL
	end
end

M.available = curl ~= nil

local OPT = {
	URL = 10002,
	WRITEDATA = 10001,
	WRITEFUNCTION = 20011,
	USERPWD = 10005,
	HTTPHEADER = 10023,
	CUSTOMREQUEST = 10036,
	POSTFIELDS = 10015,
	POSTFIELDSIZE = 60,
	FOLLOWLOCATION = 52,
	NOSIGNAL = 99,
	CONNECTTIMEOUT = 78,
	TIMEOUT = 13,
	USERAGENT = 10018,
	HTTPAUTH = 107,
	ACCEPT_ENCODING = 10102,
	NOBODY = 44,
	UPLOAD = 46,
	RESPONSE_CODE = 2097154, -- CURLINFO_RESPONSE_CODE
}

local CURLAUTH_BASIC = 1

-- ---------------- 小工具 ----------------

local function enc(s)
	-- 逐字节百分号编码：保留 unreserved + '/' + '%'，其余 %XX。
	-- '%' 保留是故意的：NAS 的 href 本来就已经编码过，再编一遍就 404。
	return (tostring(s):gsub("[^%w%._~%%/%-]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

local function unenc(s)
	return (tostring(s):gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end):gsub("&amp;", "&"))
end

M.enc, M.unenc = enc, unenc

-- RFC1123（Sun, 15 Nov 2026 10:00:14 GMT）→ epoch
local MON = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
	Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

local function days_from_civil(y, m, d)
	if m <= 2 then y = y - 1 end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function rfc1123_epoch(s)
	if not s then return 0 end
	local d, mon, y, h, mi, sec =
		tostring(s):match("(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)")

	if not d then return 0 end
	local m = MON[mon]

	if not m then return 0 end
	return days_from_civil(tonumber(y), m, tonumber(d)) * 86400
		+ tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
end

M.rfc1123_epoch = rfc1123_epoch

-- ---------------- 配置 ----------------

-- 从 cfg.nas 取；缺字段就当没配 NAS
function M.conf(cfg)
	local n = cfg and cfg.nas

	if not n or not n.url or n.url == "" then return nil end
	return n
end

function M.enabled(cfg) return M.available and M.conf(cfg) ~= nil end

-- "http://192.168.1.53:5005" → "192.168.1.53:5005"
function M.hostport(n)
	local hp = tostring(n.url):gsub("^https?://", "")

	return (hp:gsub("/+$", ""))
end

-- 虚拟路径 → 远端绝对路径："dav:/a/b" → "/a/b"
function M.remote(path)
	return (tostring(path):gsub("^dav:", ""))
end

function M.is_dav(path)
	return type(path) == "string" and path:sub(1, 4) == "dav:"
end

-- 供 play.sh 用的 dav:// 地址（认证由它从 .env 补；别在这里塞用户名密码）
function M.play_arg(n, path)
	return "dav://" .. M.hostport(n) .. enc(M.remote(path))
end

-- 给 mpv / vlc 这类**外部播放器**的 http 地址（带 userinfo 认证）。
-- 别把 play_arg 的 dav:// 递给它们：那是 play.sh 的私有协议（它自己从 .env
-- 补认证），mpv 不认识 dav://，秒退（桌面日志里就是「音乐 exit 1s」）。
local function enc_cred(s)
	-- userinfo 比路径严：'%' 也得编，':' '/' '@' 必须编
	return (tostring(s):gsub("[^%w%._~%-]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

function M.stream_url(n, remote)
	local host = M.hostport(n)
	local auth = ""

	if n.user and n.user ~= "" then
		auth = enc_cred(n.user) .. ":" .. enc_cred(n.pass or "") .. "@"
	end
	return ("%s://%s%s%s"):format((tostring(n.url):match("^https") or "http"), auth,
		host, enc(remote))
end

-- 供 curl 直接用的带认证 URL
function M.http_url(n, remote)
	return ("%s%s"):format((tostring(n.url):gsub("/+$", "")), enc(remote))
end

-- ---------------- 请求 ----------------

local function perform(url, opts, write_fn, write_data)
	if not curl then return nil, "没有 libcurl" end
	local h = curl.curl_easy_init()

	if h == nil then return nil, "curl_easy_init 失败" end
	local function set(o, v)
		curl.curl_easy_setopt(h, o, v)
	end

	set(OPT.URL, ffi.cast("const char *", url))
	set(OPT.NOSIGNAL, ffi.cast("long", 1))
	set(OPT.FOLLOWLOCATION, ffi.cast("long", 1))
	set(OPT.CONNECTTIMEOUT, ffi.cast("long", 5))
	set(OPT.TIMEOUT, ffi.cast("long", (opts and opts.timeout) or 20))
	set(OPT.USERAGENT, ffi.cast("const char *", "desktop/1.0"))
	if opts and opts.user then
		set(OPT.USERPWD, ffi.cast("const char *",
			("%s:%s"):format(opts.user, opts.pass or "")))
		set(OPT.HTTPAUTH, ffi.cast("long", CURLAUTH_BASIC))
	end
	if write_fn then
		set(OPT.WRITEFUNCTION, write_fn)
		set(OPT.WRITEDATA, write_data)
	end
	if opts and opts.method then
		set(OPT.CUSTOMREQUEST, ffi.cast("const char *", opts.method))
	end
	if opts and opts.body then
		set(OPT.POSTFIELDS, ffi.cast("const char *", opts.body))
		set(OPT.POSTFIELDSIZE, ffi.cast("long", #opts.body))
	end
	if opts and opts.nobody then set(OPT.NOBODY, ffi.cast("long", 1)) end
	-- WebDAV 的 PROPFIND 必须带 Depth（极空间没这个头直接 403 propfind-finite-depth）
	local slist
	if opts and opts.headers then
		for _, line in ipairs(opts.headers) do
			slist = curl.curl_slist_append(slist, line)
		end
		set(OPT.HTTPHEADER, slist)
	end

	local rc = curl.curl_easy_perform(h)
	local code = ffi.new("int[1]", 0)

	curl.curl_easy_getinfo(h, OPT.RESPONSE_CODE, code)
	local http = code[0]

	curl.curl_easy_cleanup(h)
	if slist then curl.curl_slist_free_all(slist) end
	if rc ~= 0 then
		return nil, ("curl: %s"):format(ffi.string(curl.curl_easy_strerror(rc)))
	end
	return http
end

local PROPFIND_BODY = [[<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:displayname/>
</d:prop></d:propfind>]]

-- 一次 PROPFIND，返回响应 XML 文本
local function propfind(n, remote, depth)
	local buf = {}
	local wf = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
		function(ptr, size, nmemb)
			local len = tonumber(size) * tonumber(nmemb)

			buf[#buf + 1] = ffi.string(ptr, len)
			return len
		end)
	local url = M.http_url(n, remote)
	local http, err = perform(url, {
		user = n.user, pass = n.pass,
		method = "PROPFIND",
		body = PROPFIND_BODY,
		headers = { "Depth: " .. tostring(depth or 1),
			"Content-Type: application/xml; charset=utf-8" },
		timeout = 15,
	}, wf, nil)

	if not http then return nil, err end
	if http ~= 207 and http ~= 200 then
		return nil, ("HTTP %d %s"):format(http, url)
	end
	return table.concat(buf)
end

-- 解析 multistatus → { {name=, href=, dir=, size=, mtime=} }
local function parse_propfind(xml)
	local out = {}

	for block in xml:gmatch("<[%w]-:?[Rr]esponse[^>]*>(.-)</[%w]-:?[Rr]esponse>") do
		local href = block:match("<[%w]-:?[Hh]ref[^>]*>(.-)</")
		local e = { href = href and unenc(href) or "" }

		e.dir = block:match("<[%w]-:?[Cc]ollection") ~= nil
		local len = block:match("<[%w]-:?[Gg]etcontentlength[^>]*>(%d+)")

		e.size = tonumber(len) or 0
		e.mtime = rfc1123_epoch(block:match(
			"<[%w]-:?[Gg]etlastmodified[^>]*>(.-)</"))
		local last = e.href:gsub("/+$", "")

		e.name = last:match("([^/]+)$") or ""
		out[#out + 1] = e
	end
	return out
end

-- ---------------- 对外：列目录 ----------------

-- 返回和 fs.lua 的 list_raw 同形状：{ name=, dir=, size=, mtime= }
function M.list(cfg, vpath)
	local n = M.conf(cfg)

	if not n then return nil, "没配 NAS" end
	if not M.available then return nil, "没有 libcurl" end
	local remote = M.remote(vpath)

	if remote == "" then remote = "/" end
	if remote:sub(1, 1) ~= "/" then remote = "/" .. remote end

	local xml, err = propfind(n, remote, 1)

	if not xml then return nil, err end
	local self_href = unenc(remote):gsub("/+$", "")
	local out = {}

	for _, e in ipairs(parse_propfind(xml)) do
		local href = e.href:gsub("/+$", "")

		-- 第一条通常是目录自己，跳过；名字为空也跳过
		if e.name ~= "" and href ~= self_href then
			out[#out + 1] = { name = e.name, dir = e.dir, size = e.size,
				mtime = e.mtime }
		end
	end
	return out
end

function M.stat(cfg, vpath)
	local n = M.conf(cfg)

	if not n then return nil, "没配 NAS" end
	local xml, err = propfind(n, M.remote(vpath), 0)

	if not xml then return nil, err end
	local e = parse_propfind(xml)[1]

	if not e then return nil, "空响应" end
	return { dir = e.dir, size = e.size, mtime = e.mtime }
end

-- ---------------- 对外：下载到本地缓存 ----------------

-- mkdir -p：FFI 直接建，不走 shell（路径里有空格/中文/引号，拼命令太脆）
local function mkdir_p(d)
	if not d or d == "" then return true end
	local built = ""

	for part in tostring(d):gmatch("[^/]+") do
		built = built .. "/" .. part
		if ffi.C.mkdir(built, 493) ~= 0 then -- 0755
			local f = io.open(built .. "/.", "rb")

			if f then f:close() else return false end
		end
	end
	return true
end

local function mkdir_parent(p)
	local d = p:match("^(.*)/[^/]+$")

	if d and d ~= "" then return mkdir_p(d) end
	return true
end

-- 下载 remote 到 dest；已存在且大小一致就直接复用（缓存）
function M.download(cfg, vpath, dest)
	local n = M.conf(cfg)

	if not n then return nil, "没配 NAS" end
	if not M.available then return nil, "没有 libcurl" end
	dest = dest or (n.cache .. M.remote(vpath))

	local st = M.stat(cfg, vpath)

	if st and not st.dir then
		local f = io.open(dest, "rb")
		local have = f and f:seek("end") or 0

		if f then f:close() end
		if have == st.size and have > 0 then return dest end
	end
	if not mkdir_parent(dest) then return nil, "建不了缓存目录 " .. dest end
	local out = io.open(dest, "wb")

	if not out then return nil, "写不了 " .. dest end
	local wf = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
		function(ptr, size, nmemb)
			local len = tonumber(size) * tonumber(nmemb)
			local ok = out:write(ffi.string(ptr, len))

			if not ok then return 0 end
			return len
		end)
	local http, err = perform(M.http_url(n, M.remote(vpath)), {
		user = n.user, pass = n.pass, timeout = 3600,
	}, wf, nil)

	out:close()
	if not http then
		os.remove(dest)
		return nil, err
	end
	if http ~= 200 and http ~= 206 then
		os.remove(dest)
		return nil, ("HTTP %d"):format(http)
	end
	return dest
end

function M.cache_path(cfg, vpath)
	local n = M.conf(cfg)

	return (n.cache or "/tmp/desktop-cache") .. M.remote(vpath)
end

return M
