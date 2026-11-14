# X96 Max（Amlogic S905X2）— 从源码内核到 eMMC 的完整记录

> **一句话**：把一台 X96 Max 4GB 电视盒子，从商家 ophub 镜像换成「自编译 Linux 7.2.12 + 官方 Armbian build framework 源码构建的 rootfs + 主线 U-Boot」，跑在 eMMC 上，只留有线和显示/音频，155 个包。
> **当前状态** `[verified]`：已从 eMMC 启动，`uname -r` = `7.2.12-x96`，hostname `x96src`，rootfs ~568M。
> **这是记录不是教程**：所有命令都是本机实际跑过的；路径、包数、分区起点是当场读出来的事实，不是「一般应该这样」。

---

## 0. 怎么读这份文档

文档按**三层**组织，同一件事**只写一次**：

| 层 | 章节 | 何时读 |
|---|---|---|
| **现状** | §1 硬件 · §2 系统来源与分区 · §3 驱动映射 · §9 进度 | 「这机器是什么 / 现在装的是什么」 |
| **流程** | §4 环境与路径 · §5 端到端流程（唯一权威）· §6 脚本与自动安装 | 「从头再做一遍 / 换一块盘重来」 |
| **经验** | §7 踩坑与铁律 · §8 风险备份回滚 · 附录 | 「失败了 / 黑屏了 / 哪步错了」 |

三条约定：

1. **§5 是唯一的操作流程**。其他章节只负责解释原理、给参数、给数据；若某条命令在 §5 和别处都出现，以 §5 为准。
2. **事实与愿望分开**。带 `[verified]` 的是从盒子 `uname`/`findmnt`/`dpkg -l` 读出来的；不带的表示「按设计应该如此」。
3. **矛盾不消灭、只标记**。原文档前后不一致的地方集中列在附录 B，不猜、不悄悄改。

---

## 1. 硬件配置

| 项目 | 实测值 |
|---|---|
| 型号 | X96 Max（DTB `meson-g12a-x96-max.dtb`，compatible `amediatech,x96-max` / `amlogic,g12a`） |
| SoC | Amlogic S905X2，4×Cortex-A53（aarch64，`meson-g12a`） |
| GPU | Mali-G31（Panfrost，`panfrost ffe40000.gpu`） |
| 内存 | 4GB 标称，Linux 可见约 3.24GiB（`MemTotal 3397224 kB`） |
| 存储 | eMMC 64GB（`064G30`，58.2GiB / 122142720 sectors），`mmcblk2`，另有 `mmcblk2boot0/1` 各 4MiB |
| 有线网卡 | Amlogic `meson8b-dwmac`（Synopsys DWMAC1000），外置 **RTL8211F** PHY，1Gbps |
| 无线 | **RTL8822BS**（SDIO `024c:b822`），Wi-Fi + 蓝牙二合一；本项目**不使用** |
| 显示 | `meson-dw-hdmi`（HDMI TX v2.01a），DRM `meson-drm`，支持 1920×1080 |
| 音频 | `axg-sound-card`（`X96-MAX`），AXG TDM/SPDIF + G12A TOHDMITX/TOACODEC |
| 视频硬解 | `meson_vdec`（V4L2 mem2mem） |
| USB | USB 3.0 ×1（5000M，1 port）+ USB 2.0 ×2（480M，2 ports），`dwc3-meson-g12a` + xHCI |
| 红外 | `meson_ir`（服务器用途可禁用） |
| RTC | `meson-vrtc`（`ff8000a8.rtc`，掉电不保时） |
| 温度 | 空闲约 35–49°C |
| 以太网 MAC | `02:00:00:10:25:01`（`ethtool -P` 永久地址；内核 cmdline 另有 `mac=90:0e:b3:10:cc:69`，未生效） |
| Wi-Fi MAC | `c4:3a:35:58:ce:bc`（不使用） |

USB 拓扑实测：

```text
Bus 002: xhci-hcd/1p, 5000M   （USB 3.0）
Bus 001: xhci-hcd/2p, 480M    （USB 2.0）
```

---

## 2. 系统来源与分区

### 2.1 三个阶段，别搞混

这台机器先后跑过三套系统。文中出现的每个「包数 / 内核版本」都对得上其中一套，**看数字前先确认在说哪一套**：

| | 原厂（商家） | 中间验证版 | **当前** `[verified]` |
|---|---|---|---|
| 发行版 | Armbian OS 26.11.0（ophub 重打包） | 同上 + 裁剪 | Armbian 26.8.3 trixie（**源码构建**） |
| 用户态 | Debian 12.15 bookworm | bookworm | Debian 13 trixie |
| 内核 | `6.12.112-ophub` | `7.2.12-x96` | **`7.2.12-x96`** |
| 包数 | ~484 | 312 → 155 | 253 → **155**（装运行依赖后 177） |
| rootfs | 2.0GiB | — | **~568M** |
| U-Boot | 原厂 | 原厂 | **主线**（`x96max-u-boot.bin.sd.bin`） |
| 主机名 / IP | `root@192.168.1.120` | — | **`x96src` / `192.168.1.121`** |

- 两个 IP 都是 DHCP，会变；`~/.ssh/config` 的 `Host x96` 指**原厂**那台。
- 密码只在 `~/.env` 的 `X96_PASS`；**仓库和本文都不写密钥**。
- 最终系统 = **源码构建 rootfs**（官方 Armbian build framework + mmdebstrap，从 Debian trixie 包构建）+ 自编译 `7.2.12-x96` + 主线 U-Boot。ophub 在这里只做两件事：提供 `rebuild` 打包器、提供基础 `.img` 骨架。

