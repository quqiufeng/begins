# 源码树裁剪记录（/x96-build/7.2.12-trim）

## 0. 目标机硬件（192.168.1.121 实测，2026-11-15 20:01）

裁剪的唯一目的是让这棵树上编出的内核能跑在这块板子上、并且只跑这块板子。硬件是裁剪判据的最终依据，故置于文档头部。

| 项 | 实测值 | 裁剪含义 |
|---|---|---|
| 板卡 | `Amediatech X96 Max`，compatible `amediatech,x96-max` / `amlogic,g12a` | 只留 `arch/arm64` + `arch/arm64/boot/dts/amlogic`，其余架构无争议可删 |
| SoC | Amlogic G12A（S905X2 家族） | 平台驱动只需 `CONFIG_ARCH_MESON` 一系 |
| CPU | 4 × Cortex-A53 r0p4，1000–1800 MHz，64 位；flags 含 `aes pmull sha1 sha2 crc32` | `CONFIG_ARM64_CRYPTO` 的 aes/sha 加速有意义；无 SVE/SVE2 |
| 内存 | 3.7 GiB 可用（4 GB 板），无 swap | 内存吃紧，KASAN/DEBUG_* 类调试项必须关 |
| 存储 | `sda` 29.3 G（U 盘：`BOOT` 511M vfat + `ROOTFS` 28.8G ext4，**当前系统在此**）；`mmcblk1` eMMC 58.2 G（`BOOT_EMMC` + `ROOTFS_EMMC`，闲置）；`mmcblk1boot0/boot1` 各 4 M | 需要 `CONFIG_MMC_MESON_GX`、USB 存储、ext4/vfat；eMMC 在用故保留 MMC 栈 |
| GPU | Mali（`panfrost` + `gpu_sched` 已加载），G12A 对应 Mali-G31 MP2 | 保留 `DRM_PANFROST`，其余 GPU 驱动全关 |
| 显示 | `meson-drm`（`vpu@ff900000`），`card0-HDMI-A-1` = connected，模式 1920x1080 | 保留 `DRM_MESON`；HDMI 音频需 `SND_SOC_MESON_G12A_TOHDMITX` |
| 视频硬解 | `meson_vdec` 已加载（H.264/H.265/VP9） | 保留 `VIDEO_MESON_VDEC` + `VIDEO_DEV` 最小集；tuner/DVB 全关 |
| 有线网 | `eth0` 192.168.1.121/24，含公网 IPv6 `240e:390:aaa:a60::b/128` | 保留 `STMMAC_ETH`/`DWMAC_MESON`；IPv6 在用，勿关 |
| 无线 | RTL8822BS，SDIO 接口（`rtw88_8822bs` + `rtw88_sdio` + `rtw88_core` + `mac80211`） | 保留 `RTW88` 一系 + `CFG80211`/`MAC80211`；其余 wifi 厂商全关 |
| 蓝牙 | 芯片有（8822BS 组合），驱动未加载 | 当前未用，可裁；若日后要用需补 `BT_HCIUART`/`RTW88` bt 支持 |
| 音频 | `meson AXG` 模块齐全（HDMI TX / S/PDIF / TDM / FRDDR / FIFO），但 `/proc/asound/cards` = `--- no soundcards ---` | 声卡未注册成功，**属软件缺口**；裁剪时勿删 `SND_SOC_MESON_*`，否则更难修 |
| 红外 | `rc0` 存在（遥控接收可用） | 保留 `RC_CORE` + meson IR |
| USB | USB2 + USB3 两个根 hub；插着 `Teclast CoolFlash` U 盘 | 保留 `USB_XHCI/DWC3`；其它 USB 外设类驱动可裁 |
| 温度 | `cpu-thermal` 41.0 ℃、`ddr-thermal` 41.4 ℃（空闲） | 散热余量足，无需温控相关额外选项 |
| 运行内核 | `7.2.12-x96`，`#1 SMP PREEMPT_DYNAMIC`，构建于 2026-11-15 18:11 CST | 与本文档裁剪目标树同源 |

**由硬件直接确定的硬约束**：① 架构只可能是 arm64（`arch/arm`、`arch/x86` 等 `FORCEKILL` 无风险）；② 只跑一块 Amlogic G12A 板，故 `FORCEKILL` 掉 323 个"仍有活符号"的候选目录里的绝大多数是对的（活符号多来自多平台共性代码）；③ 调试类大项（`DEBUG_INFO` / `KASAN` / `FTRACE`）在 3.7G 内存 + 1800MHz A53 上应全部关闭，这是体积与编译时间的主要来源，与目录删减是两条独立的轴。

