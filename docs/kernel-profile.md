# 裁剪后的内核特点（2026-11-10 真机实测）

**一句话：体积砍掉大头，功能一项没丢。**

## 一、体积账

| 项 | 旧内核 `20261025` | 裁剪版 `20261025-test` | 变化 |
|---|---|---|---|
| bzImage | 19.70 MB | 18.28 MB | −1.42 MB（−7.2%） |
| initrd | 479.67 MB | 282.89 MB | **−196.78 MB（−41.0%）** |
| `/lib/modules` | **4.0 GB** | **247 MB** | **−约 3.76 GB（−94%）** |
| .ko 数量 | 3965 | 1778 | −2187 |
| config 行数 | 6914 | 4400 | −2514 |
| 引导链合计（kernel+initrd） | 499.37 MB | 301.17 MB | **−198.2 MB（−39.7%）** |

**杠杆在模块**：3.76 GB 全是「从未插上的驱动」。内核本体只省 1.4 MB，因为压缩后
真正吃空间的是驱动集合，不是核心。initrd 那 197 MB 同理 —— 按本机模组集重生成后自然瘦身。

## 二、config 结构变化

| 类别 | 旧 | 新 | 说明 |
|---|---|---|---|
| `=y` | 2821 | 2437 | −384，内建体积来源 |
| `=m` | 3896 | 1789 | **−2107，模块宇宙塌缩** |
| `is not set` | 1281 | 1737 | +456 |
| 差异行总计 | — | **2528** | 其中 `=y` 被关掉 **386** 项 |

**裁掉的大类**（按 CONFIG 前缀计）：

```
USB 291   SENSORS 243   COMEDI 132   VIDEO 119   REGULATOR 112
MFD 104   TOUCHSCREEN 101   LEDS 77   MTD 61   INTEL 55
DRM 47    NET 44   SPI 40   JOYSTICK 37   FB 36   CHARGER 36
```

规律：**砍的全是「本机没有的外设宇宙」** —— 传感器、触屏、机顶盒调谐器、充电器、
工业现场总线。这类占 config 六成，在本机一个都用不上。

## 三、七个特点

**1. 只认这一台机器。** 驱动集按 `lspci -nn` 的 43 个 PCI 设备反向定制，不是通用发行版内核。

**2. 关键路径全内建，不靠模块。** `BLK_DEV_NVME=y`、`EXT4_FS=y`、`R8169=y`、`DRM=y`、`FB=y`
—— root 在 LVM+ext4 上，这些若编成模块就得塞进 initrd，现在直接省掉。

**3. 子系统保留完整度。** `PCI 40 · ACPI 65 · NET 178 · USB 82 · NVME 7 · SATA 8 · DRM 20`。
ACPI 一个没砍，因为 nvidia blob 和电源管理都要它。

**4. 静止项一个没动**（ABI 冻结的底线，不是懒）：

```
CONFIG_NR_CPUS=8192          改了 cpumask_t 从 1024 字节变 8 字节，610 个符号 CRC 全变
CONFIG_PREEMPT=y             与 vermagic 绑定（实测 "SMP preempt mod_unload modversions"）
CONFIG_SMP=y
CONFIG_KALLSYMS_ALL=y
CONFIG_DEBUG_INFO_DWARF5=y
CONFIG_MODULE_SIG_SHA512=y
```

**5. 压缩方式 ZSTD**（`CONFIG_KERNEL_ZSTD=y`）。实测 `/boot/initrd.img-...-test` 已非 gzip，
解压要用 `zstd -d`，`zcat` 会报 "not in gzip format"。

**6. 启动快。** `systemd-analyze`：firmware 47.7s + loader 20.9s + **kernel 5.65s** +
userspace 7.86s，graphical.target 7.8s 达成。

**7. 无致命告警。** 仅三条良性：`iommu AMD-Vi INVALID_DEVICE_REQUEST`、
`amd_pstate: _CPC not present`、`nvidia taints kernel`（闭源必然）。

## 四、唯一遗留问题（**非裁剪所致**）

`amd_pstate: the _CPC object is not present in SBIOS` → **整机没有 cpufreq**，
`/sys/devices/system/cpu/cpu0/cpufreq` 不存在，CPU 跑固定频率。

根因：BIOS 未提供 `_CPC`（ACPI 表只有 `PCCT`，无 `_CPC`）。新旧内核的
`X86_AMD_PSTATE=y`、`X86_ACPI_CPUFREQ=y` **都开着**，换哪个内核都一样失败。
要解决得进 BIOS 开 CPPC。

## 五、结论

裁剪没伤功能：显卡、网络、声音、USB、双盘、桌面全部正常，八项验收一次通过。
换来 **3.76 GB 磁盘** 和 **197 MB initrd**。

代价只有一个：**换硬件就得重新裁**。这是刻意取舍 —— 通用发行版那 4 GB 模块，
99% 是给别人的机器准备的。
