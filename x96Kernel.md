# x96Kernel.md — 内核「编译 → 安装到盒子 → 调试」全流程

> 目标机：X96 Max（Amlogic S905X2 / meson-g12a）
> 地址：`root@192.168.1.121`
> 现役内核：`7.2.12-x96-trim`（`#5 SMP PREEMPT_DYNAMIC Mon Nov 16 14:28:01 CST 2026`）
> 本机：6 核，交叉编译器 `aarch64-linux-gnu-gcc 13.3.0`
> 状态：**这条链路已完整跑通并多次实机验证**（唯一缺口是 panic 时刻抓日志，见 §7）

---

## 0. 源码从哪来 —— 缺文件从 tar 包补（先看这段）

trim 过的源码树 `/x96-build/7.2.12-trim` 是被 `trim-tools` 裁出来的：
**原始 101078 个条目 → 留下 47322 个文件 / 752M**。裁剪清单之外的目录整段不在，
所以遇到下面这些症状，不要去网上找、不要重下 linux，直接从本机的完整源码包补回来：

- `make` 报 `No rule to make target ...`、`fatal error: xxx.h: No such file or directory`
- 某个驱动/子目录 `ls` 是空的，但 `Kconfig` 里还引用着
- 想抄一份原版驱动做对比，手上只有被改过的版本

| 项 | 值 |
|---|---|
| **完整源码包** | `/opt/linux/src/linux-7.2.12.tar.xz` —— 160445268 B（153M），101078 个条目，**完整未裁剪** |
| 包内前缀 | `linux-7.2.12/`（解压时注意 `--strip-components=1`） |
| 裁剪后的树 | `/x96-build/7.2.12-trim`，752M / 47322 文件 |

**只补单个文件/目录**（推荐，不碰其它东西）：

```bash
# 例：把原版 vdec 目录整段解到临时处对比 / 补回
mkdir -p /tmp/src && tar xf /opt/linux/src/linux-7.2.12.tar.xz \
    -C /tmp/src --strip-components=1 \
    linux-7.2.12/drivers/staging/media/meson/vdec

# 补回树里（先 diff 看清差异再覆盖，别瞎 cp 把改好的代码冲掉）
diff -r /tmp/src/drivers/staging/media/meson/vdec \
        /x96-build/7.2.12-trim/drivers/staging/media/meson/vdec
cp -a /tmp/src/drivers/staging/media/meson/vdec/. \
      /x96-build/7.2.12-trim/drivers/staging/media/meson/vdec/
```

**先查包里有没有这个路径**（免得白解压 153M）：

```bash
tar tf /opt/linux/src/linux-7.2.12.tar.xz | grep '路径关键词'
```

**整个树重建**（裁剪树坏了才用，几十分钟，会丢掉 trim 的改动）：

```bash
mkdir -p /x96-build/7.2.12-full && tar xf /opt/linux/src/linux-7.2.12.tar.xz \
    -C /x96-build/7.2.12-full --strip-components=1
```

### ⚠️ 这个 tar 包**救不了**改过的驱动

实测把上游原版 vdec 目录解出来跟现役树对比（`diff -rq`，2026-11-16）：

| 类别 | 数量 | 文件 |
|---|---|---|
| **上游没有，本机新增** | 2 | `codec_hevc.c`(42K)、`codec_hevc.h` ← HEVC 8bit 修复的主体，**tar 包里根本不存在** |
| 被改过 | 14 | `codec_h264.c` `codec_hevc_common.c/.h` `codec_vp9.c` `esparser.c/.h` `hevc_regs.h` `vdec.c/.h` `vdec_helpers.c/.h` `vdec_hevc.c` `vdec_platform.c` `Makefile` |
| 与上游一致 | 11 | `codec_mpeg12.c/.h` `codec_h264.h` `codec_vp9.h` `dos_regs.h` `vdec_1.c/.h` `vdec_hevc.h` `vdec_platform.h` `Kconfig` `TODO` |

也就是说 **25 个文件里 16 个和上游不一样**。结论：

- **补缺 / 对比 / 看原版长什么样 → 用 tar 包**
- **复原「盒子上现在跑的那份」→ 只能用仓库 `meson-vdec/`（§3.5）**，tar 包给不了
- 反过来也要小心：`cp -a` 从 tar 覆盖进树，会一次性把 14 个文件 + 2 个新增全冲掉，
  驱动直接编不出来（`Makefile` 里引用的 `codec_hevc.o` 没源文件了）

---

## 1. 一张表：所有用到的路径

