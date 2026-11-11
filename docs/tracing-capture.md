# 动态追踪 与 网络抓包：依赖清单（2026-11-11 真机实测）

**一句话：内核侧全通；用户态 `tcpdump` / `tshark` / `ecapture` 已装并抓到真实明文与可解析 pcapng，
只剩 `perf` / `bpftool` 两个空壳脚本没补。
下面每一条状态都是在本机 `7.2.12-20261111-hwreal` 上敲命令验出来的，不是照文档抄的。**

---

## 一、总览

| 用途 | 工具 | 状态 | 依赖的内核开关 |
|---|---|---|---|
| 动态追踪 | `bpftrace` v0.20.2 | ✅ **实测抓到事件** | `BPF_SYSCALL` `PERF_EVENTS` `KPROBE_EVENTS` `UPROBE_EVENTS` `FTRACE_TRACEPOINTS` |
| 动态追踪 | `bcc` / `bpfcc-tools` 0.29.1 | ✅ 模块可导入 | 同上 + `DEBUG_INFO_BTF` |
| 动态追踪 | `perf` | ❌ **空壳脚本** | `PERF_EVENTS`（内核没问题，是包没装） |
| 动态追踪 | `bpftool` | ❌ **空壳脚本** | 同上 |
| 动态追踪 | `trace-cmd` | ❌ 未装（可选，tracefs 的命令行包装） |
| 网络抓包 | `tcpdump` 4.99.4 | ✅ **实测抓到 3 包** | `PACKET` |
| 网络抓包 | `libpcap` 1.10.4 | ✅ | —— |
| 网络抓包 | `tshark` / `dumpcap` 4.2.2 | ✅ **已装，实测解开 TLS+HTTP/2 明文头，见 §5.2** |
| TLS 明文 | `ecapture` v2.10.0 | ✅ **已装，实测抓到 curl 明文 + 本机 lite 自己的 API 请求明文，见 §7.7/§7.8** |
| 通用 | `strace` | ✅ | `ptrace` |

---

## 二、内核侧依赖（能不能跑的前提）

### 2.1 已开（实测 `grep '^CONFIG_' /boot/config-$(uname -r)`）

**追踪类**

```
CONFIG_BPF_SYSCALL=y            ← eBPF 系统调用入口，一切的前提
CONFIG_BPF_JIT=y                ← 解释器换 JIT，否则慢到不可用
CONFIG_PERF_EVENTS=y            ← perf_event_open，bpftrace/ecapture 挂 probe 的通道
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y                ← 用户态函数挂钩
CONFIG_UPROBE_EVENTS=y
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y         ← 62,236 个函数可挂（实测）
CONFIG_FTRACE_SYSCALLS=y        ← 4,000+ 个 syscalls:sys_enter_* 事件
CONFIG_DEBUG_INFO_BTF=y         ← CO-RE 的命根子
CONFIG_DEBUG_INFO_BTF_MODULES=y ← 模块级 CO-RE 也支持
```

**网络类**

```
CONFIG_PACKET=y                 ← AF_PACKET，tcpdump 的全部依赖就这一条
CONFIG_CGROUP_BPF=y
CONFIG_XDP_SOCKETS=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_NET_CLS_BPF=y            ← tc 挂 BPF 分类器
CONFIG_NET_ACT_BPF=y            ← tc 挂 BPF 动作
CONFIG_NETFILTER_XT_MATCH_BPF=m ← iptables 的 -m bpf
CONFIG_VETH=m
```

### 2.2 运行时产物

| 项 | 实测 |
|---|---|
| BTF | `/sys/kernel/btf/vmlinux` **6,364,855 字节（6.36 MB）** |
| tracefs | 已挂三处：`/sys/kernel/tracing`、`/sys/kernel/debug/tracing`（`debugfs` 也挂了） |
| 可挂 kprobe/kretprobe 函数 | 62,236 个 |
| `uprobe_events` / `kprobe_events` / `dynamic_events` | 都存在，root 可写 |
| uprobe 相关内核符号 | kallsyms 里 212 个，含 `uprobe_register` / `uprobe_dispatcher` / `uprobe_free_utask` |

