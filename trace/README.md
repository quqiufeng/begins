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
| `src/engine.lua` | 主线引擎，1534 行。探针解析、perf 属性、ring 读取、通用 format 解码、kallsyms 符号化 |
| `tools/render.lua` | 火焰图 / 热力图 / 卡点排行三合一渲染，**纯 LuaJIT、零 Python**；共用一套 scrub/load 归一，只出 SVG（交互 JS 内联） |
| `tools/svgpng.lua` | SVG→PNG（cairo + librsvg FFI，自包含单文件）；引擎在进程内调用，`--flame/--heat/--rank x.png` 全走它 |
| `proto/render-py/` | 移植前的 Python 渲染三件套（`flame/heat/rank.py`），**只作对照留档，已不参与任何流程** |
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
| `--mode` | `count`（默认）/ `samples` / `latency` / `folded` / `oncpu` / `offcpu` |
| `--probe` | 探针规格，**可重复**；samples/folded 每个探针 × 每个 CPU 都建 ring |
| `--entry` `--exit` | latency 模式的进入/退出探针 |
| `--arg` | 附加到探针定义的 fetchargs 字符串（拼进 `argstr`） |
| `--key` | 聚合键，默认 `comm` |
| `--str` | 指定要按字符串解的字段名 |
| `--pid` | 只跟某个进程：四模式全生效，走 `pid>0 + 每 CPU` 覆盖该进程**全部线程** |
| `--duration` | 秒，默认 2，支持小数；`CLOCK_MONOTONIC` 计时，不受改系统时间影响 |
| `--ring-size` | ring data 页数，默认 8（32KB/CPU）；高频探针必须调大 |
| `--limit` | 样本输出条数上限，默认 8 |
| `--json` | JSON 输出 |
| `--flame FILE` | oncpu/offcpu/folded 采完直接出火焰图：`.svg` 可交互（悬停/点击缩放），其他后缀由引擎进程内转 PNG，见下 |
| `--heat FILE` | 同样三种模式采完直接出**函数调用热力图**（行=调用者/列=被调用者），`.svg` 可交互悬停高亮同行同列，见下 |
| `--heat-top N` | 热力图取前 N 个热门函数，默认 24 |
| `--rank FILE` | 同样三种模式采完直接出**卡点排行榜**（结论一句话 + 排序表），见下 |
| `--rank-top N` | 排行榜行数，默认 18 |
| `--rank-by K` | 排行口径：`self`（默认，自身权重）/ `incl`（含下游）/ `count`（命中次数） |

## 火焰图（`--flame`）

`tools/render.lua` 双后端、零 Chrome、零 brendangregg 脚本：

- `--flame x.svg` → **可交互 SVG**（首选，只需标准库）：悬停任意框看样本数与占比，点击框放大到该子树，
  点空白退回全图；同一份文件里还内嵌了静态 rect，丢进没有 JS 的查看器（Inkscape/rsvg）照样能看。
- `--flame x.png` → 位图：`render.lua` 仍只写 SVG，引擎在进程内用 `tools/svgpng.lua`（cairo + librsvg）转成 2 倍图 PNG，
  **不需要 PIL、不用切身份、不用 Chrome**；转换失败会保留中间 SVG 并在 stderr 说明路径。

```bash
# 盯住某个进程的 CPU 热点（pid 全线程），顺便出可交互图
sudo luajit src/engine.lua --mode oncpu --freq 199 --duration 5 --limit 40 \
     --pid $(pgrep -f 'make|gcc' | head -1) --flame /tmp/oncpu.svg
# 折叠栈、off-CPU 同样能出（off-CPU 的框宽=阻塞时长）
sudo luajit src/engine.lua --mode folded --probe kprobe:vfs_read --duration 3 --flame /tmp/vfs.svg
sudo luajit src/engine.lua --mode offcpu --pid $(pgrep -f nginx | head -1) --duration 5 --flame /tmp/block.svg
# 要位图汇报材料就换 .png 后缀
sudo luajit src/engine.lua --mode oncpu --pid $$ --duration 3 --flame /tmp/oncpu.png
```

要点：

- **纯 LuaJIT**：渲染全在 `tools/render.lua`，引擎进程内 `dofile` 调它，不再起 `python3` 子进程；
  旧 Python 版挪到 `proto/render-py/` 只作对照（并列权重的先后两家都不保证，逐字节比对时以等权重集合为准）。
- **方向**：内核给的是「叶子在前」，出栈时已反成 `root;…;leaf`（JSON 的 `frame_dir` 标明方向），
  `render.lua` 据此归一，根在下、热点在顶，两种模式都不会画反。