### 2.2 为什么「官方 Armbian 不支持但能跑」

X96 Max 不在官方 Armbian 板型列表里。商家用的是社区项目 [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)，流程是：

```text
官方 Armbian 通用镜像（如 Odroidn2）
        ↓
ophub rebuild：替换 U-Boot / DTB / 内核 / 启动脚本
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

**所以**：复现时必须同时沿用 `-b s905x2`（即 `MODEL_ID=301`）和 `BOARD=odroidn2` 这两套「身份」。任何一环换成「等官方支持 X96 Max」都是空想。

### 2.3 分区布局

**原厂**：

```text
/dev/mmcblk2      58.2G
├─ mmcblk2p1      511M  FAT32  /boot    start=239616  sectors（约 117MiB）
└─ mmcblk2p2      57.6G ext4   /        start=1288192 sectors
```

**当前（主线 U-Boot，`armbian-install -m yes -a no`）** `[verified]`：

```text
/dev/mmcblk1      58.2G
├─ mmcblk1p1      511M  FAT32 BOOT_EMMC   /boot   start=139264  sectors（68MiB）
└─ mmcblk1p2      56.9G ext4  ROOTFS_EMMC /       start=2764800 sectors（1350MiB）
```

- 前 117MiB 是 Amlogic 启动链保留区，**不要手写**。
- 主线 U-Boot 占据 eMMC 起始区；原厂启动区 / p1 / p2 备份在 NAS（见 §8）。
- 设备名差异（`mmcblk1` vs `mmcblk2`）见附录 B：以 `findmnt -no SOURCE /` 为准，别背数字。

`/etc/ophub-release` 关键值（主线 U-Boot 安装后）：

```text
MLUBOOT_STATUS='yes'
MAINLINE_UBOOT='/usr/lib/u-boot/x96max-u-boot.bin.sd.bin'
AMPART_STATUS='no'
DISK_TYPE='emmc'
ROOTFS_TYPE='ext4'
```

### 2.4 `/boot` 内容与启动参数

```text
uEnv.txt                          启动参数
zImage / vmlinuz-7.2.12-x96       当前内核
uInitrd / initrd.img-...          initramfs
dtb/amlogic/meson-g12a-x96-max.dtb
u-boot.emmc                       6.x+ 内核的「重载 U-Boot」（原厂链上会黑屏，见 §7）
u-boot-x96max.bin                 原厂 / overload U-Boot
u-boot.sd / u-boot.usb            SD / USB U-Boot
emmc_autoscript                   从 eMMC 拉起
boot.scr                          启动脚本
```

`uEnv.txt` 形态：

```text
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/meson-g12a-x96-max.dtb
APPEND=root=UUID=<uuid> rootflags=data=writeback rw rootfstype=ext4 \
       console=ttyAML0,115200n8 console=tty0 ... video=HDMI-A-1:1920x1080@60e
```

---

## 3. 驱动映射（有线-only）

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

**关闭项**（不做无线，顺带省固件和包）：

```text
CONFIG_WLAN
CONFIG_CFG80211
CONFIG_MAC80211
CONFIG_RTW88 / RTW88_SDIO / RTW88_8822B / RTW88_8822BS
CONFIG_BT / BT_HCIUART / BT_HCIUART_RTL
CONFIG_RFKILL
```

---

## 4. 环境与路径

### 4.1 构建环境

| 项目 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04（noble），6 核，23GiB 内存 |
| 工作目录 | `/data/x96-build` |
| ophub 仓库 | `/data/x96-build/amlogic-s9xxx-armbian` |
| Armbian build | `/data/x96-build/armbian-build` |
| 内核源码 | `/opt/linux/src/linux-7.2.12` |
| 内核构建目录 | `/data/x96-build/kbuild-7.2.12` |
| 交叉工具链 | `aarch64-linux-gnu-gcc` 13.3.0 |
| 模拟器 | `qemu-aarch64-static` + binfmt（arm64 chroot 用） |
| 仓库脚本 | `/home/quqiufeng/kernel/x96max/` |

ophub 的构建依赖（官方清单，装一次）：

```bash
cd /data/x96-build/amlogic-s9xxx-armbian
sudo apt-get update
sudo apt-get install -y $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)
```

`rebuild` 相关的全部路径速查：

```text
构建仓库      /data/x96-build/amlogic-s9xxx-armbian
Armbian build /data/x96-build/armbian-build
源码 rootfs   /data/x96-build/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst
内核源码      /opt/linux/src/linux-7.2.12
内核构建      /data/x96-build/kbuild-7.2.12
基础镜像      /data/x96-build/amlogic-s9xxx-armbian/build/output/images/
内核包目录    /data/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/
最终镜像      /data/x96-build/amlogic-s9xxx-armbian/build/output/images/
仓库脚本      /home/quqiufeng/kernel/x96max/
输出镜像      /data/x96-build/recovery/x96src-autoinstall.img.gz
源码镜像      Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz
本地暂存      ~/x96-backup/
```

> 基础镜像（~2.5G）、4 个内核 tar、rootfs 缓存、recovery 镜像**都不入库**；仓库只保留脚本和配置。

### 4.2 盒子上（当前系统）`[verified]`

```text
hostname  x96src
内核      7.2.12-x96
rootfs    /dev/mmcblk1p2（eMMC）56.9G ext4
网络      eth0 1Gbps（RTL8211F），DHCP
包数      155（基础）/ 177（装 LuaJIT/音频/摄像头依赖后）
```

---

## 5. 端到端流程（唯一权威）

> 顺序执行：内核 → initrd → 四个内核包 → 源码 rootfs → 注入 + rebuild → 裁剪 → 写盘 → eMMC 安装 → 验证。
> 原理在 §1–§3、参数解释在 §7、风险在 §8；本节只给**能直接粘的命令**。

### 5.1 前置条件

| 项 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04，6 核 / 23GiB（实测够用） |
| 运行身份 | **普通用户**，脚本内部自己 `sudo`。用 `sudo ./build-image.sh` 起会把 `$HOME` 变成 `/root`，直接报 `missing root SSH public key: /root/.ssh/id_ed25519.pub` |
| 内核源码 | `/opt/linux/src/linux-7.2.12`（`VERSION=7 PATCHLEVEL=2 SUBLEVEL=12`） |
| 内核配置 | 仓库内 `x96max/kernel/config-7.2.12-x96`（**最终 `.config`，直接复制即可复现**） |
| 基础镜像 | `.../build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` |
| 输出 | `/data/x96-build/recovery/x96src-autoinstall.img.gz` |

构建前**先清场**，别让不属于本次的挂载混进来（原因见 §7.3 第 19 条）：

```bash
mount | grep -vE ' / |/data'     # 有没有该消失却还在的挂载点（U 盘、上次 loop）
sudo losetup -D                  # 清掉上次失败 rebuild 留下的 loop 设备
```

一次性装依赖：

```bash
sudo apt-get update
sudo apt-get install -y \
  git curl wget rsync zstd xz-utils cpio kmod openssl sudo \
  build-essential flex bison bc libssl-dev libelf-dev libncurses-dev \
  qemu-user-static binfmt-support u-boot-tools aarch64-linux-gnu-gcc

