# 最小可用内核：裁剪 → 编译 → 安装 完整流程

本文是**可照着敲**的操作手册。读完只需记住一句：**裁到"够本机跑"，不是"够启动"**。
`docs/trim.md` 讲方法与账本（为什么这么裁、每轮砍了什么、踩了哪些坑），本文讲**动作顺序**。

当前唯一通过真机验证的产物：

| 项 | 值 |
|---|---|
| 版本串 | `7.2.12-20261111-hwreal` |
| 内核源码 | Linux 7.2.12（`src/linux-7.2.12/`） |
| config | `configs/config-7.2.12-20261111-hwreal`（**就是装机那一份，逐字节复制**） |
| `=y` / `=m` | 2243 / 924（CONFIG_ 行 3310） |
| vmlinuz | 12.1 M |
| 模块目录 | 165 M / 918 个 `.ko` |
| initrd | 271 M（含 nvidia 5 个模块） |
| 构建耗时 | 7m53s（6 核，全新构建）；二次改动增量 274 s；三次改动增量约 3 min |
| 状态 | 已装、已设为 GRUB 默认、**正在跑**，`#29` 重启验证全绿 |

> 上表是**三次改动之后**（即当前正在跑的这个内核）的实测数字。
>
> - 2026-11-11 09:00 **二次改动**：补回被误裁的 `SQUASHFS`/`VFAT_FS`/`FAT_FS`/`FUSE_FS`/`IPV6`，详见 §4.5。
> - 2026-11-11 10:48 **三次改动**（`#29`）：`GPIO_IT87`/`GPIO_WINBOND`/`INPUT_IDEAPAD_SLIDEBAR`
>   由 `=y` 改 `=m` 消掉三行开机探测噪音，并补回整条 netfilter 链（238 个 CONFIG 行），详见 §4.7。
>   版本串不变，同名覆盖安装；这也是 `=m` 从 645 涨到 924、`.ko` 从 659 涨到 918 的原因。

---

## 0. 三条不可违背的前提

这三条是 2026-11-11 事故换来的，写在最前面，因为它比后面所有步骤都重要。

1. **驱动架构不参与裁剪。** 只裁"没有对应硬件"的驱动，不裁"驱动所依赖的子系统"。
   砍 `BLK_DEV_SD` / `MD` / `DRM` 这类东西，等于砍掉整条链路。
2. **QEMU PASS ≠ 上机 PASS。** QEMU 用 virtio-blk，根盘直接是 `/dev/vda`；
   真机是 `AHCI → SCSI → sd → dm → LVM → ext4`，少任何一环都 panic。
   每轮裁剪后必须过一遍 §1 的真实硬件清单。
3. **`MD` 是 `DM` 的闸门。** `BLK_DEV_DM` 在 menuconfig 里嵌在 MD 之内，
   `CONFIG_MD=n` 会把整块 DM 从菜单里隐藏，你单独写 `CONFIG_BLK_DEV_DM=y`
   会被 `make olddefconfig` **静默丢弃**（没有警告）。LVM 根盘直接没了。

---

## 1. 本机硬件清单（裁剪的唯一依据）

`lspci` 实测（2026-11-11）：