- **折叠重复帧**：unwind 在不靠谱的栈帧上会扫出几十层同一地址，连续同址压成一帧并在副标题记数量。
- **用户态裸地址**：kprobe 只符号化内核栈，用户态一截是 `0x00007ef8…`，ASLR 下每条都不同——直接展开会炸成上万节点，
  因此统一归并成 `[user-addr]` 占位帧（纯 ASCII，mono 字体没有 CJK 字形），保留栈深度但不保留区分度。
- **暖/冷色**：含偏移的裸地址/内核符号暖色，`libc.so.6` 这类用户态冷色。
- **零 Python 依赖**：`tools/render.lua` 只写 SVG（纯 LuaJIT 标准库 + 内联 JS），PNG 由引擎调 `tools/svgpng.lua` 转，所以 root/普通用户行为一致，没有 PIL 权限坑，也不再需要解释器。
- **高度自适应**：`ROW=17`，图高 = 头 + 最深栈层数；过窄（<0.7px）的框省略并在页脚计数。

## 调用热力图（`--heat`）

火焰图回答「谁最热」，热力图回答「谁调的谁热」——把每条调用边摊成矩阵，一眼看出热点是从哪条路径烧过来的。

```bash
# 全机 CPU 热点 + 调用关系，可交互 SVG
sudo luajit src/engine.lua --mode oncpu --freq 199 --duration 3 --heat /tmp/heat.svg
# 汇报用的位图，取前 16 个热门函数
sudo luajit src/engine.lua --mode oncpu --pid $(pgrep -f 'make|gcc' | head -1) \
     --duration 5 --heat /tmp/heat.png --heat-top 16
# off-CPU 的阻塞调用链同样适用（单元格权重 = 阻塞时长）
sudo luajit src/engine.lua --mode offcpu --pid $$ --duration 5 --heat /tmp/block.svg
```

图里三块：

- **左上 热门函数**：按包含权重排名，浅色条=包含自身及被调用者，深色条=自身；右侧 `自身 / 包含`。
- **右 调用边矩阵**：行 = 调用者，列 = 被调用者，格子颜色 = 该边权重占总权重的比例（`log(1+w)` 归一，否则长尾全白），
  够热的格子直接印数值。对角线的自递归（有重复帧折叠时常见）画灰底。
  SVG 版悬停任意格子会把**同一行同一列**点亮、其余压暗，快速定位「谁在调它、它又调了谁」。
- **左下 最热调用边**：Top 8 边平铺成 `A → B 权重 · 占比`，直接抄进报告。

与火焰图共用同一套归一规则（复用 `tools/render.lua` 的 `scrub/load`）：重复帧折叠、用户态裸地址归并为
`[user-addr]`、CJK 字体回退都一致，所以两图里函数名可以互相对照；`--heat` 与 `--flame` 也可以一次采样同时出。

## 卡点排行（`--rank`）

火焰图告诉你形状，热力图告诉你边，排行直接给结论——一行字说清「卡在哪」，下面一张按权重排好序的表。

```bash
# 盯一个进程，出排行榜 PNG（汇报截图直接可用）
sudo luajit src/engine.lua --mode oncpu --pid $(pgrep -f python3 | head -1) \
     --duration 3 --freq 199 --limit 400 --rank /tmp/rank.png --rank-top 14
# off-CPU 排行榜 = 阻塞排行榜，权重单位是毫秒
sudo luajit src/engine.lua --mode offcpu --pid $$ --duration 5 --rank /tmp/block.png
# 换排序口径：incl=含下游（找"瓶颈子系统"），count=命中次数（找"经常发生但每次很短"）
sudo luajit src/engine.lua --mode oncpu --duration 3 --rank /tmp/rank.svg --rank-by incl
```

图里三块：

- **顶部结论框**（一句话 + 卡点链）：`最热卡点 X：自身 N 样本，占已列栈 M%；Y 含下游…`，
  如果最重的包含权重落在共同入口上（`incl ≈ 全量` 而 `self` 极小），会明说「它是全栈共同入口，不是热点」，
  免得把 `_start` 当成凶手。卡点链取最重那条栈的最后 6 帧，直接给出调用路径。
- **排行表**：`结论（自热/混合/纯转发）· 函数 · 相对权重条（深色=自身，浅色=含下游）· 自身% · 包含% · 命中 · 累计%`。
  自身%=采样点正落在这个函数，包含%=含它下面所有被调用者；包含列的 `·` 表示该函数全是叶子帧（自身=包含，不重复刷数字）。
  悬停 SVG 的任意行会出明细：自身/包含绝对值、累计占比、出现在多少种不同调用栈里。
