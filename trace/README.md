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
任何一环配置缺失，Lua 侧写得再对也是 `events=0`。本机这五环实测齐全（见下表），
所以下面那节的 `events=0` 属于**用户态解析侧**的问题，不是内核不给数据。

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
| `src/engine.lua` | 主线引擎，552 行。探针解析、perf 属性、ring 读取、通用 format 解码 |
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

## 当前状态（实测，2026-11-11）

| 模式 | 状态 | 证据 |
|---|---|---|
| `count` | **可用** | `syscalls:sys_enter_openat 201 次 / 2s (100/s)`，per-cpu 分布正常（cpu5 103 / cpu3 52 / cpu4 19 / cpu0 16） |
| `samples` | **不可用** | `events=0` |
| `latency` | **不可用** | `events=0 paired=0`（与 samples 共用 `walk()`） |
| `folded` | 未验证 | 依赖 samples 的 ring 解析 |

### 已知问题：进 ring 就读不到样本

`count` 只做 `ioctl(PERF_EVENT_IOC_ENABLE)` + `read(fd, uint64) `取计数，完全不碰 ring，所以出数正常。
一旦走 `mmap` ring + `walk()` 就 `events=0`。

**已排除**：
- 权限/内核支持 —— `perf_open` 返回合法 fd，`mmap` 成功
- header 读错 —— `data_offset`(bp+1040) / `data_size`(bp+1048) / `data_head`(bp+1024) / `data_tail`(bp+1032) 位置都对
- **raw 偏移不是原因**（早期 README 的说法是错的）：`v4` 的 `raw = d+p+20` 与 `walk()` 的
  `p=off+8 → q=p+16 → raw=d+q+4` 算出来同为 `d+off+28`，两者一致

**仍待查**：
- `open_ring` 缓存了 header 的 `off`（真实 data_offset），但 `walk()` 用的是硬编码 `r.d = bp + PAGE`；
  本机 header 报的正是 4096 所以看不出差别，属于隐患而非当前症状
- `perf_open` 的 attr 是手工按字节填的（136B 结构，`sample_period=1`、`wakeup_events=1`、
  `sample_type = TID|TIME|RAW`），字段对齐有没有错位需要拿 `sizeof(struct perf_event_attr)` 对一遍
- 建议下一步：先用 `perf record -e syscalls:sys_enter_openat` 确认内核侧确有采样，再用 v4 的
  读取循环原样替换 `walk()` 做二分（v4 已验证能出样本）

## 前提

- **内核已带追踪支持**：`CONFIG_FTRACE/KPROBES/UPROBES/PERF_EVENTS...=y`，详见上面「原理」一节；
  缺配置时不是报错而是静默 `events=0`
- **需要 root**：本机 `perf_event_paranoid=2`，非特权访问会被 `EPERM` 拦掉
- tracefs 挂在 `/sys/kernel/tracing`（同时 `/sys/kernel/debug/tracing` 也挂了一份）