| 类别 | 硬件 | 对应驱动 |
|---|---|---|
| 存储 | AMD FCH SATA (AHCI) ×3 | `SATA_AHCI` `SATA_AHCI_PLATFORM` `ATA` `SCSI` `BLK_DEV_SD` |
| 根盘 | sda3 → LVM → ext4 | `MD` `BLK_DEV_DM` `DM_BUFIO` `DM_CRYPT` `EXT4_FS` |
| 显卡 | NVIDIA GA102 | `DRM` `DRM_KMS_HELPER` + nvidia DKMS（树外） |
| 显示 | EFI framebuffer | `FB` `FB_EFI` `SYSFB_SIMPLEFB` `FRAMEBUFFER_CONSOLE` `DRM_FBDEV_EMULATION` |
| USB | AMD 400 Series xHCI | `USB_XHCI_HCD` `USB_HID` `HID_GENERIC` `USB_STORAGE` `INPUT_EVDEV` |
| 网络 | RTL8111 (R8169) rev15 | `R8169` + `rtl8168h-2.fw` |
| 固件 | UEFI | `EFI` `EFI_STUB` `EFIVAR_FS` |
| 加密 | LUKS/dm-crypt | `CRYPTO` `CRYPTO_CBC` `CRYPTO_XTS` `CRYPTO_SHA256` |
| 必需 | — | `MODULES`（DKMS 前提）`BLK_DEV_INITRD` `RD_GZIP` `TMPFS` `DEVTMPFS` |

**这份清单里的每一项都必须 `=y` 或 `=m`。** 任何一项由 y/m 变 n，本轮判 FAIL，不许进安装。

校验命令：

```bash
grep -E '^CONFIG_(ATA|SATA_AHCI|SCSI|BLK_DEV_SD|MD|BLK_DEV_DM|DM_CRYPT|EXT4_FS|DRM|FB_EFI|USB_XHCI_HCD|R8169|EFI_STUB|MODULES)=' .config
```

---

## 2. 三个 config 文件的分工

仓库里 `configs/` 不是堆垃圾，每个文件有明确角色：

| 文件 | 角色 | 用途 |
|---|---|---|
| `config-baseline-2026-11-11` | **基线**：发行版原版，184 K | 裁剪起点，也是回退终点 |
| `trim-conservative.fragment` / `trim-fast.fragment` | **fragment**：只写要改的开关 | 配合 `scripts/config` 应用，可审计 |
| `config-7.2.12-20261111-hwreal` | **当前装机版**（round6 + `LOCALVERSION` + `SOUND/SND` 全开），与 `.config` md5 一致 | 编译此文件即得在跑的内核 |

> **改 config 的正确姿势**：不要把 `.config` 当源码手改。写 fragment →
> `scripts/config --file .config -e XXX -d YYY` → `make olddefconfig` →
> 立刻 `cp .config configs/config-<version>`（覆盖同名，不建 `current` 之类的别名）。
> `.config` 是产物，`configs/` 里的快照才是资产；一个内核版本只留一份。

---

## 3. 编译

```bash
cd ~/kernel/src/linux-7.2.12

# 3.1 铺入目标 config
cp ~/kernel/configs/config-7.2.12-20261111-hwreal .config

# 3.2 让 Kconfig 补全依赖（关键：这一步会静默丢弃非法的 =y/=m）
make olddefconfig

# 3.3 装机前必查：硬件清单没被丢弃
grep -E '^CONFIG_(MD|BLK_DEV_DM|SATA_AHCI|BLK_DEV_SD|DRM|USB_XHCI_HCD|R8169|MODULES)=' .config

# 3.4 真·全新构建（本树 make clean 不删 .o，必须清场，否则测的是增量时间）
~/kernel/tools/trim/clean-build.sh ~/kernel/configs/config-7.2.12-20261111-hwreal 6
```

`clean-build.sh` 做三件事：`find -name '*.o' -delete` 真清场 → `make -j6` → 打印 wall clock 与 `.o` 计数。
预期：**6 核约 8 分钟**，编译单元约 4584 个。到不了这个数，说明有目录没被裁掉。

产物位置：

```
arch/x86/boot/bzImage          12.1 M
Module.symvers                 导出符号全表（后面 ABI 校验用）
vmlinux                        含 Built-in 驱动，可反查符号
```

---

## 4. 安装

### 4.1 先改版本串（顺序搞错会覆盖现役内核）

```bash
scripts/config --file .config --set-str LOCALVERSION "-20261111-hwreal"
make olddefconfig && grep '^CONFIG_LOCALVERSION=' .config
```