- **底部红字警告**：`--limit` 截断（`top[]` 默认只留 40 条）时报「只收 A/共 B，覆盖 x%」，并提示调大 `--limit`；
  裸偏移占比过半时提示加 `--sym` 或给 pid 对应 ELF，否则排行榜全是 `python3.12+0x15bd25` 这种没法看的地址。

排序口径 `--rank-by`：`self`（默认，自身权重，找真热点）、`incl`（含下游，找瓶颈子系统）、`count`（命中次数）。
`--rank-top N` 控制行数（默认 18）。`.svg` 纯标准库直出，`.png` 由引擎用 `tools/svgpng.lua` 转；三张图同一套口径。
与火焰图/热力图共用 `tools/render.lua` 的 `load` 归一，三张图函数名可互相对照，也可以一次采样同时出。

## 当前状态（实测，2026-11-11 14:29）

> 轮询已从忙等改为 `poll()` 睡在 ring fd 上（不再吃满一个核），并如实统计 ring 溢出：
> `events=787387（丢失 516 ...）`，不再把丢事件报成精确值。

| 模式 | 状态 | 证据 |
|---|---|---|
| `count` | **可用** | `syscalls:sys_enter_openat 200 次 / 2s (100/s)`，per-cpu 分布正常 |
| `samples` | **可用** | `events=214`，字段全解出（含 `__data_loc` 串、`--str` 跨进程读串） |
| `latency` | **可用** | `events=569 paired=268 unpaired=19`，按 comm 出 avg/p50/p99/max |
| `folded` | **可用** | `events=291 stacks=60`，内核栈已符号化 |
| `uprobe` | **可用，支持符号名** | `uprobe:/tmp/t:target_fn` 自动算出文件偏移 0x1106，1.4M/s，与手工 `:0x1106` 一致 |
| `--pid` | **可用** | 目标 `python3` 刷 `getpid`：count 5.4M/s 落在单核，samples 只出该 pid |
| `oncpu` | **可用** | 全机 3s@99Hz：`样本=1591 栈种类=219`，comm 分布 `python3=1594 luajit=97 chrome=12…`；`--pid` 时 59 样本全落在目标 python3 |
| `offcpu` | **可用** | `--pid` 后台 bash：`events=1035 配对=3 阻塞=3 未回切=1`，瓶颈栈落到 `do_wait→__do_sys_wait4→…→bash` |
| `--flame PNG` | **可用** | oncpu/offcpu/folded 三种模式直出火焰图，见上节 |
| `--heat SVG/PNG` | **可用** | 同三模式直出调用边热力矩阵；SVG 1112x634、悬停高亮，PNG 带色阶图例；`--heat-top` 控制在 24/18/12 档都排版正常 |

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

### 二轮修复（2026-11-11 14:29）

7. **`--pid` 三个模式失效**：samples/latency/folded 硬编码 `open_ring(...,-1,...)`，`--pid` 被无视；
   count 又用 `pid + cpu=-1`，只挂单线程。统一改成 `pid or -1` + 每 CPU，覆盖整进程线程。
8. **丢事件无感知**：`walk()` 只认 `SAMPLE(9)`，`LOST(2)`/`THROTTLE(5)` 被静默跳过。
   现在统计 `lost`/`throttled`，输出带「（丢失 N ...）」并在 stderr 告警，JSON 里也有字段。
9. **忙等烧 CPU**：`repeat ... until os.time() > deadline` 空转。改成 `poll(rings, ≤100ms)`
   + `CLOCK_MONOTONIC` deadline，顺带支持 `--duration 0.5` 亚秒。
10. **ring 尺寸写死**：`DP=8` 不可调，高频探针必丢。加 `--ring-size`，页数 1..1024。
11. **`data_offset` 硬编码**：`r.d = bp + PAGE`。改为按 header 的 1040/1048 读，并对越界兜底。
12. **多探针只采第一个**：samples/folded 用 `probes[1]` 建 ring，其余静默丢弃。改为全建。
13. **latency 残留 entry**：有 entry 无 exit 的样本既不配对也不计 unpaired。现在计入 unpaired。
14. **uprobe 符号名必失败**：本机内核 `uprobe_events` 只认文件偏移（写 `:malloc` 直接 EIO）。
   引擎自己解析 ELF（symtab/dynsym + PT_LOAD 换 vaddr→文件偏移），`uprobe:/路径:符号` 可用。
15. **杂项**：decode 过滤 `common_type/flags/preempt_count/pid` 噪音列；`read_cstr` 256→4096；
   comm 缓存封顶 4096 条；samples 里 u64 指针不再打成 `1.84e+19`。

