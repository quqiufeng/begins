# 裁剪路线（2026-11-10 定：裁剪式，非重写）

**做法**：以 Linux 7.2.12 源码为基，删掉不针对本机的代码，重新梳理，让内核正常工作。
比"对照语义重写"风险低一个数量级 —— 不用猜驱动的隐含假设，因为代码就是原来那份。

## 基线已实测 PASS（不用编译）

`Module.symvers` 里就是全表 CRC，直接对表即可：

| 项 | 数 |
|---|---|
| `~/kernel-meta-7.2.12/Module.symvers` | 24327 符号 |
| 契约 610 | 内核侧 521 + 模块间 89 |
| 内核侧 521 匹配 | **521 / 521，CRC 不符 0** |
| 模块间 89 | 全部由 nvidia 四模块自己导出 ✅ |

**判定 PASS。** 这 521 个符号 = 裁剪时绝对不能碰的边界。

## 陷阱：config 分两类，一类不能砍

CRC 是类型签名指纹，**config 会改类型布局**。实测：

| config | 改了什么 | 后果 |
|---|---|---|
| `CONFIG_NR_CPUS=8192` | `cpumask_t = DECLARE_BITMAP(bits, NR_CPUS)` → **1024 字节** | 改 8 就变 8 字节，所有含 cpumask 的 struct 变形 → CRC 全变 |
| `CONFIG_PREEMPT_RT` | `spinlock_t` / `mutex` 整块换实现 | 类型完全不同 |
| `CONFIG_DEBUG_SPINLOCK` | `spinlock_t` 加 owner/魔数字段 | 变形 |
| `CONFIG_SMP` | `spinlock_t`、atomic、smp 辅助 | 变形 |
| `CONFIG_LOCKDEP` | 加 `dep_map` | 变形 |
| `CONFIG_MEMCG` | `struct page`/`folio`/`lruvec` | 变形 |

→ **这些开关一律不动**，即使"本机只有 6 核、单 NUMA 节点"看着浪费。
`NR_CPUS=8192` 留着的代价只是几个静态位图，改了要赔上 610 个符号的兼容性。

## 可以安全砍的（纯增量，不进类型定义）

| 类别 | 现状 | 砍法 |
|---|---|---|
| 架构 | 多 arch + ia32 兼容 | `arch/` 只留 x86，删 ia32 emulation |
| 驱动 | 上千个 `drivers/*` | 只留 nvidia 需要的（PCI/DMA/DRM/ACPI/fb） |
| 文件系统 | 几十个 | ext4 / proc / sysfs / devtmpfs / tmpfs |
| 网络协议 | 完整栈 | 留 IPv4/v6 + AF_UNIX；砍 netfilter/sched/无线 |
| cgroup/namespace | 全套 | 单用户单机，砍 |
| KVM / BPF / perf / ftrace | 有 | 不观测不当宿主，砍 |
| suspend / 热插拔 | 有 | 台式机，砍 |

参考量：当前 `.config` **6914 个 CONFIG、2821 个 =y**，目标是砍到 **~500 =y**。

## 执行顺序（每步都要回归）

```
① 基线可复现编译      cp .config → make olddefconfig → make -j6（出一份 vmlinux）
② 量出账本            每个子系统编了多少文件/行，按行数排序砍
③ 分轮砍 config       一轮只砍一类，砍完 make
④ 真删目录             归零的目录直接 rm，这是"简化代码"的实际来源
⑤ 重构                只在少数热点动实现（调度单队列、RCU）；
                      锁语义一律保留 —— SMP 是真的
```

每轮结束跑：

```bash
~/kernel/tools/abi/check_symvers.py ~/kernel-meta-7.2.12/Module.symvers \
                                     ~/kernel/kpi/abi/nvidia.contract
```

→ 必须始终 **521/521 PASS**。一旦有 CRC 不符，说明这轮砍到了类型定义，回退。

## 与"重写"路线的取舍

| | 裁剪式 | 重写式 |
|---|---|---|
| 保留 | 语义天然正确 | 需逐条复现隐含假设 |
| 风险 | 删错东西 → 编不过/启动失败（**立刻可见**） | 语义偏差 → 偶发崩（**难查**） |
| 工作量 | 删 + 梳理 | 2~4 万行新写 |
| 行数结果 | 15~20 万（同量级） | 15~20 万 |