装上的目录名 = 版本串。若与**在运行内核**同名，`make modules_install` 会覆盖现役模块目录
（含 nvidia 595.99.02 DKMS，247 M）。命名约定：`-<yyyymmdd>-<特征>`，
特征是 `hwreal`（真机硬件全）/ `test` / `trim`。

### 4.2 装内核与模块

```bash
sudo make -j6 install        # bzImage → /boot/vmlinuz-<ver>，顺带 update-grub
sudo make modules_install    # → /lib/modules/<ver>/（本次 43 M / 649 ko）
```

### 4.3 重建 initrd（LVM 根盘的生死线）

```bash
V=7.2.12-20261111-hwreal
sudo mkinitramfs -o /boot/initrd.img-$V $V
```

必须确认 initrd 里有 LVM 用户态和加密工具，否则**内核起来了也找不到根盘**：

```bash
lsinitramfs /boot/initrd.img-$V | grep -E 'usr/sbin/lvm$|lvm.conf|cryptsetup'
lsinitramfs /boot/initrd.img-$V | grep -cE 'nvidia.*\.ko'   # 期望 5
```

### 4.4 固件

`mkinitramfs` 会警告缺固件，**逐条确认是不是本机设备**，不是才可忽略。
本机唯一真实需求是 `rtl8168h-2.fw`（RTL8111 rev15），已确认打包进 initrd。
`metronomefb` / `rtl8125cp` / Renesas xHCI 三条警告与本机无关。

---

## 4.5 二次改动：补回 squashfs / vfat / fuse / ipv6

轮5 把"十几个文件系统连根拔"时，连带砍掉了 `SQUASHFS`、`VFAT_FS`、`FUSE_FS` 和 `IPV6`。
后果不是"少个功能"，而是**桌面直接残废**：

| 缺失项 | 症状 |
|---|---|
| `SQUASHFS` | snap 全坏（`snap list` 报错、firefox/chromium 起不来），`mount \| grep squashfs` 为空 |
| `VFAT_FS` / `FAT_FS` | `/boot/efi` 是 FAT32，挂不上；fwupd、EFI 相关一并报错 |
| `FUSE_FS` | `fusermount`、AppImage、gvfs、xdg-desktop-portal 一类全部失效 |
| `IPV6` | 网络栈、容器、部分浏览器行为异常 |

改回 `=y` 后**增量**编译即可，不必 clean（只重编受影响的单元）：

```bash
cd ~/kernel/src/linux-7.2.12
scripts/config --file .config -e SQUASHFS -e SQUASHFS_XZ -e VFAT_FS -e FAT_FS -e FUSE_FS -e IPV6
make olddefconfig
grep -E '^CONFIG_(SQUASHFS|SQUASHFS_XZ|VFAT_FS|FAT_FS|FUSE_FS|IPV6)=' .config   # 六项都要 =y

make -j6                    # 274 s
sudo make modules_install   # 2 s
sudo make install           # 6 s，自动 update-initramfs + update-grub
```

> 前提：`.config` 里的硬件清单（§1）没动过，否则 `olddefconfig` 可能把 `=y` 静默丢掉（见 §0 第 3 条）。

装完**先别重启**，用 `System.map` 验符号，比进系统再排查省事得多：

```bash
V=7.2.12-20261111-hwreal
for s in squashfs_fill_super vfat_fill_super fuse_fill_super inet6_create; do
  grep -qw $s /boot/System.map-$V && echo "  $s OK" || echo "  $s MISSING"
done
grep -E '^CONFIG_(SQUASHFS|VFAT_FS|FUSE_FS|IPV6)=y' /boot/config-$V   # 四项回显
```

### 覆盖同名版本必须先备份

二次改动沿用了同一个 `LOCALVERSION`（`-20261111-hwreal`），`make install` 是**覆盖**现役内核。
覆盖前先留一套能启动的备份，否则新内核起不来就等于没有退路：