# ophub（提供 rebuild + 内核打包逻辑）
git clone --depth 1 https://github.com/ophub/amlogic-s9xxx-armbian \
  /data/x96-build/amlogic-s9xxx-armbian
cd /data/x96-build/amlogic-s9xxx-armbian
sudo apt-get install -y \
  $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)

# Armbian build framework（提供源码 rootfs）
git clone https://github.com/armbian/build /data/x96-build/armbian-build
```

### 5.2 编译内核 `7.2.12-x96`

```bash
REPO=/home/quqiufeng/kernel
KSRC=/opt/linux/src/linux-7.2.12
OUT=/data/x96-build/kbuild-7.2.12

# 仅首次或源码树内有树内产物时执行；会删掉 .config
# (cd "$KSRC" && make ARCH=arm64 mrproper)

mkdir -p "$OUT"
cp "$REPO/x96max/kernel/config-7.2.12-x96" "$OUT/.config"

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

检查：

```bash
grep '^CONFIG_LOCALVERSION=' "$OUT/.config"   # 必须是 "-x96"
```

**从 6.18 基线手工重建配置时**（想理解配置怎么来的，而不是直接抄 `.config`）：

```bash
OUT=/data/x96-build/kbuild-7.2.12
cp /tmp/ophub-cfg/config-6.18 "$OUT/.config"

# 关 debug info / BTF：体积和编译时间的主要来源
for s in DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
         DEBUG_INFO_DWARF5 DEBUG_INFO_COMPRESSED_NONE \
         DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_DWARF4 \
         DEBUG_INFO_REDUCED DEBUG_INFO_SPLIT; do
  ./scripts/config --file "$OUT/.config" -d "$s"
done
./scripts/config --file "$OUT/.config" -e DEBUG_INFO_NONE

# 关无线 / BT
for s in WLAN CFG80211 MAC80211 RTW88 RTW88_SDIO RTW88_8822B \
         RTW88_8822BS BT BT_HCIUART BT_HCIUART_RTL RFKILL; do
  ./scripts/config --file "$OUT/.config" -d "$s"
done

./scripts/config --file "$OUT/.config" --set-str LOCALVERSION "-x96"
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

关键项自检（两个方向都查：该有的在、该没的没）：

```bash
grep -E 'CONFIG_(DWMAC_MESON|STMMAC_ETH|REALTEK_PHY|MDIO_BUS_MUX_MESON_G12A|MMC_MESON_GX|DRM_MESON|DRM_MESON_DW_HDMI|DRM_PANFROST|VIDEO_MESON_VDEC|USB_DWC3_MESON_G12A|USB_XHCI_HCD|SND_MESON_AXG_SOUND_CARD|SND_MESON_G12A_TOHDMITX)' "$OUT/.config" | sort
grep -E 'CONFIG_(WLAN|RTW88|BT|BT_HCIUART|RFKILL)' "$OUT/.config" | sort
```

编译的两个坑（详见 §7）：DTB 目标写 `amlogic/...`（写全路径会被 Makefile 二次拼接）；长编译用 `setsid`/`nohup` 脱离终端。

### 5.3 生成 arm64 initrd / uInitrd

`uInitrd` 必须是 **arm64**，x86 主机不能直接 `update-initramfs`。办法：挂基础镜像的 rootfs + `qemu-aarch64-static` chroot。

```bash
ROOT=/data/x96-build
OUT=$ROOT/kbuild-7.2.12
BASE=$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img

LOOP=$(sudo losetup -Pf --show "$BASE")
sudo mkdir -p /mnt/x96root
sudo mount "${LOOP}p2" /mnt/x96root

