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
ffi.cast("uint64_t*",attr+16)[0]=1                      -- sample_period
ffi.cast("uint64_t*",attr+24)[0]=1+4+1024               -- sample_type TID|TIME|RAW
ffi.cast("uint64_t*",attr+40)[0]=1                      -- disabled
ffi.cast("uint32_t*",attr+48)[0]=1                      -- wakeup_events
local cpu = 1
local fd = tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",cpu), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
print("fd", fd, "errno", ffi.errno())
local base = ffi.C.mmap(nil, 4096*9, 3, 1, fd, 0)
local bp = ffi.cast("uint8_t*", base)
print("mmap", base, "failed?", ffi.cast("intptr_t", base) == -1)
print("doff", tonumber(ffi.cast("uint64_t*", bp+1040)[0]), "dsz", tonumber(ffi.cast("uint64_t*", bp+1048)[0]))
ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
os.execute("taskset -c 1 sh -c 'for i in $(seq 50); do cat /etc/hostname > /dev/null; done'")
ffi.C.ioctl(fd, 0x2401, ffi.cast("long",0))
local h = tonumber(ffi.cast("uint64_t*", bp+1024)[0])
print("head", h)
local data = bp + 4096
for i=0,31 do io.write(string.format("%02x ", data[i])) end print()
