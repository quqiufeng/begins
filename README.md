# begin（起初）— 裁剪内核 + 现成桌面

**名字**：`begin`，中文名「**起初**」。

取意：一切从起初开始 —— 不做又一个发行版，只为一台机器（RTX 3080 / 6 核 / 单 NUMA）
把 Linux 7.2.12 裁到只留需要的部分，从这条干净的起点往下走。

| 项 | 值 |
|---|---|
| 项目名 | `begin` |
| 中文名 | 起初 |
| 内核版本串 | `7.2.12-20261111-hwreal`（**当前在跑**，真机四项验收 PASS；已二次改动补回 squashfs/vfat/fuse/ipv6，待重启验证） |
| 下一版命名 | `7.2.12-begin`（P1 起用） |
| 装机 config | `configs/config-7.2.12-20261111-hwreal`（仓库内，逐字节即装机件） |
| 旧名 | `kdb`（2026-11-10 停用） |

## 现在是什么（事实，不是愿景）

| 层 | 谁写的 | 状态 |
|---|---|---|
| 内核 | **Linux 7.2.12 裁剪版**（不是自研） | 已编完、已装、待真机重启验证 |
| 驱动 | Linux 原样 | 复用，不改 |
| 桌面 | **现成桌面**（不是自研） | 沿用系统已有会话 |

一句话：**现在是一个被裁过的 Linux，不是自研内核。** 桌面也是现成的。

## 当前阶段

| 阶段 | 目标 | 状态 |
|---|---|---|
| **P0 能启动** | 裁剪内核在真机开机、进桌面、日常能用 | **PASS（2026-11-10 23:33 真机启动，8/8 项通过）** |
| **P1 基于此版本开发** | 在这份树上改 config / 打补丁 / 删代码，每次重编可回退 | **可开始**（P0 已 PASS） |
| P2 之后 | 见「长期愿景」 | — |

P0 的验收标准就是能日常用：进桌面、nvidia 驱动起来、网络、声音、USB 都正常。
不达标就回退旧条目继续裁，不往下走。

## 长期愿景（暂停，不是当前任务）

早期定过"自研 L0 内核 + linuxkpi 兼容层"的方案 A（`docs/scope.md`）：
内核自己写、驱动复用 Linux。这条路需要年，且和 P1 抢同一份精力。

方案 A 的替代路径是 **分块重写**（[`docs/design.md`](docs/design.md)）：驱动层原样复用，
内核**实现层**按块替换（RCU → locking → timer/wq → mm 分配器 → sched → blk），
每块一个 `CONFIG_MK_*` 开关、默认关、随时回退。首个块的契约清单见 [`notes/mk-rcu.md`](notes/mk-rcu.md)。

```
L3  桌面（现成）              ← 现在用的
L2  Linux 驱动（原样编入）     ← 复用，不改
```

## 环境事实（与索引/构建精确对应）

| 项 | 路径 |
|---|---|
| 内核源码 | `/opt/linux/src/linux-7.2.12`（裁剪工作在此树内进行） |
| 配置 | `~/kernel-meta-7.2.12/.config` → 生效副本 `src/linux-7.2.12/.config` |
| 导出符号表 | `~/kernel-meta-7.2.12/Module.symvers`（24327 个） |
| 代码索引 | `/opt/code_caches/linux_7212_cache`（355188 块 + call_graph 60MB + dataflow 705MB） |
| 构建产物 | `build/artifacts/`（bzImage + config 快照），`build/initrd/`（验证用 initramfs） |

⚠️ `Module.symvers` 是**可链接 API 的唯一真相**；源码 grep 只能补结构体/宏。

## 目录

```
src/linux-7.2.12/   裁剪中的内核树（真正的工作面，本地，不入库）
src-archive/        源码快照 tar.zst（两份：hwreal 68.9 MB / sandy-dbg2 77.2 MB，入库，解包即用）
build/              构建产物与日志
tools/trim/         lint_includes.py（找彻底缺失的头文件）
                    clean-build.sh（真·全新构建+计时，绕开不删 .o 的 make clean）
                    verify-boot.sh（QEMU 真启动 + ext4 挂载断言）
tools/abi/          check_symvers.py（零编译 CRC 对表）
docs/               设计文档
  build.md          **裁剪→编译→安装 完整流程**（照着敲就能复现装机内核）
  trim.md           裁剪方法与五轮账本（主文档）
  design.md         **分块重写方案**：驱动复用 + 实现层按块替换，M1~M7 路线
  tracing-capture.md **动态追踪/网络抓包/TLS 明文依赖清单**（bpftrace、tcpdump、ecapture 真机实测）
notes/              踩坑记录
kpi/                API 面清单（愿景期产物，暂不推进）
```

## 怎么玩这份源码（clone → 编译 → 跑起来）

不用先跑裁剪流程。`src-archive/` 里是清空构建产物的完整源码树（`.config` 已就位），解包即可编译。
两份：`hwreal`（本机装机内核）与 `sandy-dbg2`（小机箱追踪/调试内核，ftrace/BTF/netfilter 全开）。

