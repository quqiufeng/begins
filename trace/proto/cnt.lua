local ffi = require "ffi"
ffi.cdef[[ typedef long ssize_t; int ioctl(int fd, unsigned long request, ...); long syscall(long number, ...); ssize_t read(int fd, void *buf, size_t n); ]]
local function rf(p) local f=io.open(p) if not f then return nil end local s=f:read("*a") f:close() return s end
local id = tonumber(rf("/sys/kernel/tracing/events/syscalls/sys_enter_openat/id"):match("%d+"))
local attr = ffi.new("uint8_t[?]",136)
ffi.cast("uint32_t*",attr)[0]=2
ffi.cast("uint32_t*",attr+4)[0]=128
ffi.cast("uint64_t*",attr+8)[0]=id
ffi.cast("uint64_t*",attr+40)[0]=1
local fd = tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",0), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
print("fd", fd, "errno", ffi.errno())
ffi.C.ioctl(fd, 0x2403, ffi.cast("long",0))
ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
os.execute("ls /etc >/dev/null; ls /usr > /dev/null")
ffi.C.ioctl(fd, 0x2401, ffi.cast("long",0))
local buf = ffi.new("uint64_t[1]")
local n = tonumber(ffi.C.read(fd, buf, ffi.cast("unsigned long",8)))
print("count", tonumber(buf[0]), "read", n)