### 2.3 安全阀门（root 之外做不了事）

| sysctl | 值 | 影响 |
|---|---|---|
| `kernel.perf_event_paranoid` | `2` | 非 root 不能 `perf_event_open` |
| `kernel.unprivileged_bpf_disabled` | `2` | BPF 只能 root（比 1 更严，安全上是好事） |
| `kernel.kptr_restrict` | `1` | 内核地址对非 root 隐藏 |
| `net.core.bpf_jit_enable` | `1` | —— |

**结论：所有工具都要 `sudo`。** 想放开 perf 给普通用户：
`sudo sysctl kernel.perf_event_paranoid=1`（或 `-1` 全开，不建议）。

### 2.4 两个刻意未开的功能边界（不算故障）

| 项 | 影响 |
|---|---|
| `CONFIG_BPF_LSM` 未开 | 追踪不到 SELinux/AppArmor 的决策过程 |
| `CONFIG_BPF_KPROBE_OVERRIDE` 未开 | 不能改内核函数返回值 → 故障注入/错误路径回放做不了 |

真要这两项，得改 config 重编内核。

---

## 三、已装的用户态组件（附版本）

| 包 | 版本 | 说明 |
|---|---|---|
| `bpftrace` | **v0.20.2** | 主力工具，单行式 eBPF 脚本 |
| `bpfcc-tools` + `libbpfcc` | 0.29.1+ds-1ubuntu7 | `execsnoop` / `opensnoop` / `biolatency` 一整套 |
| `tcpdump` | 4.99.4 | 抓包 |
| `libpcap0.8t64` | 1.10.4-4.1ubuntu3.1 | tcpdump 的运行时 |
| `libbpf1` | 1:1.3.0-2build2 | CO-RE 加载器（ecapture 静态链接自带，系统这份给别的工具） |
| `libelf-dev` | 0.190-1.1ubuntu0.1 | 读 BTF/ELF |
| `clang` / `llvm` | 18.1.3 | bpftrace 的 C 后端、BCC 编译 |
| `libssl-dev` | 3.0.13 | 编译期用；**ecapture 挂的就是它对应的 `libssl.so.3`** |
| `strace` | —— | 系统调用级排错 |

---

## 四、缺口 1：`perf` 和 `bpftool` 是空壳脚本 ⚠️

这两个**不是没装，是装了没用**：

```
$ file /usr/bin/perf
/usr/bin/perf: Bourne-Again shell script, ASCII text executable

$ perf --version
WARNING: perf not found for kernel 7.2.12-20261111

$ bpftool version
WARNING: bpftool not found for kernel 7.2.12-20261111
```

原因：`perf` / `bpftool` 只是 Ubuntu 的 **wrapper 脚本**，逻辑是去 exec
`/usr/lib/linux-tools/<uname -r>/perf`。而 `/usr/lib/linux-tools` **目录根本不存在**。

这是自己编内核的必然结果——apt 里只有跟随**官方内核**的配套包
（`linux-tools-6.8.0-*` 之类），没有 `7.2.12-20261111-hwreal` 的；
`linux-tools-common` 装了也白装。

**影响与补法**

| 工具 | 缺了有什么后果 |
|---|---|
| `perf` | 没有 `perf record/stat/trace`，**没有硬件性能计数器**（cycles/instructions/cache-miss）、没有火焰图数据源 |
| `bpftool` | 不能 dump BTF、不能看 map 内容、不能手工 `bpftool prog load`。**但 bpftrace 自带 BTF 解析，不耽误动态追踪** |

**就地编译（源码树在手，直接绕过版本匹配）**

```bash
cd ~/kernel
sudo apt install -y libdw-dev libcap-dev python3-dev bison flex
make -C tools/perf -j$(nproc)          && sudo make -C tools/perf install
make -C tools/bpf/bpftool -j$(nproc)   && sudo make -C tools/bpf/bpftool install
# 装到 /usr/local/bin，优先级高于 /usr/bin 的 wrapper
```

---

## 五、`tshark` / `dumpcap`：✅ 已装并实测（原缺口 2）

