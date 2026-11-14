# X96 Max（S905X2）刷机 — 从 0 开始 TODO

> 生成：2026-11-14 22:36
> 依据：`/opt/my-agent` 提交 `42b273c` 的 `X96max.md` §4–§16 + `scripts/x96/build-image.sh`
> 目标：在构建机上**从零**产出 `x96src-autoinstall.img.gz`，写 U 盘，首启自动装进 eMMC

**当前状态**：成品镜像与中间产物已于 2026-11-14 22:34 删除
（`rootfs-arm64-trixie-minimal_*.tar.zst`、`Armbian_26.11.0_amlogic_s905x2_*.img.gz`、
`recovery/x96src-autoinstall.img.gz`），所以是真正的从 0。
**回滚资产仍在**：`recovery/bootarea-117MiB.img`、`u-boot-x96max.bin`、
`env-0x46f0000/0x47a0000/0x7400000.bin`、`x96-boot.scr`。

---

## 0. 前置核对（缺一个就整个卡住）

- [ ] 构建机 x86_64 Ubuntu 24.04，6 核 / 23GiB，`/data` 余量 ≥15G
- [ ] `sudo -n true` 通过（`build-image.sh` 内部全用 `sudo -n`，不免密直接退）
- [ ] 装依赖
      `cd /data/x96-build/amlogic-s9xxx-armbian && sudo apt-get install -y $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)`
      另需 `aarch64-linux-gnu-gcc`(13.3.0)、`qemu-aarch64-static` + binfmt、`zstd`、`rsync`
- [ ] 五个源资产在位
      - [ ] `/data/x96-build/armbian-build/compile.sh` 可执行
      - [ ] `/data/x96-build/amlogic-s9xxx-armbian/rebuild` 可执行
      - [ ] `/opt/linux/src/linux-7.2.12` 源码树存在
      - [ ] `.../build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img`（2.5G 通用基线）
      - [ ] `~/.ssh/id_ed25519.pub`
- [ ] 脚本取回（`/opt/my-agent` 工作区当前已删）
      `cd /opt/my-agent && git checkout 42b273c -- scripts/x96/`
- [ ] 硬件：**U 盘 ≥8G**（raw 约 2.5G，写完整盘被覆盖）+ 网线（镜像有线 only）+ HDMI
- [ ] 救砖备件（只在要写主线 U-Boot 时才用）：**A-A 双公头 USB 线** + `/data/x96-build/aml-flash-tool/`

---

## A 段 — 内核四件套（手动，不在 build-image.sh 里，小时级）

> `build-image.sh` 开头检查这四件套，缺了直接 `The 4 kernel missing.` 退出。
> 这是「从 0」唯一还得照文档手敲的部分。

### A1 编内核

- [ ] `cd /opt/linux/src/linux-7.2.12 && make ARCH=arm64 mrproper`（树内产物会让 out-of-tree 构建报错）
- [ ] `export OUT=/data/x96-build/kbuild-7.2.12`，`mkdir -p "$OUT"`
- [ ] `cp scripts/x96/kernel/config-7.2.12-x96 "$OUT/.config"` + `make O="$OUT" ARCH=arm64 olddefconfig`
- [ ] 后台编：`setsid nohup make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j5 Image modules &`
- [ ] 只编这块板：`make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- amlogic/meson-g12a-x96-max.dtb`
      坑：目标写 `amlogic/xxx.dtb`，加 `arch/arm64/boot/dts/` 前缀会被 Makefile 再拼一次 → 报目标不存在
- [ ] `make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$OUT/modules" modules_install`

**产物**
```
$OUT/arch/arm64/boot/Image
$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb
$OUT/modules/lib/modules/7.2.12-x96/
```

> 停编译用进程组 `kill -- -PGID`。**别用 `pkill -f kbuild-7.2.12`**，会匹配到当前 shell 自身。

### A2 生成 arm64 initrd / uInitrd

- [ ] x86 上不能直接 `update-initramfs`。挂基础镜像 p2 → 塞入新 `Image` + `modules` →
      `qemu-aarch64-static` chroot → `mkinitramfs` → `mkimage -A arm64` 转 uInitrd
- [ ] 验收：`file uInitrd` 必须是 `u-boot legacy uImage, ARM64`

### A3 打成 ophub 四件套

- [ ] 落盘到 `/data/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/`
      - [ ] `boot-7.2.12-x96.tar.gz`（Image + uInitrd）
      - [ ] `dtb-amlogic-7.2.12-x96.tar.gz`（meson-g12a-x96-max.dtb）
      - [ ] `modules-7.2.12-x96.tar.gz`（lib/modules/7.2.12-x96）
      - [ ] `header-7.2.12-x96.tar.gz`（scripts、include/generated、.config…，按 ophub `collect_headers` 规则）
      - [ ] `sha256sums` 更新
- [ ] 四个都在 → 这一段才算完

---