| 角色 | 路径 | 说明 |
|---|---|---|
| 仓库根 | `/home/quqiufeng/kernel` | 脚本、config 归档、文档都在这 |
| **内核源码树** | `/x96-build/7.2.12-trim` | 7.2.12 + trim-tools 裁剪（782M / 50552 文件），**不可删**，删了得重新裁剪生成 |
| **编译输出树（O=）** | `/x96-build/kbuild-trim` | 4216 个 .o、`arch/arm64/boot/Image`、System.map、模块都在这里 |
| **config 权威源（脚本入口 CFG）** | `x96max/kernel/config-7.2.12-x96-trim` | 8267 行，224144 B，`CONFIG_LOCALVERSION="-x96-trim"`，改配置只改这里 |
| **编译实际读的 config** | `/x96-build/kbuild-trim/.config` | 脚本 `cp $CFG $OUT/.config`，手工编也读它 |
| config 归档 | `configs/config-7.2.12-x96-trim-live-20261116` | 脚本自动比对这份 |
| 历史基线（**编译不用**） | `x96max/kernel/config-7.2.12-x96-trim.bak-20261115-baseline` = `configs/config-...-trim-final-20261115` | 8258 行，缺 netconsole/pstore 12 行 |
| 全量套 config | `x96max/kernel/config-7.2.12-x96-full` | `-x96`（无 trim）那套用 |
| 编译脚本 | `x96max/build-kernel.sh` | 封装版，支持 `--trim` / `--mode` / `-n` |
| 路径统一源 | `x96max/lib/mode.sh` | 被 source，决定 KSRC/OUT/CFG/KNAME，保证 full/trim 不串味 |
| 交叉编译前缀 | `aarch64-linux-gnu-` | |
| 源码包（全量树用） | `/opt/linux/src/linux-7.2.12.tar.xz` | full 模式按需解压 |
| 构建日志 | `/x96-build/logs/build-nc-142544.log` 等 | 每次编译一份 |
| netconsole 日志 | `/x96-build/logs/netconsole.log` | 92636 B / 1164 行 |
| **盒子 /boot** | `/boot/zImage`、`/boot/uEnv.txt`、`/boot/dtb/` | 启动三件套 |
| **盒子 模块目录** | `/lib/modules/7.2.12-x96-trim/` | 必须与 `CONFIG_LOCALVERSION="-x96-trim"` 对上 |
| **vdec 驱动备份** | `meson-vdec/` | HEVC 8bit 修复后的整套 vdec 目录副本（源码 + `.ko`），见 §3.5 |

关键约束：**`CONFIG_LOCALVERSION` 与模块目录名、`uname -r` 三者必须一致**。
trim 套是 `-x96-trim` → `7.2.12-x96-trim`；full 套是 `-x96` → `7.2.12-x96`。串了模块就加载不上。

config 只有一份（**用哪个 config 就写哪个 config**，不存在第二份要手动同步的副本）：
`x96max/kernel/config-7.2.12-x96-trim` → 脚本拷到 `/x96-build/kbuild-trim/.config` 编译，
归档 `configs/config-7.2.12-x96-trim-live-20261116` 供回溯。三者实测同 md5
`a4a2e8218137f3f9356fcd909dbe2250`（sha256 前 12 位 `e8e75c67d463`）。

---

## 2. 编译内核

### 2.1 手工命令（本次调试实际用的就是这几条）

```bash
cd /x96-build/7.2.12-trim                     # 源码树
export O=/x96-build/kbuild-trim               # 独立输出树，绝不 in-tree 编

# 0) 确认用的就是那份 config（8267 行 / md5 a4a2e82...）
ls -l $O/.config && md5sum $O/.config

# 改了 .config 后同步依赖（增量，几秒）
make O=$O ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# 编内核 + 模块。6 核机器；改 autoconf.h 级别的东西大约重编 456 个目标 / ~100s
make O=$O ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j6 Image modules

# DTB（板子自己的 dtb，改了 dts 才需要重跑）
make O=$O ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- amlogic/meson-g12a-x96-max.dtb
```

产物：

```
/x96-build/kbuild-trim/arch/arm64/boot/Image        32444928 B
/x96-build/kbuild-trim/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb   51123 B
/x96-build/kbuild-trim/System.map                    6411578 B
/x96-build/kbuild-trim/drivers/staging/media/meson/vdec/meson-vdec.ko
```

> 注意 `Image`（未压缩的 arm64 镜像），不是 `zImage`。盒子 u-boot 侧文件名仍叫 `zImage`，直接覆盖即可，它认的是裸 Image。

### 2.2 脚本封装（推荐，路径不会写错）

