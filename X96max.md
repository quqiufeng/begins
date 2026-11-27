# X96 Max（Amlogic S905X2）— 硬件记录与源码构建/刷机流程

> 设备：X96 Max 4GB（AMedia X96 Max / Amlogic S905X2）
> 主机名：`x96src`；局域网 IP：`192.168.1.121`（DHCP，可能变化）
> 当前系统：eMMC 上的**源码构建 + 裁剪 rootfs**（Armbian build framework + mmdebstrap，Armbian 26.11.0 trixie，155 包）+ 自编译 `7.2.12-x96`（主线 U-Boot）；原商家系统为 Debian 12 bookworm + `6.12.112-ophub`。
> 最近一次整车重建（2026-11-15 09:18→09:28，`sudo x96max/rebuild-from-zero.sh --from image`）：交付镜像 `/x96-build/recovery/x96src-autoinstall.img.gz` 272M，sha256 `13ece9df…b5b1ad1`。
> 本文目标：记录硬件、现有系统打包方式，以及**从 Linux 7.2.12 源码编译内核 → 源码构建 rootfs → ophub 打包 → SD/U 盘验证 → eMMC 安装 → 体积裁剪** 的完整过程。
> 状态：**已成功从 eMMC 启动裁剪后的源码系统**（155 包，rootfs ~568M；主线 U-Boot）。
> 无线策略（2026-11 更新）：**目标是保留 Wi-Fi/蓝牙驱动与固件**（RTL8822BS → `rtw88_8822bs` + `btrtl`），内核里不再 `-d` 关闭；有线 RTL8211F 仍是主用网络。
> ⚠️ **当前构建尚未达成**：裁剪树里 `net/wireless`、`net/mac80211`、`drivers/net/wireless/` 已整目录删除，配置里也没有 `RTW88*`，所以 7.2.12-x96 的内核**没有 Wi-Fi 驱动**（蓝牙源码 48 项还在，但 `CONFIG_BT*` 未开）。补法见 §0.3。
> 仓库脚本：**本仓库 `x96max/`**（`build-image.sh` 一键镜像、`write-card.sh` 安全写卡 + 校验、`config-x96-source.conf` rootfs 配置、`x96-autoinstall.*` 首启自动安装、`x96max/kernel/config-7.2.12-x96-full` 最终内核配置、`mkbase.sh` 自造 rebuild 基础镜像）。
> 📌 **最新（2026-11-15 17:08）**：裁掉目录会连带删掉 `Kconfig` → 符号静默消失。同配置下裁剪树比全量树少 **1789 个符号**（含 genpd/`HW_PERF_EVENTS`/`USB_GADGET`），`Image` 35.9→42.2MB。全量树已编好（`/x96-build/kbuild-clean`，**2026-11-15 19:12 已连同目录删除**，只保留其 `.config` → `configs/config-7.2.12-fulltree-baseline-20261115`，257801 B / sha1 `63ae9299`），尚未打包上机。详见 **§5.7**。
> 📌 **新系统第一件事是校时（2026-11-15 17:55）**：镜像里**没有装任何 NTP 客户端**（`timesyncd`/`chrony`/`ntp` 全无），盒子 RTC 走偏后 `apt-get update` 会以 `is not signed` / `Not live until …` 报错，看着像源坏了其实是时钟错了。装 `systemd-timesyncd` + 国内 NTP 后全绿。详见 **§20**。

---

## 0. 当前任务单（2026-11-15 14:35）

**要做的事**：打包一个 X96 Max 安装镜像，走 ophub 打包流程，但内核必须用**裁剪过的源码树自编译**（不是 ophub 现成内核）。

固定输入（不许换成别的）：

| 项 | 路径 |
|---|---|
| 源码树 | 全量套 `/x96-build/src-clean`（1.8G，未裁剪，必须留）；另有 `src-full`（**按需解压，可删**，见 §21.5） |
| 内核 `O=` 输出 | `/x96-build/kbuild-trim`（现役；旧的 `kbuild-7.2.12` 2026-11-15 19:15 已删） |
| 内核配置 | `/home/quqiufeng/kernel/x96max/kernel/config-7.2.12-x96-full`（`LOCALVERSION=-x96`，**必须含 FAT**） |
| 脚本 | `/home/quqiufeng/kernel/x96max/*.sh` |
| 目标产物 | 可刷 `img.gz`（ophub 布局，首启自动装 eMMC） |

**命名约定（2026-11-15 19:00）**：内核配置名里 `-full` = 全量未裁剪，`-trim` = 硬件裁剪版；
`configs/` 归档同名再加日期。设备/包里的 `boot/config-7.2.12-x96` 是**产物名**（与 `vmlinuz-7.2.12-x96` 同名，
因 `LOCALVERSION=-x96`），不带 `-full/-trim`，别跟着改。

**两份配置别混用（2026-11-15 18:40 定稿）**：

| 文件 | sha256 | 行 / `=y` / `=m` | 对应内核 |
|---|---|---|---|
| `x96max/kernel/config-7.2.12-x96-full`（`configs/` 归档副本已删，2026-11-15） | `e137d0d5…08c94` | 6706 / 2506 / 1 | **裁剪前**全量配置，编 `kbuild-7.2.12/Image`（35.8MB，§5） |
| `configs/config-7.2.12-x96-trim-final-20261115` = `x96max/kernel/config-7.2.12-x96-trim` | `c4c802d5…6482a` | 8258 / 2084 / 167 | **当前运行内核**，编 `kbuild-trim/Image`（32.1MB），fragment 见 `configs/trim2-20261115.fragment`（`-final` 在其上补回 btrfs/CIFS/VXLAN、netfilter 匹配等，旧归档 `-trim-20261115` 已删） |

判据（已实测）：`kbuild-trim/.config`、唯一 trim 归档、`x96max/kernel/config-7.2.12-x96-trim`、盒子 `/proc/config.gz` 四者 sha256 **完全相同**；
`/boot/vmlinuz-7.2.12-x96` 与 `kbuild-trim/arch/arm64/boot/Image` 同为 `69124869…8ae8f7`。
相对全量版共关闭 **690** 个 `=y`（`ARCH_SUNXI/ROCKCHIP`、整套 `KVM`、大半 `ACPI_*`、`BINFMT_MISC` 等），
反向新开 BPF 组（`BPF_SYSCALL/BPF_JIT`）。trim 版 `=m` 有 167 条但只落 154 个 `.ko`：差的是
`CONFIG_IP6_NF_FILTER→ip6table_filter.ko` 这类改名，抽查 `nf_tables`/`panfrost`/`snd-soc-meson-aiu` 全在，非缺失。

**进度（卡在这里）**：

1. ✅ 补回被裁掉的 FAT 支持：源码 `fs/fat/` 已回，钩子 `fs/Kconfig:136`、`fs/Makefile:55` 已接，配置加 `FAT_FS/MSDOS_FS/VFAT_FS=y` + `FAT_DEFAULT_UTF8/codepage=437/iocharset=utf8`。原因：p1 是 FAT32，缺 FAT 则 `/boot` 挂不上。
   - 合并后的配置已落到**唯一权威路径**（14:43 编写 `Image` 时与 `kbuild-7.2.12/.config` 逐字节相同；该树 `.config` 后来在 16:58 被另一轮 `olddefconfig` 改成了 `b71c4f6c…`，**归档的 `e137d0d5…` 才是编出 35.8MB Image 的那份**）：`x96max/kernel/config-7.2.12-x96-full`（`build-kernel.sh` / `rebuild-from-zero.sh` 的默认 CFG，**唯一留存的 full 配置**；`configs/` 里那份归档已于 2026-11-15 删，需要时 `git show` 从 `1edfd41` 取回）。`/x96-build/config-x96-20261115-fat` 只是同一份的临时副本，不再作为入口。
2. ✅ 内核已编出：`/x96-build/kbuild-7.2.12/arch/arm64/boot/Image`，14:23，35.9MB；`.config` 三项 `=y`，`strings Image | grep -x vfat` 命中。
3. ✅ **重打包四件套**：`./x96max/pack-kernel.sh` 已在 14:59 跑完，`/x96-build/pkgs/` 全是新时间戳（boot 36.9M / dtb 10.7K / header 13.4M / modules 239K + `sha256sums`）。
4. ✅ **重出镜像**：`./x96max/rebuild-from-zero.sh --from image` 已在 15:07 出图 `/x96-build/recovery/x96src-autoinstall.img.gz`（284662631 B），时间晚于 14:58 的 `Image`，即含 FAT 的新内核。
   - 注意：`.config` 与归档配置的 md5 不同（`0719a0d0…` vs `3a3b318a…`）—— 后者是 merged/归档版，前者是 olddefconfig 后的实编版，二者**不等价属正常**，判据看 §0 第 1 条的结论而不是 md5 相等。
5. ✅ **已装上 eMMC 并启动成功**（2026-11-15 15:32 屏幕取证）：`x96src login:` 出现，日志里有
   `FAT-fs (mmcblk1p1): utf8 is not a recommended IO charset…` —— p1 是 FAT32 且**挂上了**，同时出现 `utf8` 提示说明 `FAT_DEFAULT_UTF8=y` 生效，即**跑的就是 15:07 那份含 FAT 的新内核**（旧内核无 FAT 会直接卡在挂 /boot）。
   `mmcblk1: p1 p2` 反复被打出来是首次启动 growpart/resize 的重扫，正常。
   开机耗时 `~30s` 到 login，曲线与旧系统一致，无 `I/O error` / `reset`，USB 掉盘问题不再出现（走的是 eMMC，本就不涉及）。
6. ⬜ **无线缺口**：当前树/配置里没有 `net/wireless`、`net/mac80211`、`drivers/net/wireless`，`CONFIG_RTW88*`、`CONFIG_BT*` 全未开 → 内核无 Wi-Fi/蓝牙驱动（有线正常）。补法与证据见 §0.3；这一项不动也不影响 FAT 这条主线。
7. ⬜ **U 盘在盒子上读一半掉线**（`sda` sector 1427360 / 697MiB，`cmd_age=30s` + xhci `reset`）：卡本身没问题（PC 上 `verify-card.sh` 全绿），是盒子 USB3 口只以 `high-speed`(480M) 枚举 USB3 盘所致。eMMC 未被写入。排查顺序与 `patch-bootargs.sh --usb-fix` 见 §10.2.2。
8. ⬜ **(16:34 复发，变体更狠)** `hostbyte=0x07` + `cmd_age=0s`，复位呈 ~30s 周期、始终不恢复，开机卡死在 initramfs 的 `e2fsck`。
   `quirks` + `autosuspend` 已在 `APPEND` 里且无效；结合 15:31「PC 上也掉过」→ **盘/接口在衰减**。
   处置：**换 microSD 走内部 MMC 控制器**（§10.2.2 补充二，已列为第 1 选项）。
9. 🔧 **initramfs 抢跑：U 盘根盘枚举晚 1.3 秒，先被判「UUID 不存在」**（`t=39.64s` 放弃 / `t=40.94s` 才出 `[sda]`）。
   **与第 1~3 条无关**：`CONFIG_USB_STORAGE` 早已 `=y`、`[sda]` 也确实出现了——同一句 `Gave up waiting` 的第二种成因，§5.4 的三条断言全过仍会撞上。
   - 应急：`(initramfs)` 里敲 `exit`，会重跑一轮 `mountroot` 并挂上，不用重启。
   - **`rootdelay=15` 是无效解，已弃用**（2026-11-15 读 `init`/`scripts/local` 源码证伪，见 §5.5「为什么 rootdelay 没用」）：`init` 先记 `starttime` 再 `sleep rootdelay`，而 `slumber=max(30, rootdelay)` → 15 秒只是从 30 秒预算里挖掉 15 秒，放弃时刻只提前、不推迟。
   - 固修（已写入卡 p1，**待真机复验**）：`x96max/patch-initrd-wait.sh` 把 initramfs 里 `scripts/local` 的 `slumber` 由 `30` 改成 `90`，重打包成 `uInitrd`；`uEnv.txt` 的 `rootdelay=15` 已用 `-r` 删除（`APPEND` 21 参数，`usb-storage.quirks=346d:5678:u` / `usbcore.autosuspend=-1` 保留）。
   - 卡上**两份** uInitrd 都已打（16:27 `/uInitrd`、16:30 `/uInitrd-7.2.12-x96`），`--check` 均回读 `slumber=90`（判据见 §10.1.1 第 6 步）。
   - **16:34 那次开机仍未验证到它**：根盘被第 8 条的掉盘打死在 `e2fsck`，根本没走到「等 root 设备」那一步。
     「`slumber=90` 有效」目前只有源码推理，**没有真机证据**——要等根盘能正常挂上那天才算验过。
   - 判据表 + 可复现步骤见 **§5.5**；`rebuild-from-zero.sh --from initrd` 已内置该补丁，重打镜像不会回退。
10. ⚠️ **`/x96-build/boot-good` 与 `boot-bad` 名字是反的**（16:53 复盘）：`boot-good` 里是**未修**的 `slumber=30`，`boot-bad` 里才是修好的 `90`。
   16:48 按目录名回写卡，等于把修好的换回坏的，`Gave up waiting` 重现。判据一律用 `patch-initrd-wait.sh --check`，不看目录名/时间戳。见 §5.6。
11. ✅ **裁剪树的隐性代价已量化**（16:58→17:08 对照实验）：同一份起始配置下，全量树编出的 `.config` 比裁剪树多 **1789 个符号**（345 个 `=y`、1433 个 `=m`），其中含 `PM_GENERIC_DOMAINS(_OF)`、`ARM_PSCI_CPUIDLE_DOMAIN`、`HW_PERF_EVENTS`、`USB_GADGET` 全家、`USB_SERIAL_*`。
   `Image` 35.9MB（裁剪）→ **42.2MB**（全量）。裁剪不是"少编几个驱动"，是**连带删 Kconfig 让符号静默消失**。见 §5.7。
   - 产物就绪：`/x96-build/src-clean`（全量树 1.8G）+ `/x96-build/kbuild-clean`（800M，`arch/arm64/boot/Image` 17:08，42220032 B），日志 `/x96-build/build-clean.log`（6204 行，无 error）。
   - **下一步（未做）**：用 `kbuild-clean/Image` 走 `pack-kernel.sh` → `--from initrd` → `--from image`，替换卡上的 35.9MB 内核，真机复验第 8 条掉盘是否与 genpd 缺失有关。

### 0.1 源码缺失时的补齐来源（唯一权威包）

> ⚠️ **2026-11-15 19:15 起 `src-linux` 与 `kbuild-7.2.12` 已删除**，现在只剩 `src-clean`（全量树，1.8G）
> 与 `kbuild-trim`（736M）。全量树**不缺任何文件**，本节「缺文件要解回来」的流程只在重建裁剪树时才用得到。

裁剪树 `/x96-build/src-linux` 删过整目录，编译报「找不到某文件/某目录」时**不要手写、不要从别处抄**，一律从完整源码包解回来：

```bash
# 完整源码包（160M，顶层目录 linux-7.2.12/，10 月 25 日归档，只读别改）
SRC=/opt/linux/src/linux-7.2.12.tar.xz

# ① 先确认包里有、树里没有（以 fs/fat 为例）
tar -tf $SRC | grep '^linux-7.2.12/fs/fat/'          # 包里 14 个
ls /x96-build/src-linux/fs/fat                        # 树里实际有的

# ② 只解某几个文件（推荐：不动 mtime 之外的任何东西）
cd /tmp && tar -xf $SRC linux-7.2.12/fs/fat/Kconfig
cp /tmp/linux-7.2.12/fs/fat/Kconfig /x96-build/src-linux/fs/fat/

# ③ 或整目录解回（覆盖同目录，先确认没有本地改动）
cd /tmp && tar -xf $SRC linux-7.2.12/fs/fat
cp -a /tmp/linux-7.2.12/fs/fat /x96-build/src-linux/fs/

# ④ 解完补钩子：Kconfig 的 source、Makefile 的 obj-$(CONFIG_xxx) += 目录/
#    （裁剪脚本容易把 menu 段和 obj 行一起删掉，光有目录编不进去）
```

规矩：

- `.kunitconfig`、`Documentation/`、`*.rst`、`Kconfig` 里的 `if FOO_TEST` 段解不解都行，不影响 `Image`；**`Kconfig` / `Makefile` / `*.c` / `*.h` 必须齐**。
- 补完要重新 `olddefconfig`（或直接 `build-kernel.sh`，它自带），让新 symbol 进 `.config`，然后 `strings Image | grep -x <名字>` 验证真进内核。
- 本轮已这样补回 `fs/fat/`（12 个文件，缺 `.kunitconfig`，无影响）。

### 0.2 复现纪律（照此顺序，不许跳步）

**四段有硬依赖，顺序不能换**：配置 → 内核 → 四包 → 镜像。每段都有独立的"产物断言"，断言不过就别往下走。

```bash
cd /home/quqiufeng/kernel
ROOT=/x96-build; OUT=$ROOT/kbuild-7.2.12
CFG1=x96max/kernel/config-7.2.12-x96-full
CFG2=x96max/kernel/config-7.2.12-x96-full
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
KNAME=7.2.12-x96
```

**开工第一步：跑自检**（只读，不改任何东西；19 项全绿才有资格往下走）

```bash
./x96max/preflight.sh || exit 1     # 源码树钩子三连 + 配置 =y + 工具链 + 四个脚本
```

| # | 段 | 命令 | 必须过的断言 |
|---|---|---|---|
| 0 | 配置同源 | `diff -q $CFG1 <(git show 1edfd41:x96max/kernel/config-7.2.12-x96-full)` | 与 e137d0d5 版一致（configs/ 归档已删，只剩这一个入口）；`grep -cE '^CONFIG_(FAT_FS\|MSDOS_FS\|VFAT_FS)=y' $CFG1` = 3 |
| 1 | 编内核 | `sudo ./x96max/rebuild-from-zero.sh --from kernel` | `$OUT/.config` 与 `$CFG1` 相同（`olddefconfig` 不许"优化"掉新符号）；`strings $OUT/arch/arm64/boot/Image \| grep -x vfat` 命中；`grep -x CONFIG_VFAT_FS=y $OUT/.config` |
| 2 | initrd/uInitrd | `--from initrd` | `$ROOT/initrd.img-$KNAME`、`$ROOT/uInitrd-$KNAME` 的 mtime 晚于 Image |
| 3 | 四包 | `./x96max/pack-kernel.sh` | 四个 tar 的 mtime 晚于 Image；`tar -xzOf $K/boot-$KNAME.tar.gz ./vmlinuz-$KNAME \| strings \| grep -qx vfat` 命中 |
| 4 | 镜像 | `./x96max/rebuild-from-zero.sh --from image` | `done.log` 里 sha256 与 `x96-build/pkgs/*` 的新内核时间同一天；`--from image` 的日志里有本次 boot 包大小 |
| 5 | 写卡 | `sudo ./x96max/write-card.sh <img.gz> /dev/sdX` | 逐文件 sha256 全 OK；盒子起来后 `dmesg \| grep -i vfat`、`mount \| grep /boot` |
| 6 | 写卡后**必补 initramfs 等待窗口** | `sudo ./x96max/patch-initrd-wait.sh <卡>/uInitrd --inplace` + `patch-bootargs.sh --usb-fix 346d:5678` | `slumber` 回读为 `90`；`APPEND` 含 `usb-storage.quirks=346d:5678:u` / `usbcore.autosuspend=-1`（缺了必回退 §5.5 竞态，停 initramfs）。**不要加 `rootdelay`** |

**三个已踩过的坑（写进纪律，别再犯）**：

1. **配置入口只有一个**：`rebuild-from-zero.sh` 的 `CFG=$SELF_DIR/kernel/config-$KNAME-$MODE`、`build-kernel.sh` 的 `config-$KNAME-trim|-full`、`preflight.sh` 同款 `$MODE`（`-full` 全量未裁剪 / `-trim` 硬件裁剪）。改配置要改**这里**（并同步 `configs/`），只改 `/x96-build/*` 下的副本等于没改——本轮就因此差点用无 FAT 的配置重编。
2. **`--from pkgs` / `--from image` 不重做内核**：它们只吃 `$OUT/Image` 和 `$K/*.tar.gz`。所以"改了配置/源码 → 必须至少 `--from kernel`（或先手工重编 + `pack-kernel.sh`）"，顺序反了就是拿旧内核再出一遍镜像。
   - 反过来：`--from pkgs` 不会重做 initrd。当前配置下所有驱动 `=y`，`modules-*` 只有 `test_bpf.ko`，所以**只改配置重编 Image 时 initrd 可复用**；哪天开了 `=m`（尤其 usb/storage、ext4、meson 相关），必须 `--from initrd` 重做，否则首启找不到根盘。
3. **写卡 ≠ 可以启动**：`write-card.sh` 只拷镜像，**既不写 `uEnv.txt` 的 APPEND、也不改 `uInitrd`**。每次写完卡必须紧跟第 6 步（`patch-initrd-wait.sh` + `patch-bootargs.sh --usb-fix 346d:5678`），否则 `slumber=30` 撞上 USB 读卡器 `~38s` 枚举，必回退 §5.5 的竞态、卡在 initramfs。两个脚本都幂等，重复跑无副作用。

### 0.3 已知缺口：Wi-Fi 驱动没进内核（下一轮要补）

2026-11-15 核对结果（三条硬证据）：

```bash
ls /x96-build/src-linux/net/wireless /x96-build/src-linux/net/mac80211    # 都不存在
ls /x96-build/src-linux/drivers/net/wireless                             # 空（0 项，含 realtek/rtw88）
grep -c 'RTW88' /x96-build/kbuild-7.2.12/.config                         # 0
strings /x96-build/kbuild-7.2.12/arch/arm64/boot/Image | grep -c rtw88    # 0
tar -tf /opt/linux/src/linux-7.2.12.tar.xz | grep -c 'realtek/rtw88/'    # 99（完整包里有）
```

结论：硬件在（`024c:b822`），固件在（rootfs 里 `rtw88/rtw8822b_fw.bin` 保留着），但**内核里没有驱动**，所以 Wi-Fi 现在是不可用的；蓝牙同理（`drivers/bluetooth` 48 项还在，但 `CONFIG_BT*` 没开）。有线不受影响。

补法（严格按 §0.1 的解包规矩，别手写）：

```bash
SRC=/opt/linux/src/linux-7.2.12.tar.xz
cd /tmp && tar -xf $SRC \
  linux-7.2.12/net/wireless linux-7.2.12/net/mac80211 \
  linux-7.2.12/drivers/net/wireless
cp -a /tmp/linux-7.2.12/net/wireless /tmp/linux-7.2.12/net/mac80211 /x96-build/src-linux/net/
cp -a /tmp/linux-7.2.12/drivers/net/wireless /x96-build/src-linux/drivers/net/

# 钩子必须补回（裁剪脚本会连 obj/Makefile 行一起删，光有目录编不进去）
grep -n 'wireless' /tmp/linux-7.2.12/drivers/net/Makefile /tmp/linux-7.2.12/drivers/net/Kconfig
grep -n 'wireless\|mac80211' /tmp/linux-7.2.12/net/Makefile /tmp/linux-7.2.12/net/Kconfig
# 按完整包里的原样把这几行加回裁剪树的同名文件

# 打开符号（父项先于子项，最后 olddefconfig 复查）
cd /x96-build/src-linux
for s in WLAN CFG80211 MAC80211 RFKILL RTW88 RTW88_SDIO RTW88_8822B RTW88_8822BS \
         BT BT_HCIUART BT_HCIUART_RTL; do
  ./scripts/config --file /x96-build/kbuild-7.2.12/.config -e "$s"
done
make O=/x96-build/kbuild-7.2.12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
grep -E 'CONFIG_(WLAN|CFG80211|MAC80211|RTW88|BT|RFKILL)' /x96-build/kbuild-7.2.12/.config | sort
```

注意两点：

- 一开 `=m` 就破坏"零模块"前提，**必须 `--from initrd` 重做 initrd**（§0.2 坑 2）。
- 补完记得把新配置同步回 `x96max/kernel/config-7.2.12-x96-full`，否则下一轮又回到无 Wi-Fi。

---

### 0.4 新内核首启：唯一真错误是有线网卡 `cannot attach to PHY (-ENODEV)`（2026-11-15 15:34）

屏幕取证（第二张图，启动到 login 之后仍在刷）：

```
meson8b-dwmac ff3f0000.ethernet eth0: Register MEM_TYPE_PAGE_POOL RxQ-0
meson8b-dwmac ff3f0000.ethernet eth0: cannot attach to PHY (error: -ENODEV)
```

**判读**：启动本身成功（DRM/HDMI 起了、fb0 出来了、走到 login），错只在 eth0 拿不到 PHY。
同屏其余几行都是良性噪声，别误判：
- `IRQ eth_wake_irq not found` / `IRQ sfty not found` —— 可选的 WOL/安全中断，没有不影响。
- `DSI transceiver device is disabled` —— X96 Max 没有 DSI 屏。
- `[drm] forcing HDMI-A-1 connector on` —— 强制点亮 HDMI，正常。
- `Active PHY interface: GMII/MII (0)` —— 这是 MAC 的 HW capability 寄存器 `dma_cap.actphyif`，**不是** DT 的 phy-mode，跟 -ENODEV 无关，别当线索。

**离线已排掉的原因（都不用再查）**：
| 检查 | 结果 |
|---|---|
| `drivers/net/phy/realtek/realtek_main.c` | 在（7.x 已把 realtek.c 拆成 realtek/ 子目录，`Makefile` 是 `obj-$(CONFIG_REALTEK_PHY) += realtek/`） |
| Image 里 RTL8211F 驱动 | 在（`RTL8211F Gigabit Ethernet`、`rtl8211f_config_rgmii_delay`） |
| `CONFIG_PHYLIB` / `REALTEK_PHY` / `MDIO_BUS_MUX_MESON_G12A` / `PINCTRL_MESON_G12A` | 全 `=y` |
| `mdio-mux-meson-g12a.c`、`dwmac-meson{,-meson8b}.c` | 在，`amlogic,g12a-mdio-mux` 字符串在 Image |
| 本次 dtb `meson-g12a-x96-max.dtb` 反编译 | `phy-mode = "rgmii"`、`phy-handle`→phy@0、`mdio-multiplexer@4c000` 链到 `mdio-parent-bus` 都正确 |

**7.x 目录搬迁的坑（别把它当"文件被裁"）**：`of_mdio.c`、`phylib` 相关已从 `drivers/net/phy/`
搬到 `drivers/net/mdio/`（`drivers/net/mdio/of_mdio.c` 存在，13KB）。`drivers/net/phy/` 下没有
`of_mdio.c`/`phylib.c` **是正常的**，`CONFIG_OF_MDIO=y` 也没有对应 `obj-` 行在 phy/Makefile 里。
最硬的验收是看 vmlinux 符号，本次实测全部为 `T`（全局，已编入）：
```
of_mdio_find_device  of_phy_find_device  fwnode_phy_find_device
phylink_fwnode_phy_connect  phy_attach_direct  phy_probe
__initcall__kmod_mdio_mux_meson_g12a__686_357_g12a_mdio_mux_driver_init6
```
→ **不需要补文件、不需要重编内核**。

所以**不是配置缺项、也不是 DTB 错**，是运行时 MDIO 上没扫到 PHY。`-ENODEV` 出自
`stmmac_main.c:1356`，上游走的是 `phylink_fwnode_phy_connect()` → `of_phy_find_device()` 返回 NULL，
即 **phy-handle 指向的节点没能注册成 mdio 设备** → 最常见两个原因：
1. G12A 的 MDIO 是多路复用（`amlogic,g12a-mdio-mux`），mux 没探针成功 / 没切到外置 PHY 那一路，
   则外部 PHY 根本不在任何 mdio 总线上；
2. PHY 被 `reset-gpios = <&gpio 15 GPIO_ACTIVE_LOW>` 一直按在复位里，MDIO 读回 0xffffffff。

