# 换机器后把树适配回本机（adapt.py）

裁剪是把**驱动目录连代码一起删**，所以 `.config` 里补开关没用——符号背后没有文件了。
`tools/trim/adapt.py` 反着来：不猜该开什么，直接问运行在目标硬件上的那台机器。

## 四步

```bash
cd ~/kernel
python3 tools/trim/adapt.py probe            # ① 探测本机硬件
python3 tools/trim/adapt.py plan             # ② 算差集（谁是已就绪/缺 config/缺目录）
sudo python3 tools/trim/adapt.py fetch --apply    # ③ 缺的目录从上游 tar 拷回
python3 tools/trim/adapt.py config --apply   # ④ 生成 config 片段并合并
make -j6
```

不带 `--apply` 时 `fetch` / `config` 只预演或只写片段，不动树也不动 `.config`。

## 每步在干什么

| 步 | 数据源 | 产出 |
|---|---|---|
| probe | `/sys/bus/pci/devices/*/driver`、`/sys/bus/usb/drivers/*`、`/sys/class/net/*`、`lsmod`、`lspci -nn` | `notes/hw.json` |
| plan | 上游 `Makefile` 的 `obj-$(CONFIG_X) += foo.o` → 驱动名↔符号↔目录 | `notes/adapt-plan.json` + 人读表格 |
| fetch | `linux-7.2.12.tar.xz`（只解命中的 member，不解整棵树） | 目录回到 `src/linux-7.2.12/` |
| config | `scripts/kconfig/merge_config.sh` + `make olddefconfig` | `notes/adapt-<host>.config`，并回报仍没生效的符号 |

关键映射靠 **Makefile 反查**，不靠 `MODULE_ALIAS`：`/sys` 里的驱动名是模块名/别名
（`snd-usb-audio`、`piix4_smbus`），归一掉 `-`/`_` 后去匹配 `foo.o` 的 basename，就能拿到
`CONFIG_SND_USB_AUDIO`。上游 Makefile 首次会从 tar 里解出来缓存到 `notes/.cache/`（28 MB），
之后 plan 是 0.2 秒级。

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
