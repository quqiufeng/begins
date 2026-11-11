# trace — 动态追踪（LuaJIT FFI + perf_event_open）

不依赖 perf/bcc，纯 LuaJIT 直接调 `perf_event_open(2)` + `mmap` ring buffer，
探针来源是 tracefs 的 tracepoint / kprobe / uprobe。

## 目录

| 路径 | 说明 |
|---|---|
| `src/engine.lua` | 主线引擎，552 行。探针解析、perf 属性、ring 读取、通用 format 解码 |
| `proto/` | 演进原型，**保留作对照，不是稳定接口** |
| `proto/v4.lua` | 最后一代原型：kprobe + `+0(%si):string` 跨进程读字符串，取样本这条链在这里是通的 |
| `proto/v3.lua` | v4 前身（去掉字符串提取） |
| `proto/cnt*.lua` | 纯计数实验 |
| `proto/pt*.lua` | perf tracepoint 首次打通的实验 |
| `proto/scan.lua` `proto/smp.lua` | 探针扫描 / 多 CPU 挂载实验 |

## 用法

```sh
cd ~/kernel/trace
sudo luajit src/engine.lua --mode count   --probe tracepoint:syscalls:sys_enter_openat --duration 2
sudo luajit src/engine.lua --mode samples --probe tracepoint:syscalls:sys_enter_openat --limit 5 --duration 2
sudo luajit src/engine.lua --mode latency --entry <entry> --exit <exit> --key comm --duration 3
sudo luajit src/engine.lua --mode folded  --probe kprobe:some_func --limit 10 --duration 3
```

参数：`--mode` `--probe`（可多次）`--entry/--exit` `--key` `--pid` `--duration` `--limit` `--str <field>` `--json`

## 当前状态（实测，2026-11-11）

| 模式 | 状态 | 证据 |
|---|---|---|
| `count` | **可用** | `sys_enter_openat 201 次 / 2s (100/s)`，per-cpu 分布正常 |
| `samples` | **不可用** | `events=0` |
| `latency` | **不可用** | `events=0 paired=0`（复用 samples 的 `walk()`，同一个病） |
| `folded` | 未验证 | 依赖 samples 的 ring 解析 |

### 已知问题

`count` 走 `ioctl(fd, PERF_EVENT_IOC_ENABLE) + read()`，不碰 ring，所以能出数；
一进 `mmap` ring 就读不到样本，说明是 `walk()` 的 sample 布局解析写错了，不是内核/权限问题
（`perf_open` 返回合法 fd，`mmap` 成功，header 里 `data_offset=4096`、`data_size=32768` 都正常）。

下一步定位方向：`proto/v4.lua` 里 `raw = d + p + 20`（off+8 的 perf header，+16 是 pid/tid/time，
+4 是 raw_size）这条路径当时是好的；`src/engine.lua` 的 `walk()` 多插了 callchain 分支并把 `raw`
写成 `d + q + 4`，需要对齐回 v4 的偏移，并改用 `data_offset` 而不是硬编码 `PAGE`。

## 前提

- 需要 root（`perf_event_paranoid` 会拦非特权）
- 内核需 `CONFIG_PERF_EVENTS` / `CONFIG_KPROBE_EVENTS` / `CONFIG_FTRACE`（begin 内核已含）
- tracefs 挂载在 `/sys/kernel/tracing`