## 0.1 环境

| 项 | 值 |
|---|---|
| 目标树 `KTREE` | `/x96-build/7.2.12-trim`（裁前 **1783 MB / 94775 文件**） |
| 源包 | linux-7.2.12.tar.xz（上游 7.2.12） |
| config `KCONFIG` | `~/kernel/x96max/kernel/config-7.2.12-x96-full`（180029 B） |
| 工具 | `/x96-build/trim-tools` → `~/kernel/x96max/trim-tools`（`prune_src.py` / `fix_sources.py` / `fix_makefiles2.py`，判据单点在 `~/kernel/tools/trim/trimlib.py`） |
| 规则 `RULES` | `trim-tools/rules.txt`（469 行：`KILL` / `FORCEKILL` / `PROTECT`） |
| 补回源 `KTREE_ORIG` | **改用 `/x96-build/.trim-orig`**（从同一 tar.xz 抽出的 6 处切片）。原默认 `/opt/linux/src/linux-7.2.12` 在本机**不存在**，而 `prune_src.py --apply` 必须从它补回。 |
| 时间 | 2026-11-15 19:46 CST |

判据（`trimlib.judge`，任一命中即保留）：① 目录 Makefile 的 `CONFIG_*` ∩ config `=y/=m`；② 父 Makefile
`obj-$(CONFIG_X) += dir/` 且 X 在 config 里 `=y`；③ `rules.txt` 的 `PROTECT`（只删代码留头文件的目录）。
三者都不命中才删。`FORCEKILL` 跳过判据直接删，删完按 `restore.txt` 补回。

## 1. 谁可以裁减（23 个目录，逐项列依据）

`prune_src.py` dry-run：**可删 23 个，合计 328 MB / 3906479 行**；另 323 个候选目录因仍有活符号保留（见 §1.2）。

判定链：`trimlib.judge` 三层判据（①目录 Makefile 的 `CONFIG_*` ∩ config `=y/=m`；②父 Makefile
`obj-$(CONFIG_X) += dir/` 且 X 在 config 里 `=y`；③`rules.txt` 的 `PROTECT`）任一命中即保留；
`rules.txt` 里的 `FORCEKILL`/`KILL` 有否决权（先删，再按 `restore.txt` 补回切片）。

### 1.1 待删清单

| # | 体积 | 行数 | 目录 | 谁判定可裁 | 补回/注意事项 |
|---|---|---|---|---|---|
| 1 | 8M | 156110 | `rust` | rules.txt `FORCEKILL rust`（顶层 Makefile clean 目标引用 rust/libmacros.so → 整删+整目录补回） | 整目录补回 7.1M/585 |
| 2 | 103M | 1418891 | `tools` | rules.txt `KILL tools`（scripts/Makefile 只要 tools/include，其余 1400 万行全删） | 补回 `tools/include` 2.0M/255 |
| 3 | 5M | 84154 | `arch/sh` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 4 | 2M | 26885 | `arch/arc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 5 | 39M | 288892 | `arch/arm` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/arm/boot/dts` 27M/2916 |
| 6 | 17M | 473371 | `arch/x86` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/x86/entry/syscalls` 44K/3 |
| 7 | 1M | 14134 | `arch/csky` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 8 | 7M | 152577 | `arch/m68k` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 9 | 13M | 292211 | `arch/mips` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 10 | 5M | 118487 | `arch/s390` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 11 | 3M | 53339 | `arch/alpha` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 12 | 1M | 9183 | `arch/nios2` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 13 | 5M | 68489 | `arch/riscv` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/riscv/boot/dts` 1.2M/130 |
| 14 | 5M | 123602 | `arch/sparc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 15 | 3M | 63928 | `arch/parisc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 16 | 2M | 32845 | `arch/xtensa` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 17 | 1M | 10105 | `arch/hexagon` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 18 | 18M | 439820 | `arch/powerpc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 19 | 1M | 11409 | `arch/openrisc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 20 | 84M | 1031 | `Documentation` | rules.txt `KILL Documentation`（build/clean/Image 均不读；`dt_binding_check` 才读 yaml） | 另需删顶层 Makefile:1332 `clean-dirs` 里的 Documentation，否则 `make clean` 直接 Error 2；代价：`make htmldocs`/`dt_binding_check` 不可用 |
| 21 | 3M | 49580 | `arch/loongarch` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 22 | 1M | 13778 | `arch/microblaze` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 23 | 1M | 3658 | `drivers/block/aoe` | rules.txt `KILL drivers/block/aoe`（config 无 CONFIG_ATA_OVER_ETH） | 无外部引用（ATA over Ethernet，config 里 CONFIG_ATA_OVER_ETH 未开） |