```bash
V=7.2.12-20261111-hwreal
sudo cp -a /boot/vmlinuz-$V{,.prev}
sudo cp -a /boot/initrd.img-$V{,.prev}
sudo cp -a /boot/config-$V{,.prev}
sudo cp -a /boot/System.map-$V{,.prev}
sudo cp -a /lib/modules/$V{,.prev}
sudo update-grub     # .prev 自动变成菜单里独立一项，等于白送一层保险
```

跑稳后删掉（本次已删，释放 441 M：/boot 289 M + 模块目录 151 M）：

```bash
sudo rm -f /boot/{vmlinuz,initrd.img,config,System.map}-$V.prev
sudo rm -rf /lib/modules/$V.prev
sudo update-grub     # 菜单自动清理，`grep -c hwreal.prev /boot/grub/grub.cfg` 应为 0
```

---

## 4.6 补回音频：三个坑，一个比一个阴

裁剪把 `SOUND` 整个子系统当成"桌面功能"砍掉了。`.config` 里只剩一行：

```
# CONFIG_SOUND is not set
```

后果：**38 个 snd 模块一个都不编**，`/dev/snd` 不存在，`aplay -l` 报 no soundcards，
而 `lspci` 里声卡明明在（`[1022:1487]` 板载 + `[10de:1aef]` 显卡 HDMI）。
看起来像 codec 问题，实际是内核里根本没有 ALSA。

补法（全模块，别往 vmlinux 里塞）：

```bash
cd ~/kernel/src/linux-7.2.12
scripts/config --file .config \
  -e SND -e SND_PCI -m SND_HDA_INTEL \
  -m SND_HDA_CODEC_REALTEK -m SND_HDA_CODEC_HDMI \
  -m SND_USB_AUDIO -m SND_SEQUENCER
# SOUND 是 SND 的父依赖，olddefconfig 会自己补 =m；确认后再编
make olddefconfig
grep -E '^CONFIG_(SOUND|SND)=' .config
```

### 坑 1：`CONFIG_ACPI_NHLT` 是 bool —— 只编模块必然失败

`SND_INTEL_DSP_CONFIG` 会 **无条件 `select ACPI_NHLT`**，而 `sound/hda/core/intel-dsp-config.c`
调用 `acpi_nhlt_get_gbl_table()` 等函数**没有 `#ifdef` 兜底**。`ACPI_NHLT` 是 bool，只能进 vmlinux。

所以"只 `make modules` 装新 snd 模块"这条路走不通：

```
snd_hda_intel: Unknown symbol acpi_nhlt_get_gbl_table (err -2)
```

**必须整编 vmlinux**（`make -j6`，不是 `make modules`），让 `acpi_nhlt_*` 进镜像。
好消息是 `CONFIG_ACPI_NHLT=y` 在基线和裁剪后都还是 `y`，不用改开关，只是别指望增量编模块蒙混过去。

> 同一个坑附带修好了 `sunrpc.ko` 的 `tls_handshake_*` unknown symbol
> （`CONFIG_NET_HANDSHAKE=y` 之前也没真进 vmlinux）。

### 坑 2：`modprobe` 的 install 钩子，报错信息完全误导

`/etc/modprobe.d/alsa-base.conf` 里有一条：

```
install snd /sbin/modprobe --use-blacklist snd-seq; /sbin/modprobe --ignore-install snd $CMDLINE_OPTS
```

`snd-seq` 不存在时这条 install 规则 **返回 rc=1**，`snd_hda_intel` 的依赖链断在第一步，
`insmod` 失败但报的是 `Invalid argument`——去查 codec、查 `model=` 参数、查 BIOS 全是白费。

判据：`modprobe -v snd_hda_intel` 打印到 `install /sbin/modprobe --use-blacklist snd-seq ...` 就停住
→ 缺 `CONFIG_SND_SEQUENCER`。补上 `snd-seq` 即可，**不用改 alsa-base.conf**。
（链中间的 `snd-ioctl32` 缺失不致命，那条是 `;` 分隔，失败不影响后面。）

