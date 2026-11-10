# ABI 兼容 Linux（已定稿 2026-11-10）

**决策**：内核对外 ABI 与 Linux 逐字兼容。不是"大致一样"，是 CRC 一致。

## 为什么这条不能打折

`__versions` 段里的 CRC 是 **类型签名经 genksyms 算出的 64 位指纹**。
`insmod` 时逐条比对，不匹配就 `disagrees about version of symbol xxx` 直接拒绝加载。

nvidia blob 是 108 MB 预编译 `.o`，**不可重编译**。所以：

```
我们的 struct 布局 / typedef / 字段顺序 / 函数签名  ==  Linux 7.2.12
                                       差一个 bit → 拒绝加载
```

这条顺带把 386 个头文件、16 万行的驱动 include 闭包也一并锁死了——反正都要一致，
自研部分没有理由偏离。

## 契约实测（nvidia 四个模块）

| 模块 | 未定义符号 | `__versions` | 覆盖 |
|---|---|---|---|
| nvidia | 297 | 298 | 297 ✅ |
| nvidia-drm | 257 | 258 | ✅ |
| nvidia-modeset | 103 | 104 | ✅ |
| nvidia-uvm | 285 | 286 | ✅ |
| **去重后契约** | | | **610 个符号** |

> 修正一处此前的错数：早先按 72 字节步长解 `__versions` 得到"114 条"，是错的。
> 正确结构体是 `struct modversion_info { unsigned long crc; char name[56]; }`，
> 步长 **64 字节**（`MODULE_NAME_LEN = 64 - sizeof(unsigned long)`）。

契约文件：**`kpi/abi/nvidia.contract`**（610 行，`符号=CRC`）

## 610 个符号压在哪

| 前缀 | 数量 | 谁在用 |
|---|---|---|
| `drm_*` | 123 | nvidia-drm → DRM 核心 |
| `__*` | 98 | 内部辅助（`__SCT__`/`__x86` thunk 等） |
| `pci_*` | 28 | 总线 |
| `dma_*` | 19 | DMA 映射 |
| `__x86_*` | 14 | 间接跳转 thunk + 原子操作 |
| `acpi_*` | 9 | 电源/背光 |

**`drm_*` 占 20%** —— 印证"M3 先把 DRM uAPI 当边界"是对的路线。

## 工具链（`tools/abi/`）

| 文件 | 作用 |
|---|---|
| `elf.py` | 零依赖 ELF64 解析器：读 `.symtab`、未定义符号、`__versions` |
| `manifest.py` | `.ko` → 契约；`--kv` 与已有 CRC 清单比对；`--c-header` 出自检头 |
| `verify.py` | **CRC 对表**：生成 stub 模块 → 用目标树编译 → 读回 `__versions` → 比对 |

### 关键设计：不重实现 genksyms

CRC 是类型签名的指纹，与其自己实现 genksyms（要处理宏展开、typedef 解析，边界极多），
不如**让内核自己算**：

```
生成 abistub.c（引用全部 610 个符号，不调用）
        ↓  make -C <内核树> M=... modules
读 abistub.ko 的 __versions
        ↓
与 nvidia.contract 比对  →  PASS / FAIL
```

stub 的 CRC 与契约一致 = 我们的头文件声明与 Linux 逐字同构。
**这就是我们内核 M1 的验收测试**，可以每天跑。

### 当前状态：已 PASS（零编译验证）

不需要编译。`~/kernel-meta-7.2.12/Module.symvers`（24327 条）就是内核 CRC 全表，
直接对表即可：

```
契约 610 = 内核侧 521 + 模块间 89
内核侧 521 → 匹配 521 / CRC不符 0        ✅
模块间 89  → 全部由 nvidia 四模块自导出   ✅
判定 PASS
```

```bash
~/kernel/tools/abi/check_symvers.py \
  ~/kernel-meta-7.2.12/Module.symvers kpi/abi/nvidia.contract \
  --self /lib/modules/7.2.12-rtx3080-20261025/updates/dkms/*.ko
```

**这 521 个符号 = 裁剪内核时不能碰的边界**，每轮裁剪后必须仍然是 521/521 PASS。
（`verify.py` 保留给"换内核树后重新生成 CRC"的场景。）

裁剪方案与 config 陷阱见 **docs/trim.md**。

## 三件事的先后

| # | 事 | 状态 |
|---|---|---|
| 1 | 契约提取（610 符号） | ✅ `kpi/abi/nvidia.contract` |
| 2 | CRC 对表工具 | ✅ `tools/abi/verify.py`，待树准备后首跑 |
| 3 | 386 头文件裁剪成最小契约集 | 未开始（依赖 2 跑通后的差异反馈） |