**若定位结果指向不同修法，编译代价差别很大**：
| 结论 | 改什么 | 代价 |
|---|---|---|
| reset-gpios 时序 / mux 使能 | 只改 `meson-g12a-x96-max.dts` 的 PHY 节点 | **只重编 dtb**：`make ARCH=arm64 dtbs`，秒级；不碰 Image |
| 需换 `phy-mode`（rgmii→rgmii-id 等） | 同上 | 同上 |
| mdio-mux 驱动逻辑 bug | 改 `drivers/net/mdio/mdio-mux-meson-g12a.c` | 增量 `make ARCH=arm64 Image`，约 1–2 分钟 |
| 确认某驱动真被裁掉 | 解回 + 补 Kconfig/Makefile 钩子 | 全量 `build-kernel.sh`，8 分 15 秒 |

即"补文件重编译"是**最坏情况**，且当前所有证据都不支持它。

**上机三条命令定位（登录后跑，网不通就用串口/键盘）**：
```bash
ls /sys/bus/mdio_bus/devices/            # 空 = PHY 没注册（对应原因1）
dmesg | grep -iE 'mdio|g12a-mdio-mux|dwmac|phy'   # 看 mux 有没有 probe 失败/时钟错误
cat /sys/kernel/debug/gpio | grep -i eth  # 或 gpioinfo，看 reset gpio 是否被拉高
```
- `/sys/bus/mdio_bus/devices/` 空且 dmesg 无 mux 相关行 → 查 mdio-mux 是否被裁剪成模块但没装进 uInitrd；
- 有 `mdio_bus_mux` 报 `-EPROBE_DEFER`/clk 错 → 是 mux 的 `pclk/clkin` 时钟依赖顺序；
- mux 正常但没有 phy 设备 → reset GPIO 时序，试 `reset-assert-us/deassert-us` 放宽或临时去掉 `reset-gpios` 验证。

对比基线：旧 6.12 ophub 内核在同一块板、同一 dtb 上 eth0 是通的，所以这是**7.2.12 新内核引入的差异**，
不是硬件坏。优先级排在 Wi-Fi 缺口（§0.3）之前——有线本来是最稳的网。

### 0.5 进不了系统的真因：root 密码是**锁定**的，不是键盘坏（2026-11-15 15:39）

`x96src login:` 打 root + 回车进不去 —— 根因在 `build-image.sh:12`：
`X96_ROOT_PASSWORD` 默认空，走的是**锁定密码**分支（只留 SSH key），
**空密码 ≠ 可登录**，锁定账户在 getty 上必然被拒。屏幕上那堆 DRM/eth0 日志只是把
`Login incorrect` 顶掉了，看起来像卡死。

**修法（离线，卡插到 PC 上跑，幂等）**：
```bash
sudo ./x96max/enable-autologin.sh              # 按 LABEL=ROOTFS 自动找卡
sudo ./x96max/enable-autologin.sh /dev/sdb2    # 或显式指定
```
它做四件事：
1. `shadow` 的 root 密码字段清空（空密码，**非** `!` 锁定），备份 `shadow.bak.x96`
2. `getty@tty1.service.d/autologin.conf` → HDMI 控制台 `--autologin root`
3. `serial-getty@ttyAML0.service.d/autologin.conf` → 串口同样自动登录
4. 屏蔽 `armbian-firstlogin/firstrun`，停用 `profile.d/armbian-check-first-login.sh`
   （否则自动登录后会立刻被首启向导拦住改密码）

**注意**：`systemctl --root=$MNT` 离线 enable 用不了时脚本会退化成直接建
`etc/systemd/system/getty.target.wants/getty@tty1.service` 软链，两条路都试过。

想顺手压掉刷屏日志：`sudo ./x96max/patch-bootargs.sh quiet loglevel=3`。

## 1. 硬件配置

| 项目 | 实测值 |
|---|---|
| 型号 | X96 Max（DTB `meson-g12a-x96-max.dtb`，compatible `amediatech,x96-max` / `amlogic,g12a`） |
| SoC | Amlogic S905X2，4×Cortex-A53（aarch64，`meson-g12a`） |
| GPU | Mali-G31（Panfrost，`panfrost ffe40000.gpu`） |
| 内存 | 4GB 标称，Linux 可见约 3.24GiB（`MemTotal 3397224 kB`） |
| 存储 | eMMC 64GB（`064G30`，58.2GiB / 122142720 sectors），`mmcblk2`，另有 `mmcblk2boot0/1` 各 4MiB |
| 有线网卡 | Amlogic `meson8b-dwmac`（Synopsys DWMAC1000），外置 **RTL8211F** PHY，1Gbps |
| 无线 | **RTL8822BS**（SDIO `024c:b822`），Wi-Fi + 蓝牙二合一；**保留驱动**：Wi-Fi 走 `rtw88_8822bs`（SDIO），蓝牙走 `hci_uart` + `btrtl`（UART，线路以 `dmesg` 为准） |
| 显示 | `meson-dw-hdmi`（HDMI TX v2.01a），DRM `meson-drm`，支持 1920×1080 |
| 音频 | `axg-sound-card`（`X96-MAX`），AXG TDM/SPDIF + G12A TOHDMITX/TOACODEC |
| 视频硬解 | `meson_vdec`（V4L2 mem2mem） |
| USB | USB 3.0 ×1（5000M，1 port）+ USB 2.0 ×2（480M，2 ports），`dwc3-meson-g12a` + xHCI |
| 红外 | `meson_ir`（服务器用途可禁用） |
| RTC | `meson-vrtc`（`ff8000a8.rtc`，掉电不保时） |
| 温度 | 空闲约 35–49°C |
| 以太网 MAC | `02:00:00:10:25:01`（`ethtool -P` 永久地址；内核 cmdline 另有 `mac=90:0e:b3:10:cc:69`，未生效） |
| Wi-Fi MAC | `c4:3a:35:58:ce:bc`（保留驱动，联网时才用） |

USB 拓扑实测：

```text
Bus 002: xhci-hcd/1p, 5000M   （USB 3.0）
Bus 001: xhci-hcd/2p, 480M    （USB 2.0）
```

---

## 2. 当前系统与 ophub 打包方式

### 2.1 系统信息

| 项目 | 值 |
|---|---|
| 发行版 | Armbian OS 26.11.0（ophub 重打包） |
| 用户态 | Debian 12.15 bookworm |
| 内核 | `6.12.112-ophub` |
| 默认包数量 | 约 484 个（含编译工具链、文档、`armbian-config`、`zsh`、`aptitude` 等，未裁剪） |
| SSH | `root@192.168.1.120`，已配置免密（`~/.ssh/config` 的 `Host x96`） |
| 凭据 | 密码保存在 `~/.env` 的 `X96_PASS`；**不要写进仓库文档** |

### 2.2 为什么“官方 Armbian 不支持但能跑”

X96 Max 不在官方 Armbian 的板型列表里。商家使用的是社区项目：

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)

它的流程是：

```text
官方 Armbian 通用镜像（如 Odroidn2）
        ↓
ophub rebuild：替换 U-Boot/DTB/内核/启动脚本
        ↓
X96 Max 可启动镜像
```

盒子上的文件可以证明：

```text
/etc/armbian.txt     → Board: Odroidn2
/etc/ophub-release   → MODEL_ID=301, MODEL_NAME=X96-Max-4GB, SOC=s905x2
                       KERNEL_REPO=ophub/kernel
                       REBUILD_REPOSITORY=github.com/ophub/amlogic-s9xxx-armbian
                       FDTFILE=meson-g12a-x96-max.dtb
                       UBOOT_OVERLOAD=u-boot-x96max.bin
```

因此：**盒子由 ophub 支持，不是官方 Armbian 原生板型**。我们复现时使用同一套 ophub 流程。

### 2.3 当前分区与启动

**原厂（商家）布局**（实测自 `recovery/bootarea-117MiB.img`，即 eMMC 前 117MiB 原样备份）：

```text
/dev/mmcblk2      58.2G
├─ [0 -- 117MiB]  117M  启动链保留区（MBR 未登记）   sectors 0 -- 239615
├─ mmcblk2p1      511M  FAT32  /boot                start=239616 sectors（117MiB）
└─ mmcblk2p2      57.6G ext4   /                    start=1288192 sectors（629MiB）
```

逐段内容（同一份实测数据）：

```text
偏移        大小        内容
0           68 MiB      Amlogic 原厂启动链：U-Boot 2015.01（Jun 21，年份字段被裁断）
                        + BL2/BL30/BL31（FIP 建于 2019-04-14，tag g12a gb1cc8f0，
                          luan.yuan@droid15-sz）
68 MiB      ~49 MiB     FAT32，label=EMMC_BOOT，**MBR 未登记**
                        内含 flippy 5.4.125-flippy-60+o 的 zImage/uInitrd/uEnv.txt
                        + u-boot.sd/u-boot.usb（历史残留，原系统启动链不用它）
117 MiB     511 MiB     p1  FAT32  type=0x0c  start=239616    ← 原系统 /boot
628 MiB     1 MiB       空隙（2048 扇区，对齐）
629 MiB     57.6 GiB    p2  ext4   type=0x83  start=1288192   ← 原系统 /

总计 122142720 扇区 = 58.19 GiB（64GB eMMC）；MBR 标签 id=0x10964940
```

- MBR 引导代码段（`0x000–0x1BD`）**全零**：原厂启动不靠 MBR 代码，Amlogic ROM 按固定偏移
  从 0 区加载 BL2 → BL30/BL31 → U-Boot 2015.01，所以这一段既是「保留区」也是真正的启动区。
- 68MiB 处的 `EMMC_BOOT` 是 MBR 之外的「孤儿分区」：它的 BPB 自称 160MiB / hidden=131072
  （64MiB），与实际位置不符，且被 117MiB 处的 p1 截断——说明这份分区表被重写过，
  这个 FAT 是上一代系统的 boot 分区残留。
- 安装主线 U-Boot 后 p1 挪到 68MiB（见下），正好落在这个孤儿 FAT 的位置上，把残留覆盖掉。

**安装主线 U-Boot 后的当前布局**（`armbian-install -m yes -a no`）：

```text
/dev/mmcblk1      58.2G
├─ [0 -- 68MiB]   68M   主线 U-Boot 启动链（0 区，MBR 未登记）  sectors 0 -- 139263
├─ mmcblk1p1      511M  FAT32  BOOT_EMMC   /boot      start=139264 sectors（68MiB）
├─ [579 -- 1350MiB] 771M 未使用空隙                              sectors 1185792 -- 2764799
└─ mmcblk1p2      56.9G ext4   ROOTFS_EMMC  /          start=2764800 sectors（1350MiB）
```

- **设备编号随启动介质变**：同一块 eMMC，从 SD/U 盘启动时枚举为 `mmcblk2`（§1 硬件表、
  上文「原厂布局」），从 eMMC 自身启动时枚举为 `mmcblk1`（§16 验证 `findmnt / /dev/mmcblk1p2`）。
  两个编号指的是同一块盘，别当成两块。
- **算术自洽**：p1 占 139264–1185791（68–579MiB）；p1 末尾到 p2 起点空 1579008 扇区 = 771MiB；
  p2 到盘尾 119377920 扇区 = 56.90GiB。比原厂的 57.63GiB 少 0.73GiB，正好等于 p2 起点后移的
  （1350−629）= 721MiB。
- 那段 **771MiB 空隙**（579→1350MiB）是 `-a no` 固定布局的产物，文档里没有可解释它的依据，
  按实测记为空隙、不猜用途；反正 rootfs 用不到它，扩容时可以直接跳到 1350MiB 之后。
- **相对原厂的变化**：启动链保留区从 117MiB 收到 68MiB（原厂那 117MiB 见上面「逐段内容」），
  p1 因此从 117MiB 前移到 68MiB，正好压掉 68MiB 处的孤儿 `EMMC_BOOT` FAT；p2 从 629MiB 后移到 1350MiB。
- 主线 U-Boot 位于 eMMC 起始区；原厂启动区备份在 `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`。

`/boot` 关键文件：

```text
uEnv.txt                          启动参数
zImage / vmlinuz-7.2.12-x96       当前内核
uInitrd / initrd.img-...          initramfs
dtb/amlogic/meson-g12a-x96-max.dtb
u-boot.emmc                       6.x+ 内核重载 U-Boot（主线安装时会生成）
u-boot-x96max.bin                 原厂/overload U-Boot
u-boot.sd / u-boot.usb            SD/USB U-Boot
emmc_autoscript                   从 eMMC 拉起
boot.scr                          启动脚本
```

`uEnv.txt` 示例：

```text
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/meson-g12a-x96-max.dtb
APPEND=root=UUID=<uuid> rootflags=data=writeback rw rootfstype=ext4 \
       console=ttyAML0,115200n8 console=tty0 ... video=HDMI-A-1:1920x1080@60e
```

---

## 3. 驱动映射（有线为主，无线驱动保留）

> ⚠️ 下表的无线/BT 行是**目标配置**，不是当前 7.2.12-x96 的实况：裁剪树已删掉无线源码、配置里 `RTW88*`/`BT*` 全未开，`modules-*` 只有 `test_bpf.ko`。实况与补齐步骤见 §0.3。

| 硬件 | Linux 驱动 | 内核配置 |
|---|---|---|
| SoC / 时钟 | `meson-g12a` | `CONFIG_COMMON_CLK_MESON_*`、`CONFIG_PINCTRL_MESON_G12A` |
| 有线网卡 | `meson8b-dwmac` / `stmmac` | `CONFIG_STMMAC_ETH=y`、`CONFIG_DWMAC_MESON=y` |
| 以太网 PHY | RTL8211F | `CONFIG_REALTEK_PHY=y`、`CONFIG_MDIO_BUS_MUX_MESON_G12A=y` |
| eMMC/SD/SDIO | `meson-gx-mmc` | `CONFIG_MMC_MESON_GX=y` |
| HDMI / DRM | `meson-drm` + `meson-dw-hdmi` | `CONFIG_DRM_MESON=y`、`CONFIG_DRM_MESON_DW_HDMI=y` |
| GPU | Panfrost | `CONFIG_DRM_PANFROST=m` |
| 音频 | AXG sound card | `CONFIG_SND_MESON_AXG_*`、`CONFIG_SND_MESON_G12A_TOHDMITX`、`CONFIG_SND_MESON_G12A_TOACODEC` |
| 视频硬解 | `meson_vdec` | `CONFIG_VIDEO_MESON_VDEC=m` |
| USB | DWC3 + xHCI | `CONFIG_USB_DWC3_MESON_G12A=y`、`CONFIG_USB_XHCI_HCD=y` |
| RTC | `rtc_meson_vrtc` | `CONFIG_RTC_DRV_MESON_VRTC=m` |
| 看门狗 | Meson watchdog | `CONFIG_MESON_WATCHDOG=y` |
| 红外 | `meson_ir` | `CONFIG_IR_MESON=m`（可关） |
| 无线 (Wi-Fi) | `rtw88_8822bs` | `CONFIG_WLAN=m`、`CONFIG_CFG80211=m`、`CONFIG_MAC80211=m`、`CONFIG_RTW88=m`、`CONFIG_RTW88_SDIO=m`、`CONFIG_RTW88_8822B=m`、`CONFIG_RTW88_8822BS=m` |
| 无线 (蓝牙) | `hci_uart` + `btrtl` | `CONFIG_BT=m`、`CONFIG_BT_HCIUART=m`、`CONFIG_BT_HCIUART_RTL=m`、`CONFIG_RFKILL=m` |

**保留项**（无线驱动不关，全部按模块 `=m` 编进 `modules-7.2.12-x96.tar.gz`）：

```text
CONFIG_WLAN=m
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_RTW88=m
CONFIG_RTW88_SDIO=m
CONFIG_RTW88_8822B=m
CONFIG_RTW88_8822BS=m
CONFIG_BT=m
CONFIG_BT_HCIUART=m
CONFIG_BT_HCIUART_RTL=m
CONFIG_RFKILL=m
```

> 用 `=m` 不用 `=y`：无线按需 `modprobe`，不撑内核镜像；前提是 rootfs 里 `modules-7.2.12-x96.tar.gz` 完整。
> 历史：早期版本这里是 `-d` 全关（有线-only），2026-11 起改为保留。

---

## 4. 构建环境

| 项目 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04（noble），6 核，23GiB 内存 |
| 工作目录 | `/x96-build` |
| ophub 仓库 | `/x96-build/amlogic-s9xxx-armbian` |
| 内核源码（原版，只做参照） | `/opt/linux/src/linux-7.2.12.tar.xz`（完整树 2026-11-15 已删；要用先解到 `/tmp/linux-7.2.12`，见 §0.1） |
| **内核源码（实际编译，全量树）** | `/x96-build/src-clean`（1.8G，未裁剪，`kbuild-trim/source` 指向它） |
| 内核构建目录（out-of-tree） | `/x96-build/kbuild-trim`（736M，`Image` 32.2MB + 280 个 `.ko`） |
| 已删除（2026-11-15 19:15） | `src-linux`（第一轮裁剪树 553M）+ `kbuild-7.2.12`（739M）；配置分别归档为 `configs/config-7.2.12-x96-trim-final-20261115`（当时名 `…-trim-20261115`，后被覆盖，最终名见 §2）；round1 与 full 的归档（`configs/config-7.2.12-x96-round1-kbuild7.2.12-20261115`、`configs/config-7.2.12-x96-full-20261115`）已于 2026-11-15 23:25 删，`configs/` 只留 trim 一份 |
| 内核 4 包 | 产出 `/x96-build/pkgs/`；`rebuild` 实际读取 `.../build-armbian/kernel/stable/7.2.12/` |
| Armbian build（源码 rootfs） | `/x96-build/armbian-build`，缓存 `cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst` |
| 成品镜像 | `/x96-build/recovery/x96src-autoinstall.img.gz` |
| 日志 | `/x96-build/logs/from0-<mmdd-HHMM>/{0-clean,19.3,19.4,19.5,19.6,done}.log` |
| 交叉工具链 | `aarch64-linux-gnu-gcc` 13.3.0 |
| 模拟器 | `qemu-aarch64-static` + binfmt（用于 arm64 chroot） |

> 2026-11-14：`/data` 盘空间紧张，工作目录由 `/data/x96-build` 迁到 `/x96-build`（同机、只换挂载点，内容与属主不变）。
> 三个脚本的 `X96_BUILD_ROOT` 默认值已同步；老路径可用 `sudo ln -s /x96-build /data/x96-build` 兼容。

安装依赖：

```bash
cd /x96-build/amlogic-s9xxx-armbian
sudo apt-get update
sudo apt-get install -y $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)
```

---

## 5. 内核 7.2.12 源码编译

### 5.1 源码与配置

> 本次最终 `.config` 已保存到 `x96max/kernel/config-7.2.12-x96-full`；直接复制即可复现。下面是从 6.18 基线重建/理解配置的步骤。

源码：`/opt/linux/src/linux-7.2.12.tar.xz`（Makefile：`VERSION=7 PATCHLEVEL=2 SUBLEVEL=12`）。
**原版完整树已删**，只剩这个包；实际编译用裁剪树 `/x96-build/src-linux`，缺文件一律按 §0.1 从包里解。

先清理源码树（树内构建产物会导致 out-of-tree 构建报错）：

```bash
cd /opt/linux/src/linux-7.2.12
make ARCH=arm64 mrproper
```

以内核 6.18 的 ophub stable 配置为基线，适配 7.2.12：

```bash
OUT=/x96-build/kbuild-7.2.12
mkdir -p "$OUT"
cp /tmp/ophub-cfg/config-6.18 "$OUT/.config"
```

关闭 debug info/BTF（否则体积和时间显著增加）：

```bash
cd /opt/linux/src/linux-7.2.12
for s in DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
         DEBUG_INFO_DWARF5 DEBUG_INFO_COMPRESSED_NONE \
         DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_DWARF4 \
         DEBUG_INFO_REDUCED DEBUG_INFO_SPLIT; do
  ./scripts/config --file "$OUT/.config" -d "$s"
done
./scripts/config --file "$OUT/.config" -e DEBUG_INFO_NONE
```

保留无线/BT（原来这里是 `-d` 关闭，现在改成 `-e` 启用）：

```bash
for s in WLAN CFG80211 MAC80211 RTW88 RTW88_SDIO RTW88_8822B \
         RTW88_8822BS BT BT_HCIUART BT_HCIUART_RTL RFKILL; do
  ./scripts/config --file "$OUT/.config" -e "$s"
done
```

依赖关系：`RTW88_8822BS` 依赖 `RTW88_SDIO`，`BT_HCIUART_RTL` 依赖 `BT_HCIUART`。父项若是 `n`，子项 `-e` 也不生效，
随后的 `olddefconfig` 会把它们补成 `=m` 或 `n`——所以必须复查下面的 grep 结果。

> ⚠️ 在**当前裁剪树**上这段是空转：`net/wireless`、`net/mac80211`、`drivers/net/wireless` 已删，`./scripts/config -e RTW88*` 不会报错但
> `olddefconfig` 之后仍然是 `# CONFIG_RTW88 is not set`。要真正开启，先按 §0.3 把目录和 `net/Makefile`、`drivers/net/Makefile` 的钩子解回来。

设置本内核签名：

```bash
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-x96"/' "$OUT/.config"
```

生成最终 `.config`：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

关键项检查：

```bash
grep -E 'CONFIG_(DWMAC_MESON|STMMAC_ETH|REALTEK_PHY|MDIO_BUS_MUX_MESON_G12A|MMC_MESON_GX|DRM_MESON|DRM_MESON_DW_HDMI|DRM_PANFROST|VIDEO_MESON_VDEC|USB_DWC3_MESON_G12A|USB_XHCI_HCD|SND_MESON_AXG_SOUND_CARD|SND_MESON_G12A_TOHDMITX)' "$OUT/.config" | sort
grep -E 'CONFIG_(WLAN|RTW88|BT|BT_HCIUART|RFKILL)' "$OUT/.config" | sort
```

> 无线相关项必须出现 `=m`。若看到 `# CONFIG_RTW88_8822BS is not set`，说明父项被关，重跑上一步再 `olddefconfig`。

### 5.2 编译

```bash
cd /opt/linux/src/linux-7.2.12
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j5 Image modules
```

只编译需要的 DTB（不要直接 `make dtbs`，会构建所有 ARM64 板型）：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  amlogic/meson-g12a-x96-max.dtb
```

> DTB 目标要写成 `amlogic/...`；写成 `arch/arm64/boot/dts/amlogic/...` 会被 Makefile 再次拼接，报目标不存在。

安装 modules 到临时目录：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$OUT/modules" modules_install
```

产物：

```text
$OUT/arch/arm64/boot/Image
$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb
$OUT/modules/lib/modules/7.2.12-x96/
```

> 后台编译务必用 `setsid`/`nohup` 脱离当前 shell；否则终端超时会终止整个进程组。
> 不要用 `pkill -f kbuild-7.2.12`，会匹配到当前 shell 自身；用进程组 `kill -- -PGID`。

### 5.3 源码树裁剪（2026-11-15：两轮裁到 545M，全量 8 分 15 秒）

> ⚠️ **先读 §5.7**：删目录会连带删掉目录里的 `Kconfig`，导致父 `Kconfig` 的 `source` 悬空、符号被 `olddefconfig` **静默丢弃**。
> 本节的裁剪树实测比全量树少 **1789 个符号**（含 genpd、`HW_PERF_EVENTS`、`USB_GADGET`）。裁完必须做逐符号 diff。

口径和 `docs/trim.md`（主机 `begin` 内核）不同：**不动 config，只删代码**——把源码树从
1.8G / 94777 文件两轮削到 **545M / 37911 文件（27%）**，用同一份 `.config` 换更短的全量编译。

| 项 | 值 |
|---|---|
| 裁剪树 | `/x96-build/src-linux`（原版完整树 2026-11-15 已删，仅存 `/opt/linux/src/linux-7.2.12.tar.xz`） |
| 用的 config | `/x96-build/config-x96-20261115` 生成，`make olddefconfig` 后落 `kbuild-7.2.12/.config`
（含 `CONFIG_DEBUG_INFO_NONE=y`，关 debug info 是最大的那一刀）；
**归档副本已删（2026-11-15），现只存 `x96max/kernel/config-7.2.12-x96-full`**（与当时的 `kbuild/.config` 字节一致，6672 行；
2026-11-15 12:43 已刷新为 usbfix 版，补回 `USB_STORAGE=y`/`USB_UAS=y`，见 §5.4） |
| 第一轮裁剪后 | 1.8G/94777 → **821M / 69673 文件**；干净全量 `-j6` **rc=0，526 s = 8m46s** |
| 第二轮裁剪后 | 821M/69673 → **545M / 37911 文件**；干净全量 `-j6` **rc=0，495 s = 8m15s**（目标 ≤10 分钟） |
| 产物 | `Image` 35.8 MB / `Image.gz` 13.3 MB / `vmlinux` 44.9 MB（aarch64 PIE） |
| 日志与计时 | `logs/timed-0058.log`（第一轮）、`logs/timed-clean-0815.log`（第二轮）；脚本 `x96max/build-kernel.sh`（旧名 `/x96-build/run-timed.sh`），结果落 `kbuild-7.2.12/.build-rc` / `.build-sec` |

```bash
cd /x96-build/src-linux
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make O=/x96-build/kbuild-7.2.12 clean
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j6 O=/x96-build/kbuild-7.2.12
```

> 这两条就是**实测用的编译命令**；`-j6` 即 `nproc`（构建机 6 核），`O=` 指到独立的构建目录。
> 走一键脚本时对应 `./x96max/rebuild-from-zero.sh`：
> 脚本默认 `X96_KSRC=${X96_BUILD_ROOT:-/x96-build}/src-linux`（**裁剪树**，即 8 分钟那一档）；
> 想用未裁剪原版才显式 `X96_KSRC=/opt/linux/src/linux-7.2.12`——**但该目录 2026-11-15 已删，只剩
> `linux-7.2.12.tar.xz`**，要那档须先 `cd /opt/linux/src && tar -xf linux-7.2.12.tar.xz`。

**五条踩出来的规矩**（这一轮都真炸过）：

1. **删目录必须同步改父 Makefile。** `obj-y += 已删目录/` 会让 kbuild 直接失败。
   用 `x96max/trim-tools/fix_makefiles2.py`：按**逻辑行**（`\` 续行）削尾部 token，删完只剩 `obj-$(X) +=` 就丢整句。
2. **不能按目录名删 `=y` 子系统。** 判据是「该目录 Makefile 的 `obj-$(CONFIG_*)` ∩ 当前 config 的 `=y/=m`」，
   有命中就不能删。这次误删了 `net/ethtool`(ETHTOOL_NETLINK)、`net/sched`、`net/devlink`(NET_DEVLINK)、
   `drivers/media/dvb-core`(DVB_CORE)、`kernel/cgroup`、`kernel/events`(PERF_EVENTS)，
   症状是链接期 **238 条 `undefined reference`**（编译期全绿，只有链接才炸）。
   > **不能拿「符号 → 定义它的 Kconfig 所在目录」判归属**：`NET_DEVLINK`/`ETHTOOL_NETLINK` 定义在 `net/Kconfig`，
   > `DVB_CORE` 在 `drivers/media/Kconfig`，`CGROUPS`/`PERF_EVENTS` 在 `init/Kconfig`，按归属算这些目录**永远 0 个
   > 活符号**。`prune_src.py` 现在是三层判据，任一命中即保留：① 目录 Makefile 的 `CONFIG_*` ∩ `=y/=m`；
   > ② 父 Makefile 的 `obj-$(CONFIG_X) += <dir>/`（`net/devlink/Makefile` 整份 `obj-y :=` 就靠这层）；
   > ③ `rules.txt` 的 `PROTECT <dir>`。三层都不命中才删——对已裁剪的树 dry-run 必须得「可删 0 个」。
3. **被无条件 `#include` 头文件的目录只删代码、留头文件**，并补一个空 Makefile（`make clean`/`syncconfig`
   会因为目录缺 Makefile/Kconfig 提前中断）：
   - `fs/squashfs` ← `init/do_mounts_rd.c`
   - `net/bridge` ← `net/ipv6/netfilter.c`、`net/netfilter/nfnetlink_{log,queue}.c`、`br_netfilter.h`、`trace/events/bridge.h`