### 1. 取下来

```bash
git clone https://github.com/quqiufeng/begins.git
cd begins/src-archive
sha256sum -c SHA256SUMS          # 应输出「成功」
```

### 2. 解包

```bash
tar --zstd -xf linux-7.2.12-begin-src-20261110.tar.zst
cd linux-7.2.12
```

需要 `zstd`（`apt install zstd` / `pacman -S zstd`）。没有的话用 `zstd -dc x.tar.zst | tar -xf -`。

解开后 **550 MB / 60202 个文件**，`.config` 已带好，不用再 `make menuconfig`。

### 3. 编译

```bash
cp /boot/config-$(uname -r) /tmp/orig.bak   # 可选：留个对照
make -j6                                     # 本机 6 核，按自己核数改
```

产物 `arch/x86/boot/bzImage`。全量编译后目录会涨到 **约 11.4 GB**（实测：编译产物 9.04 GB / 31155 个文件，链接产物 3.11 GB / 46 个，其中 `vmlinux.unstripped` 一段就 1.16 GB），**留 12 GB 空闲空间**。

编完想还原本仓库里那种干净状态：

```bash
make clean      # 12 GB → 701 MB，2 秒
```

### 4. 装到机器上

```bash
sudo make modules_install
sudo make install
sudo update-initramfs -c -k 7.2.12-begin    # Debian/Ubuntu
# sudo dracut -f                              # Fedora/Arch 系
sudo update-grub
```

重启，GRUB 里选 `7.2.12-begin`。

### 这份树和上游的差别

| 项 | 上游 `linux-7.2.12.tar.xz` | 这份快照 |
|---|---|---|
| 文件数 | 94775 | **60202** |
| 解包体积 | 1.51 GB | **550 MB** |
| 配置 | 无 | **`.config` 现成**（4226 个 =y/=m，裁剪前 6717） |
| 源码改动 | — | **无，一字没改** |

只动了 `.config` 和删掉整个不需要的驱动目录实体，**C 代码原样未改**。所以任何上游文档、补丁、`git bisect` 经验都照常适用。

砍掉的清单在 `tools/trim/disable.list`（2265 个符号），规则在 `tools/trim/rules.txt`。想自己重走一遍裁剪见 `docs/trim.md`。

**已实测跑通五轮：全新构建 20m05s → 7m53s，编译单元 9000 → 4584。** 方法与账本在 `docs/trim.md` 第 82 行起（含真清场、记账口径、QEMU 验证的三个坑）。复现两条命令：

```bash
tools/trim/clean-build.sh configs/config-baseline-2026-11-11 6      # 基线 20m05s
tools/trim/clean-build.sh configs/config-7.2.12-20261111-hwreal 6   # 装机版（在跑的）
tools/trim/verify-boot.sh
```

**要从零装出一模一样的内核，看 [`docs/build.md`](docs/build.md)**：9 步全流程 + 每一步的断言命令 + 回退路径，
配套的装机 config 就是 `configs/config-7.2.12-20261111-hwreal`（入仓库，直接 `cp` 即可编译）。

二次改动（§4.5）补回了轮5 误裁的 `SQUASHFS`/`VFAT_FS`/`FAT_FS`/`FUSE_FS`/`IPV6`——
缺了它们 snap 全坏、`/boot/efi` 挂不上。增量编译 274 s，覆盖安装前先留 `.prev` 备份，
装机 config 已同步更新（`=y 2175 / =m 645`，659 个 `.ko`）。

### 注意

- **显卡驱动**：用发行版自带的就行，本仓库不含 NVIDIA 闭源 blob（再分发违反 EULA）。`kpi/abi/nvidia.contract` 只是 CRC 清单文本（610 个符号 = 内核侧 521 + 模块间 89），用来校验裁剪有没有破坏 ABI。
- **不是自研内核**：这就是被裁过的 Linux 7.2.12，驱动、文件系统、网络协议栈全是原样的。
- **驱动只服务一台机器**：这份树的驱动是按本机（Ryzen / RTX 3080 / NVMe / AMD SATA / RTL8168 / USB xHCI）裁的，**换别的 x86 机器，驱动需要专门处理**，不能照搬。

### 换机器：驱动要补回来

砍驱动是**连目录一起删**，不是只关 `.config` 开关。所以 `make menuconfig` 补不回来——符号背后已经没代码了，得先把目录从上游解包回去。

常见缺的：

| 目录 | 上游文件数 | 谁会用 |
|---|---|---|
| `drivers/net/wireless/` | 2422 | 笔记本、无线网卡（现树 0 文件） |
| `drivers/net/ethernet/intel/` | 428 | Intel 有线网卡 e1000e/igb/i40e |
| `drivers/gpu/drm/amd` `i915` `nouveau` | — | AMD/Intel 核显、开源 NVIDIA |
| `drivers/{mmc,ufs,watchdog,iio,reset,pmdomain,pcmcia,staging}` | — | 传感器、看门狗、老笔记本 |