**小计：23 个目录 / 328 MB / 3906479 行**；其中 `rules.txt` 显式指定 23/23（20 个 arch + rust + tools + Documentation + aoe），纯自动判据得出的 0 个——即本轮每一刀都有人工确认过。

> `rules.txt` 的对应行：`FORCEKILL` 424–465、`KILL tools` 464、`KILL Documentation` 469、
> `KILL drivers/block/aoe` 12。20 个非 arm64 架构同属一条人工结论。

### 1.2 被保留的 323 个候选（有活符号，不能整删）

| 保留原因 | 数量 | 说明 |
|---|---|---|
| 目录 Makefile 出现 `=y/=m` 的 `CONFIG_*` | 51 | 判据①命中，例：`fs/fat` 4 个 `=y/=m` 符号 |
| Kconfig 归属的 `=y/=m` 符号 | 2 | 判据①变体 |
| 父 Makefile `obj-$(CONFIG_X) += dir/`，config 里没有 X | 213 | 判据②只认父 Makefile 字面；X 不在 config 时仍保留（保守），典型：`fs/9p`、`fs/ext2`、`fs/xfs`、`net/9p` |
| 其它（Makefile 引用 `COMPAT`/`SYSCTL` 等 =y 符号） | 57 | 例：`fs/nfs`、`fs/fuse`、`fs/xfs` |

这 213 + 57 项是**下一轮的真实增量空间**：它们要么靠 config 里根本不存在的 CONFIG、
要么靠 `obj-$(COMPAT)` 这类非配置符号被粘住，需要逐个人工确认后才能进 `FORCEKILL`。

## 2. `--apply` 后必须补回的 6 处切片（restore.txt，42 MB）

| 体积 | 切片 | 谁硬引用它 |
|---|---|---|
| 27M | `arch/arm/boot/dts` | arm64 allwinner dtsi 跨架构 `#include <arm/allwinner/sunxi-h3-h5.dtsi>`（`make dtbs`） |
| 8M | `rust` | 顶层 Makefile clean 目标列了 `rust/libmacros.so` |
| 2M | `arch/um` | `fs/Makefile` 无条件 `obj-y += hostfs/`，`fs/hostfs/Makefile` 末行 include |
| 2M | `tools/include` | `scripts/Makefile:32-38` 给 `elf-parse.o`/`sorttable.o` 加 `-I$(srctree)/tools/include` |
| 2M | `arch/riscv/boot/dts` | arm64 `sophgo/sg2000.dtsi` include `riscv/sophgo/cv180x.dtsi` |
| 1M | `arch/x86/entry/syscalls` | `scripts/checksyscalls.sh` 读 `syscall_32.tbl` |

**净体积预估 = 328 MB − 42 MB = 286 MB** → 树应从 1783 MB 降到约 1497 MB。

## 3. 执行步骤

1. 从 tar.xz 抽出 6 处切片到 `/x96-build/.trim-orig`（充当 `KTREE_ORIG`）；
2. `KTREE=/x96-build/7.2.12-trim KTREE_ORIG=/x96-build/.trim-orig ./prune_src.py --apply`
   （删 23 目录 + 清父 Kconfig 的 `source` 行 + 补回 6 切片）；
3. `./fix_sources.py`（清指向已删目录的 `source` 行，含 `$` 变量的行跳过）；
4. `./fix_makefiles2.py`（按逻辑行削父 Makefile 里 `obj-* += 已删目录/`，否则 kbuild 直接失败）；
5. `KILL Documentation` 还要删顶层 `Makefile` 的 `clean-dirs` 那一项，否则 `make clean` 报
   `scripts/Makefile.clean:12: Documentation/Makefile: 没有那个文件或目录`；
6. 复跑 dry-run 验证：去掉 `FORCEKILL` 项后应「可删 0 个」，净体积 ≈ 0。

## 4. 实测结果（drivers 目录级清理已执行，2026-11-15 20:07 CST）

### 4.1 现状快照

| 项 | 裁前（§0.1） | 现在 | 变化 |
|---|---|---|---|
| 整树体积 | 1783 MB | **1720 MB** | −63 MB |
| 文件数 | 94775 | 91451 | −3324 |
| `drivers/` | 1163 MB | **1100 MB** | −63 MB |
| `drivers/` 一级目录 | 144 | **86** | −58 |