4. **验证顺序固定**：`make clean`（先暴露缺 Makefile）→ `syncconfig` → 全量编译 → 最后查 `undefined reference`。
5. **删目录会连带删掉它的 `Kconfig`，config 里对应的 `=y` 于是被静默丢弃。** 前四条的症状都出现在编译期
   （缺 Makefile / 缺头文件 / `undefined reference`），但**整目录删掉、且符号本来就不进 vmlinux 时，全程没有一声响**：
   本轮把 `drivers/usb/storage/` 连同 `drivers/usb/Kconfig` 里那行 `source "drivers/usb/storage/Kconfig"`
   一起删了，`CONFIG_USB_STORAGE=y`/`CONFIG_USB_UAS=y` 在 `olddefconfig` 后无声消失，`Image` 照编、照烧、照引导，
   直到 initramfs 挂根盘那一刻才炸（§5.4）。**加一条判据**：删目录前先
   `grep -rn 'source.*<dir>/Kconfig' --include=Kconfig .`，命中就必须保留 Kconfig（只删 `.c`），
   或者确认 config 里该子系统确实没开。

**第二轮：删掉非 arm64 架构（821M → 545M，省 276M / 31762 文件）**

目标架构固定 arm64，`arch/` 下 23 个其他架构目录里 **20 个纯删即可**：`rules.txt` 用 `FORCEKILL` 绕过 `judge()`，
因为跨架构 Makefile 里出现 `CONFIG_64BIT=y` 会被启发式当成「活符号」而拒删。剩下 3 个（`um`/`x86`/`riscv`）
**必须补回极小切片**，删整个目录就编不过——下面每一处都真炸过（括号里是日志行）：

| 补回的切片 | 体积 | 谁要它 | 症状 |
|---|---|---|---|
| `arch/um` | 1.4M | `fs/Makefile` 无条件 `obj-y += hostfs/`；`fs/hostfs/Makefile` 末行 `include $(srctree)/arch/um/scripts/Makefile.rules` | `make clean` 直接 Error 2 |
| `arch/x86/entry/syscalls` | 44K | `scripts/checksyscalls.sh`（`Kbuild:58` 的 `.tmp_missing-syscalls`）读 `syscall_32.tbl` | `timed-clean-0812.log:964` `grep: ... syscall_32.tbl: 没有那个文件或目录` |
| `tools/include` | 2.0M | `scripts/Makefile:32-38` 给 `elf-parse.o`/`sorttable.o` 加 `-I$(srctree)/tools/include`，要 `tools/be_byteshift.h` | `timed-clean-0809.log:185` `elf-parse.h:7: fatal error: tools/be_byteshift.h` |
| `arch/arm/boot/dts` | 27M | arm64 的 `arch/arm64/boot/dts/allwinner/*.dtsi` 跨架构 `#include <arm/allwinner/sunxi-h3-h5.dtsi>` | `timed-clean-0809.log:264` `sun50i-h5.dtsi:4: fatal error: arm/allwinner/sunxi-h3-h5.dtsi`（`make dtbs`） |
| `arch/riscv/boot/dts` | 1.2M | arm64 的 `arch/arm64/boot/dts/sophgo/sg2000.dtsi:6-7` `#include <riscv/sophgo/cv180x.dtsi>` / `cv181x.dtsi` | 同上（dtbs 阶段） |
| `rust` | 7.1M | 顶层 `Makefile:1742`、`1756-1758` 的 `clean` 目标列了 `rust/libmacros.so`、`rust/libpin_init_internal.so` 等 | `make clean` 前置检查失败 |

`Documentation/`（84M / 11300 文件）也可以删，但**必须同时把 `Makefile:1332` 的 `clean-dirs` 里的 `Documentation` 去掉**，
否则 `scripts/Makefile.clean:12` 找不到 `Documentation/Makefile`，`make clean` 一上来就失败。代价是
`make htmldocs`/`dt_binding_check` 这类文档与设备树校验目标不可用（正常 `make`/`clean`/`Image` 完全不碰）。

> **补回已自动化**：`prune_src.py --apply` 删完后按 `trim-tools/restore.txt` 从 `$KTREE_ORIG`
> （默认 `/opt/linux/src/linux-7.2.12`）把这 6 处 `cp -a` 回来，所以 `--apply` 幂等——2026-11-15 08:33 实测：
> 删 5 个目录 + 补 6 处切片后树仍是 **545M / 37911 文件**（回涨的 38M 正是这 6 处），
> 6 处与原树 `diff -r` **零差异**。往 `restore.txt` 加条目的判据只有一条：编译链在
> `clean`/`syncconfig`/`dtbs` 阶段硬引用它，而 `judge()` 看不见。

> 两轮都只验证了「能编」。**Image 还没在盒子上启动过**，QEMU/真机启动断言未跑。

裁剪工具（`plan.py` / `prune_src.py` / `fix_sources.py` / `fix_makefiles2.py` / `sym2kc.py` / `rules.txt`）
在 `x96max/trim-tools/`，用法见那里的 `README.md`；`/x96-build/trim-tools` 是它的软链，老命令照跑。
**三层判据只有一份实现**：`tools/trim/trimlib.py`（主机树与 x96 共用），两边脚本只是薄壳，
差别只剩 `rules.txt` 和默认树路径——主机那套以前是一层判据（按 Kconfig 归属），同样会踩 `net/devlink`，
现已收敛；改判据改 `trimlib.py`，别在 `trim-tools/` 里复制。
`sym2kc.py` 是 `trimlib.sym2kc()` 的命令行壳（`/tmp/sym2kc.tsv` 被清会自动重建）；
config 位置按 `$KCONFIG` → `<tree>/.config` → 仓库 `x96max/kernel/config-7.2.12-x96-full` 回退（out-of-tree 构建没有 `src-linux/.config`）。

### 5.4 usbfix：裁掉 `drivers/usb/storage` 导致 U 盘根盘找不到（2026-11-15）

**症状**：u-boot 阶段一切正常（`zImage`/`uInitrd`/`dtb` 都读得到、验得过），内核起来后在 initramfs 里刷

```text
Gave up waiting for root file system device.
Common problems:
 - Boot args (cat /proc/cmdline)
 - Check rootdelay= (did the system wait long enough?)
 - Missing modules (cat /proc/modules; ls /dev)
ALERT!  UUID=d764b7d9-…  does not exist.  Dropping to a shell!
```

掉进 `(initramfs)`，`/dev/sda` 根本没出现，也无模块可 `modprobe`（`uInitrd` 里 0 个 `.ko`，全靠内建驱动）。

**根因**：两层误判叠加。

| 层 | 发生了什么 |
|---|---|
| 源码树裁剪 | `disable.list` 第 **1168**（`USB_STORAGE`）/ **1185**（`USB_UAS`）行把它们标成可删，`prune_src.py` 据此连**整个 `drivers/usb/storage/`（50 个文件：`.c` + `Makefile` + `Kconfig`）** 一起删了 |
| Kconfig 连锁 | `drivers/usb/Kconfig` 里 `source "drivers/usb/storage/Kconfig"` 随之失效，两个符号成了「没有 Kconfig 的孤儿」，`make olddefconfig` 把它们**静默丢弃**（rc=0，无任何警告） |
| 为什么没暴露 | 编译期全绿（符号本就不进 vmlinux）、u-boot 自带 USB 栈与内核无关、`Image` 大小与引导全程正常——**唯一故障点就是挂根盘那一秒** |

> 关键认知：**u-boot 能读 U 盘 ≠ 内核能读 U 盘。** Amlogic 的 u-boot 有自己一套 USB 主机栈完成 `load usb 0 …`，
> Linux 侧的 `usb-storage` 是另一条独立链路。「能引导」完全不能证明存储驱动在。

**修复**（4 步，树 `/x96-build/src-linux`，构建目录 `O=/x96-build/kbuild-7.2.12`）：

```bash
cd /x96-build/src-linux
# 1) 拷回整个存储驱动目录（完整树已不在 /opt，只剩 tar.xz，必须先解到 /tmp，见 §0.1）
SRC=/opt/linux/src/linux-7.2.12.tar.xz
[[ -d /tmp/linux-7.2.12 ]] || (cd /tmp && tar -xf $SRC linux-7.2.12/drivers/usb/storage)
cp -a /tmp/linux-7.2.12/drivers/usb/storage drivers/usb/
# 2) 恢复被连带删掉的 Kconfig 钩子（当前在 114 行，插在 endmenu 之前）
grep -q 'storage/Kconfig' drivers/usb/Kconfig || \
  sed -i '/^endmenu/i source "drivers/usb/storage/Kconfig"' drivers/usb/Kconfig
# 2b) 恢复 Makefile 钩子（缺这行目录白拷，kbuild 不会进去）
grep -q 'CONFIG_USB_STORAGE.*storage/' drivers/usb/Makefile || \
  sed -i 's|^obj-\$(CONFIG_USB) \+=  *$|obj-$(CONFIG_USB_STORAGE)\t+= storage/\n&|' drivers/usb/Makefile
# 3) 打开开关
./scripts/config --file /x96-build/kbuild-7.2.12/.config -e USB_STORAGE -e USB_UAS
# 4) 用 syncconfig 而不是 olddefconfig —— 新符号是 NEW 状态，olddefconfig 会取默认值把它再关一次
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make O=/x96-build/kbuild-7.2.12 syncconfig
```

顺带从 `disable.list` 里摘掉这两行（`disable.list.bak-123920` 是摘除前的备份，可用 `diff` 复核）。

**验证：三级断言，全在烧盘之前跑**

```bash
V=/x96-build/kbuild-7.2.12
# ① vmlinux 里有驱动符号（最硬的证据，2026-11-15 实测已过）
nm "$V/vmlinux" | grep -E ' (usb_stor_probe1|usb_stor_probe2|storage_probe|usb_storage_driver)$'
# ② config 里是 =y（内建，不依赖 uInitrd 里有没有 .ko）
grep -E '^CONFIG_(USB_STORAGE|USB_UAS)=y' "$V/.config"
# ③ Image 里搜得到字符串（证明没被裁在链接外）
strings "$V/arch/arm64/boot/Image" | grep -x 'usb-storage'
```

三条全过才烧盘。**`uInitrd` 不用重建**：驱动是 `=y` 内建，initramfs 里本来就没有存储相关的 `.ko`。

**烧盘**（U 盘 p1，vfat）：

```bash
# uEnv.txt 里 LINUX= 指向的文件才是 u-boot 真正 load 的那份
grep '^LINUX=' /media/$USER/BOOT/uEnv.txt           # 本机为 LINUX=/zImage
cp "$V/arch/arm64/boot/Image" /media/$USER/BOOT/zImage
cp "$V/arch/arm64/boot/Image" /media/$USER/BOOT/vmlinuz-7.2.12-x96   # 与 zImage 同内容
cp "$V/.config"               /media/$USER/BOOT/config-7.2.12-x96
sync && udisksctl unmount -b /dev/sdb1 && udisksctl unmount -b /dev/sdb2
```

> **别只换 `vmlinuz-*`**：那份是给人看的副本，`uEnv.txt` 的 `LINUX=/zImage` 才是真正被加载的文件，换错等于没换。
> 换完 `sha256sum` 对拍两个文件必须相同，再对盘上那份 `strings … | grep -x usb-storage` 确认驱动在里面。

**产物与备份**

| 项 | 位置 |
|---|---|
| 新 `Image` 快照 | `/x96-build/Image-usbfix-20261115-1240`（sha256 `3d0e2a6d…`） |
| 旧 U 盘内核备份 | `/x96-build/U-backup-{zImage,vmlinuz,config}-20261115-124215` |
| config | `x96max/kernel/config-7.2.12-x96-full`（与 `kbuild/.config` 字节一致；`configs/` 归档已删） |

**真机启动断言结果（2026-11-15 16:00，三条全过）**：

| 断言 | 结果 |
|---|---|
| `lsblk` 出现 U 盘自己的 `sda` | ✅ `sd 0:0:0:0: [sda]`，`sda1`/`sda2` 都出来 |
| `/proc/filesystems` 含 `ext4` | ✅ |
| `dmesg` 里 xhci/dwc3 有设备枚举 | ✅ |

**但启动仍然失败**，报的还是 `Gave up waiting for root file system device`——
只是这次不是缺驱动，而是**枚举比 initramfs 超时晚 1.3 秒**。同一个报错、两种成因，见 **§5.5**。

> 教训：这一节的「三条断言」只能证明**驱动进了内核**，**不能证明挂根盘成功**。
> 驱动到位之后再去判断能不能启动，必须看 §5.5 的时间戳判据表，否则会误以为修复没生效、白重编一遍内核。

### 5.5 同一句 `Gave up waiting` 的第二种成因：晚 1.3 秒的枚举竞态（2026-11-15 16:28 修正：`rootdelay` 无效，改抬 `slumber`）

**这是 §5.4 的陷阱版**：屏幕/串口输出**一字不差**，但根因完全不同，按 §5.4 去重编内核是白干。

```text
Gave up waiting for root file system device.
Common problems:
 - Boot args (cat /proc/cmdline)
 - Check rootdelay= (did the system wait long enough?)   ← 这次就死在这行
 - Missing modules (cat /proc/modules; ls /dev)
ALERT!  UUID=8e0a1be3-…  does not exist.  Dropping to a shell!
```

**唯一可靠的区分手段：比对两个时间戳的先后**（在 initramfs 里看不到 dmesg 就靠这条，因为提示里三行 who-done-it 全是猜的）。

本例实测：

| 事件 | 时间 | 结果 |
|---|---|---|
| initramfs-tools 超时放弃 | **39.64 s** | 此时 `/dev/sda` 还不存在 → 报 UUID 不存在 |
| `sd 0:0:0:0: [sda]` 枚举完成 | **40.94 s** | 只晚 **1.3 秒** |

⇒ 驱动**在**（§5.4 的修复已生效），`ext4` 也在，纯粹是 `initramfs-tools` 的 `ROOTDELAY` 默认值（约 30 次 × 1s 轮询）在 U 盘枚举前就到期了。
U 盘走的是 `usb-storage` 异步探测 + 30s 级 `scan`，比 eMMC/SSD 慢一大截，1.3 秒的窗口就是这么来的。

**判据表（照这个走，别猜）**

| 观察 | 结论 | 做法 |
|---|---|---|
| 超时时刻 < `[sda]` 枚举时刻（差几秒内） | 竞态 | 抬 initramfs 等待窗口（`patch-initrd-wait.sh`），**别用 `rootdelay`**，见下方「永久修复」 |
| `[sda]` 从没出现 | 真缺驱动（§5.4） | 查 `nm vmlinux \| grep usb_stor_probe`、`CONFIG_USB_STORAGE=y` |
| `[sda]` 出现了但 `EXT4-fs` 没挂上 | 不是驱动也不是时序 | 查 `root=UUID=` 是否与实际 UUID 一致、`rootfstype=ext4` |
| `I/O error` + `reset` + `hostbyte=0x03` `cmd_age=30s` | 链路掉盘（**超时**变体） | §10.2.2 |
| `I/O error` + `reset` + `hostbyte=0x07` `cmd_age=0s` | 链路掉盘（**立即打死**变体，同 §10.2.2 补充二） | §10.2.2 |

**现场应急（不用重启、不用改盘）**：在 `(initramfs)` 提示符直接敲

```text
exit
```

`initramfs-tools` 的 `local` 脚本在 shell 退出后会**重新走一遍 `mountroot` 轮询**。此时 `sda` 早已枚举完，一次就挂上，系统继续正常启动。
（这招只对「竞态」有效；真缺驱动时 `exit` 会立刻再报一次同样的错。）

**为什么 `rootdelay` 没用（2026-11-15 源码证伪，别再试了）**

`uInitrd` 解包后两处关键代码：

```sh
# init:229-236
starttime="$(_uptime)"; starttime=$((starttime + 1))   # ① 先记等待起点
if [ "$ROOTDELAY" ]; then sleep "$ROOTDELAY"; fi        # ② 再睡 rootdelay 秒

# scripts/local:82-86
slumber=30                                              # ③ 预算固定 30 秒
if [ "${ROOTDELAY:-0}" -gt $slumber ]; then slumber=$ROOTDELAY; fi
```

①→② 说明 sleep 发生在**计时窗口之内**，③ 说明窗口是 `max(30, rootdelay)`。
`rootdelay=15 < 30` ⇒ 窗口仍是 30s，且白扣 15s → 放弃时刻从 `30s` 变成 `30s`（并列），
`sda` 在 `t=37.54s` 才枚举，实测原地死于 `t=37.39s`，**差 150ms**。
（只有当 `rootdelay > 30` 才会真的延长窗口，但那是拿"每次开机硬睡 N 秒"换来的，且 `sleep` 是 hard sleep，不是轮询，早枚举也用不上。）

**永久修复：抬 `slumber`（不动启动参数）**

```bash
# 卡插在电脑上时（uInitrd 在 p1 根目录）
sudo ./x96max/patch-initrd-wait.sh /media/$USER/BOOT/uInitrd --inplace

# 离线改内核包里的 initrd（rebuild-from-zero.sh --from initrd 已自动调用）
sudo ./x96max/patch-initrd-wait.sh /x96-build/initrd.img-7.2.12-x96 -o /tmp/i.img
```

脚本做三件事：剥 uImage 头 → 改 `scripts/local` 的 `slumber=30` 为 `90` → `mkimage` 重打包，
**落盘前回读自检**（解包确认 `slumber=90` 真在里面），失败不写任何东西。
窗口 90s 对 USB 读卡器 `~38s` 枚举绰绰有余；eMMC/TF 槽启动 1 秒内就枚举完，不受影响。

> 曾被写成 `patch-bootargs.sh --usb-fix 346d:5678 rootdelay=15` 的旧方案已废弃，
> 卡 p1 上的 `rootdelay=15` 也已 `-r` 删除（只剩 `usb-storage.quirks=346d:5678:u` 和
> `usbcore.autosuspend=-1`，这两个仍建议留着：前者关 UAS 避开 §10.2.2 掉盘，后者禁 USB 自动挂起）。

> **坑（2026-11-15 实测）**：`write-card.sh` 收尾会把卡上分区**全部卸载**，紧接着跑
> `patch-bootargs.sh` 时 p1 未挂载 → 旧版 `findmnt` 返回 1 + `set -euo pipefail` 让赋值失败，
> 脚本**零输出、直接退出 1**，极易被当成"跑过了"。已修（`|| true`，commit `8c40d19`）。
> 现在正常输出应为 `+ 追加: usb-storage.quirks=346d:5678:u` 等两行，否则**当它没生效**，重跑并跟 `-l` 对拍。

> **`rootdelay` 已彻底退出方案**（§5.5 上文源码证伪）。它既治不了竞态，又要每次开机硬睡，
> 装进 eMMC 后更要删；现在盘上就不该有它。若见到旧卡还带着，`sudo ./x96max/patch-bootargs.sh -r rootdelay=15` 清掉。

**验证两个改动真的生效**（改完盘、开机后第一步）：

```bash
# ① 启动参数：只该有两条，且没有 rootdelay
cat /proc/cmdline | tr ' ' '\n' | grep -E 'rootdelay|quirks|autosuspend'
# 期望两行：usb-storage.quirks=346d:5678:u / usbcore.autosuspend=-1

# ② initramfs 等待窗口（根源修复，盘上就能验，不用开机）
./x96max/patch-initrd-wait.sh /media/$USER/BOOT/uInitrd --check
# 期望：slumber=90
```

**写盘后的权威快照（2026-11-15 16:05，`cat /media/$USER/BOOT/uEnv.txt` 实录）**

```text
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/meson-g12a-x96-max.dtb
APPEND=root=UUID=8e0a1be3-3e27-4733-9b1f-b5936d744996 rootflags=data=writeback rw rootwait \
  rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 \
  fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 cgroup_enable=cpuset \
  cgroup_memory=1 cgroup_enable=memory swapaccount=1 video=HDMI-A-1:1920x1080@60e \
  plymouth.enable=0 usb-storage.quirks=346d:5678:u usbcore.autosuspend=-1
```

下次要核对「盘上到底带没带参数」时，直接跟这段对拍，别只 `grep root`——
**`rootwait` / `rootdelay` 是两个不同的参数，而本方案里只留 `rootwait`**；`grep root` 会把两行混在一起误判。
（`APPEND` 共 21 个参数；`rootdelay=15` 已用 `-r` 删除，见 §0 第 6 条。）

**本条的可复现步骤（下一个人照做）**

1. `sudo ./x96max/patch-bootargs.sh -l` 记下当前 APPEND 并确认**没有** `rootdelay`
2. 插盘启动，在 `(initramfs)` 里敲 `exit` → 应能进系统（证明是竞态而不是缺驱动）
3. `dmesg | grep -E 'Gave up|\[sda\]'` 换算成同一时间轴，确认「放弃时刻 < 枚举时刻」
4. 抬等待窗口（**根源修复**，不动 bootargs）：
   `sudo ./x96max/patch-initrd-wait.sh /dev/sdX1/uInitrd --inplace`（或卡挂上后给 `$MNT/uInitrd`）
5. USB 兜底（可选但推荐，§10.2.2）：`patch-bootargs.sh --usb-fix 346d:5678`
6. 再启动：initramfs 最长等 90 秒（`slumber=90`），正常应在 2~3 秒内挂上 root 直接到 `login:`；
   若仍卡到 90 秒，才回到 10.2.2 的掉盘分支（这是一次真超时，不是竞态）

---

### 5.6 事故复盘：`boot-good` / `boot-bad` 两个目录**名字是反的**（2026-11-15 16:53）

`/x96-build/boot-good` 与 `boot-bad` 是 16:45–16:48 的快照，实测内容：

| 目录 | uInitrd 的 slumber | zImage 大小 | 实际含义 |
|---|---|---|---|
| `boot-good` | **30**（未修） | 42220032 | 名字骗人，这份是**坏的** |
| `boot-bad`  | **90**（已修） | 35949056 | 名字骗人，这份是**修好的** |

16:48 按 `boot-good` 回写卡 → 把已修好的 `slumber=90` 换回了 `slumber=30`，
于是 `Gave up waiting for root file system device` 重现。**不是内核问题，是我把目录名当成了事实。**

**教训（照此执行）**：
- 判断一个 uEnv/initrd 目录"能不能用"，唯一标准是 `patch-initrd-wait.sh <文件> --check` 的输出，
  **不要看目录名、不要看时间戳**。`slumber=90` 才是可用态。
- 两个 zImage 都含 `usb_stor_probe` 与 `RTL8211F Gigabit`（`grep -ac` 实测 2 / 1），
  所以「USB 存储驱动缺失」在这两版上都不成立，别再往 §5.4 方向重编内核。

**离线验收清单（卡挂上后一次性跑完，任一项不过就不算修好）**

```bash
M=/media/$USER/BOOT
blkid -o value -s UUID /dev/sdb2                        # → 8e0a1be3-3e27-4733-9b1f-b5936d744996
grep -oE 'root=UUID=[0-9a-f-]+' $M/uEnv.txt             # 必须与上一行完全相同
sudo ./x96max/patch-initrd-wait.sh $M/uInitrd --check   # → ✔ slumber=90
grep -^APPEND $M/uEnv.txt | tr ' ' '\n' | grep -c .      # → 21
grep -c rootdelay $M/uEnv.txt                           # → 0
```

> 注意 `cut -d= -f2` 解析 `root=UUID=xxx` 会拿到 `UUID`（两个等号），要用
> `sed 's/.*root=UUID=//'`，否则会误报"UUID 不一致"。

---

### 5.7 裁剪的隐性代价：1789 个符号静默消失，连 genpd 都没了（2026-11-15 17:08 对照实验）

**动机**：§5.4、§5.5 修完仍是同一个报错，而 16:34 起掉盘又抢先，无法判断"裁剪树本身是不是也削掉了什么"。
于是把完整源码包解开成**未裁剪的全量树**，用**同一份起始配置**重编一次，逐符号对比。

**做法**（两份树、同配置、`olddefconfig` 后编到底）：

```bash
# 全量树：完整包解到 /x96-build/src-clean（1.8G，原样，不裁剪）
cd /tmp && tar -xf /opt/linux/src/linux-7.2.12.tar.xz
mv linux-7.2.12 /x96-build/src-clean

# 树外输出，配置用与裁剪树同一份入口（CONFIG_LOCALVERSION="-x96"）
CU=/x96-build/kbuild-clean
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -C /x96-build/src-clean O=$CU olddefconfig
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -C /x96-build/src-clean O=$CU -j6 Image \
  2>&1 | tee /x96-build/build-clean.log     # 6204 行，无 error，17:08 出 Image
```

**结果（实测数字）**

| 项 | 裁剪树 `src-linux` + `kbuild-7.2.12` | 全量树 `src-clean` + `kbuild-clean` |
|---|---|---|
| `.config` 行数 | 7356 | **10390** |
| `=y` / `=m` | 2287 / 1465 | **2631 / 2896** |
| `arch/arm64/boot/Image` | 35 949 056 B | **42 220 032 B** |
| 编出时间 | 11-15 14:58 | 11-15 17:08 |

差的 **1789 个符号**（345 个 `=y`、1433 个 `=m`）**没有一个是因为"不想要"**，全部是因为
**目录被删 → 目录里的 `Kconfig` 一起没了 → 父 `Kconfig` 的 `source` 悬空 → `olddefconfig` 静默丢弃**。
`kbuild-clean/.config` 与归档的完整配置（`/tmp/cfg-good.txt`，257801 B）**逐字节等价（diff 0 行）**，
即全量树恢复的就是"应有"的配置。

**被静默丢掉的、与本机真正相关的（部分）**

| 符号 | 影响 |
|---|---|
| `PM_GENERIC_DOMAINS` / `PM_GENERIC_DOMAINS_OF` / `ARM_PSCI_CPUIDLE_DOMAIN` / `DT_IDLE_GENPD` | **genpd 整块没了**（`drivers/base/power/{Kconfig,domain.c}` 被裁走），meson 的电源域/PSCI idle 全不生效 |
| `HW_PERF_EVENTS` / `HAVE_HARDLOCKUP_DETECTOR_PERF` | 无硬件性能计数（`perf` 只剩软件事件） |
| `USB_GADGET` 全家、`USB_MUSB_*`、`USB_CHIPIDEA_*`、`USB_ISP1760*`、`USB_SERIAL_{CH341,CP210X,FTDI_SIO,PL2303}` | 无 USB gadget / 无 USB 转串口 |
| `USB_NET_DRIVERS`、`TLS(=m)`、`XDP_SOCKETS`、`NET_SHAPER`、`NF_TABLES_BRIDGE`、`6LOWPAN`、`9P_FS` | 网络/文件系统能力缺口 |
| `BLK_CGROUP_PUNT_BIO`、`SKB_DECRYPTED` | 块层/kTLS 细节 |

> **这不是"体积裁剪的副作用可忽略"，而是主结论**：`disable.list` 划掉一个 `CONFIG_*` 是"不编它"，
> 但 `prune_src.py` 顺手删目录会把**符号本身**从配置空间里抹掉，且**编译、链接、引导全程零告警**。
> §5.4 的 `USB_STORAGE` 只是这次撞上的一个；同样的机制已经在 `drivers/base/power`（genpd）、
> `USB_GADGET`、`HW_PERF_EVENTS` 上悄悄生效。

**自查断言（任何裁剪树都该跑，5 秒）**

```bash
A=/home/quqiufeng/kernel/configs/config-7.2.12-fulltree-baseline-20261115   # 全量树基准（原 kbuild-clean/.config 归档）
B=/x96-build/kbuild-7.2.12/.config     # 待查的裁剪树
diff <(grep -E '^CONFIG_[A-Z0-9_]+=' $A) <(grep -E '^CONFIG_[A-Z0-9_]+=' $B) \
  | sed -n 's/^< //p' | tee /tmp/lost.txt | wc -l          # 1789（本次实测）
grep -cE '=y$' /tmp/lost.txt                                # 345
grep -E '=y$' /tmp/lost.txt | grep -E 'GENPD|PM_GENERIC|PERF_EVENT|USB_GADGET|SERIAL'   # 该为 0
# 或直接用内核自带工具（按符号语义分类，输出更可读）
/usr/src/linux/scripts/diffconfig $A $B 2>/dev/null || $HOME/kernel/src/scripts/diffconfig $A $B
```

