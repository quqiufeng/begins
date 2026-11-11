-- 动态探针：tracefs 注册 kprobe/uprobe -> perf_event_open 采样 -> 通用 format 解码 -> 跨进程读字符串
local ffi = require "ffi"
local bit = require "bit"
ffi.cdef[[ typedef long ssize_t; int ioctl(int fd, unsigned long request, ...);
long syscall(long number, ...); ssize_t read(int fd, void *buf, size_t n);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset); ]]
local T = "/sys/kernel/tracing"
local function rf(p) local f=io.open(p) if not f then return false end local s=f:read("*a") f:close() return s end
local function wf(p,s) local f=io.open(p,"w") if not f then return false end f:write(s) f:close() return true end

-- 1) 注册 kprobe（函数名 + 可选偏移 + 可选 $argN 提取）
local function reg_kprobe(name, func, offset, fetchargs)
  local line = offset and (func.."+"..offset) or func
  if fetchargs then line = line .. " " .. fetchargs end
  wf(T.."/kprobe_events", "p:"..name.." "..line.."\n")
  local fmt = rf(T.."/events/kprobes/"..name.."/format")
  if not fmt then return nil end
  return tonumber(rf(T.."/events/kprobes/"..name.."/id"):match("%d+")), fmt
end
local function del_kprobe(name) wf(T.."/kprobe_events", "-:kprobes/"..name.."\n") end

local id, fmt = reg_kprobe("lp_open", "do_sys_openat2", nil, "file=+0(%si):string")
print("[kprobe] id=", id)
print(fmt:match("[^\n]*file[^\n]*"))

local function parse_fields(txt)
  local f = {}
  for line in txt:gmatch("[^\n]+") do
    local decl = line:match("^%s*field:(.-);")
    if decl then
      local name = decl:match("([%w_%.]+)%s*$")
      local fld = { name=name, off=tonumber(line:match("offset:(%d+)")),
                  size=tonumber(line:match("size:(%d+)")), str=decl:find("char%[%]")~=nil }
      fld.dynloc = decl:find("__data_loc") ~= nil
      fld.dynarr = decl:find("%[%]") ~= nil
      f[#f+1] = fld
    end
  end
  return f
end
local fields = parse_fields(fmt)

local PAGE, DP = 4096, 8
local function attach(cpu, trace_id)
  local attr = ffi.new("uint8_t[?]",136)
  ffi.cast("uint32_t*",attr)[0]=2
  ffi.cast("uint32_t*",attr+4)[0]=128
  ffi.cast("uint64_t*",attr+8)[0]=trace_id
  ffi.cast("uint64_t*",attr+16)[0]=1
  ffi.cast("uint64_t*",attr+24)[0]=2+4+1024
  ffi.cast("uint64_t*",attr+40)[0]=1
  ffi.cast("uint32_t*",attr+48)[0]=1
  local fd = tonumber(ffi.C.syscall(ffi.cast("long",298), ffi.cast("void*",attr), ffi.cast("int",-1), ffi.cast("int",cpu), ffi.cast("int",-1), ffi.cast("unsigned long",0)))
  if fd < 0 then return nil end
  local bp = ffi.cast("uint8_t*", ffi.C.mmap(nil, PAGE*(1+DP), 3, 1, fd, 0))
  ffi.C.ioctl(fd, 0x2400, ffi.cast("long",1))
  return { fd=fd, bp=bp, tail=0, cpu=cpu, d=bp+PAGE }
end

local readers = {}
for cpu=0,5 do local r = attach(cpu, id); if r then readers[#readers+1]=r end end
print("[attach]", #readers, "cpus")

-- 2) 负载（常驻，便于 process_vm_readv）
os.execute("taskset -c 3 sh -c 'while :; do cat /etc/hostname >/dev/null; done' & echo $! > /tmp/lp.pid")
os.execute("sleep 0.5")

-- 3) 流式读取
local SYS_pvm = 310
local iov_t = ffi.typeof("struct { void *base; size_t len; }[1]")
local function read_str(pid, addr, max)
  if addr == 0 then return nil end
  local buf = ffi.new("char[?]", max)
  local li, ri = iov_t(), iov_t()
  li[0].base, li[0].len = buf, max
  ri[0].base, ri[0].len = ffi.cast("void*", addr), max
  local n = tonumber(ffi.C.syscall(ffi.cast("long",SYS_pvm), ffi.cast("int",pid), li, ffi.cast("unsigned long",1), ri, ffi.cast("unsigned long",1), ffi.cast("unsigned long",0)))
  if n <= 0 then return "<e"..(-n)..">" end
  return (ffi.string(buf, n):gsub("%z.*$",""))
end

local shown, total = 0, 0
local deadline = os.time() + 2
repeat
  for _, r in ipairs(readers) do
    local h = tonumber(ffi.cast("uint64_t*", r.bp+1024)[0])
    while r.tail < h do
      local off = r.tail % (PAGE*DP)
      local ty = ffi.cast("uint32_t*", r.d+off)[0]
      local sz = ffi.cast("uint16_t*", r.d+off+6)[0]
      if sz == 0 then break end
      if ty == 9 then
        total = total + 1
        local p = off + 8
        local pid = ffi.cast("uint32_t*", r.d+p)[0]
        local tid = ffi.cast("uint32_t*", r.d+p+4)[0]
        local tm  = tonumber(ffi.cast("uint64_t*", r.d+p+8)[0])
        local raw = r.d + p + 20
        if shown < 4 then
          shown = shown + 1
          local parts = {}
          for _, f in ipairs(fields) do
            if f.name:sub(1,2) ~= "co" and f.name ~= "__probe_ip" then
              local v
              if f.dynloc or (f.dynarr and not f.str) then
                local dv = ffi.cast("uint32_t*", raw+f.off)[0]
                local o, l = bit.band(dv, 0xffff), bit.rshift(dv, 16)
                v = '"'..ffi.string(raw+o, l):gsub("%z.*$","")..'"'
              elseif f.str then v = '"'..tostring(read_str(pid, tonumber(ffi.cast("uint64_t*", raw+f.off)[0]), 200))..'"'
              elseif f.size==8 then v=string.format("0x%x", tonumber(ffi.cast("uint64_t*", raw+f.off)[0]))
              elseif f.size==4 then v=tostring(tonumber(ffi.cast("uint32_t*", raw+f.off)[0]))
              else v=tostring(raw[f.off]) end
              parts[#parts+1] = f.name.."="..v
            end
          end
          print(("[cpu%d] t=%d pid=%d/%d %s"):format(r.cpu, tm, pid, tid, table.concat(parts," ")))
        end
      end
      r.tail = r.tail + sz
    end
    ffi.cast("uint64_t*", r.bp+1032)[0] = r.tail % (PAGE*DP)
  end
until os.time() > deadline
print("[total samples]", total)
for _, r in ipairs(readers) do ffi.C.ioctl(r.fd, 0x2401, ffi.cast("long",0)) end
os.execute("kill $(cat /tmp/lp.pid) 2>/dev/null")
del_kprobe("lp_open")
