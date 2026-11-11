# 最小可用内核：裁剪 → 编译 → 安装 完整流程

本文是**可照着敲**的操作手册。读完只需记住一句：**裁到"够本机跑"，不是"够启动"**。
`docs/trim.md` 讲方法与账本（为什么这么裁、每轮砍了什么、踩了哪些坑），本文讲**动作顺序**。

当前唯一通过真机验证的产物：

| 项 | 值 |
|---|---|
| 版本串 | `7.2.12-20261111-hwreal` |
| 内核源码 | Linux 7.2.12（`src/linux-7.2.12/`） |
| config | `configs/config-7.2.12-20261111-hwreal`（**就是装机那一份，逐字节复制**） |
| `=y` / `=m` | 2158 / 641（CONFIG_ 行 2935） |
| vmlinuz | 12.1 M |
| 模块目录 | 43 M / 649 个 `.ko` |
| initrd | 271 M（含 nvidia 5 个模块） |
| 构建耗时 | 7m53s（6 核，全新构建） |
| 状态 | 已装、已设为 GRUB 默认 |

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
| `config-round{2..5}-*.ok` | **每轮快照**（`.ok` = 该轮验收过） | 出问题回退到上一轮 |
| `config-round6-hw-real` | 轮5 + 修复 439 项（事故补救版） | 事故后重建 |
| `config-7.2.12-20261111-hwreal` | **当前装机版**（round6 + `LOCALVERSION`） | 编译此文件即得在跑的内核 |

> **改 config 的正确姿势**：不要把 `.config` 当源码手改。写 fragment →
> `scripts/config --file .config -e XXX -d YYY` → `make olddefconfig` →
> 立刻 `cp .config configs/config-roundN-<描述>`。
> `.config` 是产物，`configs/` 里的快照才是资产。

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

## 5. DKMS（nvidia 闭源驱动）

新内核串意味着 nvidia 模块需要**为新内核重编**，否则进桌面是黑屏 / 软件渲染。

```bash
V=7.2.12-20261111-hwreal
sudo dkms autoinstall -k $V
dkms status | grep $V
# 期望：nvidia/595.99.02, $V: installed
#       gpu-unlock/1.0.0, $V: installed
# v4l2loopback 报 BUILD_EXCLUSIVE 不匹配 → 正常跳过，不是错误
```

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

**重启后四项验收（缺一不可）：**

| # | 命令 | 期望 |
|---|---|---|
| 1 | `uname -r` | `7.2.12-20261111-hwreal` |
| 2 | 进图形界面 | 桌面正常（根盘 LVM 链路通） |
| 3 | `nvidia-smi` | 输出 3080 信息（DKMS 模块加载成功） |
| 4 | `ip a` | 有 IP（R8169 + 固件） |

四项全过才算 PASS。日常用一天不崩，再清理旧内核。

---

## 7. 回退

任何一步失败，**不删任何东西**，先回旧内核：

```bash
# 临时：开机 GRUB 菜单选 Advanced → Ubuntu, with Linux 7.2.12-rtx3080-20261025
# 永久：
sudo cp /etc/default/grub.bak-20261111 /etc/default/grub && sudo update-grub
```

裁 config 出错回退到上一轮快照（这就是 `.ok` 后缀的意义）：

```bash
cp ~/kernel/configs/config-round5-7m53s.ok ~/kernel/src/linux-7.2.12/.config
```

---

## 8. 磁盘余量（提前算账）

`/boot` 只有 2.0 G，两个内核的 initrd 就吃掉 751 M：

| 文件 | 大小 |
|---|---|
| `initrd.img-7.2.12-rtx3080-20261025` | 480 M |
| `initrd.img-7.2.12-20261111-hwreal` | 271 M |
| 剩余 | **705 M** |

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
make -j6 && sudo make -j6 install && sudo make modules_install
sudo dkms autoinstall -k $V
sudo mkinitramfs -o /boot/initrd.img-$V $V
sudo update-grub
echo "装完。重启前先跑 §6 的 grub 默认项检查。"
```