# 放进新内核、模块、配置、符号表
sudo cp -a "$OUT/modules/lib/modules/7.2.12-x96" /mnt/x96root/lib/modules/
sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-7.2.12-x96
sudo cp "$OUT/.config"              /mnt/x96root/boot/config-7.2.12-x96
sudo cp "$OUT/System.map"           /mnt/x96root/boot/System.map-7.2.12-x96

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
```

### 5.4 打包 4 个内核包

`rebuild` 只认这四个 tar（缺一个就报 `The 4 kernel missing.`），目录固定：

```text
build-armbian/kernel/stable/7.2.12/
├── boot-7.2.12-x96.tar.gz
├── dtb-amlogic-7.2.12-x96.tar.gz
├── modules-7.2.12-x96.tar.gz
├── header-7.2.12-x96.tar.gz
└── sha256sums
```

布局要跟 ophub 官方包一致：

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

完整打包命令：

```bash
ROOT=/data/x96-build
OUT=$ROOT/kbuild-7.2.12
KSRC=/opt/linux/src/linux-7.2.12
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
KNAME=7.2.12-x96

mkdir -p "$K"/{boot,dtb,modules,header}

# boot
cp "$OUT/.config"                         "$K/boot/config-$KNAME"
cp "$OUT/System.map"                      "$K/boot/System.map-$KNAME"
cp "$OUT/arch/arm64/boot/Image"           "$K/boot/vmlinuz-$KNAME"
cp "$ROOT/initrd.img-7.2.12-x96"          "$K/boot/initrd.img-$KNAME"
cp "$ROOT/uInitrd-7.2.12-x96"             "$K/boot/uInitrd-$KNAME"
tar -czf "$K/boot-$KNAME.tar.gz" -C "$K/boot" .

# dtb（只放 X96 Max 一个）
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-$KNAME.tar.gz" -C "$K/dtb" .

# modules
tar -czf "$K/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

# header（复刻 ophub collect_headers：源码树 + out-of-tree 生成物）
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
cp -a "$OUT/include/."            "$H/include/"
cp -a "$OUT/arch/arm64/include/." "$H/arch/arm64/include/"
cp -a "$OUT/scripts/."            "$H/scripts/"
cp -a "$OUT/.config" "$OUT/Module.symvers" "$H/"
tar -czf "$K/header-$KNAME.tar.gz" -C "$H" .

(cd "$K" && sha256sum *.tar.gz > sha256sums)
ls -lh "$K"
```

> 该 header 配方已校验 `[verified]`：产物与已有 `header-7.2.12-x96.tar.gz` 的 13800 个文件一致。

### 5.5 源码构建 rootfs

不用 ophub 预编译 rootfs、也不靠事后手工裁剪：用官方 Armbian build framework + mmdebstrap 从 Debian trixie 包**构建** rootfs。

```bash
git clone https://github.com/armbian/build /data/x96-build/armbian-build
cd /data/x96-build/armbian-build

./compile.sh rootfs \
  BOARD=odroidn2 BRANCH=current RELEASE=trixie \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  EXPERT=yes PREFER_DOCKER=no ARTIFACT_IGNORE_CACHE=yes
```

三个参数是成败关键：

| 参数 | 为什么必须 |
|---|---|
| `BOARD=odroidn2` | 官方 Armbian 没有 X96 Max 板型；商家镜像的 `/etc/armbian.txt` 也是 Odroidn2，身份必须一致 |
| `ARTIFACT_IGNORE_CACHE=yes` | **不加就从 ghcr.io 拉预编译 rootfs**，等于白做「源码构建」 |
| `RELEASE=trixie` + `BUILD_MINIMAL=yes` | 目标就是最小 trixie；不带桌面、不在构建期配内核 |

- 实测耗时约 **6:52**（x86 上 mmdebstrap + qemu 构建 arm64 rootfs）。
- 产物：`cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst`（约 108M，253 包）。
- 收尾阶段 armbian 会对**所有挂载点**跑 `df`；任何一个挂载点返回 I/O error，整步就报 `ERROR` —— 见 §7.3 第 19 条。

### 5.6 注入基础镜像并 rebuild

`rebuild` 要一个 `.img` 当骨架。做法：把源码 rootfs 换进官方通用镜像的 rootfs 分区，保留它原有的 `/boot`（`rebuild` 之后会自己换成我们的内核）。

```bash
ROOT=/data/x96-build
BASE=$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
R=$(ls $ROOT/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst | tail -1)

LOOP=$(sudo losetup -Pf --show "$BASE")
sudo mkdir -p /mnt/base-root
sudo mount "${LOOP}p2" /mnt/base-root

# 1) 备份基础镜像的 /boot，再清空 rootfs
sudo rsync -a /mnt/base-root/boot/ "$ROOT/base-boot-backup/"
sudo find /mnt/base-root -mindepth 1 -maxdepth 1 -exec rm -rf {} +
zstd -dc "$R" | sudo tar -xpf - --numeric-owner --xattrs --xattrs-include='*' -C /mnt/base-root
sudo rsync -a "$ROOT/base-boot-backup/" /mnt/base-root/boot/

# 2) 源码 rootfs 是空目录结构，rebuild 缺这两个目录会报错
sudo mkdir -p /mnt/base-root/usr/lib/modules /mnt/base-root/usr/src