**与掉盘的关系（假设，未验证）**：`PM_GENERIC_DOMAINS_OF` 缺失后，meson-g12a 的 USB/PHY 电源域不再由 genpd 管理，
`xhci`/dwc3 的上电时序与全量内核不同——**有可能**与 §10.2.2 的"只以 high-speed 枚举 + 中途 `reset`"有关，
但也可能无关。判据只有一条：把 42.2MB 这份全量内核真的跑起来看 `dmesg | grep -E 'sd 0|reset|high-speed'`。
在没跑到那一步之前，**不要**把它写成结论。

**下一步（尚未执行）**

```bash
# 1) 全量内核进四包（脚本认 X96_KOUT / X96_KSRC，不是 O=）
#    ⚠ kbuild-clean 构建树已于 2026-11-15 19:12 删除：这一步要么改用现成的裁剪产物
#    （X96_KOUT=/x96-build/kbuild-trim），要么用 src-clean 重编一次全量树再打包。
X96_KOUT=/x96-build/kbuild-clean X96_KSRC=/x96-build/src-clean ./x96max/pack-kernel.sh
# 2) 重做 initrd → 重出镜像 → 写卡（写卡后仍要补 patch-initrd-wait + patch-bootargs，见 §0.2 第 6 步）
sudo ./x96max/rebuild-from-zero.sh --from initrd
./x96max/rebuild-from-zero.sh --from image
```

### 5.8 第二轮裁剪：在**全量树**上按硬件剪（2026-11-15 18:11，镜像 42.2→32.2 MB，模块 5816→140）

§5.7 的教训是"裁剪树会静默丢符号"，所以这一轮**不改源码树**，只在**全量树 `src-clean`** 上改配置：
符号空间完整，丢一个符号就一定是自己划掉的。

**两条规则**（脚本 `x96max/kernel/gen-trim2.sh`，可重跑）

| 规则 | 内容 | 结果 |
|---|---|---|
| A | 除白名单外**所有 `=m` 一律关** | 2896 → 153 |
| B | `=y` 只关"整块子系统"：`ARCH_{SUNXI,ROCKCHIP}`、媒体 DVB/模拟电视/摄像头/SDR/测试、`ATA` `MD` `MTD` `SCSI_LOWLEVEL` `VIRTIO` `KVM` `INFINIBAND` `ISDN` `HAMRADIO` `CAN` `NFC` `ATM` `WAN` `6LOWPAN` `IEEE802154` `TARGET_CORE`、xfs/btrfs/f2fs/nfs/nfsd/cifs/ceph/ocfs2/udf/hfs/… | 2631 → 2069 |

白名单只留板上真用得上的模块：`SND_MESON_*`（音频）、`DRM_PANFROST`（GPU）、
`VIDEO_MESON_VDEC/GE2D`（硬解，**在 staging/media 里，所以 `STAGING` 不能关**）、
`RTW88*`+`MAC80211`+`CFG80211`+`BT*`（Wi-Fi/BT，见 §0.3，本轮一并补上 `=m`）、
`NF_TABLES`/`NFT_*`/`IP_NF_*`/`IP6_NF_*`（防火墙）、`TUN/VETH/VLAN/WIREGUARD/ZRAM`、
`NTFS3/ISO9660`、`USB_SERIAL_{FTDI_SIO,PL2303}`。

**实测数字（同一棵树、同一工具链，`-j6`）**

| 项 | 全量基线 `kbuild-clean` | 裁剪后 `kbuild-trim` |
|---|---|---|
| `.config` 行数 | 10390 | 8922 |
| `=y` / `=m` | 2631 / 2896 | **2069 / 153** |
| `arch/arm64/boot/Image` | 42 220 032 B | **32 178 688 B**（−23.8%） |
| `.ko` 个数 / 总大小 | 5816 / 205.6 MB | **140 / 8.3 MB** |
| amlogic dtb | — | 102 个（全留） |
| 编译时间 | 8 分 15 秒 | 约 8 分钟（17:5x→18:11） |

**复现**

> 已脚本化：`./x96max/build-kernel.sh --trim`（= config-7.2.12-x96-trim + src-clean → kbuild-trim，
> 带 `.config` sha 比对与归档对照；`--dry-run` 只打印路径不编译）。下面是不依赖脚本的命令行原文，
> 用于从头生成 fragment / 补模块的场景。

```bash
# 基线已归档（kbuild-clean 构建树 2026-11-15 删除），默认值即归档路径
OUT=/x96-build/trim2-20261115.fragment ./x96max/kernel/gen-trim2.sh   # 生成 fragment（自带板载驱动误砍自检）
cp configs/config-7.2.12-fulltree-baseline-20261115 /x96-build/kbuild-trim/.config
cat /x96-build/trim2-20261115.fragment >> /x96-build/kbuild-trim/.config
make -C /x96-build/src-clean O=/x96-build/kbuild-trim ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
# Wi-Fi/BT 模块（§0.3 的缺口，本轮补上）
for s in WLAN CFG80211 MAC80211 RFKILL RTW88 RTW88_SDIO RTW88_8822B RTW88_8822BS \
         BT BT_HCIUART BT_HCIUART_RTL; do
  /x96-build/src-clean/scripts/config --file /x96-build/kbuild-trim/.config -m "$s"
done
make -C /x96-build/src-clean O=/x96-build/kbuild-trim ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -C /x96-build/src-clean O=/x96-build/kbuild-trim ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- -j6 Image modules dtbs 2>&1 | tee /x96-build/build-trim.log
```

归档：`configs/config-7.2.12-x96-trim-final-20261115` = `x96max/kernel/config-7.2.12-x96-trim` = 实编 `.config`
= 盒子 `/proc/config.gz`，四者 sha256 同为 `c4c802d5d9a3f68b7a07636cc9a863f81962aabd6f17fb06d1fe2dbd0996482a`
（8258 行 / 2084 `=y` / 167 `=m`）；fragment 在 `configs/trim2-20261115.fragment`。
与裁剪前的 `x96max/kernel/config-7.2.12-x96-full`（`e137d0d5…`）**不是同一份**，见文首"两份配置别混用"。

**板载全链复核（全部 `=y`，本轮逐个 grep 过）**

```text
ARCH_MESON MESON_SM ARM_PSCI_FW PM_GENERIC_DOMAINS(_OF) ARM_PSCI_CPUIDLE_DOMAIN DT_IDLE_GENPD
MESON_EE_PM_DOMAINS MESON_CANVAS MESON_GX_SOCINFO COMMON_CLK_AXG/AXG_AUDIO/G12A PINCTRL_MESON_G12A
STMMAC_ETH DWMAC_MESON REALTEK_PHY MDIO_BUS_MUX_MESON_G12A MMC_MESON_GX MMC_BLOCK
USB_DWC2 USB_DWC3 USB_DWC3_MESON_G12A USB_XHCI_HCD USB_STORAGE USB_HID
PHY_MESON_G12A_USB2 PHY_MESON_G12A_USB3_PCIE DRM_MESON DRM_MESON_DW_HDMI
SERIAL_MESON(_CONSOLE) I2C_MESON AMLOGIC_THERMAL MESON_WATCHDOG PWM_MESON NVMEM_MESON_EFUSE
RESET_MESON MESON_SARADC
```

`=y` 一共少了 598 个，但**没有一个 MESON/板载驱动**：丢的是其他 SoC（rockchip/sunxi 的 clk/pinctrl/phy/mmc/dwmac）、
x86 专用的 ATA/触摸屏/USB gadget 旧机、以及 §5.7 恢复回来的 genpd/perf 这轮都还在。

**注意（下一步必须做）**

1. 模块从 5816 个变 154 个，**`--from initrd` 必须重做**（depmod + update-initramfs），否则 initramfs 里
   引用的旧模块名在 rootfs 里已不存在。
2. 打四件套要指到新树：`./x96max/pack-kernel.sh --trim`（等价 `X96_KOUT=/x96-build/kbuild-trim
   X96_KSRC=/x96-build/src-clean`，并会先校验 `kbuild-trim/.config` 的 sha 在 `configs/` 归档里）。
3. 本轮**只验证到"编译零错误 + 配置对得上"**，没上机；上机判据仍是 §10.3 的 dmesg 清单
   （以太网 PHY、mmcblk、xhci、HDMI 声卡、掉盘）。

---

## 6. 生成 arm64 initrd / uInitrd

`uInitrd` 必须是 **arm64**，不能在 x86 主机上直接 `update-initramfs`。做法：用 arm64 rootfs + `qemu-aarch64-static` chroot。

```bash
# 1) 用基础镜像或最终镜像的 rootfs 分区
IMG=/x96-build/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
LOOP=$(sudo losetup -Pf --show "$IMG")
sudo mkdir -p /mnt/x96root
sudo mount ${LOOP}p2 /mnt/x96root

# 2) 放入新内核与模块
sudo cp -a "$OUT/modules/lib/modules/7.2.12-x96" /mnt/x96root/lib/modules/
sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-7.2.12-x96
sudo cp "$OUT/.config" /mnt/x96root/boot/config-7.2.12-x96
sudo cp "$OUT/System.map" /mnt/x96root/boot/System.map-7.2.12-x96

# 3) chroot 生成 initrd
sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c \
  "depmod -a 7.2.12-x96 && update-initramfs -c -k 7.2.12-x96"

# 4) 取出 initrd 并做 uInitrd
sudo cp /mnt/x96root/boot/initrd.img-7.2.12-x96 /x96-build/
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
  -d /x96-build/initrd.img-7.2.12-x96 /x96-build/uInitrd-7.2.12-x96
```

---

## 7. 打包成 ophub 可用的内核文件

`rebuild` 需要 4 个压缩包，目录：

```text
/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/
├── boot-7.2.12-x96.tar.gz
├── dtb-amlogic-7.2.12-x96.tar.gz
├── modules-7.2.12-x96.tar.gz
├── header-7.2.12-x96.tar.gz
└── sha256sums
```

参考 ophub 6.18 包的布局：

```text
boot-6.18.59-ophub.tar.gz
├── config-6.18.59-ophub
├── initrd.img-6.18.59-ophub
├── System.map-6.18.59-ophub
├── uInitrd-6.18.59-ophub
└── vmlinuz-6.18.59-ophub

modules-6.18.59-ophub.tar.gz
└── 6.18.59-ophub/...
```

对应 7.2.12：

```bash
K=/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
mkdir -p "$K/boot" "$K/dtb" "$K/modules" "$K/header"

# boot
cp "$OUT/.config"                      "$K/boot/config-7.2.12-x96"
cp "$OUT/System.map"                   "$K/boot/System.map-7.2.12-x96"
cp "$OUT/arch/arm64/boot/Image"        "$K/boot/vmlinuz-7.2.12-x96"
cp /x96-build/initrd.img-7.2.12-x96 "$K/boot/initrd.img-7.2.12-x96"
cp /x96-build/uInitrd-7.2.12-x96    "$K/boot/uInitrd-7.2.12-x96"
tar -czf "$K/boot-7.2.12-x96.tar.gz" -C "$K/boot" .

# dtb（只放需要的）
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-7.2.12-x96.tar.gz" -C "$K/dtb" .

# modules
tar -czf "$K/modules-7.2.12-x96.tar.gz" -C "$OUT/modules/lib/modules" 7.2.12-x96

# header：按 ophub collect_headers 规则生成（scripts、include/generated、.config 等）
# 完整可执行命令见 19.5；也可用 compile-kernel 的打包逻辑生成，确保 rebuild 能找到 header-*.tar.gz

(cd "$K" && sha256sum *.tar.gz > sha256sums)
```

> `rebuild` 会检查 `boot-*`、`dtb-amlogic-*`、`modules-*`、`header-*` 四个包都存在；缺一个会报 `The 4 kernel missing.`

---

## 8. 用 ophub rebuild 打包镜像

基础镜像放在：

```text
/x96-build/amlogic-s9xxx-armbian/build/output/images/*-trunk_*.img
```

执行：

```bash
cd /x96-build/amlogic-s9xxx-armbian
sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96custom
```

参数：

| 参数 | 含义 |
|---|---|
| `-b s905x2` | 板型代号（model_database.conf 第 301 行 X96-Max-4GB） |
| `-k 7.2.12` | 使用本地 `build-armbian/kernel/stable/7.2.12/` |
| `-s 512/2560` | BOOTFS 512MiB / ROOTFS 2560MiB |
| `-n x96custom` | 构建者签名 |

产物：

```text
build/output/images/Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_*.img.gz
```

---

## 9. rootfs 裁剪（自定义默认包）

`rebuild` 只负责替换板级内核/U-Boot，**不会自动裁剪**基础镜像的包。当前基础镜像约 484 个包、2.0GiB。

### 9.1 保留

```text
systemd / udev / systemd-networkd / systemd-resolved
openssh-server
iproute2 / iputils-ping / ethtool
iw / wpasupplicant / wireless-regdb / bluez / rfkill（保留 Wi-Fi/蓝牙，2026-11 起不再移除）
ca-certificates / curl / wget / rsync
e2fsprogs / dosfstools / kmod / procps / util-linux
bash / coreutils / findutils / grep / sed / gawk
tzdata / locales（可选）
initramfs-tools
```

### 9.2 移除（示例）

```text
build-essential gcc g++ cpp make autoconf automake libtool
bison flex binutils dkms device-tree-compiler
git git-man patch libc6-dev linux-libc-dev
python3-dev libpython3-dev
armbian-config armbian-zsh zsh aptitude apt-file debsums
plymouth armbian-plymouth-theme fonts-* fontconfig
vim man-db manpages groff-base info html2text
# 无线包保留，不要放这里：bluez wpasupplicant wireless-regdb iw rfkill
f2fs-tools btrfs-progs nfs-kernel-server rpcbind avahi-*
htop iotop iozone3 iperf3 fping expect dialog whiptail figlet bc
```

### 9.3 chroot 裁剪

```bash
IMG=/x96-build/amlogic-s9xxx-armbian/build/output/images/<final>.img
LOOP=$(sudo losetup -Pf --show "$IMG")
sudo mount ${LOOP}p2 /mnt/x96root
sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/

sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y <移除列表>
  apt-get autoremove --purge -y
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /root/.cache
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
'
```

### 9.4 网络与 SSH

```bash
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c '
  echo x96max > /etc/hostname
  cat > /etc/systemd/network/20-eth.network <<EOF
[Match]
Name=eth0
[Network]
DHCP=yes
EOF
  systemctl enable systemd-networkd systemd-resolved ssh
  mkdir -p /root/.ssh
  # 公钥从 ~/.ssh/id_ed25519.pub 写入
  systemctl disable NetworkManager 2>/dev/null || true
'
```

> 驱动保留 ≠ 自动联网：`systemd-networkd` 不处理 WPA。要用 Wi-Fi 时另加 `wpa_supplicant@wlan0`
> （或装 `network-manager` 并 `enable`），默认只走有线；不配置就不会触发连网动作。

### 9.5 固件裁剪

**保留无线固件**（本机 RTL8822BS 只用 `rtw88/` 和 `rtl_bt/`），只删与本机无关的厂商固件：

```bash
# 可以删：brcm / iwlwifi / ath* 等本机不存在硬件的固件
sudo rm -rf /mnt/x96root/lib/firmware/brcm
sudo rm -rf /mnt/x96root/lib/firmware/iwlwifi
sudo rm -rf /mnt/x96root/lib/firmware/ath10k /mnt/x96root/lib/firmware/ath11k
# 必须保留：rtw88（Wi-Fi）、rtl_bt（蓝牙）、rtl_nic（RTL8211F）、amlogic、meson
ls -l /mnt/x96root/lib/firmware/rtw88/rtw8822b_fw.bin \
      /mnt/x96root/lib/firmware/rtl_bt/rtl8822b_fw.bin
```

RTL8822BS 实际需要的固件（名字取自 7.2.12 源码的 `MODULE_FIRMWARE`）：

| 用途 | 固件文件 | 源码出处 |
|---|---|---|
| Wi-Fi | `rtw88/rtw8822b_fw.bin` | `drivers/net/wireless/realtek/rtw88/rtw8822b.c` |
| 蓝牙 | `rtl_bt/rtl8822b_fw.bin` + `rtl_bt/rtl8822b_config.bin` | `drivers/bluetooth/btrtl.c` |

> `rtw88` 只有 `fw.bin` 一个固件，没有 config 文件；蓝牙两个都要（缺 config 时 `btrtl` 用 ROM 默认值）。

清理后卸载、重新压缩：

```bash
sudo umount /mnt/x96root/{dev,proc,sys}
sudo umount /mnt/x96root
sudo losetup -d "$LOOP"
gzip -9 -k -f "$IMG"
```

---

## 10. 写 U 盘与启动验证

### 10.1 写卡（完整流程）

> 一句话：**用 `x96max/write-card.sh`**。它把「关自动挂载 → 写 → 校验 → 恢复」封成一条，
> 判据放在文件系统层（逐文件 sha256），不依赖裸盘 `cmp`。手工分步见 10.1.2，两个必踩的坑见 10.1.3 / 10.1.4。

#### 10.1.1 一键（推荐）

```bash
cd /home/quqiufeng/kernel
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS   # 先看清哪个是卡

sudo ./x96max/write-card.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdX
# 只校验已写好的卡，不动数据
sudo ./x96max/write-card.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdX --verify-only
```

脚本做的事，以及每步失败的含意：

| 步 | 动作 | 失败意味着 |
|---|---|---|
| 0 | 拒绝非整盘（`/dev/sdX1`）、拒绝系统盘、拒绝任何已挂载分区 | 设备选错 |
| 1 | `gsettings automount/automount-open=false` + `systemctl stop udisks2`，退出时 `trap` 恢复原值 | 见 10.1.3 |
| 2 | `dd bs=4M conv=fsync,notrunc` + `blockdev --flushbufs` + `partprobe` | 卡或读卡器写失败 |
| 3 | `losetup -rP` 挂镜像，`sfdisk -d` 比对分区表 start/size/type | 分区表没写进去 |
| 4 | 前 4MiB 裸区（U-Boot + 分区表，不在任何分区内）3 次重读，任一次一致即通过 | 真可疑，重写 |
| 5 | 逐分区：`e2fsck -fn` → 文件清单 → **逐文件 sha256** | 卡内容与镜像不等价 |

实测输出（2026-11-15，3076MiB 镜像 → 14.6G 卡）：

```text
✔ /dev/sdb 是 STORAGE DEVICE 14.6G，未挂载，非系统盘
✔ automount=false / udisks2 stopped
✔ 分区表一致: start=8192 size=1046528 type=c / start=1056768 size=5242880 type=83
✔ 第 1 次重读一致
✔ 分区 1 (vfat): 194 条目，逐文件 sha256 全部一致（190 个文件）
✔ 分区 2 (ext4): e2fsck -fn 干净，9868 条目，逐文件 sha256 全部一致（7495 个文件）
全部通过 —— 卡内容与镜像等价
```

**`write-card.sh` 只管分区里的字节等价，不动启动语义。** 镜像里带的是**出厂 `uInitrd`**
（`slumber=30`）和**出厂 `APPEND`**，所以写完卡还要补两刀，否则 §5.5 的竞态照旧复发：

| 步 | 命令 | 判据 |
|---|---|---|
| 6 | `sudo ./x96max/patch-initrd-wait.sh /dev/sdX1/uInitrd --inplace` | 回读 `slumber=90`（`--check` 可离线复查） |
| 7 | `sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678` | `APPEND` 含 `usb-storage.quirks=346d:5678:u`、`usbcore.autosuspend=-1`，且**无** `rootdelay` |

> 这两步语义幂等，可反复跑；`patch-initrd-wait.sh --inplace` 只在**首次真正改动**时留备份
> （`uInitrd.bak.<unix时间戳>`），第二次不重复备份（但 sha256 会变，属正常）。
> **卡上常有两份 uInitrd**（`uInitrd` 与 `uInitrd-7.2.12-x96`），`uEnv.txt` 的 `INITRD=/uInitrd` 才是真加载那份；
> 两份都打一遍，再用 `--check` 逐个复查，别只改一个（见 §15 第 11 条）。
> `--from initrd` 走全流程重建时，第 6 步已在 19.4 里自动做完，只在**重新写卡**后需要手动补。

参数：`--yes` 跳过输入设备名确认；`--verify-only` 不写、只校验；`--img-cache DIR` 解压缓冲目录
（默认 `$TMPDIR`，`.gz` 需约 3.1G 空间，已存在且比 `.gz` 新则复用）；`--bs 4M` 块大小。
退出码：`0` 通过 / `1` 用法错 / `2` 设备被拒 / `3` 校验失败 / `4` 写盘失败。

#### 10.1.2 手工分步（等价命令）

```bash
IMG=/x96-build/recovery/x96src-autoinstall.img     # 先解压：校验必须对着落盘的 img 比
DEV=/dev/sdX                                       # 确认过是卡

# 1) 关自动挂载（关键，别跳）
gsettings set org.gnome.desktop.media-handling automount false
gsettings set org.gnome.desktop.media-handling automount-open false
sudo systemctl stop udisks2
lsblk -o NAME,MOUNTPOINTS $DEV                     # 必须为空，否则先 umount

# 2) 写
sudo dd if=$IMG of=$DEV bs=4M conv=fsync,notrunc status=progress
sync; sudo blockdev --flushbufs $DEV; sudo partprobe $DEV

# 3) 分区表（去掉设备名差异后应完全相同）
LP=$(sudo losetup -rP --show $IMG)
diff <(sudo sfdisk -d $LP  | sed 's#^/dev/[a-z0-9]*##') \
     <(sudo sfdisk -d $DEV | sed 's#^/dev/[a-z0-9]*##') && echo 分区表一致

# 4) 前 4MiB 裸区（U-Boot + 分区表）——两行 sha256 应相同，不同就重读几次
sudo dd if=$DEV bs=512 count=8192 status=none | sha256sum
dd if=$IMG      bs=512 count=8192 status=none | sha256sum

# 5) 逐文件对拍：判据在这里，不在裸盘 cmp
mkdir -p /mnt/i /mnt/c
for n in 1 2; do
  sudo mount -o ro,noload ${LP}p$n /mnt/i
  sudo mount -o ro,noload ${DEV}$n /mnt/c
  sudo e2fsck -fn ${DEV}$n			# 只有 ext4 分区有这步
  diff <(cd /mnt/i && find . | sort) <(cd /mnt/c && find . | sort) && echo "分区$n 清单一致"
  diff <(cd /mnt/i && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
       <(cd /mnt/c && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
    && echo "分区$n 内容一致"
  sudo umount /mnt/i /mnt/c
done
sync; sudo losetup -d $LP

# 6) 恢复自动挂载
gsettings set org.gnome.desktop.media-handling automount true
gsettings set org.gnome.desktop.media-handling automount-open true
sudo systemctl start udisks2
```

`ro,noload` 不能省：卡上的 ext4 日志可能还没回放，plain `-o ro` 挂不上去，
会被误判成「文件系统结构损坏」（脚本同理，它按 fstype 自动加 `noload`）。

#### 10.1.3 坑一：dd 之前必须关桌面自动挂载

GNOME/udisks2 会在 dd 结束、内核重读分区表的瞬间把 `${DEV}2` 以 **rw** 挂上，于是：

```text
dd 写完 → 内核读到新分区表 → udisks2 自动 mount rw
        → ext4 做日志回放 → 经 USB 读卡器读到错字节
        → 回放结果写回卡里 → 垃圾被「固化」成真实损坏
```

实测症状：`/usr/lib/udev/hwdb.d/20-pci-vendor-model.hwdb` 字符错位、**文件长度不变**、
`e2fsck -fn` 干净、能正常挂载，只有逐文件 sha256 抓得到。同一镜像连写两次，坏的是同一个文件——
不是偶发，是「写 → 自动挂载 → 日志回放」这条固定链路。

正确顺序：关自动挂载 → dd → 校验 → 才恢复。脚本用 `trap` 保证异常退出也恢复，
不会把桌面长期留在「插卡不自动挂载」的状态。

#### 10.1.4 坑二：裸盘 `cmp` 不是判据

USB 读卡器大块读会返回错字节：`bs=1M` 几乎必错，`bs=256K` 仍有约 0.1% 的块出错。
更麻烦的是**同一位置重读多次给出相同的错字节**，所以「重读 3 次一致」证明不了内容正确。

对同一张卡做裸盘比对，能看到几百字节散布在小块里与镜像不同；但 `ro` 挂上逐文件 sha256，
7500 个文件全一致、`e2fsck -fn` 干净、条目数一致。这类差异只落在未分配空间，
成因可能是读路径返回错字节，也可能是 10.1.3 的日志回放写入——两者都**不影响文件系统语义**。

| 现象 | 判定 |
|---|---|
| 裸盘 cmp 有几百字节不同，但逐文件 sha256 全一致 + `e2fsck -fn` 干净 | **通过**，差异在未分配空间 |
| 逐文件 sha256 有差异（尤其同一文件反复坏） | **失败**，重写；连坏两次换读卡器/换卡 |
| 某分区挂不上，或 `e2fsck` 报结构错 | **失败**，重写 |
| 分区表 start/size 与镜像不同 | **失败**，重写（多半 dd 没跑完或写到别名设备） |

所以：**别用 `cmp`/`diff` 比整个裸盘来判写卡成败**——它会把好卡判成坏卡，逼你反复重写，
而每次重写又在放大 10.1.3 的风险。

#### 10.1.5 写完立刻拔卡

校验一通过就**马上从读卡器拔下来**。卡留在电脑上，任何一次 media-change 事件
（切 VT、插拔别的 USB、`systemctl restart udisks2`）都可能触发 rw 挂载，重复 10.1.3 的污染，
而这次的污染发生在你「已经校验过」之后，最难发现。

### 10.2 盒子从 U 盘启动

- X96 Max 的 U-Boot 通常 **USB 启动优先于 eMMC**。
- 插入 U 盘/SD、上电。

> ⚠️ **绝对不要为了「逼它走 SD/U 盘」去改名 eMMC 上的 `boot.scr` / `uEnv.txt`——会黑屏变砖，且拔卡也无法自愈。**
>
> 2026-11-15 实测（SD 卡已插好、Linux 侧能认到 `mmc0`）：把 `/boot/uEnv.txt` 改名后上电 →
> 盒子彻底黑屏、ARP `FAILED`、22 端口无响应。原因不是「卡没插好」，而是 eMMC 上的 `boot.scr` 只有
> `for devnum in 2 1 0` 三段，**dev 0 ≠ SD 卡**（U-Boot 的 mmc 编号来自设备树 alias，和 Linux 的
> `mmc0/mmc1` 不是一回事）；dev 1 失配后 dev 0 同样读不到，循环跑完无 `booti` → 黑屏。
> 而且这条链是 **BootROM 直接选了 eMMC**：Linux 能识别那张 SD 卡 ≠ BootROM/U-Boot 也能。
>
> 正确做法：**上电瞬间按住复位孔 5 秒**强制 BootROM 走 SD（见 §10.2.1），或直接走串口/USB 烧录。
> 想验证 SD 是否能启动，先「按复位上电」看 HDMI，**不要动 eMMC 上任何引导文件**。

### 10.2.1 强制 BootROM 从 SD 启动（救砖第一步）

1. 拔电源
2. 卡针按住底部复位孔（AV 口内圈或底壳小孔），**不要松**
3. 插电源，按满 **5 秒**再松
4. HDMI 出启动信息 = 成功；若停在 `Hit any key`，**不要按键**

Amlogic 官方救砖流程，绕开 eMMC 上一切 U-Boot 配置，不依赖 `boot.scr` 的 devnum 扫描。
注意：被改坏的引导文件仍在 eMMC 上，起来后立刻 `mv /boot/uEnv.txt.disabled /boot/uEnv.txt` 复原。

