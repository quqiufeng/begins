-- 单调时钟（秒，浮点）：给 READER_PROF 埋点用。
--
-- 只有这里能 cdef clock_gettime：ffi.C 的绑定只认第一次声明的结构体类型，
-- 多个文件各自定义一个 typedef 再调用，后声明的会直接
-- "cannot convert 'struct N' to 'struct M *'" 报错。统一走本模块。
local ffi = require("ffi")

local declared = false
local function ensure()
    if declared then return true end
    local ok = pcall(ffi.cdef, [[
        typedef struct { long tv_sec; long tv_nsec; } rd_timespec;
        int clock_gettime(int clk_id, rd_timespec *tp);
    ]])
    declared = ok
    return ok
end
if not ensure() then
    return { now = function() return os.clock() end, ok = false }
end

local ts = ffi.new("rd_timespec")
local CLOCK_MONOTONIC = 1

-- 单调时钟秒数；调用失败时退化为 os.clock()。
local function now()
    if ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) ~= 0 then
        return os.clock()
    end
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

return { now = now, ok = true }