```bash
cd /home/quqiufeng/kernel

./x96max/build-kernel.sh --trim          # 裁剪套：7.2.12-trim + config 本尊 → kbuild-trim
./x96max/build-kernel.sh                 # 全量套：src-full(按需解压) + config-...-full → kbuild-7.2.12

./x96max/build-kernel.sh --trim -n       # 只打印解析出的路径/校验，不编译（先确认再动手）
JOBS=6 ./x96max/build-kernel.sh --trim   # 指定并行度
X96_SKIP_AUDIT=1 ./x96max/build-kernel.sh --trim   # 跳过裁剪审计 audit_stubs.py
```

脚本**每次都会 `cp $CFG $OUT/.config`**，所以 `$CFG` 就是唯一权威源：改配置请改
`x96max/kernel/config-7.2.12-x96-trim`，不要只手改 `$OUT/.config`（下次跑脚本就被盖回去）。
这三份实测同 md5（`a4a2e8218137f3f9356fcd909dbe2250` / sha256 前 12 位 `e8e75c67d463`）：

```
x96max/kernel/config-7.2.12-x96-trim        ← 脚本入口（CFG）
/x96-build/kbuild-trim/.config             ← 编译实际读的那份
configs/config-7.2.12-x96-trim-live-20261116 ← 归档（脚本自动比对，一致才不告警）
```

`-n` 自检应打印这三行：

```
  归档 config-7.2.12-x96-trim-live-20261116 一致（e8e75c67d463）
  .config 与上次一致（e8e75c67d463）：增量编译
  dry-run：不写 /x96-build/kbuild-trim/.config、不编译。
```

脚本退出码与耗时落在 `$OUT/.build-rc`、`$OUT/.build-sec`，日志落在
`/x96-build/logs/build-<MODE>-<时间戳>.log`。当前 kbuild-trim 记录：rc=0，8 秒（纯复用，无改动时的最短耗时）。

### 2.3 这份 config 里有什么（和早期基线的区别）

调 netconsole / pstore 时在基线上加了下面这些，现在都已在**唯一的 config 里**，
手工编和脚本编取的是同一份，不存在「编的和归档的不一致」：

```
CONFIG_NETCONSOLE=y / _DYNAMIC / _EXTENDED_LOG, CONFIG_NETPOLL, NET_POLL_CONTROLLER
CONFIG_SND_SOC_SPDIF=m
CONFIG_PSTORE_CONSOLE=y / PSTORE_PMSG=y / PSTORE_RAM=m, REED_SOLOMON=m(_ENC8/_DEC8)
CONFIG_PRINTK_EXECUTION_CTX=y
CONFIG_LOCALVERSION="-x96-trim"          # → uname -r = 7.2.12-x96-trim
```

要改配置，两条路都行，改完**必须** `olddefconfig`（否则缺依赖项会静默失效）：

```bash
# a) 直接改唯一那份，再让脚本同步（推荐）
vi /home/quqiufeng/kernel/x96max/kernel/config-7.2.12-x96-trim
./x96max/build-kernel.sh --trim          # 脚本自己 cp + olddefconfig

# b) 用 scripts/config 追加符号，然后推到 CFG
cd /x96-build/7.2.12-trim
scripts/config --file /x96-build/kbuild-trim/.config -e NETCONSOLE -e PSTORE_PMSG
make O=/x96-build/kbuild-trim ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
cp /x96-build/kbuild-trim/.config /home/quqiufeng/kernel/x96max/kernel/config-7.2.12-x96-trim
cp /x96-build/kbuild-trim/.config /home/quqiufeng/kernel/configs/config-7.2.12-x96-trim-live-$(date +%Y%m%d)
```

历史快照（**编译不用**，只供回溯）：`x96max/kernel/config-7.2.12-x96-trim.bak-20261115-baseline`
= `configs/config-7.2.12-x96-trim-final-20261115`，8258 行，无 netconsole/pstore。

---

## 3. 安装到盒子

### 3.1 内核本体（最常用）

```bash
# 1) 传上去
scp /x96-build/kbuild-trim/arch/arm64/boot/Image root@192.168.1.121:/tmp/zImage.new

# 2) 备份旧内核，再覆盖（关键：留退路）
ssh root@192.168.1.121 '
  cp -p /boot/zImage /boot/zImage.bak-$(date +%Y%m%d)
  mv /tmp/zImage.new /boot/zImage
  chmod 755 /boot/zImage
  sync
'

# 3) 重启
ssh root@192.168.1.121 'reboot'
```

### 3.2 DTB（改了 dts 才要）

```bash
scp /x96-build/kbuild-trim/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb \
    root@192.168.1.121:/boot/dtb/amlogic/
```