两者最终规模一样，但裁剪式的每处错误当场暴露。**选裁剪式。**

---

# 实战：五轮裁到 7分53秒（2026-11-11 实测）

上面是路线，下面是走完一遍的账。**目标不是把 config 砍到 500 =y，而是把全新构建压进 8 分钟**——
口径变了：每个开关的取舍依据是"编译单元数"，不是"符号数"。

## 一、四条方法论（先立规矩，再动刀）

### 1. 真清场：本树 `make clean` 不删 `.o`

最容易踩的坑。`make clean`/`make mrproper` 在这棵树上跑完，`find . -name '*.o' | wc -l` 仍然非零，
于是后面每次"全新构建"测的都是**增量时间**，数字看着漂亮，全是假的。

正确清场序列（不依赖 make 的目标）：

```bash
make mrproper >/dev/null 2>&1 || true
find . -name '*.o' -delete
find . -name '.*.cmd' -delete
find . -name '*.ko' -delete
[ "$(find . -name '*.o' | wc -l)" -eq 0 ] || echo "清场失败"
```

清完必须断言归零，再 `cp` 回配置跑 `make olddefconfig`。**每轮都从 0 开始计时，否则轮与轮不可比。**

**脚本化时的连带坑**：`clean-build.sh` 要先 `cd` 进源码树再干活，此时命令行传进来的 `configs/xxx.ok`
这种相对路径就失效了（`cp: stat 失败`，且因为 `set -e` 直接退出，清场已做完、构建没开始，
树处于"干净但没编"的状态）。所以路径参数必须 `realpath` 绝对化后再 `cd`——
**这个 bug 是自测跑出来的，不是看出来的**。

### 2. 计时口径：wall clock，起点在 make 之前

```bash
S=$(date +%s); make -j6 -s >/tmp/build.log 2>&1; E=$(date +%s)
```

同时记 `bzImage` 的 mtime，两个时间对照（本轮两者一致：7m53s / 7m53s），能识破"编译完了卡在链接/后处理"。

### 3. 记账：按目录数 `.o`，不按开关数拍脑袋

砍之前先排序，只砍排前面的：

```bash
# 顶层分布
find . -name '*.o' -printf '%h\n' | awk -F/ '{print $2}' | sort | uniq -c | sort -rn | head -12
# 二级细分（drivers/fs 的大头都在第三层）
find drivers -name '*.o' -printf '%h\n' | awk -F/ 'NF>=3{print $1"/"$2"/"$3} NF==2{print $1"/"$2}' | sort | uniq -c | sort -rn | head -12
```

实测的分布（轮5 之前，4584 单元量级）：`drivers` 2229 / `net` 644 / `fs` 637 / `arch` 547 / `kernel` 285 /
`lib` 284 / `crypto` 175。**drivers 一个目录占了近一半**，所以四轮里有三轮都在削 drivers。

### 4. 验证：不信"编过了"，只信"挂上了"

编译通过 ≠ 能启动。本机内核按 `-march=native` 编译，**QEMU 必须 `-cpu max`**，否则非法指令直接死在 early boot，
会被误判成"裁剪把启动砍坏了"。

第二坑：initramfs 里若不 `mount -t devtmpfs none /dev`，`/dev/vda` 根本不存在，报
`Can't lookup blockdev`，看着像 virtio-blk 挂了，其实是环境没搭。

一把梭的验证脚本：`tools/trim/verify-boot.sh`（busybox initramfs + 32M virtio-blk ext4，断言 `TEST:EXT4-MOUNT-OK`）。

## 二、台账（每轮都是真·全新构建）

| 轮 | 全新构建 | 编译单元 | .ko | vmlinux | bzImage | =y | =m |
|---|---|---|---|---|---|---|---|
| 基线 | 20m05s | ~9000 | — | — | — | 2428 | 1780 |
| 轮2 | 12m24s | 7633 | 1767 | 78M | — | 2234 | 1128 |
| 轮3 | 10m34s | 6002 | 1008 | 61M | — | 2023 | 1001 |
| 轮4 | 9m18s | 5141 | 733 | 50M | 9.8M | 1794 | 719 |
| **轮5** | **7m53s** | **4584** | **656** | **48M** | **9.0M** | **1710** | **644** |

5 轮共砍 **49% 的编译单元 / 61% 的时间**。账本在 `logs/round{2..5}-*.{log,txt}`，数字以日志为准。