### 10.2.2 U 盘在盒子上读一半掉线（`cmd_age=30s` + `reset`）

**症状**（2026-11-15，Teclast CoolFlash `346d:5678`，32G，写卡校验全绿）：

```text
42.435373 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
42.569531 sd 0:0:0:0: [sda] tag#0 UNKNOWN(0x2003) Result: hostbyte=0x03 driverbyte=DRIVER_OK cmd_age=30s
42.573627 CDB: opcode=0x28 28 00 00 15 c7 a0 00 00 08 00
42.581156 I/O error, dev sda, sector 1427360 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 2
```

读三行的含义：

| 字段 | 说明 |
|---|---|
| `tag#0 UNKNOWN(0x2003)` + `hostbyte=0x03` | 命令没拿到结果就被链路断开，不是数据错/校验错 |
| `cmd_age=30s` | SCSI 层等到超时上限才报错（默认 `eh_timeout` 30s） |
| `hostbyte=0x07` + `cmd_age=0s` | `DID_ERROR`：命令刚下发就被 `reset` 打断，**不用等 30s**，是同一故障的更狠变体（见下方 16:34 补充） |
| `reset ... device number 2` | xHCI 在超时后复位设备；日志里只有 USB 2.0 的 `high-speed` |

**位置**：sector 1427360 × 512 = 697MiB。p1 只占 0–511MiB，所以断的是 **rootfs 内约 185MiB 处**——系统读根盘时就断，卡在挂 root，后面全无输出。

**关键判据：这不是卡坏了。** 同一根盘在同一台 PC 上 `verify-card.sh` 全量 sha256 通过（分区表 / 前 4MiB / 194 条 vs 9868 条清单），换到盒子读就掉。差异只在盒子的 USB 主控与供电。

**决定性对比——枚举速度**：

| 位置 | `speed` | 协议 |
|---|---|---|
| PC（热插后 `/sys/bus/usb/devices/*/speed`） | **5000** | USB 3.2 SuperSpeed |
| 盒子（dmesg 日志） | **480**（`high-speed`） | 掉回 USB 2.0 |

一块 USB3 盘插 USB3 口却只以 USB2 枚举 ⇒ **SuperSpeed 那对差分线没起来**（口是 USB2 / 延长线 / 供电压不住信号）。链路本就不稳，大块读必超时复位。

**按成本从低到高**：

1. **换到盒子蓝色 USB3 口，直插，不用延长线**（最可能直接解决）
2. 接**有源 HUB**（这类盒子 USB 口带不动峰值电流，廉价 U 盘尤其明显）
3. 内核参数兜底：禁 UAS + 禁运行期挂起（见下）
4. 走 **microSD 槽**，稳定性远好于 U 盘；同一个 `img.gz` 直接 `write-card.sh`
5. 换 USB-SATA SSD

**第 3 条的改法**（改 p1 的 `uEnv.txt`，不要手抠，用脚本）：

```bash
sudo ./x96max/patch-bootargs.sh -l                        # 先看当前 APPEND
sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678      # 追加下面两行
```

等价于在 `APPEND=` 末尾加：

```text
usb-storage.quirks=346d:5678:u usbcore.autosuspend=-1
```

> 这两条治的是**掉盘**（链路层超时复位）。§5.5 那个「枚举晚 1.3 秒被 initramfs 放弃」的竞态
> **不归它管**，要用 `patch-initrd-wait.sh` 抬 `slumber`（`rootdelay` 无效，已废）。
> 两种故障出现在同一根盘、同一台盒子上，所以**两样都做**：先 `patch-initrd-wait.sh`，再 `--usb-fix`。

`:u` = 对该盘禁用 UAS、强制走老的 BOT 协议（G12A 的 xHCI 上 UAS 翻车率高，症状与本例一致）。
**但要老实说**：本例在 `high-speed` 下枚举，UAS 大概率本就没参与，真正起作用的是「换口」，这两行属于保险。

> 副作用提醒：因为断在 rootfs 之前，`x96-autoinstall` 一次都没跑过，**eMMC 完全未被写入**。
> 看到这类日志不要急着怀疑安装脚本，先确认 root 是否挂上：串口里没有 `EXT4-fs ... mounted filesystem` 就是没到那一步。

**2026-11-15 15:31 补充：这根盘在 PC 上也掉了一次，判据要改。**

写卡那台 PC（15 点后）的 dmesg：

```text
27557.182388 usb 2-3: new SuperSpeed USB device number 14 using xhci_hcd   ← 5000M，正常
27558.450197 EXT4-fs (sdb2): mounted filesystem 74d71f81-… r/w              ← sdb2 读写正常
27863.540836 EXT4-fs (sdb2): unmounting filesystem 74d71f81-…
27863.659632 sdb: detected capacity change from 61440000 to 0               ← 掉盘
27868.868765 usb 1-3: new high-speed USB device number 16 using xhci_hcd    ← 重插后只剩 480M
27870.289731 usb 1-3: device not accepting address 16, error -71           ← 直接枚举失败
```

三条新信息：

1. **PC 上原本是 `SuperSpeed`(5000M)，读写 `sdb2` 正常** —— 说明线/口/卡当时都好，数据没坏。
2. **同一根盘随后在 PC 上也掉了**（`capacity change … to 0`），重插后只能 `high-speed` 且 `error -71` 枚举失败。
   ⇒ 掉盘不专属于盒子的 USB 口，「卡/线已开始接触不良或供电衰减」也是候选因，不能只怪盒子。
3. 因此 §10.2.2 的排查第 0 步改成：**先在 PC 上把这张卡重新插一次，看 `speed` 是不是 5000**。
   - 仍是 5000 且 `verify-card.sh` 全绿 → 卡没问题，锅在盒子，按上面 1→5 走；
   - 只有 480 或干脆 -71 → **先换线/换卡/换口**，再谈盒子，否则会白折腾内核参数。

```bash
# PC 侧重插后判定（不用 dmesg 也能看）
for d in /sys/bus/usb/devices/*/; do
  [ -r "$d/speed" ] && echo "$(basename $d) $(cat $d/speed) $(cat $d/product 2>/dev/null)"
done | grep -i -e 5000 -e teclast
```

**2026-11-15 16:34 补充：打完 initrd 补丁后复发，且换了个变体。**

插盒子开机（HDMI 拍照，t=12.4s 起）：

```text
12.441849 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
12.575937 sd 0:0:0:0: [sda] tag#0 UNKNOWN(0x2003) Result: hostbyte=0x07 driverbyte=DRIVER_OK cmd_age=0s
12.579922 CDB: opcode=0x28 28 00 00 15 ee 70 00 00 f0 00
12.587454 I/O error, dev sda, sector 1437296 op 0x0:(READ) flags 0x84700 phys_seg 27 prio class 2
12.718533 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
12.859290 sd 0:0:0:0: [sda] tag#0 UNKNOWN(0x2003) Result: hostbyte=0x07 driverbyte=DRIVER_OK cmd_age=0s
12.870816 I/O error, dev sda, sector 1426104 op 0x0:(READ) flags 0x80700 phys_seg 17 prio class 2
13.966007 Console: switching to colour frame buffer device 240x67
44.145170 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
44.294348 I/O error, dev sda, sector 1324564 op 0x0:(READ) flags 0x800700 phys_seg 2…
74.871827 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
105.585128 usb 3-1: reset high-speed USB device number 2 using xhci-hcd
```

四条新信息，按重要性：

1. **这是 §10.2.2 的掉盘，不是 §5.5 的竞态。** 竞态的症状是 `Gave up waiting` 后**一句 `I/O error` 都没有**；
   这里是根盘每读必错、而且 `reset` 一直重试。抬 `slumber` 对它**无效**（它治的是「等不等得到」，不治「读得动读不动」）。
2. **变体更狠：`hostbyte=0x07`(`DID_ERROR`) + `cmd_age=0s`**，不是原来的 `0x03`(`DID_TIME_OUT`) + `cmd_age=30s`。
   含义是命令刚下发就被 `reset` 打断（错误处理链立刻放弃），连 30s 超时预算都用不上。
   判据表已补这一行——**别看到 `cmd_age=0s` 就以为不是掉盘**。
3. **复位呈 ~30s 周期**（44.1 / 74.9 / 105.6），一直不恢复 ⇒ 这一轮开机**卡死在 initramfs 里**，没到 `login:`。
   12.5s 就在读 `p2` 内 646–702MiB 区域，是 initramfs 的 `e2fsck`（`fsck.fix=yes`）在扫根盘，扫到坏链路上。
4. **失败扇区稳定在同一片**：1426104 / 1437296 / 1324564（≈646–702MiB），与 15:31 那次 1427360 同区。
   这和 §15 第 9 条的「同一位置重读给出相同错字节」对得上：坏的不是随机 flash，而是**这条链路在固定负载下必断**。

**由此推出的结论（重要）**：

- `usb-storage.quirks=346d:5678:u` + `usbcore.autosuspend=-1` **已在 `APPEND` 里生效，但没治好**。
  与本节自己那句「在 `high-speed` 下 UAS 本就没参与，这两行属保险」一致——**别再在这两个参数上加码**。
- **`patch-initrd-wait.sh`（`slumber=90`）至今未被真正验证过一次**：每次都在它生效之前就被掉盘打死。
  §0 第 8 条的「待真机复验」要一直挂着，直到有一天能看到 rootfs 挂上。
- 结合 15:31 补充（同一根盘在 PC 上 `capacity change → 0`、重插只剩 `high-speed` + `error -71`）：
  **这根 Teclast 盘/它的接口已经在衰减**，把它当根盘等于拿一次开机赌一次链路。

**处置（按推荐顺序，第 1 条优先）**：

| 序 | 做法 | 理由 |
|---|---|---|
| 1 | **换 microSD 卡，同一个 `img.gz` 走 `write-card.sh`** | 盒子 SD 槽走内部 MMC 控制器，整条 USB 链路从根盘路径上消失；掉盘与竞态两个故障同时绕过 |
| 2 | USB-SATA SSD + **有源 HUB** | 供电与主控都换掉，比再换一个廉价 U 盘可靠 |
| 3 | 换全新 U 盘（USB2 盘也行，480M 本就够） | 只有手边没有 SD/SSD 时才走这条 |
| — | ~~继续调内核参数~~ | 已排除：参数在、故障照旧 |

> 目标没变（§19：装到 eMMC）。USB 只是**用来跑一次 `x96-autoinstall` 的临时载体**，
> 它在半路掉链子属于载体问题，不该让内核树陪跑。

### 10.3 验证

```bash
ssh root@<新IP>
ip -brief addr
ethtool eth0
ip route
systemctl status systemd-networkd
lsmod
dmesg | grep -iE "meson8b-dwmac|RTL8211F|panfrost|meson-drm|snd|mmc"
aplay -l
```

**先验启动门槛（这两行不过，后面的都不用看）**：

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E 'rootdelay|quirks'   # 只有 quirks 两行，无 rootdelay
dmesg | grep -E 'Gave up waiting|mounted filesystem'            # 只有后者；前者出现=等待窗口没打进去
```

预期：

- root 挂在 USB 盘上（`findmnt -no SOURCE /` = `/dev/sda2` 之类），全程无 `Gave up waiting`
- `eth0` 有 IPv4，`RTL8211F` 链路 1Gbps
- SSH 可登录
- 无线驱动在：`lsmod | grep -E 'rtw88|btrtl|hci_uart|btusb'`，`dmesg | grep -iE 'rtw88|btrtl|Bluetooth'` 无固件加载失败
- 无线**不自动联网**：`ip link` 里 `wlan0` 存在但无地址属正常，`eth0` 的 IPv4 不受影响
- `panfrost`、`meson-drm`、AXG 音频、`meson_vdec` 正常

---

## 11. 安装到 eMMC（本机最终成功方法）

**本机必须使用主线 U-Boot**。X96 Max S905X2 在 6.18/7.2 内核下：

- 用原厂 U-Boot + `u-boot.emmc` 重载 → eMMC 黑屏
- 手工 rsync / 只替换 p1、p2 → eMMC 黑屏
- **`armbian-install -m yes -a no` → 成功**

从 SD/U 盘启动后执行：

```bash
armbian-install -m yes -a no
# 设备选择 301（X96-Max-4GB,Tx5-Max）
# 文件系统选择 1（ext4）
```

参数含义：

- `-m yes`：写主线 U-Boot `x96max-u-boot.bin.sd.bin`
- `-a no`：禁用 ampart，使用主线 U-Boot 的固定布局

成功后的实际分区布局：

```text
mmcblk1p1  511M  FAT32 BOOT_EMMC   start=139264 sectors  (68MiB)
mmcblk1p2  56.9G ext4  ROOTFS_EMMC start=2764800 sectors (1350MiB)
```

`/etc/ophub-release` 关键值：

```text
MLUBOOT_STATUS='yes'
MAINLINE_UBOOT='/usr/lib/u-boot/x96max-u-boot.bin.sd.bin'
AMPART_STATUS='no'
DISK_TYPE='emmc'
ROOTFS_TYPE='ext4'
```

安装完成后：关机 → 拔 SD/U 盘 → 上电，从 eMMC 启动。

> 旧的手工 `rsync`/只替换 p1、p2 方法会黑屏，不要再用。
> 写主线 U-Boot 会覆盖 eMMC 启动区，安装前必须备份；备份在 NAS `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`（本地暂存 `~/x96-backup/emmc-original-backup/`）。

---

## 12. 风险与回滚

1. **不要先写 eMMC**：先在 U 盘验证网络/SSH/驱动。
2. **保留商家原镜像/备份**：U 盘可启动 + eMMC 备份是最低要求。
3. **U-Boot**：本机最终使用**主线 U-Boot**（`-m yes`），不是原厂 U-Boot；这是解决 eMMC 黑屏的关键。
   - 写主线 U-Boot 会覆盖 eMMC 启动区，**必须先备份**：原厂启动区 117MiB、p1、p2 在 NAS `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`（本地暂存 `~/x96-backup/emmc-original-backup/`）。
   - 手工只替换 p1/p2 而不写主线 U-Boot，会黑屏；不要再用。
   - 若要回退原厂系统：从 SD 启动，把备份的启动区/p1/p2 写回，或按原厂线刷流程恢复。
4. **eMMC 起始区不要手写**：原厂占 0–117MiB（U-Boot 2015.01 + BL2/BL30/BL31 + 孤儿 FAT），
   主线 U-Boot 后占 0–68MiB；这段只能由 `armbian-install -m yes` 或 `dd` 原厂备份整段写入。
5. **失败恢复**：
   - 仍能 USB 启动：重新写 U 盘镜像即可。
   - 不能 USB 启动：用 Amlogic USB Burning Tool + 原厂/备份镜像救砖（需 USB 双公头线）。
6. 凭据只放 `~/.env`，不要写进仓库。

---

## 13. 当前进度

| 步骤 | 状态 |
|---|---|
| 硬件/系统/驱动分析 | 完成 |
| ophub 构建环境 | 完成 |
| 基础镜像 + 6.18.59 重打包（未裁剪，用于验证流程） | 完成 |
| 7.2.12 源码与配置（有线为主，Wi-Fi/BT 驱动保留） | 完成 |
| Wi-Fi/蓝牙驱动 + 固件（RTL8822BS） | 驱动/固件已保留，联网实测待做 |
| 7.2.12 `Image` / `modules` 编译 | 完成 |
| DTB `meson-g12a-x96-max.dtb` | 完成 |
| initrd / uInitrd | 完成（arm64 chroot 生成） |
| 内核 4 个 tar 包 | 完成 |
| `rebuild` 最终镜像 | 完成 |
| rootfs 裁剪（第一版验证） | 完成（484 → 312 包） |
| 源码 rootfs（Armbian build + mmdebstrap） | 完成（253 包，6:52） |
| 源码 rootfs 注入 + `rebuild` | 完成（7.2.12-x96） |
| SD/U 盘启动验证 | 完成（源码系统 `x96src`） |
| eMMC 安装 | 完成（主线 U-Boot，`-m yes -a no`） |
| eMMC 启动验证 | 完成（源码系统，`/dev/mmcblk1p2`，7.2.12-x96） |
| initramfs 等待窗口固修（`slumber` 30 → 90） | 已打进卡（`patch-initrd-wait.sh`），**待真机复验** |
| 启动参数 `rootdelay=15` 废弃并删除 | 完成（`patch-bootargs.sh -r rootdelay=15`，APPEND 21 参数） |
| 脚本归位 `x96max/`（build-kernel / pack-kernel / build-image / write-card / verify-card / flash-p1 / backup-card / rebuild-from-zero / patch-bootargs / patch-initrd-wait + README） | 完成（多数是本次从临时目录收进来的） |
| 全量树对照编译（`src-clean` + `kbuild-clean`，同配置） | 完成（17:08，`Image` 42.2MB；量化出裁剪树静默丢 **1789** 个符号，见 §5.7） |
| 用全量内核重出四包 / initrd / 镜像 | **未做**（下一步，§5.7 末） |
| 系统校时（`systemd-timesyncd` + 国内 NTP） | 完成（17:55，`NTPSynchronized=yes`；镜像本身未装，见 §20） |

**卡当前状态（2026-11-15 16:30 实测，`/dev/sdb`，只读取证）**

| 项 | 值 | 怎么验的 |
|---|---|---|
| 卡内容 vs 镜像 | 等价（逐文件 sha256） | `write-card.sh … --verify-only` 全绿（§10.1.1） |
| `uEnv.txt` `APPEND` | 21 参数，`rootdelay` 已无；保留 `rootwait` / `usb-storage.quirks=346d:5678:u` / `usbcore.autosuspend=-1` | `patch-bootargs.sh -l` |
| `/uInitrd`（u-boot 实载，`INITRD=/uInitrd`） | `slumber=90` | `patch-initrd-wait.sh … --check` |
| `/uInitrd-7.2.12-x96`（ophub 产物，原名保留） | `slumber=90`（16:30 补打） | 同上 |
| 待办 | 插盒子上真机复验：开机不出现 `Gave up waiting`，直接到 `login:`。**16:34 那次被掉盘（`hostbyte=0x07`/`cmd_age=0s`）打死在 `e2fsck`，`slumber=90` 仍未取到真机证据**（§10.2.2、§5.6） | — |

> 最终 rootfs 是 **Armbian build framework + mmdebstrap 源码构建**；内核 7.2.12 是自编译。

---

## 14. 关键路径速查

```text
构建仓库      /x96-build/amlogic-s9xxx-armbian
Armbian build /x96-build/armbian-build
源码 rootfs   /x96-build/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst
内核源码      /x96-build/src-linux（裁剪树 545M；/opt/linux/src 原版树已删，见 §5.3）
内核构建      /x96-build/kbuild-7.2.12
基础镜像      /x96-build/amlogic-s9xxx-armbian/build/output/images/
内核包目录    /x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/
最终镜像      /x96-build/amlogic-s9xxx-armbian/build/output/images/
仓库脚本      /home/quqiufeng/kernel/x96max/
输出镜像      /x96-build/recovery/x96src-autoinstall.img.gz
initrd 中间件 /x96-build/initrd.img-7.2.12-x96、/x96-build/uInitrd-7.2.12-x96
卡上 uInitrd   <卡 p1>/uInitrd（已 patch 成 slumber=90，备份 uInitrd.bak.<时间戳>）
源码镜像      Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz
eMMC 备份     dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/
NAS 备份目录  dav://192.168.1.53:5005/sata11-18072858035/x96-backup/
              http://192.168.1.53:5005/sata11-18072858035/x96-backup/
              含 x96src-autoinstall.img.gz、x96src-fixed.img.gz、
              x96src-small.img.gz、emmc-original-backup/、SHA256SUMS
NAS 镜像备份  dav://192.168.1.53:5005/sata11-18072858035/x96max/
              http://192.168.1.53:5005/sata11-18072858035/x96max/
              含 x96-trim-autoinstall.img.gz、Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
              及各自 .sha256（见 §19.6.3）
 本地暂存      /x96-build/recovery/（两个成品 gz、orig/、u-boot 等）
               基础镜像只在 amlogic-s9xxx-armbian/build/output/images/ 一处
               （`~` 下无副本；`~/x96-backup/` 只剩 usb-stick 快照，见 §19.6.3）
设备          root@192.168.1.121（DHCP，可能变化；ssh 用 IP）
只换内核      §23：编 Image/dtb/modules → scp 到盒子 /tmp → 盒上 depmod+mkinitramfs+mkimage → 重启
              不动 rootfs、不做镜像、不写卡；/boot 是 mmcblk1p1，uEnv.txt 加载 zImage + uInitrd + dtb
