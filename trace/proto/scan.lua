local ffi = require "ffi"
ffi.cdef[[ typedef long ssize_t; int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...); ssize_t read(int fd, void *buf, size_t n);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset); ]]
local function rf(p) local f=io.open(p) if not f then return nil end local s=f:read("*a") f:close() return s end
local id = tonumber(rf("/sys/kernel/tracing/events/syscalls/sys_enter_openat/id"):match("%d+"))
local attr = ffi.new("uint8_t[?]",136)
ffi.cast("uint32_t*",attr)[0]=2
ffi.cast("uint32_t*",attr+4)[0]=128
ffi.cast("uint64_t*",attr+8)[0]=id
ffi.cast("uint64_t*",attr+16)[0]=1
ffi.cast("uint64_t*",attr+24)[0]=1+4+1024
ffi.cast("uint64_t*",attr+40)[0]=1
ffi.cast("uint32_t*",attr+48)[0]=1
local fd = tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",1), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
local bp = ffi.cast("uint8_t*", ffi.C.mmap(nil, 4096*9, 3, 1, fd, 0))
ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
os.execute("taskset -c 1 sh -c 'for i in $(seq 40); do cat /etc/hostname >/dev/null; done'")
ffi.C.ioctl(fd, 0x2401, ffi.cast("long",0))
local h = tonumber(ffi.cast("uint64_t*", bp+1024)[0])
print("head", h)
local d = bp + 4096
local hdrs = {}
local i = 0
while i < h - 4 do
  local w = ffi.cast("uint32_t*", d+i)[0]
  local ty = bit.band(w,0xff)
  local sz = bit.rshift(w,16)
  if ty>=1 and ty<=20 and sz>=16 and sz<=2048 and (i+sz) <= h then
    hdrs[#hdrs+1] = {i=i,ty=ty,sz=sz}
  end
  i = i + 1
end
print("candidate headers:", #hdrs)
for k=1,math.min(#hdrs,6) do
  local x = hdrs[k]
  print(string.format("  off=%d type=%d size=%d", x.i, x.ty, x.sz))
  local s = {}
  for j=0,math.min(x.sz-1,40) do s[#s+1] = string.format("%02x", d[x.i+j]) end
  print("    "..table.concat(s," "))
end