**复现校验（同配置再跑一遍 `clean-build.sh`）**：7分29秒 / 4584 单元 / 656 `.ko` / 48M vmlinux / 9.0M bzImage / warning 3，
随后 `verify-boot.sh` → `EXT4-MOUNT-OK` PASS。**单元数、`.ko` 数、两个镜像尺寸全部逐项相同**，
时间差 24s 属缓存与机器状态抖动 —— 所以对比轮次应该看**单元数**（确定性），时间只作参考。
3 个 warning 都是上游 `-Wframe-larger-than`（ublk_drv 1424B、wireguard 1048B×2），非裁剪引入，可忽略。

## 三、每轮砍了什么（按收益排序）

| 轮 | 主要动作 | 收益 |
|---|---|---|
| 轮2 | `=m` 全转 `=y`（不装模块），砍 `DEBUG_INFO`、`KALLSYMS_ALL` 类 | −4m |
| 轮3 | 缩 `arch/`：删 ia32 兼容、多平台；砍 KVM/BPF/perf/ftrace 大半 | −1m50s |
| 轮4 | 驱动类目归零：删无关 `drivers/*` 子目录挂载 | −1m16s |
| 轮5 | 二线子系统连根拔：PHYLIB(137)、TPM(51)、EDAC(49)、PINCTRL(39)、ACCESSIBILITY/speakup(38)；整个 NETFILTER/BRIDGE/BT/WIRELESS/CAN/NFC；十几个文件系统（xfs/ntfs3/cifs/fuse/squashfs/nilfs2/hfsplus/orangefs/jfs/gfs2/ocfs2/9p/iso9660/udf） | −1m25s |

轮5 的开关清单见 `logs/round5-summary.txt`，可 `scripts/config --disable ...` 原样重放。

> ⚠ **轮5 的"文件系统连根拔"里有五个是错的**：`SQUASHFS`、`VFAT_FS`、`FAT_FS`、`FUSE_FS`、`IPV6`。
> 它们不属于"没有硬件的驱动"，而是桌面运行时必需（snap 全靠 squashfs，`/boot/efi` 是 FAT32）。
> 砍掉的表现不是少个功能，而是 snap 全坏 + ESP 挂不上。已于 2026-11-11 09:00 补回 `=y`，
> 编译安装过程见 [`docs/build.md`](build.md) §4.5。
> 教训：**"文件系统"不是一类东西**，要按"本机谁在用它"逐个判，不能按目录一刀切。

## 四、砍不动的边界（补充新踩的坑）

原表那 6 条（`NR_CPUS` / `PREEMPT_RT` / `DEBUG_SPINLOCK` / `SMP` / `LOCKDEP` / `MEMCG`）依然成立。新增三条：

- **`DEVTMPFS` 不能砍成 n**：没有它 `/dev` 空白，所有 block 设备访问全废。`DEVTMPFS_MOUNT` 可以留着。
- **`VIRTIO_PCI` 不能砍**：QEMU 里所有 virtio 设备走它。砍了会出现"virtio_blk 符号在、设备不注册"的假象——
  `nm vmlinux` 查 `virtio_blk_init` 存在并不等于能用，**必须走一次真实挂载**。
- **`SOUND` / `SND` 不能整块砍**：声卡在 `lspci` 里、驱动缺失时**不报任何错**，只是 `/dev/snd` 不存在。
  更阴的是补回来也不便宜：`SND_INTEL_DSP_CONFIG` 无条件 `select ACPI_NHLT`（bool，只能进 vmlinux），
  所以"只编模块"必然 `Unknown symbol acpi_nhlt_get_gbl_table`，得整编 vmlinux。
  外加 `alsa-base.conf` 的 `install snd` 钩子依赖 `snd-seq`，缺了报的是误导性的 `Invalid argument`。
  完整流程与三个坑见 **build.md §4.6**。

另有一条判据：**`=m` 的模块同样消耗编译时间**。轮2 之前有 1780 个 `=m`，编译成 `.ko` 一样要编一次编译单元。
所以"砍时间"的正确做法是把 `=m` 直接 `--disable`，而不是留 `=m` 以为省了——省的是链接和安装，不是编译。

## 五、还能往哪走（已到 CPU 上限）

轮4→轮5 速率稳定在 **8.9~9.5 单元/秒**（6 核 `-j6` 打满），说明瓶颈是纯 CPU 吞吐，不是配置冗余。
剩下的三条路，按性价比：