装前只能「抓得到、解不开」：`tcpdump -w x.pcap` 出得来文件，但看不见
VXLAN / QUIC / HTTP2 / TLS 握手字段 / 流重组。

### 5.1 装（2026-11-11 已在本机执行）

```bash
# 先预置 debconf，避免装到一半卡在交互提问
echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tshark
sudo usermod -aG wireshark $USER        # 非 root 抓包，重新登录后生效
```

装完的结果（实测）：

| 项 | 值 |
|---|---|
| `tshark --version` | **TShark 4.2.2**（`4.2.2-1.1build3`） |
| `dumpcap` capability | `cap_net_admin,cap_net_raw=eip` ✅ |
| `/usr/bin/dumpcap` | `-rwxr-xr-- root:wireshark` → **必须进 `wireshark` 组**才能执行，否则报「权限不够」 |
| 立即生效验证（免重登） | `sg wireshark -c 'dumpcap -D'` → 列出 `enp34s0 / any / lo` |

### 5.2 实测记录

```bash
# A. 解析 tcpdump 抓的老 pcap
$ sudo tcpdump -i any -c 5 -nn -w t.pcap 'tcp port 80 or tcp port 443'
$ tshark -r t.pcap -nn
    1 0.000000 192.168.1.10 → 111.124.195.32 TCP 60 52216 → 443 [RST, ACK] ...
    2 0.000085 240e:...::3 → 2607:f8b0:400e:c07::54 TCP 100 59264 → 443 [SYN] ...

# B. 解析 ecapture 抓的 pcapng（真·端到端：uprobe 抓包 → tshark 解析）
$ tshark -r e2r.pcapng -q -z io,phs
eth → ip → tcp → tls → http2 → data-text-lines      # ← TLS 被 ecapture 解开了
$ tshark -r e2r.pcapng -Y http2.headers -T fields -e http2.header.value | head -1
GET,https,www.bing.com,/,curl/8.5.0,*,*               # ← :method/:authority/:path 全明文
```

> 也就是说 `ecapture -m pcap -w x.pcapng` 出来的包，**tshark 直接就能读懂 TLS+HTTP/2**，
> 不需要再喂 keylog。这两件工具是配套的，不是二选一。

**没有 tshark 时的替代**：`tcpdump -r x.pcap -nn -vvv -X` 只能看裸字节 + 基本协议头。

---

## 六、实测记录（可复现）

### 6.1 bpftrace + tracepoint：通

```bash
$ sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)) }'
Attaching 1 probe...
luajit    /tmp/lua_X2U5oQ        ← 真抓到了
```

### 6.2 bpftrace + uprobe：通（打用户态函数）

```bash
$ cat /tmp/up.c
__attribute__((noinline)) int target(int x){ return x*2; }
int main(){ for(int i=0;i<3;i++) printf("%d\n", target(i)); }

$ sudo bpftrace -e 'uprobe:/tmp/up:target { printf("hit target arg0=%d\n", arg0); }' -c '/tmp/up'
Attaching 1 probe...
hit target arg0=0
hit target arg0=1
hit target arg0=2                ← 3 次调用全中
```

### 6.3 tracefs 手工挂 uprobe：**要用偏移，别用符号名** ⚠️

本机实测出来的坑，值得记下来：

```bash
$ sudo sh -c 'printf "p:g/e /tmp/up:target\n" > /sys/kernel/tracing/uprobe_events'
sh: 1: printf: I/O error                     ← 符号名解析失败（EIO），即使符号存在
$ sudo sh -c 'printf "p:g/e /tmp/up:nosuchfunc\n" > /sys/kernel/tracing/uprobe_events'
sh: 1: printf: I/O error                     ← 不存在的符号也是 EIO，不是 ENOENT

$ OFF=$(nm /tmp/up | awk '$3=="target"{print "0x"$1}')   # 0x1149
$ sudo sh -c "printf 'p:g/e /tmp/up:$OFF\n' > /sys/kernel/tracing/uprobe_events"
$ sudo cat /sys/kernel/tracing/uprobe_events
p:g/e /tmp/up:0x0000000000001149             ← 偏移形式写入成功
$ sudo sh -c 'echo 1 > /sys/kernel/tracing/events/g/e/enable'
$ /tmp/up >/dev/null && sudo head /sys/kernel/tracing/trace
# entries-in-buffer/entries-written: 3/3    ← 3 次调用，事件确实触发
```

