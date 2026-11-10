# 换机器后把树适配回本机（adapt.py）

裁剪是把**驱动目录连代码一起删**，所以 `.config` 里补开关没用——符号背后没有文件了。
`tools/trim/adapt.py` 反着来：不猜该开什么，直接问运行在目标硬件上的那台机器。

## 五步

```bash
cd ~/kernel
python3 tools/trim/adapt.py probe            # ① 探测本机硬件
python3 tools/trim/adapt.py plan             # ② 算差集（谁是已就绪/缺 config/缺目录）
sudo python3 tools/trim/adapt.py fetch --apply    # ③ 缺的目录从上游 tar 拷回（末尾自动跑 refs）
python3 tools/trim/adapt.py refs --apply     # ④ 把目录重新挂回父 Makefile / Kconfig
python3 tools/trim/adapt.py config --apply   # ⑤ 生成 config 片段并合并
make -j6
```

不带 `--apply` 时 `fetch` / `refs` / `config` 只预演或只写片段，不动树也不动 `.config`。
`fetch` 成功后会自动调用 `refs`；单独再跑一次是幂等的，只补缺的那几行。

**为什么要第 ④ 步**：裁剪时 `tools/trim/fix_makefiles.py` 删掉了父 Makefile 里指向已删目录的
token，`prune_src.py` 删掉了父 Kconfig 的 `source` 行。所以只把目录拷回来，代码是**哑的**——
kbuild 不会 descend 进去，menuconfig 里连符号都看不到，`config` 步骤自然报「依赖没满足」。
`refs` 按上游原文件把这几行按原位置插回去：
`obj-$(CONFIG_NET_VENDOR_INTEL) += intel/`、`source "drivers/mmc/Kconfig"` 这类。
整棵子树都没了的中间层（如 `drivers/net/wireless/Makefile`）会从上游生成一份**过滤过**的版本，
只保留本树还存在的目录，避免挂上没回填的兄弟目录。

## 每步在干什么

| 步 | 数据源 | 产出 |
|---|---|---|
| probe | `/sys/bus/pci/devices/*/driver`、`/sys/bus/usb/drivers/*`、`/sys/class/net/*`、`lsmod`、`lspci -nn` | `notes/hw.json` |
| plan | 上游 `Makefile` 的 `obj-$(CONFIG_X) += foo.o` → 驱动名↔符号↔目录 | `notes/adapt-plan.json` + 人读表格 |
| fetch | `linux-7.2.12.tar.xz`（只解命中的 member，不解整棵树） | 目录回到 `src/linux-7.2.12/` |
| refs | 上游同名 `Makefile` / `Kconfig`（缓存到 `notes/.cache/mk/`） | 父级引用行按原位置补回，符号变可见 |
| config | `scripts/kconfig/merge_config.sh` + `make olddefconfig` | `notes/adapt-<host>.config`，并回报仍没生效的符号 |

关键映射靠 **Makefile 反查**，不靠 `MODULE_ALIAS`：`/sys` 里的驱动名是模块名/别名
（`snd-usb-audio`、`piix4_smbus`），归一掉 `-`/`_` 后去匹配 `foo.o` 的 basename，就能拿到
`CONFIG_SND_USB_AUDIO`。上游 Makefile 首次会从 tar 里解出来缓存到 `notes/.cache/`（28 MB），
之后 plan 是 0.2 秒级。

## 换机（新硬件）实跑流程

树不进仓库（`src/` 被 gitignore），所以换机是**搬树 + 在现场补驱动**，不是重新裁一遍。

```bash
# ① 把这棵树整体搬过去（701 MB，比重新裁剪稳）
rsync -aH --info=progress2 ~/kernel/src/linux-7.2.12  smallbox:~/kernel/src/
rsync -a ~/kernel/tools ~/kernel/notes/hw.json  smallbox:~/kernel/     # 脚本也要带走
scp /opt/linux/src/linux-7.2.12.tar.xz  smallbox:/opt/linux/src/       # 回填驱动要用原始源码包

# ② 小机箱上：探测 → 计划 → 回填 → 挂接 → 开符号
cd ~/kernel
python3 tools/trim/adapt.py probe
python3 tools/trim/adapt.py plan
sudo python3 tools/trim/adapt.py fetch --apply     # 自动接 refs
python3 tools/trim/adapt.py refs --apply           # 幂等，可重复跑
python3 tools/trim/adapt.py config --apply
make -j$(nproc)

# ③ 验收（三步都该干净）
python3 tools/trim/fix_makefiles.py                # 应为「0 条失效引用」
grep -E "^CONFIG_(你的驱动)=" src/linux-7.2.12/.config
```