**别手抄清单——在目标机器上问它自己。** `tools/trim/adapt.py` 读 `/sys` 拿到本机真正在用的
驱动名，反查 `obj-$(CONFIG_X) += y.o` 得到符号和目录，缺哪个就从上游 tar 里只解哪个：

```bash
python3 tools/trim/adapt.py probe            # 上机探测 → notes/hw.json
python3 tools/trim/adapt.py plan             # 谁缺目录、谁缺 CONFIG，一目了然
python3 tools/trim/adapt.py fetch --apply    # 缺的目录从 tar.xz 拷回树里
python3 tools/trim/adapt.py refs  --apply    # 把目录重新挂回父 Makefile/Kconfig（否则代码是哑的）
python3 tools/trim/adapt.py config --apply   # 生成 config 片段并 merge，回报没生效的符号
make -j6
```

本机实测：100 个在用驱动/模块 → 88 个已就绪、0 个缺目录（这棵树本来就是为本机裁的）；
伪造一台 Intel 网卡+无线+读卡器的机器 → 正确报出 3 个缺目录并从上游拷回 921 个文件。
细节见 [`docs/adapt.md`](docs/adapt.md)。

手工兜底（知道确切目录时）：

```bash
tar -xf linux-7.2.12.tar.xz \
    linux-7.2.12/drivers/net/ethernet/intel \
    linux-7.2.12/drivers/net/wireless
cp -r linux-7.2.12/drivers/net/{ethernet/intel,wireless} ./drivers/net/
make menuconfig      # 这时符号才有代码可开
make -j6
```

x86 核心链路（ACPI / PCI / AHCI / NVMe / USB xHCI / input / DRM core）是完整的，所以换机器**能进桌面**，典型问题是能开机但没网。

## P0 验收清单（2026-11-10 23:33 实测 PASS）

实测结果：`uname -r` = `7.2.12-rtx3080-20261025-test`；RTX 3080 / 595.99.02 正常；LXQt(X11) 会话正常；
网络通（HTTP 200）；6 核识别；sda+nvme 挂载读写 283MB/s；USB 输入正常；dmesg 无致命错误。
遗留（非裁剪导致）：`amd_pstate: _CPC object is not present in SBIOS` → 无 cpufreq，BIOS 未提供 _CPC，旧内核同样如此。

逐项命令：

| # | 检查 | 命令 |
|---|---|---|
| 1 | 起来了、版本对 | `uname -r` → `7.2.12-rtx3080-20261025-test` |
| 2 | 无报错 | `dmesg -l err,warn \| head -30` |
| 3 | 桌面进得去 | 图形会话正常，无黑屏/掉驱动 |
| 4 | 显卡 | `nvidia-smi` 有型号、无 Xid 错误 |
| 5 | 网卡 | `ip a` 有地址，能上网 |
| 6 | 声音 | `aplay -l` 有设备，能出声 |
| 7 | USB/输入 | 键盘鼠标摄像头正常 |
| 8 | 磁盘 | `lsblk`、能挂载、能读写 |

**默认启动项（重要）**：`/etc/default/grub` 里
`GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-rtx3080-20261025"`，
默认进的是**旧内核**，不是裁剪版。当前正在跑的也是旧版（`uname -r` = `7.2.12-rtx3080-20261025`）。
所以重启不会自动进裁剪版，必须：

- 重启时进 `Advanced options for Ubuntu`，手选 `7.2.12-rtx3080-20261025-test`；或
- 先验证通过，再改默认：
  `sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-rtx3080-20261025-test"|' /etc/default/grub && sudo update-grub`

**回退**：改回上述 GRUB_DEFAULT，或重启时手选 `7.2.12-rtx3080-20261025`（旧条目），一切照旧。

## P1 基于此版本开发（P0 通过后）

在这份树上按"改一点 → 编 → 启 → 回退"的小步循环推进，每轮守两条底线：

1. **能启动**：`make -j6 bzImage modules` 通过，且重启后 P0 清单不复测失败。
2. **ABI 不破**：`tools/abi/check_symvers.py` 对 521 个内核侧符号始终 PASS（nvidia blob 靠它）。
3. **保留上一版**：新产物先进 `build/artifacts/<日期>`，装到 `/boot` 时旧条目不动，随时回退。

## 愿景附录（暂停，不投入）

早期方案 A 的产物，保留记录但当前不做：

- `kpi/virtio_blk.txt` —— virtio-blk 需内核提供 63 个符号（blk-mq 28 是真门槛）
- `docs/scope.md` / `docs/abi.md` —— 自研 L0 + linuxkpi 的分层与 ABI 契约
- 目标曾是 M1 hello → M2 virtio-blk → M3 framebuffer+自研桌面 → M4 真机 nvidia

现在这些全部让位于：**先把裁过的 Linux 跑稳，再在这上面开发。**