### 坑 3：无音频的快照会让音频静默消失

任何写着 `# CONFIG_SOUND is not set` 的快照，拿去铺 `.config` 就是重演一遍静默丢声，
而且因为坑 1，等你发现时又得整编一次。

所以 `configs/` 里只留两份：`config-baseline-2026-11-11`（回退用）和
`config-7.2.12-20261111-hwreal`（装机用，与 `src/linux-7.2.12/.config` md5 一致）。
改完 config 直接覆盖同名文件，不留中间态、不留 `current` 这种会过期的别名。

### 装完怎么验（重启前就能查）

```bash
V=7.2.12-20261111-hwreal
ls /lib/modules/$V/kernel/sound/core/snd.ko*           # 存在
grep -c '^CONFIG_SND.*=m' /boot/config-$V              # 38
nm vmlinux | grep -w acpi_nhlt_get_gbl_table           # 在 vmlinux，不在 .ko
sudo depmod -a $V 2>&1 | grep -c 'unknown symbol'      # 0
```

重启后：`ls /dev/snd`、`aplay -l` 应列出 ALC1220（analog）与 NVIDIA HDMI 两张卡。
若仍无声，先查用户层默认设备（`pactl info | grep 'Default Sink'`），再查 `snd-hda-intel model=`。

---

## 4.7 三次改动：关掉探测噪音 + 补回 netfilter

这一轮改了两件事，都**不改版本串**，同名覆盖安装（覆盖前 build-install.sh 已留 `.prev`）。

### (a) 三个探测型驱动 `=y` → `=m`

`GPIO_IT87` / `GPIO_WINBOND` / `INPUT_IDEAPAD_SLIDEBAR` 在**没有对应硬件**的机器上照样 probe，
各吐一行 err/warn，于是 `dmesg -l err,warn` 永远不干净，真问题被埋掉。
本机既无 IT87/Winbond 传感器也无 IdeaPad 滑条，改 `=m`：噪音消失，硬件真出现时 udev 仍会加载。

```bash
scripts/config --file .config -m GPIO_IT87 -m GPIO_WINBOND -m INPUT_IDEAPAD_SLIDEBAR
make olddefconfig && grep -E 'CONFIG_(GPIO_IT87|GPIO_WINBOND|INPUT_IDEAPAD_SLIDEBAR)=' .config
```

### (b) 补回 netfilter：裁剪时整条链被误判成"没硬件"

防火墙/VPN/容器网桥全靠它，`nft`、`iptables`、`docker` 一用就报 `Table does not exist`。
成片符号在 `configs/netfilter.fragment`（238 个 CONFIG 行），合并进 config：

```bash
cd ~/kernel/src/linux-7.2.12
make LSMOD=/dev/null olddefconfig >/dev/null            # 先收敛到确定状态
scripts/kconfig/merge_config.sh -m .config ~/kernel/configs/netfilter.fragment
make olddefconfig
grep -E '^CONFIG_(NETFILTER|NF_TABLES|IP_NF_IPTABLES|NF_CONNTRACK)=' .config   # 必须都不是 n
```

### 装完必查（编译成功 ≠ 生效）

```bash
V=7.2.12-20261111-hwreal
ls /lib/modules/$V/kernel/drivers/gpio/gpio-it87.ko* \
   /lib/modules/$V/kernel/drivers/gpio/gpio-winbond.ko* \
   /lib/modules/$V/kernel/drivers/input/input-ideapad-slidebar.ko*   # 三个 =m 真落地
sudo nft list tables; sudo iptables -L -n >/dev/null && echo iptables-ok
sudo modprobe nf_tables && echo nf_tables-ok
```