> **注意**：§1 那 23 项（`Documentation` 84M / `tools` 103M / `rust` 8M / 20 个非 arm64 `arch/*` ≈ 133M / `aoe`）
> **全部尚未执行**，本次落地的只有 drivers 子树级清理。§2/§3 的补回与 `fix_*` 步骤也仍在待办。
> 即 1720 MB 距 §1 预估的 1497 MB 还差 223 MB，缺口就在这 23 项上。

### 4.2 本次删除：`drivers/` 下 58 个设备子树

清单落盘：`/x96-build/7.2.12-trim/.trim-drivers-removed-20261115.txt`（含逐项体积、判据、恢复命令）。

```
accel(16M) infiniband(14M) mtd(6M) s390(5M) comedi(4M) interconnect(3M) message(2M)
target(2M) thunderbolt(2M) vfio(2M) gpib(2M) atm(1M) accessibility bcma cdx counter
dca dibs dio dpll eisa fpga fsi fwctl gnss greybus hsi hte hv hwspinlock ipack mcb
memstick most ntb nubus nvdimm parisc parport pcmcia peci powercap ps3 rapidio
remoteproc rpmsg sbus sh siox slimbus soundwire ssb tc uio vdpa w1 xen zorro（无标注=1M）
```

### 4.3 判据更换（**重要，§1 的旧判据在此被证明不可靠**）

原方法是拿 121 上的 `modules.builtin` + `modules.order` 反推"哪些驱动在用"，得到 85 个候选。
**这个判据会误删核心子系统**——凡是纯基础设施、没有 `module_init` 的 builtin 都不进
`modules.builtin`，实测被它判成"死代码"的包括：

`ata`(CONFIG_ATA=y) `md`(MD=y, DM_CRYPT=y) `of`(OF=y，设备树核心) `clocksource`(ARM_ARCH_TIMER=y，
系统时钟) `cpuidle`(ARM_PSCI_CPUIDLE=y) `memory` `opp` `pnp` `ras` `vhost` `platform`。

**改用真实判据**：解析 `drivers/Makefile` 里每个子目录的**门控 CONFIG**，代入
`config-7.2.12-x96-full` 求值——门控为 `n`/未定义 ⇒ 编译流程根本不进入该目录 ⇒ 删掉对构建零影响。

四类处理结果：

| 分类 | 数量 | 例子 |
|---|---|---|
| 门控 CONFIG 已关 → **删** | 58 | `infiniband`(CONFIG_INFINIBAND 未开)、`xen`、`vfio`、`mtd` |
| 无条件 `obj-y` → **留**（删须改 Makefile） | 15 | `clocksource` `android`(BINDERFS) `misc`(SRAM) `platform` `cdrom` `cache` `idle` `auxdisplay` `amba` `cxl` `firewire` `i3c` `macintosh` `nfc` `resctrl` |
| 门控 CONFIG 仍 `=y/m` → **留** | 10 | `ata` `cpuidle` `md` `memory` `of` `opp` `pnp` `ras` `vhost` `hwtracing` |
| 无直接条目/多条目 → 逐项核对后归入上列 | — | `hwtracing` 拆成 coresight/intel_th/stm/ptt 四条门控 |

### 4.4 双重校验

1. **符号级**：58 个子树自身及其子 Makefile 内**没有任何 `=y`/`=m` 的 `CONFIG_*` 引用**（逐条 grep + 回代 config 确认，输出为空）。
2. **结构级**：删完后反向解析 `drivers/Makefile`，检查"门控已启用但目录缺失" →
   `缺失且被启用: 无 (OK)`，即 kbuild 不会因缺目录报错。

### 4.5 恢复方式

```bash
tar -xJf /opt/linux/src/linux-7.2.12.tar.xz --wildcards 'linux-7.2.12/drivers/NAME/*'
```

### 4.6 收益偏小的原因与下一轮方向

只有 63 MB / 5%，因为真正的大户是**在用**目录的内部内容，而非整目录：
`drivers/gpu` 607M（只用 `meson` + `panfrost`/Mali-G31，其余厂商 500M+ 是死代码）、
`drivers/net` 161M、`drivers/media` 50M、`drivers/scsi` 31M。

下一轮必须从"目录级"下沉到**"文件级"**：按 config 逐个检查子目录内驱动文件（判据同上——取子目录
Makefile 门控 CONFIG 求值），这才是把 1720 MB 压到 800 MB 量级的主要空间。