### 3.3 模块

整树安装（内核结构变了、新加 =m 的驱动时必须）：

```bash
make O=/x96-build/kbuild-trim ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     INSTALL_MOD_PATH=/x96-build/kbuild-trim/_install modules_install
cd /x96-build/kbuild-trim/_install && tar cf - lib/modules/7.2.12-x96-trim \
  | ssh root@192.168.1.121 'cd / && tar xf - && depmod -a 7.2.12-x96-trim'
```

只换一个驱动的快路（调驱动时 99% 用这个，秒级）：

```bash
scp /x96-build/kbuild-trim/drivers/staging/media/meson/vdec/meson-vdec.ko \
    root@192.168.1.121:/lib/modules/7.2.12-x96-trim/kernel/drivers/staging/media/meson/vdec/
ssh root@192.168.1.121 'rmmod meson_vdec 2>/dev/null; modprobe meson-vdec; lsmod | grep vdec'
```

### 3.4 启动参数 `uEnv.txt`

`/boot/uEnv.txt` 的 `APPEND` 行是内核 cmdline 的唯一入口。现役内容：

```bash
# 查看
ssh root@192.168.1.121 "grep '^APPEND' /boot/uEnv.txt"
```

```
APPEND=root=UUID=6deadcc9-47f7-4648-9d78-d365caaaf1e4 rootflags=data=writeback rw
 rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0
 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128
 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
 video=HDMI-A-1:1920x1080@60e plymouth.enable=0 cma=1024M
 console_flush_on_panic panic=20
 netconsole=6666@192.168.1.121/eth0,6666@192.168.1.10/
```

改之前先备份：`cp -p /boot/uEnv.txt /boot/uEnv.txt.bak-$(date +%Y%m%d)`。
**坑**：本内核 `netconsole_parser_cmdline` 要求 target IP 后面必须跟 `/`，否则报
`couldn't parse config` 静默不生效。

### 3.5 驱动副本 `meson-vdec/`（HEVC 8bit 修复版）

`/home/quqiufeng/kernel/meson-vdec/` 是源码树驱动目录的原样副本：

```bash
# 46 个文件 / 780K，与源码树 diff -r 零差异（含 .o 时间戳）
diff -r /home/quqiufeng/kernel/meson-vdec \
        /x96-build/7.2.12-trim/drivers/staging/media/meson/vdec
```

内容：

| 项 | 说明 |
|---|---|
| `codec_hevc.c` 42K、`codec_hevc_common.c`、`hevc_regs.h` | HEVC 8bit 修复的主体 |
| `vdec.c` / `vdec_hevc.c` / `esparser.c` / `vdec_helpers.c` | V4L2 M2M 框架 + 平台层 |
| `codec_h264.c` / `codec_vp9.c` / `codec_mpeg12.c` | 其余三路解码器 |
| `Makefile` / `Kconfig` / `TODO` / `README-8BIT-FIX.md` | 构建与修复说明 |
| `meson-vdec.ko` 130248 B | **就是盒子上现役的那份**，md5 `d82bf348816b774e881863571562bf55` |
| 13 个 `.o` | 与该 `.ko` 同一次编译的中间产物 |

> ⚠️ **别和 `/x96-build/kbuild-trim/.../meson-vdec.ko` 搞混**：那是 `O=` 输出树里
> **另一次**编译的产物（md5 `894b4996db719746753020448aba6845`），不是盒子上跑的那份。
> 要复原「盒子上现在跑的驱动」，认准 `meson-vdec/` 这份 `d82bf348...`。

三种用法：

**a) 只换驱动（调驱动时最常用，秒级，不用重编内核）**

```bash
scp /home/quqiufeng/kernel/meson-vdec/meson-vdec.ko \
    root@192.168.1.121:/lib/modules/7.2.12-x96-trim/kernel/drivers/staging/media/meson/vdec/
ssh root@192.168.1.121 'rmmod meson_vdec 2>/dev/null; modprobe meson-vdec; \
     lsmod | grep vdec; dmesg | tail -30; v4l2-ctl --list-devices'
```

`/dev/video0` 的 `name` 应出现 `meson-video-decoder`。

**b) 源码树丢了 / 被 trim 脚本改坏 → 拷回去复原**

```bash
cp -a /home/quqiufeng/kernel/meson-vdec/. \
      /x96-build/7.2.12-trim/drivers/staging/media/meson/vdec/
```

**c) 改完代码重新出 `.ko`**（在源码树里编，别在这个副本里编）