重启后 `dmesg | grep -iE 'it87|winbond|ideapad'` 应为空，§6 的九项验收一项都不许退化。

---

## 5. DKMS（nvidia 闭源驱动）

新内核串意味着 nvidia 模块需要**为新内核重编**，否则进桌面是黑屏 / 软件渲染。

### 不要用 `dkms autoinstall`

`LOCALVERSION` 不变时，DKMS 拿**内核版本串**当 key，认为"这个内核已经构建过"→ 直接跳过，
`/lib/modules/$V/updates/dkms/*.ko` 还是上一版编的。因为 vermagic 相同、`module_layout`
的 CRC 也常常相同，模块能"半个"加载进去，只在个别符号上报：

```
nvidia: disagrees about version of symbol fget
nvidia: Unknown symbol fget (err -22)
```

看起来像驱动坏了，实际是没重编。本次实测 nvidia.ko 有 5 个符号 CRC 不一致
（fget / fd_install / iterate_fd / wake_up_process / dev_driver_string），`gpu_unlock` 2 个。

### 强制同步：`tools/kernel/sync-drivers.sh`

```bash
tools/kernel/sync-drivers.sh --check      # 只体检，逐符号比对 CRC，不改任何东西
tools/kernel/sync-drivers.sh             # dkms build/install --force + 校验 + 重打 initrd
```

它做四件事：`dkms build/install --force`（绕开跳过逻辑）→ 用源码树 `Module.symvers`
逐符号验 CRC → 校验不过就中止（不重打 initrd）→ `update-initramfs -u`。
`nv*` / `nvKms*` 这类模块间互供的符号不算缺失，脚本已排除。

### 已经自动化：`make install` 里挂了钩子

`arch/x86/boot/install.sh` 末尾加了本地补丁（原版备份为 `install.sh.orig`），
`sudo make install` 收尾时自动调 `sync-drivers.sh -k $1`，**每次重编内核都会强制重装显卡驱动**，
失败会打印 `警告：显卡驱动同步失败，重启会丢显卡`。临时跳过：

```bash
LITE_SKIP_DRIVER_SYNC=1 sudo make install
```

注意顺序：钩子依赖 `/lib/modules/$V/build` 软链，那是 `make modules_install` 建的。
**必须先 `modules_install` 再 `install`**。一条命令做完全套（含改版前自动备份）：

```bash
tools/kernel/build-install.sh          # make -j → modules_install → install → 强制同步 → update-grub
```

`v4l2loopback` 因 `BUILD_EXCLUSIVE` 不为本内核构建 → 正常跳过，不是错误。

`/lib/modules/$V/build` 必须指向源码树（`make modules_install` 已建软链）：

```bash
ls -l /lib/modules/$V/build   # → ~/kernel/src/linux-7.2.12
```

DKMS 编完**重跑一次 §4.3**，否则 initrd 里的 nvidia 还是旧的。

### ABI 校验：`check_symvers.py` 报 FAIL 是正常的

裁剪会改变 struct 布局 → 全部 CRC 漂移，所以拿"完整基线树的契约"去对裁剪树必然 FAIL。
这个工具的正确用法是**对预编译二进制**（不改源码的 blob）；DKMS 是**源码重编**，
CRC 由内核在编译时重新生成，不受影响。

真正该看的指标是**未解析符号数**：

```bash
sudo nm -u /lib/modules/$V/updates/dkms/nvidia.ko | awk '{print $2}' | sort -u > /tmp/nv-und.txt
awk '{print $2}' Module.symvers | sort -u > /tmp/kern-exp.txt
comm -23 /tmp/nv-und.txt /tmp/kern-exp.txt | wc -l    # 必须是 0
```

本次结果：`nvidia.ko` 107 M，vermagic 匹配，未解析符号 **0 个**。
被裁掉的 16 个符号（`__fentry__`、`numa_node`、`__node_distance`、`__tracepoint_read_msr` 等）
在 nvidia 源码里全被 `#ifdef` 绕开，实测引用数均为 0。