**谁受影响：**

| 途径 | 走哪条路 | 受影响？ |
|---|---|---|
| `bpftrace uprobe:` | `perf_event_open` + uprobe PMU（符号在用户态解析成偏移） | **不受影响** ✅ |
| `bcc` 的 `attach_uprobe` | 同上 | ✅ |
| `ecapture` | libbpf `link.Uprobe` → 同为 perf_event_open 路径 | **不受影响** ✅ |
| 手写 tracefs `uprobe_events`（`trace-cmd`、脚本直写） | tracefs 内核侧符号解析 | ⚠️ 必须自己算偏移 |

### 6.4 tcpdump：通

```bash
$ sudo tcpdump -i any -c 3 -nn -q
listening on any, link-type LINUX_SLL2
3 packets captured
10 packets received by filter
```

网卡 `enp34s0` UP（1Gbps Full）；`/usr/bin/tcpdump` 无 capability，靠 root 跑。

### 6.5 kprobe 对照：tracefs 的 kprobe 路径完全正常

```bash
$ sudo sh -c 'printf "p:mykp do_sys_open\n" > /sys/kernel/tracing/kprobe_events'
$ sudo cat /sys/kernel/tracing/kprobe_events
p:kprobes/mykp do_sys_open
```

kprobe 用符号名没问题，**只有 uprobe 的符号解析这条有 EIO 毛病** —— 说明不是 tracefs 整体坏了，
而是 uprobe 事件创建时读 ELF 符号表那一步在本机出了问题。绕开即可，不影响主流工具。

---

## 七、ecapture：TLS 明文抓取

### 7.1 它和 tcpdump 根本不是一回事

```
tcpdump   → 网卡收发的原始帧                 → 你看到 TLS 密文
ecapture  → libssl 的 SSL_read/SSL_write 入参 → 你看到 TLS 明文
```

它用 eBPF **uprobe** 挂在用户态 `libssl.so` 的函数进出点上，把 buffer 拷出来。
所以：**不装 CA 证书、不做中间人、不改网络栈**。

| | tcpdump | ecapture |
|---|---|---|
| 抓什么 | 线缆上的 TCP 段 | `SSL_read`/`SSL_write` 的明文 buffer |
| 要不要 CA | —— | **不要** |
| 加密应用 | 只见密文 | 直接读明文 |
| 内核底座 | `CONFIG_PACKET` | `UPROBES` + `UPROBE_EVENTS` + `DEBUG_INFO_BTF` + `PERF_EVENTS` |
| 本机 | ✅ | ✅（内核侧已齐备，装二进制即可） |

### 7.2 版本与要求

- 最新版：**v2.10.0**（2026-11-07 发布）
- 要求：Linux **x86_64 且内核 ≥ 4.18**（aarch64 ≥ 5.5，loong64 ≥ 6.6；本机 7.2.12 远超）
- 权限：root，或 `docs/minimum-privileges.md` 里那组 capability
- 只支持 Linux，**不支持 Windows / macOS**
- 不依赖系统 `libbpf`：官方二进制是静态编译的 Go 程序，自带 CO-RE 加载器

### 7.3 装（三选一，推荐第 1 个；2026-11-11 已用 deb 装好）

> **本机实测：GitHub Release 直连超时（15 s 无响应）**，`wget` 也挂在下载。
> 走镜像前缀 `https://ghfast.top/` 后 2 MB/s 秒下，命令如下：
>
> ```bash
> curl -L -o ecap.deb https://ghfast.top/https://github.com/gojue/ecapture/releases/download/v2.10.0/ecapture_v2.10.0_linux_amd64.deb
> sudo dpkg -i ecap.deb && ecapture --version
> # eCapture version: linux_amd64:v2.10.0
> ```
>
> 可用的镜像前缀（实测 `http=200`）：`https://ghfast.top/`、`https://gh-proxy.com/`、`https://ghproxy.net/`；
> `gitmirror.xyz`、`hub.gitmirror.com` 在本机不通。