```bash
make O=/x96-build/kbuild-trim ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     M=drivers/staging/media/meson/vdec modules
# 产物在 /x96-build/kbuild-trim/drivers/staging/media/meson/vdec/meson-vdec.ko
```

驱动本身对不对，用 `hevcdec/`（§仓库根）的用户态工具验，见 `hevcdec/README.md`：

```bash
scp hevcdec/v4l2hevc-aarch64 root@192.168.1.121:/tmp/
ssh root@192.168.1.121 /tmp/v4l2hevc-aarch64 /tmp/test720.265
```

---

## 4. 验证新内核真的跑起来了

```bash
ssh root@192.168.1.121 'uname -r; uname -v; md5sum /boot/zImage; ls /lib/modules/'
md5sum /x96-build/kbuild-trim/arch/arm64/boot/Image      # 两边 md5 必须相等
```

本次实测结果（就是「跑通了」的硬证据）：

| 项 | 盒子 | 本机产物 | |
|---|---|---|---|
| 内核版本 | `7.2.12-x96-trim` | `Makefile` VERSION=7 PATCHLEVEL=2 SUBLEVEL=12 | ✅ |
| 构建标记 | `#5 ... Mon Nov 16 14:28:01 CST 2026` | 本次编译时间 | ✅ |
| 镜像 md5 | `5b2f811d278edf3a7252ea84c3d486f8` | `5b2f811d...` 同大小 32444928 | ✅ |
| 模块目录 | `/lib/modules/7.2.12-x96-trim` 就位 | `LOCALVERSION=-x96-trim` | ✅ |
| 稳定性 | 多次 reboot（含 panic 自动复位）后仍正常起、ssh/网络可用 | — | ✅ |

---

## 5. 调试通道：netconsole

本机接收端 `/x96-build/logs/nclisten.py`：

```python
import socket, time
LOG = '/x96-build/logs/netconsole.log'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 6666)); s.settimeout(1.0)
f = open(LOG, 'a', buffering=1)
while True:
    try: d, a = s.recvfrom(65535)
    except Exception: continue
    f.write('%s %s %s\n' % (time.strftime('%H:%M:%S'), a[0],
            d.decode('utf-8','replace').rstrip('\n')))
```

开跑：

```bash
python3 /x96-build/logs/nclisten.py &          # 后台常驻，写 netconsole.log
tail -f /x96-build/logs/netconsole.log
# 盒子侧立刻回显一行证明通道通：
ssh root@192.168.1.121 'echo netconsole-ok > /dev/kmsg'
```

实测：正常启动/运行日志全量可收（1164 行，`transmit_errors=0`）。

---

## 6. 回滚（出事就跑这个）

```bash
ssh root@192.168.1.121 '
  cp -p /boot/zImage.bak-20261116 /boot/zImage
  cp -p /boot/uEnv.txt.bak-20261116 /boot/uEnv.txt
  sync; reboot
'
```

盒子上现存的备份：`zImage.bak-20261116`（32246272 B）、`uEnv.txt.bak-20261116`、`uEnv.txt.bak-nocma`。

---

## 7. 当前已知的唯一缺口

| 通道 | 正常运行时 | panic 时刻 | 原因 |
|---|---|---|---|
| netconsole | ✅ 1164 行 | ❌ 完全静默 | panic 路径上 netconsole/netpoll 不发出（`console_flush_on_panic` 也救不了） |
| ramoops/pstore | ✅ pmsg 标记读回成功（热重启可存活） | ❌ 全丢 | panic 自动复位时 DRAM 被重初始化，pstore 区被清 |
| UART (ttyAML0) | — | 待验证 | 需确认 X96 Max 是否有可用串口排针 |

→ 「编译 → 安装 → 启动」主链路没有问题；缺的只是**崩溃现场取证**能力。

---

## 8. 速查：一次完整迭代

```bash
# 改代码（例：vdec 探针）
vi /x96-build/7.2.12-trim/drivers/staging/media/meson/vdec/codec_hevc.c

cd /home/quqiufeng/kernel
./x96max/build-kernel.sh --trim                     # ~100s（增量）
md5sum /x96-build/kbuild-trim/arch/arm64/boot/Image

scp /x96-build/kbuild-trim/arch/arm64/boot/Image root@192.168.1.121:/tmp/zImage.new
ssh root@192.168.1.121 'cp -p /boot/zImage /boot/zImage.bak-$(date +%Y%m%d) && \
                        mv /tmp/zImage.new /boot/zImage && sync && reboot'

sleep 40 && ssh root@192.168.1.121 'uname -v; md5sum /boot/zImage'
tail -50 /x96-build/logs/netconsole.log
```