树或 tar 不在默认路径时：`--tree /path/to/linux-7.2.12` 或 `KERNEL_TREE=... --tar /path/to.tar.xz`。

### 三个坑（都在 sim-smallbox 上踩过）

1. **父级引用**：见第 ④ 步。漏了它的表现是「目录回来了、config 也写了，但 .config 里符号
   不生效」，且 `make` 根本不编译那个目录——不报错，最坑。
2. **传递依赖**：符号生效了不代表驱动能编。`IWLWIFI` 要 `depends on PCI && HAS_IOMEM && CFG80211`，
   实测第一次就卡在 `CONFIG_WLAN` 没开（无线 `menuconfig WLAN` 在
   `drivers/net/wireless/Kconfig` 里，`source` 行没挂上就整块不可见）。`config` 的
   「⚠️ 合并后仍未生效」列表就是这类，逐个按 `depends on` 往上补符号或再 `fetch` 父目录。
3. **config 别整份搬**：小机箱的 `.config` 要基于本机现跑出来的那份再 merge，直接拷这台机器的
   `.config` 会把 nvidia 等本机特有项带过去（`olddefconfig` 会删掉不可见的符号，但白白一轮）。

### 实测（sim-smallbox：e1000e / iwlwifi / rtsx_pci / mmc_core / amdgpu）

| 阶段 | 结果 |
|---|---|
| fetch | 回填 4 个目录：`gpu/drm/amd`(2839 文件)、`mmc`(177)、`net/ethernet/intel`(410)、`net/wireless/intel`(334) |
| refs | 补回 10 处父级引用（含 `drivers/Makefile: obj-y += mmc/`、`drm/Makefile: amd/amdgpu/`、`drm/Kconfig: source .../amd/amdgpu/Kconfig`） |
| config | `E1000E=m`、`MMC=m`、`DRM_AMDGPU=m`、`WLAN=y`、`IWLWIFI=m` 全部生效 |
| 验收 | 全树悬空 Makefile 引用 0 条、悬空 Kconfig `source` 0 条（`arch/$(SRCARCH)` 除外） |

## 实测

**本机（RTX 3080 这台）**：100 个在用驱动/模块 → 88 个已就绪，0 个缺目录，0 个缺 config。
这棵树本来就是为它裁的，所以全绿才是正确答案。

**伪造的 sim-thinkpad**（加了 e1000e / iwlwifi / rtsx_pci / mmc_core）：

```
❌ 目录被删了 3 个（要先从上游拷回来）
   E1000E         drivers/net/ethernet/intel     ← e1000e
   IWLWIFI        drivers/net/wireless/intel     ← iwlwifi
   MMC            drivers/mmc                    ← mmc_core
→ fetch --apply：921 个文件、25 MB 拷回，e1000e/netdev.c、iwl-drv.c、mmc/core/core.c 齐全
→ config：CONFIG_E1000E=m / CONFIG_IWLWIFI=m / CONFIG_MMC=m
```
（验证完把这 3 个目录删了、`hw.json` 复原，树保持为本机裁剪态。）

## 两个坑

1. **别按设备列表手抄。** `/sys` 里的驱动名不一定等于模块文件名：`piix4_smbus` 的代码在
   `i2c-i801.c`（`CONFIG_I2C_I801`）。`lsmod` 里的模块名（`i2c_i801`）比驱动别名可靠，
   两者都喂给索引，命中任一即可。
2. **`config --apply` 的回报要看。** 加进去的符号可能因 Kconfig 依赖没满足（父开关没开）
   被 `olddefconfig` 丢弃，脚本会单独列出"合并后仍未生效"的符号，按它去补父符号。

## 里外不是硬件的那部分

`nvidia*`（`gpu_unlock`/`nvidia_drm`/`nvidia_modeset`/`nvidia_uvm`）和 `v4l2loopback`
是 out-of-tree 模块，不在这棵内核树里，plan 会把它们列成"对不上 CONFIG"，属正常，
由 `docs/gpu-nvidia.md` 那套外部构建负责。
