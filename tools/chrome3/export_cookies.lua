#!/usr/bin/env luajit
-- export_cookies.lua —— 把本机 Chrome/Chromium cookie 解密导出成 Lua 表字面量
--
-- 纯 LuaJIT FFI + 一个 C 补充件（cookiecrypt.c）：
--   SQLite 读表 / host 过滤 / Lua 表输出 → 本文件（ffi 直调 libsqlite3）
--   GNOME Keyring 取密码 + PBKDF2 + AES-128-CBC → libcookiecrypt.so（libsecret 无头文件，
--   遍历服务要 GObject/GList，FFI 写不划算）
--
-- 用法：
--   luajit export_cookies.lua [profile_dir] [out.lua] [hosts]
--   hosts 是逗号分隔的子串，默认 youtube,.google
--
-- 本机专用：只读本机 keyring + profile，明文只写到 out.lua（不落仓库）。

local ffi = require("ffi")

local HERE = (arg[0] or ""):match("^(.*)/") or "."
local SO   = HERE .. "/libcookiecrypt.so"
local SRC  = HERE .. "/cookiecrypt.c"

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int  sqlite3_open(const char *filename, sqlite3 **ppDb);
int  sqlite3_prepare_v2(sqlite3 *db, const char *sql, int n, sqlite3_stmt **st, const char **tail);
int  sqlite3_step(sqlite3_stmt *st);
const void *sqlite3_column_blob(sqlite3_stmt *st, int i);
const unsigned char *sqlite3_column_text(sqlite3_stmt *st, int i);
long long sqlite3_column_int64(sqlite3_stmt *st, int i);
int  sqlite3_column_bytes(sqlite3_stmt *st, int i);
int  sqlite3_column_type(sqlite3_stmt *st, int i);
int  sqlite3_finalize(sqlite3_stmt *st);
int  sqlite3_close(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);

char *cc_password_nth(const char *labels, int idx);
char *cc_unseal(const char *password, const void *blob, int bloblen, const char *host);
void  cc_free(void *p);
]]

-- ---------- 自动编译补充件 ----------
local function file_mtime(p)
  local f = io.open(p, "rb")
  if not f then return 0 end
  f:close()
  local h = io.popen("stat -c %Y '" .. p .. "' 2>/dev/null")
  local s = h:read("*a"); h:close()
  return tonumber(s) or 0
end

if file_mtime(SO) <= file_mtime(SRC) then
  io.stderr:write("[build] 编译 libcookiecrypt.so ...\n")
  local cmd = string.format(
    "cd '%s' && cc -O2 -shared -fPIC -o libcookiecrypt.so cookiecrypt.c " ..
    "/lib/x86_64-linux-gnu/libsecret-1.so.0 -lgobject-2.0 -lglib-2.0 -lcrypto", HERE)
  local ok = os.execute(cmd)
  if ok ~= 0 and ok ~= true then error("编译失败，见上面的 cc 输出") end
end

local cc      = ffi.load(SO)
local sqlite3 = ffi.load("sqlite3")

-- ---------- 读表 ----------
local SAMESITE = { [-1] = "Unspecified", [0] = "None", [1] = "Lax", [2] = "Strict" }

local function col_text(st, i)
  if sqlite3.sqlite3_column_type(st, i) == 5 then return nil end -- SQLITE_NULL
  local p = sqlite3.sqlite3_column_text(st, i)
  if p == nil then return nil end
  local n = sqlite3.sqlite3_column_bytes(st, i)
  return ffi.string(p, n)
end