### 四轮（2026-11-11 16:00）：卡点排行 `--rank`

`tools/render.lua` 的 rank 后端复用 flame/heat 的同一套归一，输入同一次采样，输出「结论一句话 + 排序表」。
排序三口径（self/incl/count）、`--rank-top N` 控行数、SVG 悬停出行明细（自身/包含/累计/出现在多少种栈里）。
两个当初踩到的判断坑已在图上显式规避：① `--limit` 会截断 `top[]`，底部红字报「只收 A/共 B，覆盖 x%」；
② 最重包含权重常落在共同入口（`_start` 类），此时明说「它是全栈共同入口，不是热点」而不是当成凶手。
自身=包含的纯叶子行，包含列显示 `·` 避免刷两遍同一个数。

### 三轮（2026-11-11 15:37）：火焰图 + 一处稳定性

16. **退出时段错误**：`cleanup()` 对 `all_rings` 里每个 ring 无条件 `munmap`，但 `ring_close` 已经收过的也在表里；
    二次 `munmap` 可能卸载已被 malloc 复用的地址（连 LuaJIT 堆一起），表现为偶发 SIGSEGV。加 `r.closed` 哨兵。
17. **`frame_dir` 显式化**：oncpu/folded 的折叠栈是**叶子在前**，offcpu 是**根在前**，渲染器不能猜。
    JSON 里加 `frame_dir` 字段，`offcpu` 另加 `unit:"ms"`（权重是阻塞时长而非样本数，但条目同样带 `count`，
    只能靠 `unit` 区分）。
18. **`--pid` 出一堆 0 样本（假警报）**：一度怀疑 perf 的 pid 过滤失效，实测是测试脚本 `$!` 抓到的是
    bash 包装进程（`STAT S`），真忙的 python 在子进程里；直接 trace 那个 pid 立刻出 59 个样本、全部命中。
    **结论：不是 bug**，只是目标选错了——排查 perf 类问题时先 `ps -o stat,pcpu` 确认目标是 `R` 且在跑。

### 测试桩的孤儿进程（2026-11-11 16:16，把整机拖到卡死）

造负载验证 `--sym` / 火焰图时用的桩脚本（`/tmp/spin.py` 之类）跑完没有收尾，19 个 python3
空转进程挂在 `lxqt-session` 下继续烧 CPU：**合计 657% / 600%，load 20.3**，桌面明显卡顿。
桩脚本长这样，`while True` 没有出口：

```python
data = bytes(random.getrandbits(8) for _ in range(200000))
while True:
    for _ in range(20):
        hashlib.sha256(data).digest()
    x = [i*i for i in range(200000)]; x.sort(reverse=True)
```

三处该记住的：

1. **桩一律挂 `timeout`**：`timeout 60 python3 spin.py &`。别指望测试脚本的 trap 能兜住，
   它自己被 kill 时子进程照跑（孤儿进程被 init/session 收养，cwd 还留在 `trace/`）。
2. **`pkill -f` 会匹配到自己**。`pgrep -f 'while True: pass'` 的执行命令行里本身含这串，
   于是 shell 把自己 SIGTERM 了（表现为工具返回 `[terminated]`，看着像环境故障）。
   想干净：`pgrep -f 'while Tru[e]: pass'` 用字符类断开自匹配，或 `pgrep -f -- pat | grep -v $$`。
3. **认领依据**：这些进程 `ppid` 全是 `lxqt-session`（从终端起的）、`cwd` 是 `trace/`、
   `stdout` 指向已删除的 `/tmp/lua_*`。系统包不会这么起，看到这组合就是自己留下的。

收尾用 `kill -TERM` 即可；load 是移动平均，1 分钟值要过几分钟才回落到真实水平，
`vmstat 1 3` 的 idle 立刻从 0% 回到 90%+ 才是真干净。

### 已知限制

- glibc 的 `malloc`/`getpid` 是 IFUNC，符号本身没有实体指令地址；探针要落在 ifunc 的 resolver
  或具体实现上（`uprobe` 能注册成功，但命中数取决于解析器调用路径）。
- folded 的 user 帧只打 `0x地址`，不做用户态符号化（内核帧才查 kallsyms）。

## 前提

- **内核已带追踪支持**：`CONFIG_FTRACE/KPROBES/UPROBES/PERF_EVENTS...=y`，详见上面「原理」一节；
  缺配置时不是报错而是静默 `events=0`
- **需要 root**：本机 `perf_event_paranoid=2`，非特权访问会被 `EPERM` 拦掉
- tracefs 挂在 `/sys/kernel/tracing`（同时 `/sys/kernel/debug/tracing` 也挂了一份）
