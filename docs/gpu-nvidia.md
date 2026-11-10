# NVIDIA 闭源驱动：能不能拿来用（实测结论）

**结论：能。我上一版说"路根本不通"是错的，已纠正。**

## 实测环境

| 项 | 值 |
|---|---|
| 驱动版本 | `595.99.02` |
| 源码包 | `/usr/src/nvidia-595.99.02`（27 个 open shim 头文件 + `.c`） |
| 预编译 blob | `nvidia/nv-kernel.o_binary`、`nvidia-modeset/nv-modeset-kernel.o_binary`（**108 MB**，ELF relocatable，not stripped） |
| 现状 | **DKMS 已在本机内核 `7.2.12-rtx3080-20261025` 上编译并加载成功**（nvidia 100MB 常驻） |

## 好消息：符号面完全过关

| 模块 | 未定义符号 | symvers 里能找到 | GPL-only |
|---|---|---|---|
| `nvidia.ko` | 297 | **297（全部）** | **0** |
| `nv-kernel.o_binary`（blob 本体） | 335 | — | — |
| `nvidia-drm.ko` | 257（含 124 个 `drm_*`） | 全部 | 0 |
| `nvidia-uvm.ko` | 285 | 全部 | 0 |
| `nvidia-modeset.ko` | 103 | 全部 | 0 |

**297 个符号全是普通 `EXPORT_SYMBOL`，没有一个 GPL-only** —— 所以闭源模块在许可上可以链接。
这一条比 virtio-blk 的 63 个只多一档，不是数量级问题。

## 真正的三道门（不是符号数）

### 门 1：MODVERSIONS CRC

```
vermagic: 7.2.12-rtx3080-20261025 SMP preempt mod_unload modversions
__versions 条目: nvidia 114 · nvidia-drm 113 · nvidia-modeset 37 · nvidia-uvm 118
```

CRC 由符号的**类型签名**算出（`genksyms`）。我们内核里 `kmalloc` 的声明与 Linux 差一个 typedef，CRC 就不同，`insmod` 直接拒。

**这条反而是好消息**：`/opt/linux/src/linux-7.2.12/scripts/genksyms` 就在手边，可以自己算 CRC 和 `.ko` 里的 `__versions` 对表 —— 变成**编译器可验证的指标**，不靠眼睛猜。

### 门 2：结构体布局冻结（这才是硬约束）

blob 是**预编译**的，它内部对 `struct pci_dev` / `struct device` / `struct file` 的
字段偏移已经烧死。我们能改编译器、能改函数体，**不能改偏移**。

推论：凡是 blob 碰到的结构体，布局必须和 Linux 7.2.12 **逐字节一致**。
满足它的唯一现实做法是 —— **直接复用 Linux 的头文件**（`include/linux/*.h` 原样编入），
而不是"照着写一遍"。这样 layout 天然一致，不用赌。

代价要说清楚：这已经不是"L1 越薄越好"，而是 **L1 在驱动可见面上必须是 Linux ABI 的克隆**。
（性质上更像 Wine/ReactOS，而不是 FreeBSD linuxkpi。）

### 门 3：`nvidia-drm` 要一套真的 DRM/KMS

124 个 `drm_*` 符号，都是"已导出"，但**导出 ≠ 存在**——得自己实现：

| 文件 | 行数 |
|---|---|
| `drm_atomic_helper.c` | 4104 |
| `drm_connector.c` | 3656 |
| `drm_atomic.c` | 2143 |
| `drm_plane.c` | 1879 |
| `drm_gem.c` | 1769 |
| `drm_framebuffer.c` | 1238 |
| 其余若干 | ~5k+ |

核心集约 **16k 行**，还没算 dma-buf / dma-fence。作为对比：blk-mq 全部 7300 行。

## 修正后的判断

| 说法 | 原判断 | 实测 |
|---|---|---|
| "RTX 3080 无开源驱动 → 路不通" | ❌ 错 | 闭源 blob 可编译、可链接、0 GPL 障碍 |
| "符号太多做不到" | ❌ 错 | 297 个，比 virtio-blk 只多一档 |
| "改不了不能写" | ✅ | 但 **layout 冻结**，只能用真头文件 |

**结论不是"不通"，而是"通，但要付 ABI 克隆的代价"**：
用真头文件 + genksyms 对 CRC + 实现 DRM/KMS，这是**机械可验证**的活，
比"手写驱动"可控得多，但工作量在 DRM 那 16k 行上。

## 于是 M3/M4 的边界变了

这个发现让 `docs/hardware.md` 里"M4 只能 GOP"的结论作废一半。新的三条路：

- **M3（QEMU）不变**：virtio-gpu，小，先跑通自研桌面
- **真机 + 自研桌面**：把 **DRM uAPI 当边界**。桌面走 libdrm/KMS，
  Linux 上今天就能用 nvidia-drm 跑起来（真机验证不等内核）
- **真机 + 自研内核 + nvidia blob**：需要 ABI 克隆 + 16k 行 DRM/KMS，
  可以排到 M4 之后，做为"验证 M4 ABI 假设"的靶子

## 下一步决策

1. 是否接受"驱动可见面 = Linux ABI 克隆"这个前提（这决定 L1 的性质）
2. 若接受：先做 **CRC 对表工具**（genksyms vs `__versions`），它是所有 M4 工作的地基
3. 若不接受：真机就用 GOP framebuffer 软绘制，blob 只当"将来再说"
