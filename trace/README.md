# trace — 动态追踪（LuaJIT FFI + perf_event_open）

不依赖 perf/bcc，纯 LuaJIT 直接调 `perf_event_open(2)` + `mmap` ring buffer，
探针来源是 tracefs 的 tracepoint / kprobe / uprobe。

## 原理：动态追踪说到底靠内核支持

用户态只能「读结果」，**插桩能力全部在内核里**。这个项目用纯 LuaJIT，但下面几个环节一个都不能少，且每一环都是内核提供的：

| 环节 | 内核提供什么 | 本机证据 |
|---|---|---|
| 1. 追踪子系统 | `FTRACE/TRACEPOINTS/TRACING` 把 tracefs 挂出来 | `tracefs on /sys/kernel/tracing type tracefs`，`CONFIG_FTRACE=y` |
| 2. 探针注册 | kprobe/uprobe 在函数入口布断点，往 `kprobe_events` 写一行即生效 | `events/kprobes/*/format` 可读、`id` 能分配（v4 会打印 `[kprobe] id=<非0>`） |
| 3. 采集 | 探针注册为 perf 事件，`perf_event_open(2)` 拿 fd | `CONFIG_PERF_EVENTS=y`，`perf_open` 返回合法 fd |
| 4. 回传 | `mmap` 的 ring buffer（header + data pages）由内核填 | `data_head` 在 `bp+1024`、`data_offset/size` 在 `bp+1040/1048` |
| 5. 解码 | `format` 文件给出字段偏移（含 `__data_loc` 动态串） | 靠它算 raw/`file=`，不必硬编码结构 |

流程即：**写 tracefs → 内核装探针 → perf 事件 → mmap ring → 按 format 解码**。
任何一环配置缺失，Lua 侧写得再对也是 `events=0`。本机这五环实测齐全（见下表）。
历史上一度出现过 `events=0`，事后定位是**用户态解码侧**的 bug（`common_type` 按 u32 读），
不是内核不给数据 —— 详见下面「已修的问题」。

### 为什么这台机器要专门编译内核

出厂 begin 内核这块是整块关掉的（`FTRACE=n`，等于追踪子系统不存在）。
`configs/trace-capture.fragment` 逐条 `scripts/config -e` 后 `make olddefconfig` 重编，
当前运行内核 `7.2.12-20261111-hwreal` 就是这份产物。已确认生效（`src/linux-7.2.12/.config`）：

```
CONFIG_FTRACE=y              CONFIG_KPROBES=y          CONFIG_PERF_EVENTS=y
CONFIG_TRACEPOINTS=y         CONFIG_KPROBE_EVENTS=y    CONFIG_DYNAMIC_EVENTS=y
CONFIG_TRACING=y             CONFIG_UPROBES=y          CONFIG_FTRACE_SYSCALLS=y
CONFIG_GENERIC_TRACER=y      CONFIG_UPROBE_EVENTS=y    CONFIG_DEBUG_INFO_BTF=y
CONFIG_FUNCTION_TRACER=y     CONFIG_BPF_EVENTS=y       CONFIG_KALLSYMS_ALL=y
CONFIG_DYNAMIC_FTRACE=y      CONFIG_FPROBE=y           CONFIG_FRAME_POINTER=y
  (+WITH_REGS / +WITH_ARGS)  CONFIG_TRACER_SNAPSHOT=y  CONFIG_DEBUG_INFO_DWARF5=y
```

要点：`DEBUG_INFO_DWARF5` 是 BTF 的地基（原先是 `DEBUG_INFO_NONE`，必须显式 `-d` 让位），
没它 bpftrace/BCC 的 CO-RE 起不来；`KALLSYMS_ALL` 让 kprobe 能按名字解析非导出符号。
这些不是「为了跑通本项目才要」，而是**动态追踪本身的硬前提**。

## 目录

| 路径 | 说明 |
|---|---|
| `src/engine.lua` | 主线引擎，589 行。探针解析、perf 属性、ring 读取、通用 format 解码、kallsyms 符号化 |
| `proto/` | 演进原型，**保留作对照，不是稳定接口** |
| `proto/v4.lua` | 最后一代原型，**实测可用**：kprobe `do_sys_openat2` + `file=+0(%si):string`，2s 收 36758 样本，跨进程读出 `file="/dev/bus/usb/006/001"` |
| `proto/v3.lua` | v4 前身（去掉字符串提取） |
| `proto/cnt*.lua` | 纯计数实验 |
| `proto/pt*.lua` | perf tracepoint 首次打通的实验 |
| `proto/scan.lua` `proto/smp.lua` | 探针扫描 / 多 CPU 挂载实验 |

## 用法