```

---

## 15. 本次踩坑（重要）

1. **不要直接用 USB 镜像的 p1 覆盖 eMMC p1**：会把 `aml_autoscript` / `u-boot.emmc` 带进去，eMMC 黑屏。
2. **不要手工 rsync p1/p2**：即使 UUID、fstab 都正确，eMMC 启动脚本不对也会黑屏。
3. **`armbian-install` 默认 `-a yes` 不够**：本机必须用 `-m yes -a no`（主线 U-Boot + 禁用 ampart）。
4. **`u-boot.emmc` 是 6.x+ 内核的重载 U-Boot**：原厂 U-Boot + 它会黑屏；主线 U-Boot 流程可以正常接管。
5. **eMMC 启动验证前先 SD 启动**：SD 是可靠的救援盘；失败可随时插 SD 回来修。
6. **Amlogic Maskrom 的 `update` 工具在本机控制传输不稳定**：T95 的 Allwinner FEL 经验不能直接套用；能 SD 启动就不要再纠结 Maskrom。
7. **备份先行**：原厂启动区 117MiB、p1、p2 都在 `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`；写主线 U-Boot 前必须保留。
8. **写卡前关桌面自动挂载**：udisks2 会在 dd 结束后把卡以 **rw** 挂上 → ext4 日志回放 → 经不稳的读路径读到错字节再写回，垃圾被固化成真损坏（症状：文件字符错位、**长度不变**、`e2fsck -fn` 干净，只有逐文件 sha256 抓得到）。一条命令避开：`sudo x96max/write-card.sh <img.gz> /dev/sdX`，详见 §10.1.3。
9. **U 盘掉盘先看 `speed`，别急着换卡**：`reset ... high-speed` + `I/O error` + `hostbyte=0x03`/`0x07` 是链路层故障，不是数据损坏（`0x03`+`cmd_age=30s` 是超时；`0x07`+`cmd_age=0s` 是刚下发就被打断，同一故障两种形态）；同一根盘在 PC 上 sha256 全绿就说明卡没问题。USB3 盘在盒子上只以 480M 枚举基本等于掉到了 USB2 链路，先换口/上有源 HUB。详见 §10.2.2。
10. **别用整盘 `cmp` 判写卡成败**：USB 读卡器大块读会返回错字节，且同一位置重读给出**相同的错字节**，裸盘比对必然出现几百字节假差异，会把好卡判成坏卡、逼你反复重写（每次重写又在放大第 8 条的风险）。判据是逐文件 sha256 + `e2fsck -fn`，见 §10.1.4。
11. **卡 p1 上有两份 uInitrd，改错白改**：`uEnv.txt` 的 `INITRD=/uInitrd` 才是 u-boot 真加载的那份，
    但同一目录还躺着 `uInitrd-7.2.12-x96`（ophub `rebuild` 产物，37MB，`slumber=30`）。
    只打 `/uInitrd` 时它是**静默的地雷**——哪天 `INITRD=` 被改、或 boot 脚本回退到带版本号的名字，30 秒预算就回来了。
    两份都打（`--check` 逐个复查），见 §10.1.1 第 6 步。
12. **`patch-initrd-wait.sh --inplace` 是语义幂等、不是字节幂等**：重复跑会重新 `cpio | gzip -9`，
    sha256 会变（存档顺序/时间戳），但 `slumber` 仍是 90、内容不丢；备份只在**首次真正改动**时留
    （`<文件>.bak.<unix时间戳>`），第二次不会堆垃圾。
13. **`patch-initrd-wait.sh` 只能处理 gzip initramfs**：`uInitrd` 头部之后若不是 gzip（`.xz`/`.zstd`）脚本会直接报错退出，
    不会产出半成品；换了压缩方式的镜像要先 `--check` 一遍，别假设它能打。
14. **删源码目录前先看它的 `Kconfig` 有没有被 `source`。** `disable.list` 划掉一个 `CONFIG_*` 只是「不编它」，
    但 `prune_src.py` 若因此删掉整个目录（含 `Makefile` + `Kconfig`），`drivers/*/Kconfig` 里的 `source` 行
    就悬空了，`olddefconfig` 会把这个开关**静默丢成 `n`**：`Image` 照编照引导，直到挂根盘才报
    `Gave up waiting for root file system device`。这次的代价是 `drivers/usb/storage/` 整目录被裁，
    完整复盘与三级验证见 §5.4。
15. **裁剪的真正代价是"符号从配置空间里消失"，不是"少编几个驱动"**（2026-11-15 17:08 实测）：
    全量树与裁剪树用同一份起始配置编译，`.config` 差 **1789 个符号**（345 个 `=y`、1433 个 `=m`），
    `Image` 35.9MB → 42.2MB。丢掉的 `=y` 里有 `PM_GENERIC_DOMAINS(_OF)`、`ARM_PSCI_CPUIDLE_DOMAIN`（genpd 整块）、
    `HW_PERF_EVENTS`、`USB_GADGET` 全家。**所以"裁剪树能编能启动"不能作为"裁剪无害"的证据**；
    判据是逐符号 diff（`diff <(grep '=' 全量.config) <(grep '=' 裁剪.config)`）或 `scripts/diffconfig`，见 §5.7。
16. **`apt-get update` 报 `is not signed` / `Not live until 2026-11-15T07:38:06Z` 先查时钟，别急着换源**（2026-11-15 17:55）：
    镜像**没装任何 NTP 客户端**（`timesyncd`/`chrony`/`ntp` 全无），RTC 一偏就是几个月，Debian 的 `InRelease`
    签名"还没到生效时间" → sqv 判定整个仓库未签名，所有源全红，但网络和清华源本身完全正常。
    判据：`timedatectl` 里 `System clock synchronized: no`、`NTP service: n/a`。修法见 **§20**。

---

## 16. 源码 rootfs 构建（Armbian build framework，最终方案）

> 目标：不用 ophub 预编译 rootfs，也不靠手工裁剪；用官方 Armbian build framework + mmdebstrap 从 Debian trixie 包构建 rootfs，再与自编译 7.2.12 内核打包。

### 16.1 构建 rootfs

> 仓库内已提供 `x96max/build-image.sh`，会自动安装 `x96max/config-x96-source.conf` 并执行以下步骤；也可按本节手工执行。

```bash
git clone https://github.com/armbian/build /x96-build/armbian-build
cd /x96-build/armbian-build

./compile.sh rootfs \
  BOARD=odroidn2 BRANCH=current RELEASE=trixie \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  EXPERT=yes PREFER_DOCKER=no ARTIFACT_IGNORE_CACHE=yes
```

关键：

- `BOARD=odroidn2`：官方 Armbian 没有 X96 Max 板型；沿用商家镜像的 OdroidN2 基础（`/etc/armbian.txt` 也是 Odroidn2）。
- `ARTIFACT_IGNORE_CACHE=yes`：**必须**。否则 Armbian 会从 ghcr.io 拉预编译 rootfs 缓存，不是源码构建。
- 原生 x86 构建会用 `mmdebstrap` + qemu 构建 arm64 rootfs；实测约 **6:52**。
- 产物：`cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst`（约 108M）。

### 16.2 注入通用 Armbian 镜像

`rebuild` 需要 `.img` 基础镜像。把源码 rootfs 替换进官方通用镜像：

```bash
BASE=.../Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
R=.../cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst
LOOP=$(sudo losetup -Pf --show "$BASE"); sudo mount ${LOOP}p1 /mnt/base-root
sudo rsync -a /mnt/base-root/boot/ /x96-build/base-boot-backup/
sudo find /mnt/base-root -mindepth 1 -maxdepth 1 -exec rm -rf {} +
zstd -dc "$R" | sudo tar -xpf - --numeric-owner --xattrs --xattrs-include='*' -C /mnt/base-root
sudo rsync -a /x96-build/base-boot-backup/ /mnt/base-root/boot/
# 源码 rootfs 是空目录结构，rebuild 需要这两个目录
sudo mkdir -p /mnt/base-root/usr/lib/modules /mnt/base-root/usr/src
# SSH/网络
sudo mkdir -p /mnt/base-root/root/.ssh
sudo cp ~/.ssh/id_ed25519.pub /mnt/base-root/root/.ssh/authorized_keys
# 设置 root 密码、sshd_config、/etc/systemd/network/20-eth.network
sudo umount /mnt/base-root; sudo losetup -d "$LOOP"
```

### 16.3 打包 7.2.12 镜像

```bash
cd /x96-build/amlogic-s9xxx-armbian
sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96src
```

产物：

```text
build/output/images/Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz (375M)
```

- 首次 `rebuild` 若报 `tar: .../usr/lib/modules: No such file`，就是 16.2 的两个目录没建。
- `rm: ... Device or resource busy` 来自上一次失败 `rebuild` 的临时挂载；清理 `build/tmp_dir` 的 loop mount 即可，不影响本次产物。

### 16.4 写盘与验证

```bash
sudo dd if=<source>.img of=/dev/sdX bs=4M status=progress conv=fsync
```

盒子按复位从 U 盘/SD 启动，确认：

```text
hostname  x96src
uname -r  7.2.12-x96
findmnt / /dev/sda2（U 盘）或 /dev/mmcblk0p2（SD）
```

### 16.5 安装到 eMMC

从源码系统启动后：

```bash
armbian-install -m yes -a no
# 301 / ext4
```

关机、拔 U 盘/SD、上电；eMMC 启动后：

```text
hostname  x96src
uname -r  7.2.12-x96
findmnt / /dev/mmcblk1p2
dpkg -l | grep -c ^ii   # 253
```

- `/etc/ophub-release`：`MLUBOOT_STATUS='yes'`、`MAINLINE_UBOOT='/usr/lib/u-boot/x96max-u-boot.bin.sd.bin'`、`AMPART_STATUS='no'`。
- eMMC 布局：p1 68MiB 起 511M，p2 1350MiB 起 56.9G。

### 16.6 结果

最终系统 = **源码构建 rootfs（Armbian 26.8.3 trixie，从 253 包裁剪到 155 包）+ 自编译 Linux 7.2.12-x96 + 主线 U-Boot**。  
Wi-Fi/蓝牙驱动与固件保留（`rtw88_8822bs` + `btrtl`，固件 `rtw88/`、`rtl_bt/`）；有线 RTL8211F 1Gbps；Panfrost/AXG audio/meson_vdec 正常。  
裁剪后 rootfs 约 568M（不含无线包；保留无线后约 +14M），`/lib/firmware` 9.4M（不含 `rtw88`/`rtl_bt`，保留后约 +0.5M），`/usr/share` 14M。

## 17. 源码构建踩坑

1. `ARTIFACT_IGNORE_CACHE=yes` 必须加，否则拿到的是 OCI 预编译 rootfs。
2. `rebuild` 要求 rootfs 存在 `/usr/lib/modules` 和 `/usr/src`；源码 rootfs 没有，需手动创建。
3. 源码 rootfs 的 `/boot` 是空的；注入基础镜像时先备份/恢复基础镜像的 `/boot`，再由 `rebuild` 替换内核。
4. 源码 rootfs 的时间戳可能超前，`tar` 会刷 `time stamp ... is in the future`，无害。
5. 源码 rootfs 默认 253 包；如要更小，可在 `userpatches/customize-image.sh` 或构建后继续裁。
6. 保留无线时**两处必须同时改**：内核 `-e` 启用 + rootfs 别删 `rtw88`/`rtl_bt` 固件与 `iw`/`wpasupplicant`。
   只改一处的话症状是：`wlan0` 根本不出现（内核无模块），或出现了但 `dmesg` 报
   `Direct firmware load for rtw88/rtw8822b_fw.bin failed`（固件被裁）。
7. **`rootfs-minimal` 不自带 `hexdump`**（属 `bsdextrautils`）：`armbian-install` 的 `check_depends` 会
   `which hexdump`，200/352 行真的用它读 `zImage`/`u-boot` 魔数；`x96-autoinstall.sh` 依赖自检
   `exit 1` 且只往 tty0 写一行日志 → **首启静默装死，看起来像没开机**。
   `build-image.sh` 已自愈：4b 从镜像源解 deb 塞 `/usr/bin/hexdump`；4c 断言
   `hexdump parted mkfs.vfat mkfs.ext4 mkfs.btrfs losetup fdisk lsblk tar dbus-uuidgen` 全在，
   缺一个直接构建失败（不要在 rebuild 之后再补，那时没人补）。

---

## 18. 体积裁剪（最终，约 161 包）

在源码系统上执行 `apt-get purge --auto-remove`，**253 → 155 包**，不碰 `openssh-server` / `systemd` / `apt` / `initramfs-tools`。  
2026-11 起保留无线：`iw` / `wpasupplicant` / `wireless-regdb` / `bluez` / `rfkill` 及其依赖不再删（+6 包左右 → **约 161 包**，装机后按实际复核）。

移除列表（显式包；依赖会连带删除，共 96 个）：

```text
# 无线：保留，不再移除（2026-11 起）
# iw wpasupplicant wireless-regdb bluez rfkill
# 本地控制台/键盘
console-setup console-setup-linux kbd keyboard-configuration xkb-data
# 文档/交互工具
man-db groff-base debsums figlet toilet toilet-fonts
htop jq lsof dialog bc bash-completion nano less
# 存储/硬件工具
btrfs-progs mtd-utils mmc-utils gpiod pahole usbutils wireguard-tools
parted fdisk dosfstools dmsetup apt-utils debconf-utils
# 服务
cron cron-daemon-common rsyslog logrotate fake-hwclock
# 音频/网络工具
alsa-utils curl wget rsync
# 其他
sudo u-boot-tools perl perl-modules-5.40 locales
```

清理文件：

```bash
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
       /usr/share/locale/* /usr/share/fonts/* /usr/share/i18n/*
rm -rf /usr/src/linux-headers-*
rm -f  /usr/lib/modules/7.2.12-x96/build
cd /lib/firmware
for d in *; do [ -d "$d" ] || continue; case "$d" in rtl_nic|amlogic|meson|rtw88|rtl_bt) ;; *) rm -rf "$d" ;; esac; done
# 注意：rtw88 / rtl_bt 必须留下，否则无线驱动加载时报 Direct firmware load ... failed
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/log/*
apt-get clean
```

apt 源改为清华 IPv4（原 `deb.debian.org` 的 IPv6 会超时）：

```bash
# /etc/apt/sources.list.d/debian.sources
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian-security
# /etc/apt/apt.conf.d/99force-ipv4
Acquire::ForceIPv4 "true";
```

结果（重启后实测）：

```text
包数      155（保留无线包后约 161）
rootfs    568M used（保留无线包后约 +14M）
firmware  9.4M（含 rtw88/rtl_bt 后约 +0.5M）
/usr/share 14M
内核      7.2.12-x96
网络      eth0 1Gbps
固件缺失  无
无线固件  rtw88/rtw8822b_fw.bin、rtl_bt/rtl8822b_fw.bin 就位
failed units 无
```

需要时可随时装回：

```bash
apt-get install -y nano less curl wget rsync sudo alsa-utils
apt-get install -y sudo u-boot-tools parted btrfs-progs   # 以后要 armbian-install / 内核更新
```

---

## 19. 从源码到 eMMC：端到端操作流程

> 本节是按顺序执行的清单；原理、参数解释和踩坑见第 4–18 节。仓库脚本在本仓库 `x96max/`。

### 19.1 产物与前置

| 项 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04，6 核 / 23GiB（实测） |
| 工作目录 | `/x96-build` |
| 内核源码（原版参照） | `/opt/linux/src/linux-7.2.12.tar.xz`（160M，**原版解压树已删除**，需要补文件才从包里解，见 §0.1） |
| 内核源码（实际编译） | `/x96-build/src-linux`（裁剪树，`X96_KSRC` 指向它，见 §5.3） |
| 内核构建 | `/x96-build/kbuild-7.2.12`（out-of-tree，`O=`） |
| 内核 4 包 | 产出 `/x96-build/pkgs/`；`rebuild` 读 `.../build-armbian/kernel/stable/7.2.12/` |
| ophub 仓库 | `/x96-build/amlogic-s9xxx-armbian` |
| Armbian build | `/x96-build/armbian-build`（rootfs 缓存 `cache/rootfs/*.tar.zst`） |
| 日志 | `/x96-build/logs/from0-<mmdd-HHMM>/{0-clean,19.3,19.4,19.5,19.6,done}.log` |
| 基础镜像 | `.../build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` |
| 仓库脚本 | `x96max/build-image.sh`、`config-x96-source.conf`、`x96-autoinstall.*`、`mkbase.sh` |
| 最终内核配置 | `x96max/kernel/config-7.2.12-x96-full` |
| 输出镜像 | `/x96-build/recovery/x96src-autoinstall.img.gz` |

> 基础镜像约 2.5G、内核 4 个 tar 包、rootfs 缓存和 recovery 镜像都**不入库**；仓库只保留脚本和配置。

### 19.2 一次性准备

```bash
sudo apt-get update
sudo apt-get install -y \
  git curl wget rsync zstd xz-utils cpio kmod openssl sudo \
  build-essential flex bison bc libssl-dev libelf-dev libncurses-dev \
  qemu-user-static binfmt-support u-boot-tools aarch64-linux-gnu-gcc

# ophub（rebuild + kernel packaging）
git clone --depth 1 https://github.com/ophub/amlogic-s9xxx-armbian \
  /x96-build/amlogic-s9xxx-armbian
cd /x96-build/amlogic-s9xxx-armbian
sudo apt-get install -y \
  $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)

# Armbian build framework（源码 rootfs）
git clone https://github.com/armbian/build /x96-build/armbian-build

# 内核源码：实际编译用裁剪树 /x96-build/src-linux（§5.3）；原版解压树已删除，
# 只在补文件时从 /opt/linux/src/linux-7.2.12.tar.xz 里解（§0.1）
# 基础镜像：放到上面的默认路径，或通过 X96_BASE_IMAGE 指定
# （不想下 2.5G 官方镜像可以自造：sudo x96max/mkbase.sh → $ROOT/base-own.img，
#   再 X96_BASE_IMAGE=$ROOT/base-own.img；ophub 的 extract_armbian() 只从基础镜像里
#   取一个可挂载的 ext4 rootfs + /etc/os-release，make_image() 会用 parted 重造整个分区表）
```

### 19.3 编译内核 7.2.12-x96

```bash
REPO=/home/quqiufeng/kernel
KSRC=/x96-build/src-full         # 全量套：解压缓存，缺席时从 linux-7.2.12.tar.xz 现解压（9s/1.8G），编完可删
# 现役源码树 /x96-build/src-clean（= 原样解压的全量树，1.8G；裁剪只在 .config 层，必须保留）
OUT=/x96-build/kbuild-7.2.12

# 仅首次或源码树有树内产物时执行；会删除 .config
# (cd "$KSRC" && make ARCH=arm64 mrproper)

mkdir -p "$OUT"
cp "$REPO/x96max/kernel/config-7.2.12-x96-full" "$OUT/.config"

# 配置前置断言：p1 是 FAT32，缺 FAT 就挂不上 /boot（§0.2 #0）
diff -q "$REPO/x96max/kernel/config-7.2.12-x96-full" <(git -C "$REPO" show 1edfd41:x96max/kernel/config-7.2.12-x96-full)
grep -cE '^CONFIG_(FAT_FS|MSDOS_FS|VFAT_FS)=y' "$OUT/.config"     # 必须 3

cd "$KSRC"
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image modules
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  amlogic/meson-g12a-x96-max.dtb
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$OUT/modules" modules_install
```

产物：

```text
$OUT/arch/arm64/boot/Image
$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb
$OUT/modules/lib/modules/7.2.12-x96/
```

检查（三条都要过，第一条防 `olddefconfig` 悄悄改配置）：

```bash
grep '^CONFIG_LOCALVERSION=' "$OUT/.config"                     # "-x96"
diff <(sort "$OUT/.config") <(sort x96max/kernel/config-7.2.12-x96-full)   # 无输出
strings "$OUT/arch/arm64/boot/Image" | grep -x vfat             # 命中 vfat
```

### 19.4 生成 arm64 initrd / uInitrd

用基础镜像的 rootfs + `qemu-aarch64-static` chroot：

```bash
ROOT=/x96-build
OUT=$ROOT/kbuild-7.2.12
BASE=$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img

LOOP=$(sudo losetup -Pf --show "$BASE")
# 6.18.60 基础镜像是单分区（只有 p1=rootfs），老的两分区镜像才是 p2：按 p2 → p1 回退
PART=${LOOP}p2; [[ -b $PART ]] || PART=${LOOP}p1
sudo mkdir -p /mnt/x96root
sudo mount "$PART" /mnt/x96root

sudo cp -a "$OUT/modules/lib/modules/7.2.12-x96" /mnt/x96root/lib/modules/
sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-7.2.12-x96
sudo cp "$OUT/.config" /mnt/x96root/boot/config-7.2.12-x96
sudo cp "$OUT/System.map" /mnt/x96root/boot/System.map-7.2.12-x96

sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c \
  "depmod -a 7.2.12-x96 && update-initramfs -c -k 7.2.12-x96"
sudo cp /mnt/x96root/boot/initrd.img-7.2.12-x96 "$ROOT/"

sudo umount /mnt/x96root/sys /mnt/x96root/proc /mnt/x96root/dev
sudo umount /mnt/x96root
sudo losetup -d "$LOOP"

mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
  -d "$ROOT/initrd.img-7.2.12-x96" "$ROOT/uInitrd-7.2.12-x96"

# 5) 抬 initramfs 等待窗口（slumber 30 → 90，§5.5）——打包前的最后一道，别漏
./x96max/patch-initrd-wait.sh "$ROOT/uInitrd-7.2.12-x96" --inplace
./x96max/patch-initrd-wait.sh "$ROOT/uInitrd-7.2.12-x96" --check   # 期望 slumber=90
```

> `rebuild-from-zero.sh --from initrd` 已把第 5 步内置；上面是手工分步时的等价命令。
> 生成物 `uInitrd-7.2.12-x96` 就是 §19.5 打进 boot 包的那份，卡上也用它。

### 19.5 打包 4 个内核包

现役做法只有一条：调脚本，别手敲。`x96max/pack-kernel.sh`（引擎）+ `x96max/{full,trim}/pack-kernel.sh`
（两套固定入口），参数全由 `lib/mode.sh` 按 MODE 给出；`-n` 只打印三元组与 sha 校验不落包，
`--stage` 打完同步进 ophub 的 `kernel/stable/7.2.12`。

| 项 | full | trim（**现役，日常用这个**） |
|---|---|---|
| 入口 | `./x96max/full/pack-kernel.sh` | `./x96max/trim/pack-kernel.sh` |
| 配置 | `x96max/kernel/config-7.2.12-x96-full` | `x96max/kernel/config-7.2.12-x96-trim` |
| 源码树 | `/x96-build/src-full`（按需解压，可删） | `/x96-build/7.2.12-trim`（裁剪树，必须留） |
| 产物树 | `/x96-build/kbuild-7.2.12` | `/x96-build/kbuild-trim` |
| KNAME | `7.2.12-x96` | `7.2.12-x96-trim` |
| 包仓 | `/x96-build/pkgs/full` | `/x96-build/pkgs/trim` |

```bash
cd /home/quqiufeng/kernel
./x96max/trim/pack-kernel.sh              # 只打四包 → pkgs/trim/
./x96max/trim/pack-kernel.sh --stage      # 打 + 同步进 ophub kernel/stable/7.2.12
./x96max/full/pack-kernel.sh -n           # 只校验不落包（full 套）
```

> 旧的 `src-linux` / `src-clean` 都已作废：full 不常驻全量树（缺席时 `x96_ensure_src` 现解压
> 1.8G，编完可 `--clean-src` 删），trim 的树实际叫 `7.2.12-trim`（`x96_pick_trim_src` 依次找
> `src-trim`→`src-clean`→`7.2.12-trim`→`7.2.12-src`）。下面这段是**等价手工命令，仅用于对照**，
> 照抄时要自己按上表把 `KNAME`/`KSRC`/`OUT`/`K` 换成对应一套。

打包前强制校验：`$OUT/.config` 的 sha256 必须命中 `configs/config-<KNAME>[-trim]-<date>` 之一，
否则说明这棵树的配置没进归档、打出的包无法溯源，直接 rc=1 拒绝（`--force` 可越过）。下面是等价的
手工命令，用于对照：

```bash
ROOT=/x96-build
OUT=$ROOT/kbuild-trim                   # full 套换成 kbuild-7.2.12
KSRC=$ROOT/7.2.12-trim                  # 裁剪树（full 套换成 src-full，缺席会现解压；见 §5.3/§5.8）
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12   # ophub 只认这个版本号目录
KNAME=7.2.12-x96-trim                   # full 套是 7.2.12-x96

mkdir -p "$K"/{boot,dtb,modules,header}

# boot
cp "$OUT/.config"                         "$K/boot/config-$KNAME"
cp "$OUT/System.map"                      "$K/boot/System.map-$KNAME"
cp "$OUT/arch/arm64/boot/Image"           "$K/boot/vmlinuz-$KNAME"
cp "$ROOT/initrd.img-7.2.12-x96"          "$K/boot/initrd.img-$KNAME"
cp "$ROOT/uInitrd-7.2.12-x96"             "$K/boot/uInitrd-$KNAME"
tar -czf "$K/boot-$KNAME.tar.gz" -C "$K/boot" .

# dtb（只放 X96 Max）
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-$KNAME.tar.gz" -C "$K/dtb" .

# modules
tar -czf "$K/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

# header（复刻 ophub collect_headers；源码树 + out-of-tree 生成物）
H=$K/header
rm -rf "$H"/*
(
  cd "$KSRC"
  head_list=$(mktemp)
  obj_list=$(mktemp)
  {
    find . arch/arm64 -maxdepth 1 -name 'Makefile*'
    find include scripts -type f -o -type l
    find arch/arm64 -name Kbuild.platforms -o -name Platform
    find $(find arch/arm64 -name include -o -name scripts -type d) -type f
  } >"$head_list"
  {
    [[ -n "$(grep '^CONFIG_OBJTOOL=y' "$OUT/include/config/auto.conf" 2>/dev/null)" ]] && echo tools/objtool/objtool
    find arch/arm64/include include scripts -type f
    [[ -f Module.symvers ]] && echo Module.symvers
    [[ -n "$(grep '^CONFIG_GCC_PLUGINS=y' "$OUT/include/config/auto.conf" 2>/dev/null)" ]] && find scripts/gcc-plugins -name '*.so'
  } >"$obj_list"
  tar --exclude '*.orig' -cf - -T "$head_list" | tar -xf - -C "$H"
  tar --exclude '*.orig' -cf - -T "$obj_list"  | tar -xf - -C "$H"
  rm -f "$head_list" "$obj_list"
)
mkdir -p "$H/include" "$H/arch/arm64/include" "$H/scripts"
cp -a "$OUT/include/."                "$H/include/"
cp -a "$OUT/arch/arm64/include/."     "$H/arch/arm64/include/"
cp -a "$OUT/scripts/."                "$H/scripts/"
cp -a "$OUT/.config" "$OUT/Module.symvers" "$H/"
tar -czf "$K/header-$KNAME.tar.gz" -C "$H" .

(cd "$K" && sha256sum *.tar.gz > sha256sums)
ls -lh "$K"
```

实测产物（2026-11-15 09:20，日志 `logs/from0-1115-0920/19.5.log`；同名副本拷到 `/x96-build/pkgs/`）：

```text
boot-7.2.12-x96.tar.gz          36M  69478137b5de77de966642477606c5e6be0ad5359e57a7e38393c18355c0dc39
dtb-amlogic-7.2.12-x96.tar.gz   11K  2f0c8e209fb72282c6bef8f7a261a704af9674ec2f56723f03dc24a4e9b2df83
header-7.2.12-x96.tar.gz        13M  91e525e950bcf0a9aa004bfd4a5fb7c2a0cab35b9d41fe90215647aea17a2965
modules-7.2.12-x96.tar.gz      226K  b113fef3d0dbef60ae1f56e981d3ba7dfa7a09c04cf47b46e3a8955dc3988eb6
```

> `modules-*` 只有 226K 是那版 full config 的正常结果：全树只剩 **1 个模块** `kernel/lib/test_bpf.ko`，
> 其余（含无线）都是 `=y` 直接编进 `Image`——模块少换来的是 initrd 不用等 modprobe，但每次改驱动要重编内核。

裁剪套实测（**现役**，2026-11-15 21:31，日志 `logs/from0-trim-1115-2131/19.5.log`，输出在 `pkgs/trim/`）：

```text
boot-7.2.12-x96-trim.tar.gz          34M  7ef1b227baa9cd11947f31264044027f3c2e6dab836ef7f4e6baf4e2d038502d
dtb-amlogic-7.2.12-x96-trim.tar.gz   11K  1f9a827c3215fead20c6fc678e01bc680199022d227006a11d5d5951c7f61e55
header-7.2.12-x96-trim.tar.gz        13M  1012760f4f2d59a2c4a1e9dafe54be90477f3efb594a4b843f12e7cb068e2200
modules-7.2.12-x96-trim.tar.gz      2.4M  79da87b8a6805d598762601b654300d57ec1a9d32af3d0f4716da52f0100d41a
```

- 打前自检那行必须出现：`配置溯源 OK：config-7.2.12-x96-trim-final-20261115（c4c802d5d9a3 字节一致）`——
  这说明 `$OUT/.config` 与归档配置逐字节同源，包可溯源；不一致脚本会 rc=1 拒绝（`--force` 越权）。
- trim 套 `Image` = **32,246,272 B（30.7M）**、dtb 51,123 B、模块 **154 个**（全量树是 35.9M / 5816 个，§5.8）。

> 该 header 配方已在本次构建中校验：生成结果与已有 `header-7.2.12-x96.tar.gz` 的 13800 个文件一致。
>
> `rebuild` 检查 `boot-*`、`dtb-amlogic-*`、`modules-*`、`header-*` 四件套，缺一不可。

打完必验（§0.2 #3）——**包里的 Image 才是 rebuild 真正吃的东西**，只看 `$OUT/Image` 不算：

```bash
K=/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
KNAME=7.2.12-x96-trim          # full 套换成 7.2.12-x96
ls -l --time-style=+%m-%d_%H:%M "$K"/{boot,dtb}-*"$KNAME".tar.gz "$K"/{modules,header}-*"$KNAME".tar.gz
tar -xzOf "$K/boot-$KNAME.tar.gz" ./vmlinuz-$KNAME | strings | grep -qx vfat && echo "包内 Image 有 vfat ✔"
tar -xzOf "$K/boot-$KNAME.tar.gz" ./config-$KNAME | grep -E '^CONFIG_(VFAT|FAT|MSDOS)_FS=y'
```

四包 mtime 必须晚于 `$OUT/arch/arm64/boot/Image`；不晚就是旧包，`--from image` 会把旧内核再打一遍镜像。

### 19.6 构建可刷镜像

> 前提：19.3–19.5 已产出 `boot/dtb-amlogic/modules/header` 四个内核包，且 **mtime 晚于本次 Image**（§19.5 的必验）。
> `build-image.sh` **不检查内核新旧**：四包是旧的它照样出镜像，只是镜像里是旧内核。改过内核就必须先 19.5。
> 脚本也会自己兜底：四包缺任一个直接退出，并按 MODE 把本套 `pkgs/<mode>/` 同步进 ophub 目录（`x96_stage_pkgs`）。

```bash
cd /home/quqiufeng/kernel

# 裁剪套（现役）：用 pkgs/trim 的四包 → recovery/x96-trim-autoinstall.img.gz
./x96max/trim/build-image.sh

# 完整套：用 pkgs/full 的四包 → recovery/x96-full-autoinstall.img.gz
./x96max/full/build-image.sh

# 复用已有 rootfs 产物，只重打包（最快，约 3–4 分钟）
./x96max/trim/build-image.sh --skip-rootfs

# 直接写 U 盘/SD（转调 write-card.sh：关自动挂载 → dd → 文件系统层校验 → 恢复）
./x96max/trim/build-image.sh --skip-rootfs --write /dev/sdX
```

不带 `full/` 前缀的 `x96max/build-image.sh` 也认 `--mode trim`（默认 full）；`lib/mode.sh` 决定
`KNAME/PKGS/成品名`，两套互不覆盖。

可用环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/x96-build` | 工作目录 |
| `X96_BASE_IMAGE` | 上面的 6.18.60 通用镜像 | 基础镜像（提供 boot 区与分区表） |
| `X96_ROOT_PASSWORD` | `x96max`（脚本内默认，非空→开密码登录 + 控制台自动登录） | 置空则锁定 root 密码、仅 SSH key（§0.5 的坑） |
| `X96_ROOT_SSH_KEY` | `~/.ssh/id_ed25519.pub` | 写入镜像的 root 公钥 |

脚本会检查 passwordless sudo、基础镜像、4 个内核包、auto-install 文件（`x96-autoinstall.sh` +
`.service`）、`config-x96-source.conf`、rootfs 产物；装完还要过两道工具断言（rootfs 侧
`hexdump/parted/mkfs.*/losetup/fdisk/lsblk/tar/dbus-uuidgen`，交付镜像侧再加 `ampart/armbian-install`）。
输出（`$OUT=$ROOT/recovery`）：

```text
/x96-build/recovery/x96-trim-autoinstall.img.gz    # 现役
/x96-build/recovery/x96-full-autoinstall.img.gz    # 全量套
```

### 19.6.1 一键从零重建（实际用的流程）

`x96max/rebuild-from-zero.sh` 把 §19.3→§19.6 串成一条，脚本里跑的就是上文那些命令：

```bash
cd /home/quqiufeng/kernel

# 现役：裁剪套全流程（0 清空本套旧产物 → 19.3 内核 → 19.4 initrd → 19.5 四包 → 19.6 镜像）
sudo ./x96max/trim/rebuild-from-zero.sh

# 全量套（同样一条，互不覆盖）
sudo ./x96max/trim/rebuild-from-zero.sh    # ← 换成 ./x96max/full/rebuild-from-zero.sh

# 只重做某一段（--from 隐含 --no-clean，不清旧产物）
sudo ./x96max/trim/rebuild-from-zero.sh --from kernel    # 从编内核开始
sudo ./x96max/trim/rebuild-from-zero.sh --from initrd    # 复用 kbuild-*/Image，只重做 initrd/uInitrd
sudo ./x96max/trim/rebuild-from-zero.sh --from pkgs      # 只重打四包
sudo ./x96max/trim/rebuild-from-zero.sh --from image     # 只重做镜像（四包不变时用这个）

# 无前缀入口 + --mode / --trim 等价写法
sudo ./x96max/rebuild-from-zero.sh --mode trim
sudo ./x96max/rebuild-from-zero.sh --trim --from pkgs
```

开跑前会自动做两件拦截：`x96_ensure_src`（full 缺席则现解压 1.8G 源码包；trim 缺裁剪树直接报
「裁剪树是解压+裁剪的产物，还原不出来」并给两条补救路）、`x96_audit_trim`（trim 套先跑
`tools/trim/audit_stubs.py`，被剥空的目录/被删的 Makefile 行会让它 rc≠0 立刻中止，不白编一轮）。

| 变量 | 默认值（trim / full） | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/x96-build` | 工作根（`logs/`、`pkgs/`、`recovery/` 都在其下） |
| `X96_CFG_MODE` | `trim`（`trim/*.sh` 里导出）/ `full` | 选哪一套，就这一个开关 |
| `X96_KSRC` | trim→`7.2.12-trim`（自动找）/ full→`src-full` | 源码树；full 不常驻，缺席现解压 |
| `X96_KOUT` | `kbuild-trim` / `kbuild-7.2.12` | O= 输出树 |
| `X96_KNAME` | `7.2.12-x96-trim` / `7.2.12-x96` | 内核 release 名 = 包名后缀 |
| `X96_SKIP_AUDIT` | `0` | `1` = 跳过 trim 裁剪审计（确知无害时才用） |
| `X96_BASE_IMAGE` | `.../images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` | 基础镜像（取 rootfs 做 initrd） |