## B 段 — rootfs + 注入 + rebuild + 瘦身（一条命令，~15 分钟）

- [ ] 清残留（若之前跑过）：`armbian-build/cache/rootfs/*.tar.zst`、`build/output/images/*s905x2*.img.gz`
- [ ] 跑：
```bash
cd /opt/my-agent
X96_ROOT_SSH_KEY=/home/quqiufeng/.ssh/id_ed25519.pub bash scripts/x96/build-image.sh
```
- [ ] 日志另存，确认六个内部步骤全绿：
      - [ ] `compile.sh x96-source rootfs`（`BOARD=odroidn2`，`ARTIFACT_IGNORE_CACHE=yes` **必须**，否则拉 ghcr.io 预编译包）
      - [ ] 换 rootfs：`losetup -Pf` 挂 base p1 → 备份 `/boot` 到 `base-boot-backup` → 清空 p1 → 解 `tar.zst` → 还原 boot → `mkdir /usr/lib/modules /usr/src`（不加则 rebuild 报 No such file）
      - [ ] 预置系统：root 公钥 / `PermitRootLogin yes` / `20-eth.network`(eth0 DHCP) / 启用 networkd+resolved+ssh / 屏蔽 `armbian-firstrun*` / hostname `x96src` / tuna Debian 源 + `Acquire::ForceIPv4`
      - [ ] 注入 `x96-autoinstall.sh` + `.service` + `multi-user.target.wants` 软链
      - [ ] `sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96src`
      - [ ] 瘦身：删 doc/man/locale/fonts/groff、`linux-headers-*`、`modules/*/build|source`、`/lib/firmware` 只留 `rtl_nic|amlogic|meson`、清 apt 缓存、禁用 armbian 源、**删 `/etc/x96-autoinstall.done`**
- [ ] 产出：`/data/x96-build/recovery/x96src-autoinstall.img.gz`（约 300M）

### B 段坑（已踩）

1. **别用 `sudo` 跑 `build-image.sh`** —— `$HOME` 变 `/root`，报
   `missing root SSH public key: /root/.ssh/id_ed25519.pub`。脚本内部自己调 `sudo -n`。
2. 环境变量名是 **`X96_ROOT_SSH_KEY`**（默认 `~/.ssh/id_ed25519.pub`）；`X96_BUILD_ROOT` 改工作目录（默认 `/data/x96-build`）。
3. `--skip-rootfs` 复用最新 rootfs 只重打镜像；`--write /dev/sdX` 打完直接 dd。

---

## C 段 — 写盘 + 上机（人工两下）

- [ ] `lsblk -o NAME,SIZE,TRAN,MODEL` 确认 U 盘设备名，**别碰 sda（931.5G ZHITAI 系统盘）**
- [ ] 写盘
```bash
gzip -dc /data/x96-build/recovery/x96src-autoinstall.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync && sync
```
- [ ] 插 U 盘上电（X96 Max 的 U-Boot **USB 启动优先于 eMMC**）
- [ ] 不进 U 盘就 SSH 进 eMMC 系统 `mv /boot/boot.scr /boot/boot.scr.bak` 再重启
- [ ] 首启自动 `printf '301\n1\n' | armbian-install -m yes -a no`（301 = X96-Max-4GB，1 = ext4），
      日志 `/var/log/x96-autoinstall.log`，完了自己 `poweroff`
- [ ] 拔 U 盘，从 eMMC 启动
- [ ] 验收（`X96max.md` §10.3）：`ip a` 有 eth0 地址、`ssh root@<ip>` 通、`uname -r` = `7.2.12-x96`、
      `ethtool eth0` Link detected yes、`aplay -l` 有卡、`lsblk` 见 p1 511M FAT32 + p2 ext4
- [ ] 分区布局对得上：p1 从 68MiB 起 511M FAT32，p2 从 1350MiB 起 ~56.9G ext4

---

## D 段 — 回滚（写主线 U-Boot 前必须确认）

- [ ] `recovery/bootarea-117MiB.img` 完好（原厂 boot0/boot1）
- [ ] NAS 副本还在：`dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`
- [ ] 彻底救砖：A-A 双公头线接盒子 → `dmesg` 见 `1b8e:c003` 且出现 `/dev/worldcup` →
      `./flash-tool.sh --img=aml_upgrade_package.img --parts=all --wipe --soc=g12a`
      注意 `aml-flash-tool/tools/_install_/` 的 update 二进制还没装

> **不要再走的路**：原厂 U-Boot，或手工 rsync 只换 p1/p2 → eMMC 黑屏。
> `armbian-install -m yes` 写主线 U-Boot `x96max-u-boot.bin.sd.bin` 是唯一不黑的写法。

---

## 可选：把 A 段也脚本化

- [ ] 抽 `scripts/x96/build-kernel.sh`：mrproper → 复制 config → Image/modules/dtb → initrd/uInitrd →
      打四件套 → sha256，把现在手敲的 A1–A3 收成一条命令