1. **ccache**：`make CC="ccache gcc"`，冷缓存没用，热重建可到 1~2 分钟。**迭代开发首选**，不改功能。
2. **继续减单元**：剩余大头 `drivers/acpi/acpica`(169)、`crypto`(175)、`net`(~500)、`drivers/firmware/efi`(69)。
   代价是丢 UEFI 启动和网络能力，收益约 30~60s——**不划算，除非明确不要网络**。
3. **加核**：硬件层解决。

## 六、复现（两条命令）

```bash
tools/trim/clean-build.sh configs/config-baseline-2026-11-11 6   # 基线：20m05s 起点
tools/trim/clean-build.sh configs/config-7.2.12-20261111-hwreal 6 # 装机版：实际在跑的那份
tools/trim/verify-boot.sh                                        # QEMU 真启动+ext4 挂载断言
```

重走某一轮：以 `config-baseline-2026-11-11` 为起点，按 `logs/round{N}-summary.txt` 的开关清单逐条重放。

两步都绿，才算这一轮成立。单看第一步会漏掉"能编不能启动"，单看第二步会漏掉"时间没变"。

两个脚本均已在本机实跑通过：

```
== 清场（不依赖 make clean）==
  .o = 0 ✓
== 结果 ==
  耗时    7分29秒 (rc=0)
  单元    4584           .ko     656
  vmlinux 48M            bzImage 9.0M
  warning 3
== PASS：内核能挂 ext4（virtio-blk + 8250 + initramfs 均正常）==
```

---

## 构建速度：实测与结论（2026-11-11）

### 数据

| 场景 | 命令 | 耗时 |
|---|---|---|
| 只编到 `.o` | `make drivers/block/loop.o` | **1.9s** |
| 改 1 个 `.c` + 完整构建 | `make -j6` | **40s**（编 2s + 链接打包 38s）|
| no-op | `make -j6` | 4s |
| 改公共头 `include/linux/sched.h` | `make -j6` | **147s** |
| 清场全量（基线） | `clean-build.sh` | **7分29秒** |
| ccache 冷缓存全量 | `make CC="ccache gcc" -j6` | 612s（比基线慢 36%）|
| ccache 热缓存全量 | 同上，清场后重编 | **153s**（2分33秒，快 2.9 倍）|

ccache 热缓存阶段 `Hits 4459/8854 (50.36%)`，产物 `vmlinux 48M / bzImage 9.0M`，与基线完全一致。

### 关键结论

1. **增量编译本身已是最优**：改一个文件的编译开销就是 1.9s，无优化空间。
2. **40s 的瓶颈是链接**：`vmlinux`(48M) + `bzImage` 打包占 38s，与改动量无关，改 1 行和改 500 行一样。
3. **ccache 只对"反复改公共头 + 频繁清场"划算**，日常改 `.c` 完全帮不上（瓶颈在链接）。且首次填充反而慢 36%，需先预热。
4. `export CC="ccache gcc"` **无效**——kbuild 顶层 `Makefile` 的 `CC = $(CROSS_COMPILE)gcc` 是简单赋值会覆盖环境变量，必须命令行传参。

### 采用的工作流

**决定：不启用 ccache，不为链接做优化。**

- 改代码验证语法 → `make <目标>.o`，约 2 秒
- 需要确认能挂上 → 完整 `make -j6`，约 40 秒
- 判断"有没有变快"看**单元数**（4584）与产物大小，不看秒数（秒数有 ±24s 机器抖动）

上述 38s 链接开销是 4800 万行 Linux 树的代价；重写的 mini 内核规模小一到两个数量级，完整回环预期 2~3 秒，无需任何加速手段。

---

## 事故记录：轮3 把驱动架构砍掉了（2026-11-11）

### 事实

| 轮次 | ATA | SATA_AHCI | BLK_DEV_SD | SCSI | MD/BLK_DEV_DM | USB_XHCI |
|---|---|---|---|---|---|---|
| 基线 | y | y | y | y | y | y |
| 轮2 (12m24s) | y | y | y | y | **丢** | y |
| 轮3 (10m34s) | 丢 | 丢 | 丢 | 丢 | 丢 | 丢 |
| 轮5 (7m53s) | 丢 | 丢 | 丢 | 丢 | 丢 | 丢 |

