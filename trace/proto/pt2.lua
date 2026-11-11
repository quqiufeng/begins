local ffi = require "ffi"
ffi.cdef[[ int ioctl(int fd, unsigned long request, ...); long syscall(long number, ...);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset); ]]
local bit = require "bit"
local function read_file(p) local f=io.open(p); if not f then return nil end local s=f:read("*a"); f:close(); return s end
local function u32(a,o,v) ffi.cast("uint32_t*",a+o)[0]=v end
local function u64(a,o,v) ffi.cast("uint64_t*",a+o)[0]=v end
local function sys_perf(attr,pid,cpu,gfd,fl)
  return tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr),
    ffi.cast("int",pid), ffi.cast("int",cpu), ffi.cast("int",gfd), ffi.cast("unsigned long",fl)))
end
local function online_cpus()
  local s = read_file("/sys/devices/system/cpu/online") or "0"
  local list = {}
  for a,b in s:gmatch("(%d+)%-(%d+)") do for i=tonumber(a),tonumber(b) do list[#list+1]=i end end
  if #list == 0 then for n in s:gmatch("%d+") do list[#list+1]=tonumber(n) end end
  return list
end
local EV = "/sys/kernel/tracing/events/syscalls/sys_enter_openat"
local function parse_format(path)
  local txt = read_file(path.."/format"); local fields = {}
  for line in txt:gmatch("[^\n]+") do
    local decl = line:match("^%s*field:(.-);")
    if decl then
      local name = decl:match("([%w_%.]+)%s*$")
      local ty = decl:sub(1,#decl-#name)
      fields[#fields+1] = { name=name, off=tonumber(line:match("offset:(%d+)")),
        size=tonumber(line:match("size:(%d+)")), signed=ty:find("signed")~=nil, isptr=ty:find("%*")~=nil }
    end
  end
  return fields
end
local fields = parse_format(EV)
local id = tonumber(read_file(EV.."/id"):match("%d+"))
local PAGE, DP = 4096, 8
local SAMPLE_TID, SAMPLE_TIME, SAMPLE_RAW = 1, 4, 1024
local cpus = online_cpus()
print("[cpus]", #cpus)
local readers = {}
for _, cpu in ipairs(cpus) do
  local attr = ffi.new("uint8_t[?]",136)
  u32(attr,0,2) u32(attr,4,128) u64(attr,8,id) u64(attr,16,1)
  u64(attr,24,SAMPLE_TID+SAMPLE_TIME+SAMPLE_RAW) u64(attr,40,1) u32(attr,48,1)
  local fd = sys_perf(attr, -1, cpu, -1, 0)
  if fd < 0 then print("[warn] cpu"..cpu.." errno="..ffi.errno())
  else
    local base = ffi.cast("uint8_t*", ffi.C.mmap(nil, PAGE*(1+DP), 3, 1, fd, 0))
    readers[#readers+1] = { fd=fd, base=base, cpu=cpu,
      doff=tonumber(ffi.cast("uint64_t*", base+1040)[0]), dsz=tonumber(ffi.cast("uint64_t*", base+1048)[0]) }
    ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
  end
end
print("[attached]", #readers)
os.execute("ls /etc >/dev/null; cat /etc/hostname >/dev/null; ls /usr >/dev/null")
local total, shown = 0, 0
for _, r in ipairs(readers) do
  ffi.C.ioctl(r.fd, 0x2401, ffi.cast("long",0))
  local h = tonumber(ffi.cast("uint64_t*", r.base+1024)[0])
  local data = r.base + r.doff
  local tail = 0
  while tail < h do
    local off = tail % r.dsz
    local hdr = ffi.cast("uint32_t*", data+off)[0]
    local rtype, rsize = bit.band(hdr,0xff), bit.rshift(hdr,16)
    if rsize == 0 then break end
    if rtype == 9 then
      total = total + 1
      local p = off+4
      local pid = ffi.cast("uint32_t*", data+p)[0]
      local rl = ffi.cast("uint32_t*", data+p+16)[0]
      local raw = data+p+20
      if shown < 5 then
        shown = shown + 1
        local parts = {}
        for _, f in ipairs(fields) do
          local v
          if f.size==8 then v=tonumber(ffi.cast("uint64_t*",raw+f.off)[0])
          elseif f.size==4 then v=tonumber(ffi.cast("uint32_t*",raw+f.off)[0])
          else v=raw[f.off] end
          parts[#parts+1] = f.name.."="..tostring(v)
        end
        print(("[cpu%d] pid=%d rawlen=%d | %s"):format(r.cpu, pid, rl, table.concat(parts," ")))
      end
    end
    tail = tail + rsize
  end
end
print("[samples]", total)
