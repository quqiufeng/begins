# 本机真实硬件与所需驱动（实测，非推测）

采集：`lspci -nn` 43 个 PCI 设备 / `lsmod` 96 个模块。

| 功能 | 硬件 ID | 需要的驱动 |
|---|---|---|
| SSD | `[14a4:23f1]` Lite-On NVMe | `nvme` + `nvme_core` |
| 显卡 | `[10de:2206]` **RTX 3080 (GA102)** | 闭源 blob `nvidia 595.99.02`（**可编译可链接，见 docs/gpu-nvidia.md**） |
| 显卡音频 | `[10de:1aef]` | `snd_hda_intel` |
| 网卡 | `[10ec:8168]` RTL8168 | `r8169` |
| SATA | `[1022:43c8] [1022:7901]` | `ahci` + `libata` |
| USB | `[1022:43d5] [1022:149c]` | `xhci_hcd` |
| 声卡 | `[1022:1487]` HD Audio | `snd_hda_intel` + `snd_hda_codec_realtek`（**曾被整块裁掉，见 build.md §4.6**） |

## ⚠️ 关于 `.config` 的一个纠正

`~/kernel-meta-7.2.12/.config` 里 **=m 有 3896 项**——那是发行版"允许编译"，**不是本机需要**。
本机真正用到的驱动由 `lspci` 的设备 ID + `lsmod` 的在跑模块决定，只有 7 类。

## 真实 API 面（静态下界）

| 范围 | 需内核提供的导出符号 |
|---|---|
| virtio-blk（M2 靶子） | 63 |
| **本机真实驱动集合（并集）** | **779** |

779 还是**下界**：未做传递展开（kpi 函数自己又调别的），实际会到 1000+。

## 对 M3/M4 的直接影响（已修正）

~~RTX 3080 没有可移植的开源驱动~~ → **错，已实测推翻**：

- 闭源 blob（108MB 预编译 .o）**能编译、能链接**，本机 DKMS 已成功加载
- 需要的内核符号 **297 个，全部普通 EXPORT_SYMBOL，0 个 GPL-only**
- 真正的代价不是符号而是 **结构体布局冻结**（blob 偏移烧死）→ 驱动可见面必须 ABI 克隆 Linux
- 外加 `nvidia-drm` 需要的 **16k 行 DRM/KMS**

详见 **docs/gpu-nvidia.md**。QEMU（virtio-gpu）路线不受影响。