```bash
# 1) deb 包（7.4 MB，最省事）
wget https://github.com/gojue/ecapture/releases/download/v2.10.0/ecapture_v2.10.0_linux_amd64.deb
sudo dpkg -i ecapture_v2.10.0_linux_amd64.deb

# 2) tar.gz 解压即用（9.1 MB，不碰包管理器）
wget https://github.com/gojue/ecapture/releases/download/v2.10.0/ecapture-v2.10.0-linux-amd64.tar.gz
tar xzf ecapture-v2.10.0-linux-amd64.tar.gz && sudo mv ecapture /usr/local/bin/

# 3) apt 源
sudo apt install ecapture       # 注意：官方源里不一定有
```

> `apt-cache policy ecapture` 在本机**无输出** → Ubuntu 源里没有这个包，只能走 GitHub Release。

### 7.4 本机适配要点

| 项 | 本机实测值 | 说明 |
|---|---|---|
| 系统 OpenSSL | **3.0.13** | 在 ecapture 支持范围内（1.0.x ~ 3.0.x） |
| `libssl.so.3` | `/usr/lib/x86_64-linux-gnu/libssl.so.3` | `tls` 模块默认按这组路径找 |
| `libcrypto.so.3` | 同目录 | 同上 |
| BTF | `/sys/kernel/btf/vmlinux` 6.36 MB | CO-RE 重定位靠它，**必须有** |
| uprobe PMU | 可用（§6.2 已验证） | ecapture 的挂载通道 |
| glibc | 系统自带 | 静态二进制无额外依赖 |

**常见坑**：
- 目标程序**静态链接**了 OpenSSL（如自己编的 nginx）→ 默认 `libssl.so` 找不到，用 `--ssl_version` 或指定 uprobe 偏移
- Go 程序（静态编译）用 `gotls` 模块，不是 `tls`

### 7.5 用法示例

```bash
# OpenSSL 明文（最常用）
sudo ecapture tls --hex

# 存成 pcapng，之后用 wireshark 看（需 §5 的 tshark 才有解析力）
sudo ecapture tls -w tls.pcapng

# 只要 key log（可供 wireshark 解密别的抓包）
sudo ecapture tls -k tls.log

# Go 静态二进制
sudo ecapture gotls --elf /usr/local/bin/mytool

# 其它模块：gnutls / nss / bash / zsh / mysqld / postgres
sudo ecapture bash
```

输出三选一：`text`（默认）/ `pcap`|`pcapng` / `keylog`。

### 7.6 它在这台机器上从"跑不起来"到"可以跑"

早期记录：旧内核 `FTRACE` / `TRACEPOINTS` / `KPROBE_EVENTS` / `UPROBES` / `DEBUG_INFO_BTF`
**全未开**，ecapture / pwru / BCC 一律不可用。当前内核这些全部 `=y`，
且 §6.2 已实测 uprobe 命中 3/3。

**唯一注意点就是 §6.3 的 tracefs 符号解析 EIO** —— 而 ecapture 走
`perf_event_open` + uprobe PMU（用户态解析偏移），不经过 tracefs 文件写入，
所以**不受这个坑影响**。

> 红线仍然有效：不改 VFS 主体和 net 栈。ecapture 只是旁观者，一个字节都不改。

### 7.7 实测记录（2026-11-11，text 模式）

```bash
sudo timeout 25 ecapture tls > e1.log 2>&1 &
# 自动探测：openssl 3.0.13 → /usr/lib/x86_64-linux-gnu/libssl.so.3，CO-RE 模式，挂 14 个 probe
curl -s https://www.baidu.com/s?wd=ecapture
```

抓到的原文（`e1.log`，仅去日志行）：

```
[13:25:43.224] PID:9219 Comm:curl   WRITE (89 bytes):
GET /s?wd=ecapture HTTP/1.1
Host: www.baidu.com
User-Agent: curl/8.5.0
[13:25:43.252] PID:9219 Comm:curl   READ (933 bytes):
HTTP/1.1 302 Found
Location: https://wappass.baidu.com/static/captcha/...
Date: Wed, 11 Nov 2026 05:25:43 GMT
```

