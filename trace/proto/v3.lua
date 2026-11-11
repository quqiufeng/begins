local ffi = require "ffi"
local bit = require "bit"
ffi.cdef[[ typedef long ssize_t; int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...); ssize_t read(int fd, void *buf, size_t n);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset); ]]
local function rf(p) local f=io.open(p) if not f then return nil end local s=f:read("*a") f:close() return s end
local EV = "/sys/kernel/tracing/events/syscalls/sys_enter_openat"
local id = tonumber(rf(EV.."/id"):match("%d+"))
local function parse_format(path)
  local txt = rf(path.."/format"); local f = {}
  for line in txt:gmatch("[^\n]+") do
    local decl = line:match("^%s*field:(.-);")
    if decl then
      local name = decl:match("([%w_%.]+)%s*$")
      f[#f+1] = { name=name, off=tonumber(line:match("offset:(%d+)")),
                  size=tonumber(line:match("size:(%d+)")), isptr = decl:find("%*")~=nil }
    end
  end
  return f
end
local fields = parse_format(EV)
local attr = ffi.new("uint8_t[?]",136)
ffi.cast("uint32_t*",attr)[0]=2
ffi.cast("uint32_t*",attr+4)[0]=128
ffi.cast("uint64_t*",attr+8)[0]=id
ffi.cast("uint64_t*",attr+16)[0]=1
ffi.cast("uint64_t*",attr+24)[0]=2+4+1024     -- TID|TIME|RAW  (1<<1,1<<2,1<<10)
ffi.cast("uint64_t*",attr+40)[0]=1
ffi.cast("uint32_t*",attr+48)[0]=1
local fd = tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",1), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
local bp = ffi.cast("uint8_t*", ffi.C.mmap(nil, 4096*9, 3, 1, fd, 0))
ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
os.execute("taskset -c 1 sh -c 'for i in $(seq 40); do cat /etc/hostname >/dev/null; done'")
ffi.C.ioctl(fd, 0x2401, ffi.cast("long",0))
local h = tonumber(ffi.cast("uint64_t*", bp+1024)[0])
local d = bp + 4096
local s = {} for j=0,15 do s[#s+1]=string.format("%02x", d[j]) end
print("head="..h.."  first16: "..table.concat(s," "))
local tail, n = 0, 0
while tail < h do
  local off = tail % 32768
  local ty = ffi.cast("uint32_t*", d+off)[0]
  local sz = ffi.cast("uint16_t*", d+off+6)[0]
  if sz == 0 then print(("[stop] off=%d type=%d size=0"):format(off, ty)); break end
  if ty == 9 then
    n = n + 1
    local p = off + 8
    local pid = ffi.cast("uint32_t*", d+p)[0]
    local tid = ffi.cast("uint32_t*", d+p+4)[0]
    local rl  = ffi.cast("uint32_t*", d+p+16)[0]
    local raw = d + p + 20
    if n <= 3 then
      local parts = {}
      for _, f in ipairs(fields) do
        local v
        if f.size==8 then v=string.format("0x%x", tonumber(ffi.cast("uint64_t*",raw+f.off)[0]))
        elseif f.size==4 then v=tostring(tonumber(ffi.cast("uint32_t*",raw+f.off)[0]))
        else v=tostring(raw[f.off]) end
        parts[#parts+1]=f.name.."="..v
      end
      print(("[REC] pid=%d tid=%d rawsize=%d recsize=%d"):format(pid,tid,rl,sz))
      print("      "..table.concat(parts," "))
    end
  end
  tail = tail + sz
end
print(("[total] samples=%d consumed=%d head=%d"):format(n, tail, h))