每步一个日志文件，过滤时最好带上 MODE（两套日志目录不会混，但机器上会并排躺着）：
`done.log` 收最终镜像大小 + sha256；本次未跑 image 阶段时会写「本次未跑 image 阶段」。

```text
/x96-build/logs/from0-<MODE>-<mmdd-HHMM>/{0-clean,19.3,19.4,19.5,19.6,done}.log
```

> 历史日志（09:xx 那批，无 MODE 段、用的是 `x96src-autoinstall.img.gz`）只作留档，别再照抄路径。

### 19.6.2 裁剪套端到端实测（2026-11-15 21:0x，现役基线）

从裁剪树到可刷镜像的完整链路，一次 `trim` 套分段跑完（不是一条命令到底，按段重试更省时）：

```bash
cd /home/quqiufeng/kernel
sudo ./x96max/trim/rebuild-from-zero.sh --from initrd   # 21:28 → 21:29  initrd/uInitrd
sudo ./x96max/trim/rebuild-from-zero.sh --from pkgs     # 21:31        四包 + 配置溯源校验
sudo ./x96max/trim/rebuild-from-zero.sh --from image     # 21:32 → 21:39 rootfs 注入 + ophub rebuild
```

| 阶段 | 命令/脚本 | 产物（实测） | 日志 |
|---|---|---|---|
| 19.3 内核 | `trim/build-kernel.sh` | `kbuild-trim/arch/arm64/boot/Image` 32,178,688 B（30.7M）；dtb 51,123 B | `logs/…/19.3.log` |
| 19.4 initrd | `--from initrd`（loop 挂 base + chroot qemu） | `initrd.img-7.2.12-x96-trim` 11,081,541 B，`uInitrd-…` 11,081,605 B（`slumber` 已由 30 抬到 90，回读自检通过） | `from0-trim-1115-2128/19.4.log` |
| 19.5 四包 | `trim/pack-kernel.sh --stage` | `pkgs/trim/`：boot 34M / dtb 11K / header 13M / modules 2.4M，自检 `配置溯源 OK：config-7.2.12-x96-trim-20261115（52763fda73ce 字节一致）` | `from0-trim-1115-2131/19.5.log` |
| 19.6 镜像 | `trim/build-image.sh` | `/x96-build/recovery/x96-trim-autoinstall.img.gz` **271M**，sha256 `ce37a41ed27891a5832e09a64e6f465e9eb72196842b04c3809babce4d75d8ff`；ophub 中间产物 `Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.15.img.gz`；末行断言 `final image assertions ok` | `from0-trim-1115-2132/19.6.log` |

19.6 这段日志里两处**看似报错其实无害**的输出，别再当故障查：

- `docker: 未找到命令` → ophub 自动降级 `PREFER_DOCKER=no`，本机原生构建。
- `tar: … Cannot change ownership to uid 1000 …` → root 打包、目标属主是普通用户，属主位无关紧要；
  后面跟着 `(1.1) Armbian built successfully.` + `SUCCESS` 才算数。

镜像体积参考：裁剪套 271M（gz）/ 全量套 271M→272M 一档，两者差在 `boot` 包与 `Image`（30.7M vs 35.9M），
rootfs 部分相同——想再瘦要动 §18 的包清单，而不是内核。

### 19.6.3 成品与基础镜像现状（2026-11-15 23:44 核对 NAS）

**两条旧记录都错了，以此节为准。**

**错记录 1**：此前写“本地 `~` 留一份（`~/x96-trim-autoinstall.img.gz`、`~/Armbian_...img`）”——
23:39 实测这两个路径**都不存在**，全盘 `find` 无第二份。

**错记录 2**：23:38 我把 `/tmp/x96-trim-autoinstall.img`（3.0GiB，root，mtime **21:52**）压成 311M 的 gz
放进 `recovery/`，并写下“与旧 `98d4803b…` 内容一致”。**这是错的**：两者解压体虽同为 3225419776 字节，
但 sha256 分别是 `4480c312…` 与 `09f7662f…`，`cmp` 显示 489,891,314 字节不同；
按 64M 分块比对，**chunk 0/1（boot 区）与 8、10–19、22、26、28（rootfs 元数据区）不同**，其余一致。
即 21:52 那份是**上一轮构建（§19.6.2 的 21:39 基线）**的残留解压体，NAS 上的才是 **22:21 最终成品**。
311M 那份已删，`recovery/` 现用 NAS 版本覆盖。

| 文件 | 本地位置 | 大小 | sha256 / 状态 |
|---|---|---|---|
| `x96-trim-autoinstall.img.gz` | `/x96-build/recovery/` | 275M | `98d4803bdbfe1671e543c569b7c2a23411b1cc1668ae681e2647341a322b3cc6`（从 NAS 取回，`gzip -t` 通过）——**现役成品** |
| （本地已删，见下） | — | — | `x96src-autoinstall.img.gz` 271M/18:25 的全量套，23:51 已验证归档 NAS 后从本地删除 |
| `Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` | `/x96-build/amlogic-s9xxx-armbian/build/output/images/` | 2.5G | `1cbca554455ac57855f960bea4873431df01ef870b1c0a4cb01e5a42330996a8` |
| eMMC 原始备份 | `/x96-build/recovery/orig/` | 876M | 见下表 |

**NAS 已复核（`~/.env` 里的 `WEBDAV_*` 可用，`curl -u … -X PROPFIND` 能列目录）**：
`http://192.168.1.53:5005/sata11-18072858035/x96max/`

| NAS 文件 | 字节 | 核对结果 |
|---|---|---|
| `emmc-original-backup/emmc-bootarea-117MiB.img.gz` | 34633290 | 与本地同名文件 sha256 一致 `c4f37419…` |
| `emmc-original-backup/emmc-p1-boot.img.gz` | 98297115 | 一致 `fa0774ff…` |
| `emmc-original-backup/emmc-p2-rootfs.tar.gz` | 784828180 | 一致 `2b77baf7…` |
| `emmc-original-backup/mmcblk1.sfdisk` | 212 | 一致 `341a843f…` |
| `SHA256SUMS` | 441 | 上述四行全对上 |
| `x96-trim-autoinstall.img.gz` + `.sha256` | 288757378 | `98d4803b…`，即 22:21 成品 |
| `x96src-autoinstall-2026-11-15-1825.img.gz` + `.sha256` | 284040362 | **18:25 全量套**，sha256 `18cc4a846db1f78866aefed7b1aa19196ab959a6c8b98a9053ef074412bfb7ba`；23:51 上传并回读校验一致 |
| ~~`x96src-autoinstall-2026-11-15.img.gz`~~ | ~~329277929~~ | **17:39 的另一轮构建，≠ 18:25 版**（见下方勘误）；23:53 已从 NAS 删除（HTTP 204，复 HEAD 404） |
| `Armbian_…6.18.60.img` + `.sha256` | 2684354560 | `1cbca554…`，与本地一致 |

→ **结论：eMMC 原始备份（唯一一份不可再生的东西）已安全落在 NAS，本地+NAS 双份且校验一致**；
基础镜像同样双份一致。出图请认 `98d4803b…`，别再拿 `/tmp` 里的东西当成品。

**勘误（2026-11-15 23:51）：NAS 那份 `x96src-autoinstall-2026-11-15.img.gz` 不是本地 271M 的换压缩级别副本。**
解压体同为 3225419776B 但 sha256 不同（NAS `3fca0ccb…` vs 本地 `ef58a733…`），
64M 分块差异在 chunk 0/1/2（boot 区）与 8、10–22、26、28（rootfs 元数据），
首个差异字节 4194372（= p1 起始 8192×512 + 68）。挂载 p1 对比可确认是两轮不同构建：

| p1 文件 | 本地 18:25 | NAS 17:39 |
|---|---|---|
| `vmlinuz-7.2.12-x96` / `zImage` | 32178688 | 42220032 |
| `uInitrd` | 11081587 | 15752192 |
| `initrd.img-…` | 11081523 | 15752128 |
| `config-7.2.12-x96` | 223168 | 257801 |
| `System.map-…` | 6401799 | 8131676 |

即 NAS 旧名那份 = **17:39 的 fat 内核构建**，本地 18:25 是裁剪版内核构建。
所以“NAS 已备份，可以删本地”这个假设对 18:25 版**不成立**；
已按 `18cc4a84…` 上传为 `x96src-autoinstall-2026-11-15-1825.img.gz`（带 .sha256）并回读校验，
之后才删掉本地 271M。

23:53 该过期文件（17:39 版，329M）已从 NAS 删除，NAS `x96max/` 现只剩：
`x96-trim-autoinstall.img.gz` 275M（+ .sha256）、`x96src-autoinstall-2026-11-15-1825.img.gz` 271M（+ .sha256）、
`Armbian_…_6.18.60.img`、`SHA256SUMS`、`emmc-original-backup/`（原始 eMMC 备份，不动）。
注：NAS 顶层 `SHA256SUMS` 只覆盖 `emmc-original-backup/` 四项，不含镜像本体；镜像各自带 `.sha256` 旁文件。

**`recovery/` 曾被整个丢进回收站**（23:29–23:37 之间，`~/.local/share/Trash/files/recovery`，4.9G，
含 u-boot / bootarea / eMMC 备份 / 两个成品 gz）——23:37 已原样还原。凡是 `recovery/` 突然消失，先查回收站再谈重建。

### 19.6.4 磁盘清理记录（2026-11-15 23:38 / 23:44，15G → 8.8G）

日志 `/x96-build/logs/cleanup-20261115-2338.log`。只删可再生成/重复的，共释放约 6.3G：

| 删掉 | 大小 | 为什么可以删 |
|---|---|---|
| `recovery/stale/x96src-autoinstall-2114.gz` | 334M | 21:14 旧中间产物，已被 18:25 成品取代 |
| `recovery/x96src-autoinstall.img.gz.bak-hexdump-missing` | 299M | 同镜像的另一份压缩（解压同为 3225419776B），`gzip -t` 通过但冗余 |
| `recovery/x96s905x2.img` | 3.1G | 全量套解压态中间图，内容= `x96src-autoinstall.img.gz` |
| `src-pristine` | 1.8G | 全量源码树，`/opt/linux/src/linux-7.2.12.tar.xz` 可重解 |
| `kbuild-odc` | 729M | olddefconfig 试验树，无脚本引用 |
| `armbian-build/cache` | 396M | ophub apt/pip 缓存（root 属主部分需 `sudo rm`） |
| `initrd/uInitrd/uEnv.txt.bak.*` | 66M | 打补丁前的临时回滚副本，可重建 |

**保留**：`7.2.12-trim`（裁剪源码树，解压不出来）、`kbuild-trim`、`pkgs/`、`recovery/orig/`、
`recovery/*.img.gz` 两个成品、`amlogic-s9xxx-armbian`（基础镜像唯一副本）、`base-own.img`。

> 2026-11-27 23:55 又清一轮（`/x96-build` 8.3G → 7.8G）：删 `boot-bad`(107M)、`boot-good`(104M)、
> 老内核 `7.2.12-x96`（非 trim）的 `initrd.img`/`uInitrd`/`vmlinuz` 与 `base-boot-backup` 里的整套
> （后者只留 `-trim` 一套并修好 `Image`/`uInitrd` 符号链接，113M → 49M）。
> 现役只剩 `7.2.12-x96-trim`：源树 `7.2.12-trim` + 增量树 `kbuild-trim` 在，随时可重编。
还能再砍：`amlogic-s9xxx-armbian` 里的 ophub 源码 3.3G（先把基础镜像挪出来）、`base-own.img` 1.2G（`mkbase.sh` 可重造）。

**第二轮（23:44，`/tmp` 3.0G×2 与错压的旧构建）**：删 `/tmp/x96-trim-autoinstall.img`（3.0G，21:52 旧构建解压体，
已成 NAS 版取代）、`/tmp/Armbian_...2026.11.15.img`（3.0G，基础镜像解压中间体；`build-image.sh:55` 的 `$BASE`
指向 `output/images/` 那份，脚本不引用 `/tmp`）、`/tmp/local-trim.img` 与分块比对临时件。
`recovery/x96-trim-autoinstall.img.gz` 由错压的 311M 换回 NAS 的 275M / `98d4803b…`。

**为什么要单独备份基础镜像**：`build-image.sh:68` 硬校验 `$BASE`，缺了直接 `missing base image` 退出；
它的 rootfs 会被整体清空（§19.6 步骤 1），但那个 ext4 分区容器本身不能凭空造出来，
`mkbase.sh` 虽能自造（§19.6.1），仍需源码 rootfs 与 `base-boot-backup` 都在位。留着最省事。

**校验方式**：`gzip -t` 已过；`sha256sum` 源/目标分别计算，基础镜像两侧一致。

**注意 sha256 与 §19.6.2 不同**：19.6.2 记的是 21:39 的裁剪套基线（271M / `ce37a41e…`），
22:21 又重跑过一次 image 阶段，把 `recovery/x96-trim-autoinstall.img.gz` 覆盖成 276M / `98d4803b…`；
旧的 271M 文件已不存在，重新出图请以本次记录为准。

### 19.7 写盘、首启与 eMMC 安装

```bash
# 写 U 盘/SD：一律走 write-card.sh（关自动挂载 → dd → 逐文件 sha256 → 恢复设置）
sudo ./x96max/write-card.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdX

# 只校验卡上现有内容，不重写（1~2 分钟）
sudo ./x96max/write-card.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdX --verify-only

# 从构建脚本转调，内部就是第一条
./x96max/build-image.sh --skip-rootfs --write /dev/sdX

# 只把镜像塞进卡上已分好区的 p1（卡上分区方案不变、不想重写整盘时用）
sudo ./x96max/flash-p1.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdX1

# 写完卡必补两刀（镜像里是出厂 uInitrd 和出厂 APPEND，见 §10.1.1 第 6/7 步）
sudo ./x96max/patch-initrd-wait.sh /dev/sdX1/uInitrd --inplace     # slumber 30 → 90（§5.5 根源修复）
sudo ./x96max/patch-initrd-wait.sh /dev/sdX1/uInitrd --check       # 回读，期望 slumber=90

# 改卡上 p1 的启动参数（uEnv.txt 的 APPEND），不重写任何分区
sudo ./x96max/patch-bootargs.sh -l                     # 只列出当前 APPEND
sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678    # USB 保险套餐（两参数，§5.5 / §10.2.2）
sudo ./x96max/patch-bootargs.sh quiet loglevel=7       # 追加任意参数（幂等）
sudo ./x96max/patch-bootargs.sh -r rootdelay=15        # 清掉历史遗留（现已不用，见 §5.5）
```

`patch-bootargs.sh` 定位分区的方式和 `flash-p1.sh` 一样（`X96_ROOT_LABEL=ROOTFS` → 反查父盘 → 找 p1 的 FAT32），
每步都重读回验，写前先把原文件备份到 `$X96_BUILD_ROOT/uEnv.txt.bak.<时间戳>`。盒子读一半掉盘时的用法见 **§10.2.2**。

> 不要再手工 `dd`：见 §10.1.3（自动挂载把日志回放出的垃圾固化进卡）与 §10.1.4（裸盘 `cmp` 不是判据）。
> 完整流程、手工等价命令、失败判定表在 **§10.1**。
>
> **盒子已经在跑、只是换了内核 → 别写卡，走 §23**（scp Image/dtb/modules，盒上重做 uInitrd，3 分钟）。

盒子从 U 盘/SD 启动后确认：

```bash
hostname          # x96src
uname -r          # 7.2.12-x96
findmnt -no SOURCE /
```

镜像内已启用 `x96-autoinstall.service`，首启会自动执行：

```text
armbian-install -m yes -a no
# 301 / ext4
```

查看：

```bash
systemctl status x96-autoinstall
cat /var/log/x96-autoinstall.log
```

安装完成后服务会 `poweroff`；拔掉 U 盘/SD，上电从 eMMC 启动。若自动安装未触发，手动执行：

```bash
armbian-install -m yes -a no
# 设备 301（X96-Max-4GB），文件系统 1（ext4）
```

### 19.8 安装后验证

```bash
hostname
uname -r
findmnt -no SOURCE /
dpkg -l | grep -c '^ii'          # 基础镜像 155（保留无线包后约 161）；装运行依赖后会增加
ip -br a
aplay -l
arecord -l
v4l2-ctl --list-devices
timedatectl                       # 必看：System clock synchronized: yes / NTP service: active（见 §20）
systemctl is-enabled systemd-timesyncd
```

当前盒子装完 LuaJIT/音频/摄像头运行依赖后为 **177 包**；155 是裁剪后的基础系统包数（保留无线包后约 161）。

### 19.9 回滚与安全

- **不要**用 U 盘镜像的 p1 直接覆盖 eMMC p1；会带入 `u-boot.emmc` 导致黑屏。
- 原厂启动区 117MiB、p1、p2 在 NAS：`dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`。
- eMMC 黑屏时用主线 U-Boot：`armbian-install -m yes -a no`，详见第 11、15 节。
- 产品镜像默认不设 root 密码（脚本留空即锁定），只保留 SSH key；确需控制台密码时再显式设置 `X96_ROOT_PASSWORD='强密码'`。
- 固定基础镜像和内核源码版本/校验和；API key 按设备下发或走后端代理，不能共用同一把 key。

---

## 20. 系统时间与 apt 源（新系统第一件事）

> 2026-11-15 17:55 实测。**镜像出厂状态里没有任何 NTP 客户端**，`apt` 的"源坏了"多半是时间错了。

### 20.1 症状：所有源都 "not signed"

```text
W: Failed to fetch http://mirrors.tuna.tsinghua.edu.cn/debian/dists/trixie/InRelease ...
E: The repository '... debian trixie InRelease' is not signed.
   Verifying signature: Not live until 2026-11-15T07:38:06Z
```

- `Not live until <未来时间>` 是关键指纹：**系统时钟早于签名生效时间**，`sqv` 直接判定仓库未签名
  （本次盒子差 **7 个月**：`Tue Apr 14 2026` vs 真实 `2026-11-15`）。
- 同一条时间线会连带打死 `apt-get install`、`dpkg` 校验、TLS（`curl`/`wget` 报证书未生效）。
- 与镜像源无关：清华源本身可通（`apt-get update` 拿到 17.7MB 即可证明网络正常）。
- 判据一条命令：`timedatectl` → `System clock synchronized: no` + `NTP service: n/a`。

### 20.2 一次性修好（含开机自动同步）

```bash
# 1) 先把时间拨到"大致正确"（允许 apt 验证签名；-u 用 UTC，避免时区二次偏移）
date -u -s '2026-11-15 09:56:00'

# 2) 装时间同步服务（镜像里没有 chrony/ntp/timesyncd 任何一个）
apt-get update            # 时钟修好后这次应该全绿、无 E:/W:
apt-get install -y systemd-timesyncd

# 3) 配国内 NTP（不配的话默认走 systemd 的 pool，盒子上延迟大且常失败）
cat > /etc/systemd/timesyncd.conf <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com time1.cloud.tencent.com cn.pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org time.cloudflare.com
EOF

systemctl enable --now systemd-timesyncd
systemctl restart systemd-timesyncd

# 4) 落进 RTC，重启不回退
hwclock -w
```

### 20.3 验收

```bash
timedatectl                       # System clock synchronized: yes
timedatectl show -p NTPSynchronized -p NTP     # NTPSynchronized=yes
journalctl -u systemd-timesyncd -n 5 --no-pager # Contacted time server 203.107.6.88:123 (ntp.aliyun.com)
hwclock -r                        # RTC 与系统一致
apt-get update                    # rc=0，无 E:/W:
```

本次实测：`Contacted time server 203.107.6.88:123 (ntp.aliyun.com)` → `Initial clock synchronization to Sun 2026-11-15 17:55:06 CST`，
`apt-get update` **rc=0，零 E/W**，`apt-get install tzdata` 正常。

### 20.4 顺带记录

- `apt-get install -y curl` 现在可以装了（之前 `curl` 不存在，盒子上只有 `wget` 级别的工具）。
- `/etc/apt/sources.list.d/armbian.sources` 与 `armbian-config.sources` 在出厂镜像里是 **`.disabled`**，
  Debian 源（清华 `debian.sources`，trixie + security）够用；要 Armbian 专属包再改回 `.sources`，
  但先确认 `apt.armbian.com` / `github.armbian.com` 可达（本次未验证通过）。
- **`RTC in local TZ: no`** 是正确状态（RTC 存 UTC）；别为了"看起来对"去改它。
- 建议把 `systemd-timesyncd` + §20.2 的 `timesyncd.conf` 直接做进镜像（rootfs 注入阶段），
  否则每次重装都要手工走一遍。

## 21. 两套打包（完整源码树 / 裁剪版）

需求：**同时维护两套可打包的流水线** —— 一套全量源码树、一套裁剪版，各自的 sh 脚本、编译 config、
源码目录都分开，产物互不覆盖。

### 21.1 参数矩阵（唯一出处在 `x96max/lib/mode.sh`）

| 项 | `full`（完整源码树） | `trim`（裁剪版） |
|---|---|---|
| 配置 | `x96max/kernel/config-7.2.12-x96-full` | `x96max/kernel/config-7.2.12-x96-trim` |
| `CONFIG_LOCALVERSION` | `-x96` | `-x96-trim` |
| 源码树 | `/x96-build/src-linux` | `/x96-build/src-clean` |
| 产物树 (`O=`) | `/x96-build/kbuild-7.2.12` | `/x96-build/kbuild-trim` |
| 内核名 `KNAME` | `7.2.12-x96` | `7.2.12-x96-trim` |
| 模块目录 | `.../lib/modules/7.2.12-x96` | `.../lib/modules/7.2.12-x96-trim` |
| initrd / uInitrd | `initrd.img-7.2.12-x96` | `initrd.img-7.2.12-x96-trim` |
| 四件套包仓 | `/x96-build/pkgs/full` | `/x96-build/pkgs/trim` |
| 成品镜像 | `recovery/x96-full-autoinstall.img.gz` | `recovery/x96-trim-autoinstall.img.gz` |
| 入口脚本 | `x96max/full/*.sh` | `x96max/trim/*.sh` |

要点（都是这次踩出来的）：

1. **两套必须有两个 `KNAME`**。以前两套共用一个 `7.2.12-x96`，`boot-7.2.12-x96.tar.gz`
   名字一模一样，后打的把先打的覆盖掉，`/lib/modules/7.2.12-x96` 也会串味。
   现在 `trim` 的 `CONFIG_LOCALVERSION="-x96-trim"`，`uname -r` 就能分辨在跑哪套。
2. **ophub 的 `-k` 只认版本号**（`7.2.12`），两套包最终都要落到 `kernel/stable/7.2.12`。
   所以做成「包仓（各一套）→ 出镜像前同步」：`build-image.sh` 调 `x96_stage_pkgs`，
   先清空该目录再放本套四个包，同一时刻只有一套在位，包仓里两套都留着。
3. **成品名带 MODE**，`x96-full-…` / `x96-trim-…`，写卡不会拿错。

### 21.2 用法

```bash
./x96max/full/preflight.sh              ./x96max/trim/preflight.sh
./x96max/full/rebuild-from-zero.sh      ./x96max/trim/rebuild-from-zero.sh

# 等价的分步写法（引擎脚本 + --mode）
./x96max/build-kernel.sh --trim
./x96max/pack-kernel.sh --trim --stage     # --stage：打完同步进 ophub 的 kernel/stable/7.2.12
./x96max/build-image.sh --mode trim
./x96max/rebuild-from-zero.sh --from initrd --mode trim
```

`full/*.sh`、`trim/*.sh` 里没有任何参数，只有一行 `export X96_CFG_MODE=<mode>` 再 exec 引擎，
所以「两份脚本」不会分叉成两份逻辑：改引擎两套同时生效。

### 21.3 配置溯源用语义比对

`olddefconfig` 会把 `.config` 重写一遍（`=m` 与注释行顺序全变），字节 sha 对不上并不等于配置不同。
`pack-kernel.sh` 现在先比 sha，**字节不同再比「符号=值」语义**（`x96_cfg_same`），
语义一致也放行并打印「语义一致，olddefconfig 噪声已忽略」；真不同才要 `--force`。

### 21.4 当前状态（2026-11-15 19:0x）

- 两套参数、入口、脚本已就绪，`full/preflight.sh` 27 项、`trim/preflight.sh` 28 项全绿。
- **`full` 需要重编一次**：`kbuild-7.2.12/.config` 与归档的 `-full` 配置有 1686 个符号不同
  （大量 `=m` vs `=y`），即现在这棵树不是用 `config-…-full` 编出来的，重编后包才可溯源。
- **`trim` 需要重编一次**：`LOCALVERSION` 改成 `-x96-trim` 后，旧产物仍是 `7.2.12-x96`，
  `pack-kernel.sh` 会直接报「缺模块目录 / 缺 initrd」。
- 旧的同名包已挪到 `/x96-build/pkgs/_legacy-7.2.12-x96/` 留档（对应现在卡上跑的那版）。

### 21.5 源码树：full 不常驻，按需解压（2026-11-15 19:08）

决定：**全量源码树不再作为长期资产保留**，它随时能从源码包还原，所以脚本改成「用前解压」。

- `lib/mode.sh` 新增 `SRC_XZ=/opt/linux/src/linux-<KV>.tar.xz`、`x96_ensure_src`、`x96_drop_src`：
  - full 的 `KSRC` 默认 `/x96-build/src-full`；树不在就从包里
    `tar -xJf ... --strip-components=1` 现解压（实测 **9s / 1.8G / 94776 文件**），并写标记 `.x96-extracted`。
  - 编完带 `--clean-src`（或 `X96_CLEAN_SRC=1`）就整目录删掉；下次再编自动重解。
- `preflight.sh`：full 只要求**源码包**在，树缺席直接判 ok（提示「开跑时现解压」）；trim 仍要求 `src-clean` 在。
- `rebuild-from-zero.sh`：把 `-d $KSRC` 硬检查换成 `x96_ensure_src`，新增 `--clean-src` 透传。
- **旧 `/x96-build/src-linux` 不再默认使用**：实测它被削过——38 332 文件 vs 完整树 94 776，
  缺 `Documentation` 与 alpha/mips/riscv 等非 arm64 架构（553M vs 1.8G）。要用它得显式 `X96_KSRC=`。
- trim 的 `src-clean` 仍然必须保留：它是原样解压的全量树（1.8G，未裁剪；裁剪只在 `.config` 层），解压要重来一遍 160M 包 + 时间
  （删了用 `kernel/gen-trim.sh` 重生成，耗时远大于解压）。

## 22. 壁纸终端（console-wall，2026-11-18）

需求：开机不进桌面时，HDMI 上的命令行也要能用 —— **高清壁纸打底 + 半透明终端**，
不是黑底白字，也不要花屏。做法不是改 framebuffer 驱动，而是「先把图画进 `/dev/fb0`，
再用半透明 fbterm 盖在上面」。

### 22.0.1 截图（tools/x96-shot.sh）

两套显示栈各有一条抓法，`/dev/fb0` 里**没有**桌面像素（桌面走 DRM planes），别拿 fb 抓桌面：

```bash
tools/x96-shot.sh                 # tty1 桌面（失败自动回落 -d） → ~/x96-desktop-<时间>.png（走 /tmp/desktop-automation.sock 的 app.capture）
tools/x96-shot.sh -d              # DRM 直读，不依赖 app，兜底
tools/x96-shot.sh -c              # tty2 壁纸终端 → ~/x96-console-<时间>.png（dd /dev/fb0 → BGRA → PNG）
tools/x96-shot.sh -a -o /tmp/a.png  # 两个都抓（第二张自动加 -console 后缀）
```

