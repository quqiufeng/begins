local ffi = require "ffi"
ffi.cdef[[
typedef long ssize_t;
int open(const char *pathname, int flags, ...);
int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int munmap(void *addr, size_t length);
]]
local bit = require "bit"
local PROT_READ, PROT_WRITE = 1, 2
local MAP_SHARED = 1
local PERF_TYPE_TRACEPOINT = 2
local PERF_SAMPLE_TID   = bit.lshift(1, 0)
local PERF_SAMPLE_TIME  = bit.lshift(1, 2)
local PERF_SAMPLE_RAW   = bit.lshift(1, 10)
local IOC_ENABLE, IOC_DISABLE, IOC_RESET = 0x2400, 0x2401, 0x2403
local SYS_perf_event_open = 298
local SYS_process_vm_readv = 310

local function read_file(p)
  local f = io.open(p); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local EV = "/sys/kernel/tracing/events/syscalls/sys_enter_openat"
local function parse_format(path)
  local txt = read_file(path .. "/format")
  local fields = {}
  for line in txt:gmatch("[^\n]+") do
    local decl = line:match("^%s*field:(.-);")
    local name = decl and decl:match("([%w_%.]+)%s*$")
    local ty = (decl and name) and decl:sub(1, #decl - #name):gsub("%s+$", "")
    if name then
      fields[#fields+1] = { name = name,
        off = tonumber(line:match("offset:(%d+)")),
        size = tonumber(line:match("size:(%d+)")),
        signed = (ty or ""):find("signed") ~= nil }
    end
  end
  return fields
end
local fields = parse_format(EV)
local t = {}; for _,f in ipairs(fields) do t[#t+1] = f.name.."@"..f.off.."/"..f.size end
print("[format] "..table.concat(t, " "))

local id = tonumber((read_file(EV.."/id") or ""):match("%d+"))
print("[id]", id)

local ATTR_SIZE = 128
local attr = ffi.new("uint8_t[?]", 136)
local function u32(o,v) ffi.cast("uint32_t*", attr+o)[0]=v end
local function u64(o,v) ffi.cast("uint64_t*", attr+o)[0]=v end
u32(0, PERF_TYPE_TRACEPOINT)
u32(4, ATTR_SIZE)
u64(8, id)
u64(16, 1)
u64(24, PERF_SAMPLE_TID + PERF_SAMPLE_TIME + PERF_SAMPLE_RAW)
u64(40, 1)
u32(48, 1)

local fd = tonumber(ffi.C.syscall(ffi.cast("long",SYS_perf_event_open), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",0), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
if fd < 0 then print("[FAIL] perf_event_open errno="..ffi.errno()); os.exit(1) end
print("[ok] perf fd =", fd)

local PAGE, DATA_PAGES = 4096, 8
local base = ffi.C.mmap(nil, PAGE*(1+DATA_PAGES), PROT_READ+PROT_WRITE, MAP_SHARED, fd, 0)
local base_p = ffi.cast("uint8_t*", base)
local function head() return tonumber(ffi.cast("uint64_t*", base_p+1024)[0]) end
local data_off  = tonumber(ffi.cast("uint64_t*", base_p+1040)[0])
local data_size = tonumber(ffi.cast("uint64_t*", base_p+1048)[0])
print(("[mmap] off=%d size=%d"):format(data_off, data_size))

ffi.C.ioctl(fd, IOC_RESET, 0)
ffi.C.ioctl(fd, IOC_ENABLE, 1)
os.execute("ls /etc >/dev/null; cat /etc/hostname >/dev/null")
ffi.C.ioctl(fd, IOC_DISABLE, 0)

local iov_t = ffi.typeof("struct { void *base; size_t len; }[1]")
local function read_str(pid, addr, max)
  if addr == 0 then return nil end
  local buf = ffi.new("char[?]", max)
  local liov, riov = iov_t(), iov_t()
  liov[0].base, liov[0].len = buf, max
  riov[0].base, riov[0].len = ffi.cast("void*", addr), max
  local n = tonumber(ffi.C.syscall(ffi.cast("long",SYS_process_vm_readv), ffi.cast("int",pid), liov, ffi.cast("unsigned long",1), riov, ffi.cast("unsigned long",1), ffi.cast("unsigned long",0)))
  if n <= 0 then return "<errno "..(-n)..">" end
  return (ffi.string(buf, n):gsub("%z.*$",""))
end

local data = ffi.cast("uint8_t*", base_p + data_off)
local h = head()
local tail, nsamp, shown = 0, 0, 0
while tail < h do
  local off = tail % data_size
  local hdr = ffi.cast("uint32_t*", data+off)[0]
  local rtype = bit.band(hdr, 0xff)
  local rsize = bit.rshift(hdr, 16)
  if rsize == 0 then break end
  if rtype == 9 then
    nsamp = nsamp + 1
    local p = off + 4
    local pid = ffi.cast("uint32_t*", data+p)[0]
    local tid = ffi.cast("uint32_t*", data+p+4)[0]
    local tm  = tonumber(ffi.cast("uint64_t*", data+p+8)[0])
    local rl  = ffi.cast("uint32_t*", data+p+16)[0]
    local raw = data + p + 20
    if shown < 6 then
      shown = shown + 1
      local parts = {}
      for _, f in ipairs(fields) do
        local v
        if f.size == 8 then v = tonumber(ffi.cast("uint64_t*", raw+f.off)[0])
        elseif f.size == 4 then v = tonumber(ffi.cast("uint32_t*", raw+f.off)[0])
        elseif f.size == 2 then v = ffi.cast("uint16_t*", raw+f.off)[0]
        else v = raw[f.off] end
        parts[#parts+1] = f.name.."="..tostring(v)
        if f.name == "filename" and f.size == 8 then
          parts[#parts+1] = 'STR="'..tostring(read_str(pid, v, 256))..'"'
        end
      end
      print(("[sample] pid=%d tid=%d t=%d rawlen=%d | %s"):format(pid, tid, tm, rl, table.concat(parts," ")))
    end
  end
  tail = tail + rsize
end
print(("[done] samples=%d"):format(nsamp))
ffi.C.close(fd)