```sh
cd ~/kernel/trace
sudo luajit src/engine.lua --mode count   --probe tracepoint:syscalls:sys_enter_openat --duration 2
sudo luajit src/engine.lua --mode samples --probe tracepoint:syscalls:sys_enter_openat --limit 5 --duration 2
sudo luajit src/engine.lua --mode latency --entry tracepoint:syscalls:sys_enter_openat --exit tracepoint:syscalls:sys_exit_openat --key comm --duration 3
sudo luajit src/engine.lua --mode folded  --probe kprobe:do_sys_openat2 --limit 10 --duration 3
```

参数（全部，见 `src/engine.lua:214-231`）：

| 参数 | 说明 |
|---|---|
| `--mode` | `count`（默认）/ `samples` / `latency` / `folded` |
| `--probe` | 探针规格，**可重复**（但 samples 只给 `probes[1]` 建 ring，多给只采第一个） |
| `--entry` `--exit` | latency 模式的进入/退出探针 |
| `--arg` | 附加到探针定义的 fetchargs 字符串（拼进 `argstr`） |
| `--key` | 聚合键，默认 `comm` |
| `--str` | 指定要按字符串解的字段名 |
| `--pid` | 只跟某个 pid（count 模式走 `perf_open(id, pid, -1)`） |
| `--duration` | 秒，默认 2 |
| `--limit` | 样本输出条数上限，默认 8 |
| `--json` | JSON 输出 |

## 当前状态（实测，2026-11-11 14:20）

| 模式 | 状态 | 证据 |
|---|---|---|
| `count` | **可用** | `syscalls:sys_enter_openat 200 次 / 2s (100/s)`，per-cpu 分布正常 |
| `samples` | **可用** | `events=214`，字段全解出（含 `__data_loc` 串、`--str` 跨进程读串） |
| `latency` | **可用** | `events=569 paired=268 unpaired=19`，按 comm 出 avg/p50/p99/max |
| `folded` | **可用** | `events=291 stacks=60`，内核栈已符号化 |
| `uprobe` | **可用** | `uprobe:/tmp/t:0x1129 34.4k 次 / 3s (11466/s)` |

### 已修的问题（早期 README 的「进 ring 就读不到样本」已不成立）

1. **`common_type` 读成 u32**（`events=0` 的真因）：raw 首个字段是 `common_type`(u16)，
   读 4 字节会把 `common_flags`(0x0100) 一起读进来，值变成 `0x01000322`，`by_id` 查不到 → 全部丢弃。
   改成读 u16 后 samples/latency/folded 三个模式同时恢复。
2. **`latency` 未填 `pid/tid`** 就调 `key_of()` → `attempt to concatenate local 'pid'`。
3. **`load_kallsyms` 缓存哨兵失效**：`ksym_addr` 初始化成 `{}`（真值），每次 `sym()` 直接 return；
   修正后仍会在未命中时重解析 30 万行 `/proc/kallsyms`（表现为 CPU 100% 跑不完）。
4. **64 位内核地址丢精度**：`tonumber(addr,16)` 是 double，`0xffffffff8d800000` 只剩 2048 字节分辨率，
   kallsyms 表和查询值一起被压扁。改为全程 16 位小写 hex 串比较，偏移用 32 位切片算。
5. **`reg_dynamic` 不区分 kind**：uprobe 也写 `/kprobe_events`，永远注册不上。改为按 kind 选
   `uprobe_events` + `uprobes` 事件组，并以「事件目录是否出现」判定成败（内核 write 时只报 errno）。
6. **探针残留不自愈**：被 SIGTERM/超时杀掉时 `cleanup()` 不执行，留下 `p:kprobes/lite_N` 占住探针
   （后续注册全 `EBUSY`）。补了启动自清、SIGTERM/SIGINT 置标志优雅退出、`cleanup` 前先
   `close`+`munmap` ring（否则删探针 `EIO`）。

### 已知限制

- **uprobe 不支持符号名**：`uprobe:/lib/.../libc.so.6:malloc` 报 `EIO`（内核侧不认），
  要用 `nm` 拿偏移再写 `uprobe:文件:0x偏移`；`malloc`/`getpid` 在 glibc 里是 IFUNC，本身无实体地址。
- `walk()` 用硬编码 `r.d = bp + PAGE`，而 header 的 `data_offset` 已缓存未用；本机报的正是 4096，
  属隐患非当前症状。

## 前提

- **内核已带追踪支持**：`CONFIG_FTRACE/KPROBES/UPROBES/PERF_EVENTS...=y`，详见上面「原理」一节；
  缺配置时不是报错而是静默 `events=0`
- **需要 root**：本机 `perf_event_paranoid=2`，非特权访问会被 `EPERM` 拦掉
- tracefs 挂在 `/sys/kernel/tracing`（同时 `/sys/kernel/debug/tracing` 也挂了一份）