---

## 6. 设为默认 + 验证

```bash
sudo cp /etc/default/grub /etc/default/grub.bak-$(date +%Y%m%d)
sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-20261111-hwreal"|' /etc/default/grub
sudo update-grub
grep -E '^GRUB_DEFAULT' /etc/default/grub
sudo grep -n 'set default=' /boot/grub/grub.cfg | head -2   # 确认落到 grub.cfg
```

**重启后九项验收（缺一不可）：**

| # | 命令 | 期望 |
|---|---|---|
| 1 | `uname -r` | `7.2.12-20261111-hwreal` |
| 2 | 进图形界面 | 桌面正常（根盘 LVM 链路通） |
| 3 | `nvidia-smi` | 输出 3080 信息（DKMS 模块加载成功） |
| 4 | `ip a` | 有 IP（R8169 + 固件） |
| 5 | `mount \| grep -c squashfs` | ≥ 1（snap 挂载恢复） |
| 6 | `mount \| grep /boot/efi` | 有 vfat 行（§4.5 改动生效） |
| 7 | `ip -6 addr \| grep inet6` | 有地址（IPV6 恢复） |
| 8 | `snap list` | 不报损坏 |
| 9 | `sudo nft list tables; sudo iptables -L -n` | 不报 `Table does not exist`（§4.7 netfilter 生效） |

九项全过才算 PASS。日常用一天不崩，再清理旧内核。

---

## 7. 回退

任何一步失败，**不删任何东西**，先回旧内核：

```bash
# 临时：开机 GRUB 菜单选 Advanced → Ubuntu, with Linux 7.2.12-rtx3080-20261025
# 永久：
sudo cp /etc/default/grub.bak-20261111 /etc/default/grub && sudo update-grub
```

裁 config 出错回退到**基线**（发行版原版，是唯一保证能启动的 config）：

```bash
cp ~/kernel/configs/config-baseline-2026-11-11 ~/kernel/src/linux-7.2.12/.config
cd ~/kernel/src/linux-7.2.12 && make olddefconfig
```

想回到"能用的裁剪态"就编 `config-7.2.12-20261111-hwreal`，别退到中间轮次。

---

## 8. 磁盘余量（提前算账）

`/boot` 只有 2.0 G，两个内核的 initrd 就吃掉 752 M。**保留 `.prev`/`.old` 备份时**（当前状态）：

| 文件 | 大小 |
|---|---|
| `initrd.img-7.2.12-rtx3080-20261025` | 480 M |
| `initrd.img-7.2.12-20261111-hwreal` | 271 M |
| `initrd.img-7.2.12-20261111-hwreal.prev` | 271 M |
| 已用 / 剩余 | **1.1 G / 706 M**（62%） |

> 确认新内核跑稳、删掉 `.prev` 和 `.old` 后可回收到约 811 M / 1017 M（45%）；
> 反过来，余量只剩 700 M 时**再加一套就装不下**——这是先算账再动手的理由。

**下次装内核前必须先清一个旧内核**，否则 `mkinitramfs` 半路 No space 会留下一个坏 initrd
（比装失败更危险：它能被 GRUB 选到）。

---

## 9. 一次跑完（复制粘贴版）

```bash
set -e
V=7.2.12-20261111-hwreal
cd ~/kernel/src/linux-7.2.12
cp ~/kernel/configs/config-7.2.12-20261111-hwreal .config
make olddefconfig
# 顺序：modules_install 必须在 install 之前（DKMS 靠 /lib/modules/$V/build 软链找源码）
make -j6 && sudo make -j6 modules_install && sudo make install
# install 的钩子已强制重建显卡驱动；想显式确认再跑一次 --check：
tools/kernel/sync-drivers.sh --check
sudo update-grub
echo "装完。重启前先跑 §6 的 grub 默认项检查。"
```
