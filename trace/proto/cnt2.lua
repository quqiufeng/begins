local ffi = require "ffi"
ffi.cdef[[ typedef long ssize_t; int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...); ssize_t read(int fd, void *buf, size_t n); ]]
local function rf(p) local f=io.open(p) if not f then return nil end local s=f:read("*a") f:close() return s end
local id = tonumber(rf("/sys/kernel/tracing/events/syscalls/sys_enter_openat/id"):match("%d+"))
local function open_counter(cpu)
  local attr = ffi.new("uint8_t[?]",136)
  ffi.cast("uint32_t*",attr)[0]=2
  ffi.cast("uint32_t*",attr+4)[0]=128
  ffi.cast("uint64_t*",attr+8)[0]=id
  ffi.cast("uint64_t*",attr+40)[0]=1
  return tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",cpu), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
end
local fds = {}
for cpu=0,5 do
  local fd = open_counter(cpu)
  if fd >= 0 then ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1)); fds[#fds+1]={fd=fd,cpu=cpu} end
end
print("open:", #fds)
os.execute("ls /etc >/dev/null; ls /usr >/dev/null")
local sum = 0
for _, f in ipairs(fds) do
  ffi.C.ioctl(f.fd, 0x2401, ffi.cast("long",0))
  local b = ffi.new("uint64_t[1]")
  ffi.C.read(f.fd, b, ffi.cast("unsigned long",8))
  print("cpu"..f.cpu, tonumber(b[0])); sum = sum + tonumber(b[0])
end
print("sum", sum)