# 3) SSH 与网络
sudo mkdir -p /mnt/base-root/root/.ssh
sudo cp ~/.ssh/id_ed25519.pub /mnt/base-root/root/.ssh/authorized_keys
# 另需：root 密码（可留空锁定）、sshd_config、/etc/systemd/network/20-eth.network
sudo umount /mnt/base-root
sudo losetup -d "$LOOP"
```

> 不想依赖 26.11.0 官方镜像时，可用 `x96max/mkbase.sh` 自造骨架：它把同一份源码 rootfs 直接灌进一个
> 至少 2560MiB 的 ext4 镜像，`parted` 建 msdos 分区表（4MiB 起始），产物 `base-own.img` 只满足
> `extract_armbian()` 取挂载点 + `/etc/os-release` 的需要——`make_image()` 本来就会重造整个分区表。
> 前提是 `/data/x96-build/base-boot-backup` 已存在（即上面第 1 步）。

打包：

```bash
cd /data/x96-build/amlogic-s9xxx-armbian
sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96src
```

| 参数 | 含义 |
|---|---|
| `-b s905x2` | 板型代号（`model_database.conf` 第 301 行 X96-Max-4GB） |
| `-k 7.2.12` | 用本地 `build-armbian/kernel/stable/7.2.12/` 那四个包 |
| `-s 512/2560` | BOOTFS 512MiB / ROOTFS 2560MiB |
| `-n x96src` | 构建者签名（进镜像文件名） |

产物：

```text
build/output/images/Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz  (375M)
```

> 也可以 `./x96max/build-image.sh` 一条命令跑完 5.5–5.7（见 §6）。
> 或者跳过源码 rootfs、直接用 ophub 基础镜像 rebuild（这就是「中间验证版」，见附录 A）。

### 5.7 体积裁剪到 155 包

在镜像里 chroot 裁，或在系统起来后裁（两者等价，最终都落在 §5.7.3 的结果上）。

**5.7.1 卸载 96 个包**（253 → 155，不碰 `openssh-server` / `systemd` / `apt` / `initramfs-tools`）：

```bash
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y \
    iw wpasupplicant wireless-regdb \
    console-setup console-setup-linux kbd keyboard-configuration xkb-data \
    man-db groff-base debsums figlet toilet toilet-fonts \
    htop jq lsof dialog bc bash-completion nano less \
    btrfs-progs mtd-utils mmc-utils gpiod pahole usbutils wireguard-tools \
    parted fdisk dosfstools dmsetup apt-utils debconf-utils \
    cron cron-daemon-common rsyslog logrotate fake-hwclock \
    alsa-utils curl wget rsync \
    sudo u-boot-tools perl perl-modules-5.40 locales
  apt-get autoremove --purge -y
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/*
'
```

分组看（同一条命令，只是注释了用途）：

```text
# 无线          iw wpasupplicant wireless-regdb
# 本地控制台    console-setup console-setup-linux kbd keyboard-configuration xkb-data
# 文档/交互     man-db groff-base debsums figlet toilet toilet-fonts
#               htop jq lsof dialog bc bash-completion nano less
# 存储/硬件     btrfs-progs mtd-utils mmc-utils gpiod pahole usbutils wireguard-tools
#               parted fdisk dosfstools dmsetup apt-utils debconf-utils
# 服务          cron cron-daemon-common rsyslog logrotate fake-hwclock
# 音频/网络     alsa-utils curl wget rsync
# 其他          sudo u-boot-tools perl perl-modules-5.40 locales
```

**5.7.2 清文件与固件**（只留有线/显示/音频需要的）：

```bash
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
       /usr/share/locale/* /usr/share/fonts/* /usr/share/i18n/*
rm -rf /usr/src/linux-headers-*
rm -f  /usr/lib/modules/7.2.12-x96/build
cd /lib/firmware
for d in *; do [ -d "$d" ] || continue; case "$d" in rtl_nic|amlogic|meson) ;; *) rm -rf "$d" ;; esac; done
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/log/*
apt-get clean
```

> `/lib/firmware` 只留 `rtl_nic`（RTL8211F 可能用）、`amlogic`、`meson`；`rtw88`/`rtl_bt`/`brcm` 全部删掉。

**5.7.3 网络与 SSH**（源码 rootfs 默认没有这些配置）：

```bash
echo x96src > /etc/hostname
cat > /etc/systemd/network/20-eth.network <<'EOF'
[Match]
Name=eth0
[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd systemd-resolved ssh
systemctl disable NetworkManager 2>/dev/null || true
mkdir -p /root/.ssh   # 公钥写入 authorized_keys
```

**5.7.4 结果**（重启后实测）`[verified]`：

```text
包数      155
rootfs    568M used
firmware  9.4M
/usr/share 14M
内核      7.2.12-x96
网络      eth0 1Gbps
固件缺失  无
failed units 无
```

**5.7.5 apt 源换清华 IPv4**（原 `deb.debian.org` 的 IPv6 在这条线路上超时）：

```text
# /etc/apt/sources.list.d/debian.sources
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian-security

# /etc/apt/apt.conf.d/99force-ipv4
Acquire::ForceIPv4 "true";
```

**5.7.6 随时装回来**：

```bash
apt-get install -y nano less curl wget rsync sudo alsa-utils
apt-get install -y sudo u-boot-tools parted btrfs-progs   # 以后要 armbian-install / 内核更新
```

### 5.8 写盘与首启

```bash
lsblk -o NAME,SIZE,MODEL,TRAN          # 先确认 U 盘/SD 设备，不要选错
gzip -dc /data/x96-build/recovery/x96src-autoinstall.img.gz | \
  sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

> 或 `./x96max/build-image.sh --skip-rootfs --write /dev/sdX`（会再确认一次设备名）。
> `dd` 覆盖整个介质，务必确认 `/dev/sdX` 是 U 盘而不是系统盘。

启动：

- X96 Max 的 U-Boot 通常 **USB 启动优先于 eMMC**：插盘上电即可。
- 若仍进 eMMC：通过 SSH 把 eMMC 的 `/boot/boot.scr` 改名（`mv /boot/boot.scr /boot/boot.scr.bak`）再重启，或看串口/HDMI 上的 U-Boot 输出手动 `usb start; usb storage`。

首启确认：

```bash
hostname          # x96src
uname -r          # 7.2.12-x96
findmnt -no SOURCE /
```

### 5.9 安装到 eMMC

**本机只有一条路能成功：主线 U-Boot**。手工 rsync、只替换 p1/p2、`armbian-install` 默认参数都会黑屏（见 §7）。

```bash
armbian-install -m yes -a no
# 设备选择 301（X96-Max-4GB,Tx5-Max）
# 文件系统选择 1（ext4）
```

| 参数 | 含义 |
|---|---|
| `-m yes` | 写主线 U-Boot `x96max-u-boot.bin.sd.bin` |
| `-a no` | 禁用 ampart，用主线 U-Boot 的固定布局 |

装完关机 → 拔 SD/U 盘 → 上电，从 eMMC 启动。

eMMC 布局 `[verified]`：p1 68MiB 起 511M，p2 1350MiB 起 56.9G（见 §2.3）。

### 5.10 安装后验证

```bash
hostname                        # x96src
uname -r                        # 7.2.12-x96
findmnt -no SOURCE /            # /dev/mmcblk1p2
dpkg -l | grep -c '^ii'         # 基础 155；装运行依赖后 177
ip -br a                        # eth0 1Gbps + DHCP
aplay -l
arecord -l
v4l2-ctl --list-devices
lsmod                           # 不应有 rtw88 / bt
dmesg | grep -iE "meson8b-dwmac|RTL8211F|panfrost|meson-drm|snd|mmc"
```

预期：`eth0` 有 IPv4 且 RTL8211F 链路 1Gbps；无 `rtw88`/`bt` 模块；Panfrost、meson-drm、AXG 音频、`meson_vdec` 全部正常；无 failed unit。

---

## 6. 一键脚本与首启自动安装

仓库 `x96max/` 里六件东西：

| 文件 | 作用 |
|---|---|
| `build-image.sh` | 跑完 §5.5–§5.7：源码 rootfs → 注入 → rebuild → 裁剪 → gzip（可选直接写盘） |
| `config-x96-source.conf` | 被脚本安装进构建环境的内核/rootfs 配置 |
| `mkbase.sh` | 可选：自造基础镜像容器（源码 rootfs → ext4 → `base-own.img`），只在不想下载 26.11.0 官方镜像时走这条路，见 §5.6 注 |
| `x96-autoinstall.sh` + `.service` | 镜像内首启自动执行 `armbian-install -m yes -a no`，含依赖自检与 done 标记防误判 |
| `kernel/config-7.2.12-x96` | 最终内核配置，§5.2 直接复制 |

```bash
cd /home/quqiufeng/kernel

./x96max/build-image.sh                            # 完整：源码 rootfs + 注入 + rebuild + 裁剪 + gzip
./x96max/build-image.sh --skip-rootfs              # 复用已有 rootfs，只重打包
./x96max/build-image.sh --skip-rootfs --write /dev/sdX   # 顺便写盘（危险，确认设备名）
```

环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/data/x96-build` | 工作目录 |
| `X96_BASE_IMAGE` | `/data/x96-build/.../Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` | 基础镜像 |
| `X96_ROOT_PASSWORD` | 空 | 默认锁定 root 密码、仅 SSH key；要控制台密码登录才显式设置 |
| `X96_ROOT_SSH_KEY` | `~/.ssh/id_ed25519.pub` | 写进镜像的 root 公钥 |

**用普通用户跑**（不要 `sudo ./build-image.sh`，`$HOME` 会变成 `/root` 而丢掉 `~/.ssh/id_ed25519.pub`；
确实要从 root shell 起，就显式给 `X96_ROOT_SSH_KEY`）。脚本会先检查：sudo、基础镜像、四个内核包、
auto-install 文件、rootfs 产物。它**不检查**遗留挂载，构建前自己按 §5.1 清场。输出：

```text
/data/x96-build/recovery/x96src-autoinstall.img.gz
```

**首启自动安装**：镜像内 `x96-autoinstall.service` 在第一次开机自动跑

```bash
armbian-install -m yes -a no      # 301 / ext4
cat /var/log/x96-autoinstall.log  # 看结果
systemctl status x96-autoinstall
```

装完服务会 `poweroff`；拔盘上电即从 eMMC 启动。没触发就手工执行同一条命令。

`x96-autoinstall.sh` 里两个真机踩出来的坑，别当成可优化项：

- **依赖必须自检，不能交给 apt**：`armbian-install` 的 `check_depends` 会 `which` 9 个命令，缺一个就
  `apt-get update/install`；apt 会读走 stdin，后面的 `read boxid` 拿到 EOF → `Input error, exit!` 或
  `DTB file not found`。所以脚本先自检，缺就报错退出（该 service 在 local-fs.target 之后跑，那时也没网）。
- **`done` 标记只能在安装真正成功后写**：旧版无条件 `touch done`，装失败也标「已完成」然后关机，
  下次开机直接 skip —— 静默装死。

---

## 7. 踩坑与铁律

### 7.1 eMMC / U-Boot（黑屏全是这一类）

1. **不要用 U 盘镜像的 p1 覆盖 eMMC p1**：会把 `aml_autoscript` / `u-boot.emmc` 带进去，eMMC 黑屏。
2. **不要手工 rsync p1/p2**：UUID、fstab 都对也会黑屏——启动脚本不对。
3. **`armbian-install` 默认 `-a yes` 不够**：本机必须 `-m yes -a no`（主线 U-Boot + 禁用 ampart）。
4. **`u-boot.emmc` 是 6.x+ 内核的「重载 U-Boot」**：原厂 U-Boot + 它会黑屏；主线 U-Boot 流程才能接管。
5. **先 SD/U 盘验证，再动 eMMC**：SD 是救援盘，失败随时插回修。
6. **eMMC 前 117MiB 保留区不要手写**。
7. **Amlogic Maskrom 的 `update` 工具在本机控制传输不稳定**：T95/Allwinner FEL 的经验套不过来；能 SD 启动就别折腾 Maskrom。

### 7.2 编译与打包

8. **DTB 目标写 `amlogic/meson-g12a-x96-max.dtb`**；写 `arch/arm64/boot/dts/amlogic/...` 会被 Makefile 二次拼接，报目标不存在。
9. **不要 `make dtbs`**：会构建所有 ARM64 板型，白等。
10. **树内有编译产物时 out-of-tree 会失败** → 先 `make ARCH=arm64 mrproper`（会删 `.config`）。
11. **长编译必须 `setsid`/`nohup` 脱离 shell**，否则终端超时会杀掉整个进程组；**不要 `pkill -f kbuild-7.2.12`**（会匹配到自己），用 `kill -- -PGID`。
12. **x86 上不能直接 `update-initramfs`**：`uInitrd` 必须 arm64，走 §5.3 的 qemu chroot。
13. **`rebuild` 要四个包齐全**：`boot-*`、`dtb-amlogic-*`、`modules-*`、`header-*`，缺一个报 `The 4 kernel missing.`。

### 7.3 源码 rootfs

14. **`ARTIFACT_IGNORE_CACHE=yes` 必须加**，否则拿到的是 ghcr.io 的 OCI 预编译 rootfs。
15. **`rebuild` 要求 rootfs 里有 `/usr/lib/modules` 和 `/usr/src`**；源码 rootfs 没有，要手动 `mkdir -p`，否则报 `tar: .../usr/lib/modules: No such file`。
16. **源码 rootfs 的 `/boot` 是空的**：注入前先备份基础镜像的 `/boot`、注入后还原，再由 `rebuild` 替换内核。
17. **时间戳超前**导致 `tar` 刷 `time stamp ... is in the future`，无害。
18. **`rm: ... Device or resource busy`** 是上一次失败 `rebuild` 的残留 loop 挂载：清 `build/tmp_dir` 的挂载即可，不影响产物。
19. **`df: /mnt/xxx: Input/output error` 会让 rootfs 步骤假失败**：armbian 收尾会对全挂载点跑 `df`，
    一个坏挂载点（拔掉的 U 盘、上次的 loop、`errors=remount-ro` 的 vfat）返回非 0 → 子 shell 判失败 →
    日志里整个 rootfs 步骤 `ERROR`，但**包其实已经装完**，日志指向 `rootfs-create.sh` 完全没提 `df`。
    判据：`df -h >/dev/null; echo $?` 不是 0 就先找挂载点，`sudo umount -l <点>` 后直接重跑（rootfs 缓存会命中，约 7 分钟）。
20. **必须普通用户跑脚本**：`sudo ./build-image.sh` 让 `$HOME=/root`，默认 key 路径变 `/root/.ssh/id_ed25519.pub`
    → `missing root SSH public key`。要 root shell 就传 `X96_ROOT_SSH_KEY=/home/<user>/.ssh/id_ed25519.pub`。

### 7.4 通用

21. **备份先行**：写主线 U-Boot 前，原厂启动区 117MiB + p1 + p2 必须在 NAS 上有备份（§8）。
22. **凭据只放 `~/.env`**，不写进仓库、不拼进命令行。

---

## 8. 风险、备份与回滚

**最低要求**：一个能启动的 U 盘/SD + eMMC 原厂备份，两者缺一不要往下走。

备份位置：

```text
dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/
本地暂存  ~/x96-backup/emmc-original-backup/
```

内容：原厂启动区（117MiB）、p1、p2；同目录另有 `x96src-autoinstall.img.gz`、`x96src-fixed.img.gz`、`x96src-small.img.gz`、`SHA256SUMS`。

失败恢复：

| 症状 | 处理 |
|---|---|
| 还能 USB 启动 | 重写 U 盘镜像，回 §5.8 |
| 不能 USB 启动（黑屏） | 从 SD 启动 → 写回备份的启动区/p1/p2；或 Amlogic USB Burning Tool + 备份镜像救砖（需 USB 双公头线） |
| 想回原厂系统 | 从 SD 启动，写回原厂启动区 + p1 + p2，或走原厂线刷流程 |

红线：

- 写主线 U-Boot 会覆盖 eMMC 启动区，**必须先备份**。
- 只替换 p1/p2 不写主线 U-Boot = 黑屏，别试。
- 产品镜像默认不设 root 密码（脚本留空即锁定），只保留 SSH key；确需控制台密码再 `X96_ROOT_PASSWORD='强密码'`。
- 固定基础镜像与内核源码版本/校验和；API key 按设备下发或走后端代理，不共用同一把。

---

## 9. 进度

| 步骤 | 状态 |
|---|---|
| 硬件/系统/驱动分析 | 完成 |
| ophub 构建环境 | 完成 |
| 基础镜像 + 6.18.59 重打包（未裁剪，验证流程用） | 完成 |
| 7.2.12 源码与配置（有线-only，关 Wi-Fi/BT） | 完成 |
| `Image` / `modules` / DTB 编译 | 完成 |
| initrd / uInitrd（arm64 chroot） | 完成 |
| 内核 4 个 tar 包 | 完成 |
| `rebuild` 镜像 | 完成 |
| rootfs 裁剪第一版（484 → 312 包） | 完成 |
| 源码 rootfs（Armbian build + mmdebstrap，253 包，6:52） | 完成 |
| 源码 rootfs 注入 + `rebuild`（7.2.12-x96） | 完成 |
| SD/U 盘启动验证（`x96src`） | 完成 |
| eMMC 安装（主线 U-Boot，`-m yes -a no`） | 完成 |
| eMMC 启动验证（`/dev/mmcblk1p2`，7.2.12-x96） | 完成 `[verified]` |
| 裁剪到 155 包 | 完成 `[verified]` |

---

## 附录 A：旧路径——在 ophub 预装镜像上裁剪

**已废弃**，只作历史参照：最终方案是 §5.5 源码 rootfs + §5.7 裁剪，不依赖这一节。保留它是因为「拿到一个 484 包的预装镜像，想快速瘦身」时仍然可用。

保留（最小可用集）：

```text
systemd / udev / systemd-networkd / systemd-resolved
openssh-server
iproute2 / iputils-ping / ethtool
ca-certificates / curl / wget / rsync
e2fsprogs / dosfstools / kmod / procps / util-linux
bash / coreutils / findutils / grep / sed / gawk
tzdata / locales（可选）
initramfs-tools
```

移除（示例，第一版 484 → 312）：

```text
build-essential gcc g++ cpp make autoconf automake libtool
bison flex binutils dkms device-tree-compiler
git git-man patch libc6-dev linux-libc-dev
python3-dev libpython3-dev
armbian-config armbian-zsh zsh aptitude apt-file debsums
plymouth armbian-plymouth-theme fonts-* fontconfig
vim man-db manpages groff-base info html2text
bluez wpasupplicant wireless-regdb iw rfkill
f2fs-tools btrfs-progs nfs-kernel-server rpcbind avahi-*
htop iotop iozone3 iperf3 fping expect dialog whiptail figlet bc
```

chroot 执行：

```bash
IMG=/data/x96-build/amlogic-s9xxx-armbian/build/output/images/<final>.img
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

sudo umount /mnt/x96root/{dev,proc,sys}
sudo umount /mnt/x96root
sudo losetup -d "$LOOP"
gzip -9 -k -f "$IMG"
```

---

## 附录 B：文档一致性待确认项

原文档在四处自相矛盾。**没有猜**，按下表标记；动手前请用盒子上的实际值确认。

| # | 矛盾 | 本文采取 | 怎么确认 |
|---|---|---|---|
| B1 | eMMC 设备名：§1 写 `mmcblk2`，1.4 的 §11/§16.5 写 `mmcblk1`（2.0 已在 §2.3 两套布局并列） | 硬件表保留 `mmcblk2`（原厂布局），当前布局保留 `mmcblk1`（那次安装的记录） | `findmnt -no SOURCE /`、`lsblk` |
| B2 | 包数：155 / 177 / 253 / 312 / 484 并存 | 明确分支：原厂 484 → 第一版裁到 312 → 源码 rootfs 253 → 裁到 **155** → 装运行依赖 177 | `dpkg -l \| grep -c '^ii'` |
| B3 | 发行版版本：Armbian **26.8.3** 与 **26.11.0** 都出现在「当前系统」语境 | 原厂=26.11.0（ophub 重打包产物），源码构建=26.8.3；两者不是同一套 | `cat /etc/armbian-release` |
| B4 | 原文档 §2.1 标题是「当前系统」，内容其实是**原厂 ophub 系统**（bookworm + 6.12.112-ophub） | 拆成 §2.1 的三阶段对照表 | `uname -r`、`cat /etc/os-release` |

---

## 附录 C：速查

```text
当前设备      x96src / 192.168.1.121（DHCP，会变）
原厂设备      root@192.168.1.120（ssh config 的 Host x96）
当前系统      7.2.12-x96 + 源码 rootfs + 主线 U-Boot，155 包，rootfs 568M
NAS 备份      dav://192.168.1.53:5005/sata11-18072858035/x96-backup/
              http://192.168.1.53:5005/sata11-18072858035/x96-backup/
本地备份      ~/x96-backup/
构建全程      §5（5.1 准备 → 5.10 验证）
构建假失败    rootfs 步骤 ERROR 但包已装完 → 查遗留挂载，`sudo umount -l` 后重跑（§7.3 第 19 条）
出错先看      §7；黑屏看 §7.1，备份回滚看 §8
```

---

*文档版本: 2.1 · 重写: 2026-11-14 · 2.1 补构建前清场与 `df` EIO 假失败（§5.1/§7.3-19、20） · 上一版: 1.4（`git show HEAD:x96max/X96max.md`） · 设备: X96 Max / S905X2*