- 桌面那条：socket 是 `root:600`，必须 root ssh；返回 `{"ok":true,"path":...}` 才算成功。
  抓不到时 `x96-shot.sh` 会自动回落到 `-d` 的 DRM 直读，不会一头撞死。
- `-d` 第三条路（`tools/drmcap/drmcap.c`，首次在盒子上用 `cc -I/usr/include/libdrm ... -ldrm` 编一次）：
  直接 `drmModeGetResources` 找有 active crtc 的卡 → `drmModeGetFB` 拿扫描缓冲 → `MAP_DUMB` + mmap 读原始 BGRA。
  **不需要 app 配合、不需要那个 unix socket，app 卡死也能抓**；桌面这时是走 KMS 的，所以这条路能拿到真的桌面像素。
  代价：抓到的是"屏上此刻的帧"，正好半帧时会撕裂；buffer 不是 dumb（GPU 私有 tiled bo）时 `MAP_DUMB` 会失败——
  这台 card0 的 fb 恰好是 dumb 的，所以能读。card1 会报 `Operation not supported`（无资源接口），脚本会自动挑卡。
- fb 那条：`fb0/virtual_size` 是 `2560,2160`（比屏高），真正上屏行数看 `fb0/modes`（`U:2560x1440p-0`），
  只 `dd` 可见的 1440 行，否则下面多一大条白边。stride 10240 = 2560×4，32bpp 小端 BGRA。
- 桌面在前台时 fb0 里只是打底壁纸，fbterm 的文字要 `chvt 2` 才有。

### 22.0.2 回归对拍（tools/x96-check.sh）

截图只是原料，判定要能自动出「通过/不通过」。`x96-check.sh` 把三层串成一条命令：
**注入**（socket 的 key/click/call）→ **状态断言**（`brief` 的 sel/count/name）→ **画面对拍**（与基线比差异像素占比）。

```bash
tools/x96-check.sh --golden home                      # 录基线 → tools/golden/home.png
tools/x96-check.sh --diff home                        # 比基线，0=过 1=画面不符 2=状态断言失败 3=环境/抓图失败
tools/x96-check.sh --diff home --do "key:HOME;wait:400;key:RIGHT;wait:400" \
    --assert-sel 机器学习 --max-diff 0.5
tools/x96-check.sh --case tools/cases/list-home.case  # 跑一个用例
tools/x96-check.sh --run-dir tools/cases              # 跑整目录，末尾出汇总、有失败即 exit 1
tools/x96-check.sh --run-dir tools/cases --record     # 批量重录基线（改版式后执行）
```

- 判据是 ImageMagick `compare -metric AE -fuzz N%` 的**差异像素占比**。这块屏静止时实测**逐像素可重现**
  （连抓两张差异 0），所以默认 `--fuzz 1 --max-diff 0.1`（≈3700px）足够严：实测「选区右移一格」3.4%、
  「整屏下移 1px」7.9%、`-modulate` 调 0.5% 色偏也有 7% —— 真回归落不进容差里。
  有动画/时钟的界面用 `--ignore x,y,w,h` 抹掉那块（可重复），或放宽 `--max-diff`。
- 分辨率变了（换模式/换屏）会先缩放到基线尺寸再比，并在 stderr 提示一句；基线本身不会被动。
- 失败自动留证：`logs/check-<name>-actual.png` 与 `check-<name>-diff.png`（IM 的红标差异图）。
- 步骤语法（`--do`/用例里 `do` 行，**分隔符只认分号**，因为 JSON 参数里有逗号）：
  `key:NAME`、`click:ID`、`wait:ms`、`call:FN`、`call:FN:{json}`、`raw:{json}`。
  用例里另有 `restore` 行：**无论成败都执行**（例如进过阅读器要按 BACK 退回书架），别让失败把机器留在半开状态。
- 用例（`tools/cases/*.case`）第一段通常固定 `call:app.goto:{"dir":...}` + `key:HOME` 归位，
  这样每条都幂等、跟执行顺序无关；`assert-sel/assert-count/assert-name` 断言"注入真的生效"，
  只靠截图比容易把「按了没反应 + 恰好长得像」判成通过。

### 22.1 两个落点

| 件 | 位置 | 说明 |
|---|---|---|
| 脚本（装机源） | 仓库根 `console-wall.sh` → 盒子 `/usr/local/bin/console-wall.sh`（755） | 画背景 + exec fbterm |
| 服务 | `/etc/systemd/system/console-wall.service` | 绑 `/dev/tty2`（**默认形态：藏在桌面后面**），`WantedBy=multi-user.target` |
| 壁纸库 | `/root/backgrounds/`，`/root/backgrounds/.pinned` 写第一行=固定那张 | 不给参数时按此顺序挑图 |

service 关键字段（出错基本都在这几条）：

```ini
[Unit]
Conflicts=getty@tty2.service
[Service]
TTYPath=/dev/tty2
StandardInput=tty
StandardOutput=tty
TTYReset=yes
TTYVHangup=yes
Environment=HOME=/root
Environment=TERM=fbterm
ExecStart=/usr/local/bin/console-wall.sh
```

### 22.0 默认形态：桌面在 tty1 前台，壁纸终端在 tty2 后台（2026-11-18 定）

开机 = **桌面**（`desktop.service`，SDL2 KMSDRM 占 tty1）；壁纸终端同时在 **tty2** 起好并等着，
只要 `Ctrl+Alt+F2` 就切过去，`Ctrl+Alt+F1` 回桌面 —— 两边都是常驻，不用互相停服务。

要点（踩过的）：

- 服务里**不要**写 `Conflicts=desktop.service`（那是老的一山不容二虎版，会把桌面顶掉，见 §22.7）；
  只跟自己的 `getty@tty2` 冲突即可，tty1 不碰。
- fbterm 只在 tty2 画：它走 fbcon/`/dev/fb0`，而桌面走 DRM planes，两套缓冲互不干扰 —— 实测反复
  `chvt 1 ↔ 2` 三次，`desktop` 仍 `active`、pid 不变、无 warning。
- 开机 `cat /sys/class/tty/tty0/active` 应为 `tty1`（桌面在前台）。
- 想改成"开机就进终端"：把 service 的 `TTYPath` 换回 `/dev/tty1`，再加回
  `Conflicts=desktop.service getty@tty1.service` 与 `Before=getty@tty1.service`，
  同时 `systemctl disable desktop`。二者在 tty1 上是硬互斥。

一键切换（默认形态）：

```bash
systemctl enable --now desktop        # tty1 桌面
systemctl enable --now console-wall   # tty2 壁纸终端（可同时开）
```

### 22.2 分辨率：取 `modes`，不要取 `virtual_size`

`/sys/class/graphics/fb0/virtual_size` 在这台机器上报 **2560,2160**（虚拟高，是双缓冲/对齐后的值），
按它画图会垂直拉伸 1.5 倍且底部被裁掉。脚本先读真实模式：

```bash
MODE=$(head -1 /sys/class/graphics/fb0/modes)   # 期望 2560x1440p-0
[[ "$MODE" =~ ([0-9]+)x([0-9]+) ]] && W=${BASH_REMATCH[1]} H=${BASH_REMATCH[2]}
```

读不到才退回 `virtual_size`，最后兜底 2560x1440。

### 22.2.1 分辨率池（vmode）：换屏/换分辨率不用改启动参数（2026-11-18 新方案）

上一节是**画图那一层**的自适应（没模式就按屏算 W/H）。这一节是**更下面一层**：
`video=` 与 `drm.edid_firmware=` 决定内核给这块屏走什么模式，原来写死 `2560x1440MR@60e`，
换台只有 1080p 的显示器就黑屏。现在改成"**预置 EDID 池 + 一条命令切换**"。

原理（三条必须同时对齐，缺一条白改）：

```
edid-pool/x96-<名字>.bin  ──cp──>  /lib/firmware/edid/active.bin
                                        │ initramfs hook (hooks/edid) 每次构建时
                                        └─cp──> edid/benq-pd2500q.bin
uEnv.txt:  drm.edid_firmware=HDMI-A-1:edid/benq-pd2500q.bin   ← 名字固定，内容由 active.bin 决定
           video=HDMI-A-1:2560x1440MR@60e                     ← 数字必须跟着改
```

- `uEnv.txt` 里的 EDID **文件名是固定的**（`benq-pd2500q.bin`），不改它；
  盒子上的 `/etc/initramfs-tools/hooks/edid` 每次 `update-initramfs` 都把 `active.bin` 拷成这个名字塞进 initrd。
  所以**换分辨率 = 换 `active.bin` + 同步改 `video=` 的数字 + 重建 initrd**。
- 只改 `active.bin` 不重建 initrd = 重启后还是老的（initrd 里那份才是真的）。
- 只改 EDID 不改 `video=` 数字 = 内核仍按 `video=` 要模式，可能被忽略或回落。

池里四档（`edid-pool/`，`mk-pool.py` 可重生成，自校验 PASS）：

| 名字 | 模式 | 来源 | 备注 |
|---|---|---|---|
| `720p60` | 1280x720@60 | 1080p 底稿里 DTD1 搬到 DTD0 | 最保守，兜底用 |
| `1080p60` | 1920x1080@60 | 盒子空 HDMI 自报 EDID | 通用，换任何屏都亮 |
| `1440p60` | 2560x1440@60 | BenQ PD2500Q 原生 DTD | **当前在用** |
| `2160p30` | 3840x2160@30 | 手写 DTD（297MHz） | 4K 只能 30Hz，HDMI2.0 带宽不足 |

盒子上一条命令切（脚本走 `/root/vmode`，仓库根 `vmode` 是源）：

```bash
vmode status            # 启动参数 / active.bin / initrd 里那份是否一致 / card0 现有模式
vmode list              # 池里有什么
vmode set 1080p60       # 换 EDID + 改 video= + 重建 initrd，四步都自校验
vmode set 2160p30 -y    # 改完自动重启
vmode rollback          # 回退 uEnv.txt 并同步把 active.bin 切回对应档
```

`set` 的四个步骤（任一步失败就中止，不会留半改状态）：① 原子换 `active.bin`（`cp` 到 `.tmp` 再 `mv`）
② `sed` 只替换 `video=HDMI-A-1:[^ ]*`，保留已验证的 `MR@60e` 语法 ③ `update-initramfs -u`
（30–60s）④ `unmkinitramfs` 拆开 initrd、`cmp` 确认里面那份 == `active.bin`。
改之前自动留 `uEnv.txt.before-<时分秒>`，以及首次运行留一份 `uEnv.txt.orig`。

验收（重启后）：

```bash
ssh x96 'vmode status'                       # 三段都该 green，不能有 !=
ssh x96 'head -1 /sys/class/drm/card0-HDMI-A-1/modes'
ssh x96 'head -1 /sys/class/graphics/fb0/modes'   # 应与上一条一致
```

换分辨率后**连带要动的东西**（容易漏）：

- `console-wall.sh` 不用改：它读 `fb0/modes` 拿真实 W/H，字号也按高自动算（见 §22.4）。
- `tools/golden/*.png` 基线会失效 —— 换模式后必须 `tools/x96-check.sh --run-dir tools/cases --record` 重录，
  否则每条用例都报画面不符（判据里有缩放兜底，但录新的才准）。
- 桌面 `desktop/` 走 KMSDRM，按 DRM 报的模式自己铺，不用改；确认它没被挤到半屏看 §22.0.2 的截图流程。

> DDC 读不到：这台 HDMI 的 DDC/I2C 通道**实测不可用**（`vmode detect` 会报失败），
> 所以做不到"插上屏自动认"，只能是"手动选一档 + 记住选择"。`vmode auto` 在 DDC 失败时
> 沿用 `/var/lib/vmode/current` 里上次的选择，没有就用最通用的 `1080p60`。

### 22.3 背景处理链路

```bash
ffmpeg -i "$IMG" -vf "scale=W:H:force_original_aspect_ratio=increase,crop=W:H,\
                      lutrgb=r=val*0.42:g=val*0.42:b=val*0.42,gblur=sigma=2" \
       -pix_fmt bgra -f rawvideo /run/console-wall.raw
dd if=/run/console-wall.raw of=/dev/fb0 bs=$((W*4)) conv=notrunc status=none
```

- `scale…increase + crop`：铺满不留边，宁可切掉一点。
- `val*0.42`：压暗到 42%，否则浅色壁纸上的文字压不住。
- `gblur=sigma=2`：轻微模糊，去掉噪点，让文字边缘干净。
- `-pix_fmt bgra`：framebuffer 是 BGRA（`fb0` 的 `32bpp`），顺序错就是偏色/花屏。
- 没有图时的兜底：`tr '\0' '\30'` 铺 `0x30` 深灰，**不能留空**（残留内容看起来像花屏）。

### 22.4 字号 ↔ 屏幕网格（随分辨率自动算）

字号决定行×列，选错了要么字太小要么行距挤。**不要写死一个字号**：`-s` 是像素字号，
1440p 合适的 20 号在 1080p 上偏挤、在 4K 上也偏小。脚本现在按真实高自动算：

```
fs = H / 72，夹在 [12, 32]      # 1440 -> 20，正好等于原来实测的默认值
```

`CONSOLE_WALL_FONTSIZE` 仍可强行覆盖（临时试字号用）。

| 分辨率 | 自动 `-s` | 行 × 列 | 说明 |
|---|---|---|---|
| 1280x720 | 12（夹底） | ≈38 × 106 | 推算值 |
| 1920x1080 | 15 | 45 × 128 | 推算值，与 1440p 密度相当 |
| **2560x1440** | **20** | **49 × 170** | **实测**，`stty size` 读数，日常够用 |
| 3840x2160 | 30 | 45 × 170 | 推算值，与 1440p 密度相当 |

改字号（覆盖自动值；行号见脚本里 `FSIZE` 那段）：

```bash
# 盒子执行
CONSOLE_WALL_FONTSIZE=24 /usr/local/bin/console-wall.sh /root/backgrounds/xxx.jpg
# 想永久固定某个字号，就把上面这行写进 service 的 Environment=
```

字体默认 `Noto Sans Mono CJK SC`（`CONSOLE_WALL_FONT` 可换）。必须留 CJK 等宽字体，
否则中文不占两列，ASCII 混排会错位。

### 22.5 坑：不要手写 `--font-width/--font-height` 硬指定格子

2026-11-18 踩过：为了「更大更清楚」把 fbterm 起成 `--font-height=24 --font-width=12`，
结果行与行叠压、字符挤成一团糊在屏幕上半部 —— 手写格子与字体实际行高不匹配就是这个症状。

结论：**只用 `-s 字号`，让 fbterm 自己算格子**。真要指格子，宽:高 必须 ≈ **0.53**
（如 16×30、15×29），否则重演叠行。

排查顺序：`stty size </dev/pts/0` 看网格是否合理 → `pgrep -a fbterm` 看参数有没有多出来的
`--font-*` → 截一张 fb0 的图看渲染。截图：

```bash
ssh x96 'dd if=/dev/fb0 bs=10240 count=1440 status=none' > /tmp/fb.raw
ffmpeg -f rawvideo -pix_fmt bgra -s 2560x1440 -i /tmp/fb.raw -vf crop=1600:260:0:0 /tmp/fb.png
```

### 22.6 发布（无编译，纯脚本）

```bash
cd /home/quqiufeng/kernel
scp console-wall.sh x96:/tmp/console-wall.sh
ssh x96 'install -m755 /tmp/console-wall.sh /usr/local/bin/console-wall.sh && systemctl restart console-wall'
ssh x96 'systemctl is-active console-wall; stty -F /dev/pts/0 size'
```

> `stty size </dev/pts/0` 在 ssh 里读不到（那是**自己**的终端），要 `stty -F /dev/pts/0`。
> 也别拿 fbterm 自己的 `fd/0`（=`/dev/tty2`）当结果，那是 fbcon 的网格（会给出 90 320），
> 真正的网格在 fbterm 起的 bash 那个 pts 上。

分辨率池/切换器一起发布（改分辨率时才动，平时不用）：

```bash
scp vmode x96:/tmp/vmode
scp edid-pool/x96-*.bin x96:/tmp/pool/          # 先在盒子 mkdir -p /lib/firmware/edid/pool
ssh x96 'install -m755 /tmp/vmode /root/vmode && cp /tmp/pool/*.bin /lib/firmware/edid/pool/ && vmode status'
```

验收：service `active`、`stty -F /dev/pts/0 size` 给出 `49 170`（1440p 下自动字号 20）、截图里中英混排对齐不叠行。

### 22.7 坑：老版 console-wall 会把桌面顶掉（已修）

**旧版** `console-wall.service` 写的是 `Conflicts=desktop.service` + `Before=getty@tty1.service`
且绑 tty1，于是 `systemctl enable console-wall` 后重启，**桌面不会起来**（`desktop` 显示
`inactive (dead)`，`is-enabled` 被置 `disabled`），HDMI 上只剩壁纸终端 —— 2026-11-18 就是这样
"桌面没启动"了一次。

现在改成 §22.0 的 tty2 双活版（备份在盒子 `/root/console-wall.service.bak-tty1`），两个服务可以同时
enabled。若真要回到互斥的老形态，才需要二选一：

```bash
# 只要桌面
systemctl disable console-wall; systemctl stop console-wall
# 只要 tty1 壁纸终端
systemctl disable desktop; systemctl stop desktop
```

排查：`systemctl is-active desktop console-wall` → 两个都 `inactive` 说明都没启用；
`journalctl -u desktop -b` 空 = 根本没跑过（不是崩了）。

注意：desktop 走 SDL2 KMSDRM，画面**不经过 `/dev/fb0`**，所以跑起来时 `dd if=/dev/fb0` 截出来是空白，
别把它当"没渲染"的证据；看 `/proc/<pid>/fd` 里有没有 `/dev/dri/card0` 才是真在画。

---

## 23. 只换内核：单独编译 → 直接装进盒子（不重做镜像）

一句话：**改的是内核，就别碰 rootfs。** `Image` + `dtb` + `modules` 三样 SCP 上去，
在盒子**本机**重做 initrd/uInitrd，重启即可。**装这一段实测约 2 分钟**（盒上 `mkinitramfs` 14 秒 + 重启到 ssh 回来 35 秒 + 传输校验），
编译时间另看 `$OUT/.build-sec`（无改动时增量复查 8 秒即过）。2026-11-27 23:50 实测走通一遍（含重启回读）。

### 23.1 判据：这套流程管的是"盒子已在跑、只换内核"

| 要走 §23 | 要走 §19.6 / §10 |
|---|---|
| 已有能启动的盒子（eMMC 或 U 盘），只改内核/配置/dtb/模块 | 新卡、换系统、rootfs 裁剪、首启自动装 eMMC |
| 判据：`ssh root@<盒子IP> uname -r` 有输出且 `/lib/modules/<KNAME>` 在 | 判据：`lsblk` 里没有可用的 rootfs 分区 |

盒子现役（2026-11-27 核对）：eMMC 启动，`/boot` = `mmcblk1p1`（vfat 510M），`/` = `mmcblk1p2`（ext4 56.9G），
`uEnv.txt` 的 `LINUX=/zImage`、`INITRD=/uInitrd`、`FDT=/dtb/amlogic/meson-g12a-x96-max.dtb`。

> **`/boot/vmlinuz-7.2.12-x96-trim` 和 `/boot/initrd.img-*` 不是启动用的那份** —— 它们是 ophub 打包留下的
> Debian 风格副本（vmlinuz 还是 4 月 14 日的旧文件）。u-boot 只认 `uEnv.txt` 里那三个路径，
> **改错文件等于没改**：必须动 `zImage` / `uInitrd` / `dtb/amlogic/*.dtb`。

### 23.2 主机：只编内核（不出 initrd、不打包、不做镜像）

```bash
cd /home/quqiufeng/kernel
./x96max/trim/build-kernel.sh          # 裁剪套（现役）：config-7.2.12-x96-trim → kbuild-trim
# ./x96max/full/build-kernel.sh        # 全量套：另一个产物树，两套互不覆盖
```

产物（`/x96-build/kbuild-trim`，本次实测值）：

| 产物 | 大小 | md5 |
|---|---|---|
| `arch/arm64/boot/Image` | 32512512 | `fa0a45cd93293add25b70aeb3a64539a` |
| `arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb` | 51123 | `bc5d038e84a8faacd6271b812f8b17cf` |
| `modules/lib/modules/7.2.12-x96-trim/` | 16M / 155 个 `.ko` | — |

编完先自查 LOCALVERSION 与模块目录名对得上（对不上，装上就起不来，见 23.6）：

```bash
grep '^CONFIG_LOCALVERSION=' /x96-build/kbuild-trim/.config     # "-x96-trim"
basename /x96-build/kbuild-trim/modules/lib/modules/*           # 7.2.12-x96-trim
```

### 23.3 主机：打包三样并传到盒子 `/tmp`

```bash
OUT=/x96-build/kbuild-trim
KNAME=7.2.12-x96-trim
BOX=root@192.168.1.121

tar -czf /tmp/mod-$KNAME.tar.gz -C "$OUT/modules/lib/modules" $KNAME      # 4.0M（155 个 .ko）
scp /tmp/mod-$KNAME.tar.gz \
    "$OUT/arch/arm64/boot/Image" \
    "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" \
    $BOX:/tmp/
```

### 23.4 盒子：备份 → 覆盖 → depmod → 重做 initrd/uInitrd

> initrd **不需要主机 qemu chroot**（§6 / §19.4 那是给镜像准备时用的离线做法）。
> 盒子自己就是 arm64，`mkinitramfs`/`update-initramfs`/`mkimage`/`depmod`/`cpio`/`gzip` 全都有
> （`u-boot-tools 2025.01-3+deb13u1`、`initramfs-tools 0.148.4`），直接在本机生成，14 秒。

```bash
KNAME=7.2.12-x96-trim
S=$(date +%Y%m%d-%H%M%S)

# 1) 备份：boot 里 5 个 + dtb 1 个
cd /boot
for f in zImage uInitrd uInitrd-$KNAME initrd.img-$KNAME vmlinuz-$KNAME; do
  [ -f $f ] && cp -a $f $f.bak-inst-$S
done
cp -a dtb/amlogic/meson-g12a-x96-max.dtb dtb/amlogic/meson-g12a-x96-max.dtb.bak-inst-$S

# 2) 模块（整目录覆盖，不要只解新文件）
tar -xzf /tmp/mod-$KNAME.tar.gz -C /lib/modules/
find /lib/modules/$KNAME -name '*.ko*' | wc -l        # 期望 155

# 3) 内核与 dtb：uEnv.txt 里 LINUX=/zImage、FDT=/dtb/amlogic/...
cp /tmp/Image /boot/zImage
cp /tmp/meson-g12a-x96-max.dtb /boot/dtb/amlogic/

# 4) 依赖表 + initrd
depmod -a $KNAME
mkinitramfs -o /boot/initrd.img-$KNAME $KNAME
# 盒子没有 zstd → 会打 "W: No zstd ... using gzip"，是提示不是错误；压缩方式随之变成 gzip

# 5) uInitrd：两份都要换（uEnv.txt 加载 /uInitrd，另一份是 ophub 命名习惯的副本）
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
  -d /boot/initrd.img-$KNAME /boot/uInitrd
cp /boot/uInitrd /boot/uInitrd-$KNAME
```

判据（三条都成立才算装上）：

```bash
md5sum /boot/zImage                                                            # 应等于主机 Image 的 md5
md5sum /boot/dtb/amlogic/meson-g12a-x96-max.dtb                                # 应等于主机 dtb 的 md5
ls -l /boot/zImage /boot/uInitrd /boot/uInitrd-$KNAME                          # uInitrd 两份字节数一致
```

### 23.5 重启与验收（本次实测）

```bash
sync; systemctl reboot
# 约 35 秒后 ssh 能进（本次 35s）
ssh root@192.168.1.121 'uname -a; cat /proc/version; uptime -p; systemctl is-active desktop console-wall'
```

```text
Linux x96src 7.2.12-x96-trim #13 SMP PREEMPT_DYNAMIC Fri Nov 27 23:27:09 CST 2026 aarch64 GNU/Linux
up 0 minutes
desktop: active   console-wall: active
eth0 UP 192.168.1.121/24

# dmesg（err 级）里只有这些陈年噪声，都不是本次引入的：
#   meson-drm ff900000.vpu: DSI transceiver device is disabled        ← 正常（不用 DSI）
#   Failed to find module 'autofs4'                                    ← config 里就是 "# CONFIG_AUTOFS_FS is not set"（第 7254 行）
#   panfrost ffe40000.gpu: -ENODEV: _opp_set_regulators: no regulator (mali) ← DT 没给 mali 调压器，一直如此，不影响显示
```

> **版本名没变，`uname -r` 认不出换了没有** —— 同 `KNAME` 覆盖安装时唯一变的是 build 时间戳
> （`#13 SMP PREEMPT_DYNAMIC Fri Nov 27 23:27:09 CST 2026`）。要确认到底换没换，
> 对 `md5sum /boot/zImage` 与主机 `Image` 的 md5，或看 `/proc/version` 里的编译时间。

### 23.6 回滚

> **2026-11-27 23:55 起这些备份已不存在**：新内核跑稳后清了 `/boot` 里全部 `*.bak-inst-*`
> 与 `*.bak-pre-vdec-1127`、7 个 `uEnv.txt.bak-*`（323M → 120M，24%）。
> 现在要回退只能**重编同版本**（`kbuild-trim` 源树都在）或从 `/x96-build/base-boot-backup`
> （只留 `-trim` 一套，49M）取件。下面的命令是**当时**的写法，留着给以后打备份时用。

一条命令回到上一版（备份是同一时刻的全套，别跨版本混用）：

```bash
S=20261127-235032          # 上一步打的时间戳，/boot 里 ls *.bak-inst-* 能看到
cd /boot
for f in zImage uInitrd uInitrd-7.2.12-x96-trim initrd.img-7.2.12-x96-trim vmlinuz-7.2.12-x96-trim; do
  [ -f $f.bak-inst-$S ] && cp -a $f.bak-inst-$S $f
done
cp -a dtb/amlogic/meson-g12a-x96-max.dtb.bak-inst-$S dtb/amlogic/meson-g12a-x96-max.dtb
sync; systemctl reboot
```

模块目录要回滚就重解旧 tar（本流程没保留旧模块包时，只能重编同版本或从 §19.5 的四件套里取）。

### 23.7 这段流程的坑

1. **改错文件**：动 `vmlinuz-*` / `initrd.img-*` 不生效（u-boot 读 `uEnv.txt` 的 `LINUX=/zImage`）。详见 23.1 的提示。
2. **`/boot` 只有 510M**：一套备份 ≈ 100M（zImage 32M + vmlinuz 32M + initrd 12.7M + uInitrd 12.7M×2 + dtb）。
   本次装完从 225M 涨到 323M，只剩 188M（清理后回到 120M/391M 可用）。**只留一代备份**，装第二轮前先删上一轮 `.bak-inst-*`，
   否则 `/boot` 满了以后 `cp` 失败会留下半截 `zImage`。
3. **模块目录名必须等于 `CONFIG_LOCALVERSION` 拼出来的 KNAME**。名不对 → `depmod` 不报错，
   但开机后模块全加载失败（网卡/声卡/文件系统驱动全没）。
4. **`mkinitramfs` 与 `mkimage` 的压缩参数要一致**（这里都是 gzip）。盒子没有 zstd，别手写 `-C zstd`。
5. **`initrd.img-*` 里只有 7 个 `.ko`**，其余 148 个在 `/lib/modules` 里由 depmod 索引 —— 所以
   **`/lib/modules` 必须先解完再 `mkinitramfs`**，顺序反了 initrd 里就是旧依赖表。
6. **不要在主机上 `cp Image /boot/zImage` 式的远程强写**（vfat 不能原子替换，断网/断电会得到半截内核）。
   要么像 23.3 那样先落 `/tmp` 再本机 `cp`，要么 `sync` 后立刻校验 md5。

---

*文档版本: 2.3 · 更新: 2026-11-27 · 设备: X96 Max / S905X2*