轮3 一次性关掉 **357 项**，`CONFIG_ATA`、`BLK_DEV_SD`、`SCSI`、`DRM`、`FB_EFI`、`USB_XHCI_HCD` 全没了。
轮2 丢 DM 的根因：`BLK_DEV_DM` 在 `menuconfig MD` 之内，`MD=n` 会把整块 DM 隐藏，单独设 `BLK_DEV_DM=y` 会被 olddefconfig 静默丢掉。

### 后果

本机 `/dev/mapper/ubuntu--vg-ubuntu--lv` 是 LVM，根盘走 **AHCI(SATA) → SCSI → sd → dm**。
缺任何一环：GRUB 装得上镜像 → 内核启动 → 找不到根盘 → `VFS: Unable to mount root fs` → panic。必错，非概率。

### 为什么没被发现

判定标准只有"编译单元数下降"，验证只有 QEMU + **virtio-blk**。
virtio 链路不需要 ATA/SCSI/dm，所以"能挂 ext4 = PASS"一直成立，真实 SATA+LVM 链路从未被覆盖。

### 规则（新增，必须遵守）

1. **驱动架构不参与裁剪。** 与用户既定原则"驱动复用，包括驱动架构"一致。
2. **QEMU PASS ≠ 上机 PASS。** 每轮裁剪后必须过一遍真实硬件清单（见下），任何一项由 y/m 变 n 即判 FAIL，不得继续下一轮。
3. **`MD` 是 DM/LVM 的闸门。** 改 DM 相关必须同时确认 `CONFIG_MD=y`。
4. 上机前先确认 `/boot` 余量与**内核版本串**：与在运行内核同名时，`modules_install` 会覆盖现役 247M 模块目录（含 nvidia 595.99.02 DKMS）。

### 真实硬件必需清单（本机，2026-11-11 实测）

lspci：AMD FCH SATA(AHCI) ×3 / AMD 400 Series xHCI / RTL8111(R8169) / NVIDIA GA102。根盘 sda3 → LVM → ext4。

```
ATA SATA_AHCI SATA_AHCI_PLATFORM SCSI BLK_DEV_SD
MD BLK_DEV_DM DM_BUFIO DM_CRYPT            # LVM 根盘，不可缺
EXT4_FS BLK_DEV_INITRD RD_GZIP TMPFS DEVTMPFS
DRM DRM_KMS_HELPER DRM_FBDEV_EMULATION FB FB_EFI FRAMEBUFFER_CONSOLE VT_CONSOLE SYSFB_SIMPLEFB
USB_SUPPORT USB_XHCI_HCD USB_HID HID_GENERIC USB_STORAGE INPUT_EVDEV
R8169 SERIAL_8250 SERIAL_8250_CONSOLE
EFI EFI_STUB EFIVAR_FS CRYPTO CRYPTO_CBC CRYPTO_XTS
MODULES IO_URING                             # nvidia DKMS 需要 MODULES
```

### 修复状态

以轮5 为底，恢复 439 项（存储34 / DRM22 / USB-输入131 / 网络1 / EFI-PCI5 / 加解密7 / 其他241），
`make olddefconfig` 后 `=y 2158 / =m 641`；`make drivers/md/` 退出码 0，`dm.o`、`dm-crypt.o` 已产出。
备份：`/tmp/config-round5-before-fix.bak`。

后续进展（2026-11-11）：

| 阶段 | 结果 |
|---|---|
| 全量编译 + 装机 | PASS，7m53s，已设为 GRUB 默认 |
| 二次改动补 6 项（squashfs/xz、vfat、fat、fuse、ipv6） | PASS，增量 274 s，覆盖安装 |
| 当前 config | `configs/config-7.2.12-20261111-hwreal`，`=y 2200 / =m 701`，701 个 `.ko`（含音频） |
| 旧 `.prev` 备份 | 已清理，释放 441 M |

**唯一未完成的一项**：新内核尚未重启验证（§4.5 的八项验收跑在重启之后）。

---

## 下一步：把它装到真机上

本文只管"怎么裁"。裁完到能在本机开机，中间还有版本串、modules_install、initrd（LVM 用户态）、
DKMS 重编、GRUB 默认项、四项验收、回退这一串动作，全部写在 **[`docs/build.md`](docs/build.md)**。
装机用的 config 就是 `configs/config-7.2.12-20261111-hwreal`（已入库）。