**连本机 lite 自己的 TLS 都被抓到了**（`Comm:luajit`，就是 lite 进程；它调模型 API 走
libcurl → libssl.so.3 → `SSL_write`）：

```
[13:25:45.502] PID:3439 Comm:luajit WRITE (16384 bytes):
{"temperature":0,"messages":[{"role":"system","content":"You are lite, ...
```

### 7.8 实测记录（pcap 模式 → 交给 tshark）

```bash
sudo timeout 20 ecapture tls -m pcap -i enp34s0 -w /tmp/ec2.pcapng 'tcp port 443'
# INF Applying BPF filter to TC probes filter="tcp port 443"   num_probes=6
# → /tmp/ec2.pcapng  20 KB
tshark -r ec2.pcapng -q -z io,phs
# eth→ip→tcp→tls→http2 + data-text-lines：被 ecapture 解开的明文直接进了解析树
```

结论：**`tshark` 装完 → `ecapture` 装完 → 两者串起来可用**，这一条链路在本机已经闭合。

---

## 八、按场景的"要不要补"速查

| 我想干嘛 | 现在能不能 | 要补什么 |
|---|---|---|
| 看谁打开了哪个文件 | ✅ `bpftrace -e 'tracepoint:syscalls:sys_enter_openat {...}'` | 无 |
| 看用户态函数被谁调、参数多少 | ✅ `uprobe:` | 无 |
| 看内核函数参数/延迟分布 | ✅ kprobe / kretprobe | 无 |
| 看 IO 延迟、块层分布 | ✅ `biolatency-bpfcc` 等 | 无 |
| 抓 HTTP 明文 | ✅ tcpdump + `-A` | 无 |
| 抓 HTTPS 明文 | ✅ `ecapture tls`（实测抓到 curl 明文） | 无 |
| 分析 pcap 里的 TLS/QUIC/HTTP2 细节 | ✅ `tshark -r x.pcap -q -z io,phs` | 无 |
| CPU 周期/缓存命中率/火焰图 | ❌ | 编 `perf`（+ `libdw-dev`） |
| 看 BPF map 内容 / dump BTF | ❌ | 编 `bpftool` |
| 追踪 SELinux 决策 | ❌ | 重编内核开 `BPF_LSM` |
| 改内核函数返回值（故障注入） | ❌ | 重编内核开 `BPF_KPROBE_OVERRIDE` |

---

## 九、一次性补齐（复制粘贴）

```bash
# 1) 抓包解析层 —— ✅ 2026-11-11 已装（TShark 4.2.2）
echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install -y tshark
sudo usermod -aG wireshark $USER        # 不开这一步，普通用户跑 dumpcap 会「权限不够」

# 2) ecapture（TLS 明文）—— ✅ 2026-11-11 已装（v2.10.0）
#    GitHub 直连在本机超时，必须加镜像前缀
curl -L -o /tmp/ecap.deb \
  https://ghfast.top/https://github.com/gojue/ecapture/releases/download/v2.10.0/ecapture_v2.10.0_linux_amd64.deb
sudo dpkg -i /tmp/ecap.deb && ecapture --version

# 3) perf + bpftool（走源码树，绕开 wrapper）
sudo apt install -y libdw-dev libcap-dev python3-dev bison flex
cd ~/kernel
make -C tools/perf -j$(nproc)        && sudo make -C tools/perf install
make -C tools/bpf/bpftool -j$(nproc) && sudo make -C tools/bpf/bpftool install
/usr/local/bin/perf --version && /usr/local/bin/bpftool version

# 4) 收尾验证
sudo bpftrace -e 'BEGIN{printf("bpftrace ok\n");exit()}'   # 追踪
sudo tcpdump -i any -c 1 -nn -q                             # 抓包
sudo ecapture tls -h | head -3                              # TLS 明文
```

---

*实测环境：`Linux 7.2.12-20261111-hwreal x86_64`，Ubuntu 基线，VFS 与 net 栈未改。
文档随内核/工具升级更新。*