local function read_rows(dbfile)
  local pp = ffi.new("sqlite3*[1]")
  if sqlite3.sqlite3_open(dbfile, pp) ~= 0 then
    error("打不开 " .. dbfile .. ": " .. ffi.string(sqlite3.sqlite3_errmsg(pp[0] or nil)))
  end
  local db = pp[0]
  local st  = ffi.new("sqlite3_stmt*[1]")
  local sql = "select host_key,name,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite from cookies"
  if sqlite3.sqlite3_prepare_v2(db, sql, -1, st, nil) ~= 0 then
    error("prepare 失败: " .. ffi.string(sqlite3.sqlite3_errmsg(db)))
  end
  local rows = {}
  local s = st[0]
  while sqlite3.sqlite3_step(s) == 100 do            -- SQLITE_ROW
    local enc_p  = sqlite3.sqlite3_column_blob(s, 2)
    local enc_n  = sqlite3.sqlite3_column_bytes(s, 2)
    rows[#rows + 1] = {
      host     = col_text(s, 0),
      name     = col_text(s, 1),
      blob     = (enc_p ~= nil and enc_n > 0) and ffi.string(enc_p, enc_n) or nil,
      path     = col_text(s, 3),
      expires  = tonumber(sqlite3.sqlite3_column_int64(s, 4)),
      secure   = sqlite3.sqlite3_column_int64(s, 5) ~= 0,
      httpOnly = sqlite3.sqlite3_column_int64(s, 6) ~= 0,
      samesite = tonumber(sqlite3.sqlite3_column_int64(s, 7)),
    }
  end
  sqlite3.sqlite3_finalize(s)
  sqlite3.sqlite3_close(db)
  return rows
end

-- ---------- 主流程 ----------
local profile = arg[1] or (os.getenv("HOME") .. "/.config/google-chrome/Default")
local out     = arg[2] or "/tmp/cookies.lua"
local hosts   = {}
for h in (arg[3] or "youtube,.google"):gmatch("[^,]+") do hosts[#hosts + 1] = h end

-- Chrome 运行中 SQLite 被锁，先快照
local snap = "/tmp/host-cookies.db"
local rc = os.execute(string.format("cp '%s/Cookies' '%s'", profile, snap))
if rc ~= 0 and rc ~= true then error("复制 Cookies 失败: " .. profile) end

-- keyring 里可能有多把同名 "Chrome Safe Storage"（换过 profile / 遗留旧条目），
-- 只有一把能解开当前库 → 全取出来，逐把试。
local LABELS = "Chrome Safe Storage,Chromium Safe Storage"
local keys = {}
for i = 0, 15 do
  local p = cc.cc_password_nth(LABELS, i)
  if p == nil then break end
  keys[#keys + 1] = ffi.string(p)
  cc.cc_free(p)
end
if #keys == 0 then error("keyring 里没找到 Safe Storage（解锁登录钥匙环后再试）") end
if #keys > 1 then io.stderr:write(("[info] keyring 里有 %d 把 Safe Storage，逐把试\n"):format(#keys)) end

-- 试出一把能解开"第一条可解 cookie"的 key，避免每条都全量重试
local function unseal(blob, host)
  for _, k in ipairs(keys) do
    local p = cc.cc_unseal(k, blob, #blob, host)
    if p ~= nil then return ffi.string(p) end
  end
  return nil
end

local rows = read_rows(snap)
local sel, bad = {}, 0
local hit
for _, r in ipairs(rows) do
  hit = false
  for _, h in ipairs(hosts) do
    if r.host and r.host:find(h, 1, true) then hit = true; break end
  end
  if hit and r.blob then
    local v = unseal(r.blob, r.host)
    if v == nil then
      bad = bad + 1
    else
      r.value = v
      sel[#sel + 1] = r
    end
  elseif hit then
    bad = bad + 1
  end
end

local f = assert(io.open(out, "w"))
f:write("return {\n")
for _, r in ipairs(sel) do
  f:write(string.format(
    "  {domain=%q,name=%q,value=%q,path=%q,expires=%d,secure=%s,httpOnly=%s,sameSite=%q},\n",
    r.host, r.name, r.value, r.path or "/",
    math.floor(r.expires / 1000000) - 11644473600,
    tostring(r.secure), tostring(r.httpOnly),
    SAMESITE[r.samesite] or "Unspecified"))
end
f:write("}\n")
f:close()

-- 快照里是密文，但仍是登录态材料，不留在 /tmp
os.remove(snap)

print(string.format("总 %d 行，选中 %d 条（%s），解失败 %d -> %s",
  #rows, #sel, table.concat(hosts, "/"), bad, out))
