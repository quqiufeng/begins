# x96max — X96 Max（S905X2 / meson-g12a）构建、打包、安装脚本总目录

所有自己写/改过的 sh 脚本都放这里，**这是唯一位置**；`/x96-build` 只当**构建工作区**
（源码、产物、日志），不放脚本。原先 `/x96-build/{pack-kernel,flash-p1,run-timed}.sh`
三个软链已于 2026-11-15 删除，调用一律写 `x96max/xxx.sh`。

文档：`../X96max.md`（§19 是端到端流程，脚本注释里标的 §x.y 对应它）。

## 1. 脚本清单（按流水线顺序）

| 阶段 | 脚本 | 作用 |
|---|---|---|
| **开工** | `preflight.sh` | **只读自检**（源码树钩子三连 / 配置 `=y` / `CONFIG_LOCALVERSION` 对得上 KNAME / 两份配置同源 / 工具链 / 两套入口齐全），全绿才开建，对应 `X96max.md` §0.2 第 0 步 |
| 环境 | `mkbase.sh` | 用源码 rootfs 造 rebuild 需要的基础镜像 `base-own.img`（2560M ext4 + base-boot-backup） |
| 裁剪 | `kernel/gen-trim.sh` → `kernel/x96-trim.fragment` | 第一轮：从 `config-7.2.12-x96-full` 扫出激进裁剪 fragment（只动 `=m`），**基线是裁剪树，会踩 §5.7 的符号丢失** |
| 裁剪 | `kernel/gen-trim2.sh` → `configs/trim2-*.fragment` | **第二轮（2026-11-15，现用）**：基线必须是全量树配置（已归档 `configs/config-7.2.12-fulltree-baseline-20261115`；原 `kbuild-clean` 树 2026-11-15 已删）；规则 A 除白名单外关掉所有 `=m`，规则 B 只关整块 `=y` 子系统 → 镜像 42.2→32.2 MB、模块 5816→140（§5.8）|
| 裁剪 | `trim-tools/*.py` | 源码树裁剪工具箱（`prune_src.py` 删目录、`fix_makefiles*.py` 补 Makefile、`plan.py`、`sym2kc.py`），规则见 `trim-tools/rules.txt` |
| 编译 | `build-kernel.sh` | 只编内核（§19.3）：olddefconfig + Image + modules + dtb + modules_install，带计时、`rc`/`sec` 落盘（原 `/x96-build/run-timed.sh`）；两套各编各的产物树 |
| initrd | —（在 `rebuild-from-zero.sh --from initrd`） | loop 挂 base → chroot qemu → `depmod` + `update-initramfs` → `mkimage` 出 uInitrd |
| 打包 | `pack-kernel.sh` | 只打四件套（§19.5）：boot/dtb/modules/header + `sha256sums`，**输出到本套包仓** `$ROOT/pkgs/<mode>/{full,trim}`；`--stage` 再同步进 ophub 的 `kernel/stable/7.2.12` |
| 镜像 | `build-image.sh` | ophub rebuild 出可刷镜像（rootfs 裁剪 + 注入首启 service），`--mode full|trim`，可 `--skip-rootfs`、`--write` |
| 镜像 | `rebuild-from-zero.sh` | 全流程 §19.3→§19.6，`--mode full|trim`，支持 `--from kernel|initrd|pkgs|image`、`--no-clean` |
| **两套入口** | `full/*.sh`、`trim/*.sh` | 每套 5 个固定入口（preflight / build-kernel / pack-kernel / rebuild-from-zero / build-image），只设 `X96_CFG_MODE`，参数统一来自 `lib/mode.sh` |
| 写卡 | `write-card.sh` | 安全写整盘镜像 + 文件系统层校验（关 automount/udisks2，逐文件 sha256） |
| 写卡 | `flash-p1.sh` | 只把新 `Image` 写进已启动 U 盘 p1（按 rootfs UUID 定位父盘），快速试内核 |
| 写卡 | `patch-bootargs.sh` | 改卡上 p1 `uEnv.txt` 的 `APPEND`：幂等追加/删除内核参数，`--usb-fix VID:PID` 一键禁 UAS + 关 USB 自动挂起（§10.2.2）|
| 写卡 | `patch-initrd-wait.sh` | 把 initramfs 里 `scripts/local` 的 `slumber` 由 30 抬到 90（`--secs N` 可调）；吃 `initrd.img` 或 `uInitrd`（自动剥头/重打包 + 回读自检 + 首次改动留 `.bak.<时间戳>`）；`--check` 只读复查（§5.5）|
| 校验 | `verify-card.sh` | 卡 vs 备份镜像：两侧 `ro,noload` 挂载逐文件 sha256 对拍（不用裸盘 cmp） |
| 备份 | `backup-card.sh` | 把已验证可启动的卡备份成可还原镜像 |
| 安装 | `x96-autoinstall.sh` + `x96-autoinstall.service` | 首启自动 `armbian-install` 装到 eMMC（防 apt 吃 stdin、done 标记只在成功后写） |
| 配置 | `kernel/config-7.2.12-x96-full` | **全量套配置**（未裁剪），`LOCALVERSION=-x96` → `7.2.12-x96`，sha `e137d0d5…`，编 35.8MB Image |
| 配置 | `kernel/config-7.2.12-x96-trim` | **裁剪套配置**（全量树 + 硬件裁剪），`LOCALVERSION=-x96-trim` → `7.2.12-x96-trim`，与 `configs/config-7.2.12-x96-trim-20261115` 同源 |
| **参数源** | `lib/mode.sh` | 两套参数（配置/源码树/产物树/KNAME/initrd/包仓/成品名）**唯一出处置**；`x96_mode full|trim` + `x96_stage_pkgs` + `x96_cfg_same` |
| 配置 | `config-x96-source.conf` | armbian-build 的 rootfs 构建参数（BLOCK 列表在此） |

第三方工具（不是我们写的，别改）：`/x96-build/{armbian-build, amlogic-s9xxx-armbian, pyamlboot, radxa-aml, aml-flash-tool}`。

## 2. 两套打包（完整源码树 / 裁剪版）—— 各自独立的脚本、配置、源码目录

一个 `MODE` 两套参数，**从配置到成品全程不共用**，两套可以同时存在于 `/x96-build` 而互不覆盖：

| 项 | full（完整源码树） | trim（裁剪版） |
|---|---|---|
| 配置 | `kernel/config-7.2.12-x96-full` | `kernel/config-7.2.12-x96-trim` |
| 源码树 | `/x96-build/src-full`（**按需解压，可删**） | `/x96-build/src-trim`（**裁剪树 782M，必须留**；现役叫 `7.2.12-trim`，`x96_pick_trim_src` 自动找） |
| 产物树 | `/x96-build/kbuild-7.2.12`（**2026-11-15 已删**，`--full` 会重建） | `/x96-build/kbuild-trim`（现役，源码树 `7.2.12-trim`）|
| 内核名 / 模块目录 | `7.2.12-x96` | `7.2.12-x96-trim` |
| initrd / uInitrd | `initrd.img-7.2.12-x96` | `initrd.img-7.2.12-x96-trim` |
| 四件套包仓 | `/x96-build/pkgs/full` | `/x96-build/pkgs/trim` |
| 成品镜像 | `recovery/x96-full-autoinstall.img.gz` | `recovery/x96-trim-autoinstall.img.gz` |
| 入口脚本 | `x96max/full/*.sh` | `x96max/trim/*.sh` |

```bash
# 两套各自一键到底（清本套旧产物 → 编译 → initrd → 四包 → 镜像）
./x96max/full/rebuild-from-zero.sh
./x96max/trim/rebuild-from-zero.sh

# 或者分步（示例：裁剪套）
./x96max/trim/preflight.sh                     # 只读自检
./x96max/trim/build-kernel.sh                  # 只编，看 rc/耗时
./x96max/trim/pack-kernel.sh --stage           # 打四包并放进 ophub 目录
./x96max/trim/build-image.sh                   # 只出镜像
sudo ./x96max/flash-p1.sh                       # 换到 U 盘 p1 试跑（X96_KNAME 选哪套）

# 注意：ophub 的 -k 只认版本号，两套包共用 kernel/stable/7.2.12，
# 出镜像前 build-image.sh 会自动把本套包同步进去（另一套的会被清掉，包仓里都还在）。
```

## 3. 常用命令

```bash
# 只改配置后快速验证（不带 --mode 默认 full）
./x96max/build-kernel.sh
./x96max/build-kernel.sh --trim

# 换 initrd / 重打包 / 只做镜像
./x96max/rebuild-from-zero.sh --from initrd --mode trim
./x96max/pack-kernel.sh --trim
./x96max/rebuild-from-zero.sh --from image --mode trim

# 写卡与校验
sudo ./x96max/write-card.sh /x96-build/recovery/x96-full-autoinstall.img.gz /dev/sdb
sudo ./x96max/write-card.sh /x96-build/recovery/x96-trim-autoinstall.img.gz /dev/sdb
sudo ./x96max/backup-card.sh /dev/sdb
sudo ./x96max/verify-card.sh ~/x96-backup/usb-stick-XXXX /dev/sdb

# 只改卡上的启动参数（不重写分区）
sudo ./x96max/patch-bootargs.sh -l                    # 看当前 APPEND
sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678   # U 盘读一半掉线时先加保险
```

> 盒子从 U 盘起不来、串口里是 `reset ... high-speed` + `cmd_age=30s` + `hostbyte=0x03`，
> 那是链路超时不是卡坏（PC 上校验全绿即可排除卡）。排查顺序见 `../X96max.md` §10.2.2：
> 换蓝色 USB3 口直插 → 有源 HUB → `--usb-fix` → 改走 microSD。

### 源码树只有一份「必须存在」的

- **full**：不保留全量树。`src-full` 缺席时 `x96_ensure_src` 用
  `tar -xJf /opt/linux/src/linux-7.2.12.tar.xz --strip-components=1` 现解压（实测 **9s / 1.8G**），
  编完可 `--clean-src` 删掉；下次再编自动重解。旧的 `/x96-build/src-linux` 是被削过的树
  （无 `Documentation`、只剩 arm64 等，38k 文件 vs 完整 95k），已不默认使用，要它请显式 `X96_KSRC`。
- **trim**：源码树**真删过**（`trim-tools/prune_src.py --apply`：删无用驱动/文档，`Kconfig` 全部从源码包补回，
  所以符号定义不会随目录消失）。现役 `/x96-build/7.2.12-trim`：**782M / 50553 文件**，顶层 45 项、
  `Documentation` 只剩 24K、`drivers` 142 个目录——比原版 1.4G/95k 文件小一半。
  目录名不写死：`x96_pick_trim_src` 依次找 `src-trim` → `src-clean` → `7.2.12-trim` → `7.2.12-src`，
  取第一个带 `Makefile` 的（旧文档写的 `src-clean` 这台机器上从没落盘，trim 模式因此一直报「缺源码树」）。
  删了用 `kernel/gen-trim.sh` 重生成，或解压后跑 `trim-tools/prune_src.py --apply`（会写 `<树>/.trimmed` 标记）。

**裁剪审计闸**：`prune_src.py` 删目录时会把 `obj-$(CONFIG_X) += dir/` 改成空 RHS，
若符号还 `=y` 就是静默丢代码，症状迟到大链接期（undefined reference）才爆。
所以 `MODE=trim` 的 `build-kernel.sh` / `rebuild-from-zero.sh` 在解包后**先跑**
`tools/trim/audit_stubs.py`（`KTREE=$KSRC KCFG=$CFG`），非 0 直接中止，不会白编一轮。
补回：`python3 tools/trim/audit_stubs.py --restore`；确知无害时 `X96_SKIP_AUDIT=1` 跳过。

## 4. 公共环境变量（各脚本都认，默认值都在 `lib/mode.sh`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/x96-build` | 构建工作区 |
| `X96_CFG_MODE` | `full` | 选哪一套：`full`（完整源码树）/ `trim`（裁剪版）；`full/*.sh`、`trim/*.sh` 就是设它 |
| `X96_KSRC` | full→`src-full` / trim→自动找（`src-trim`/`src-clean`/`7.2.12-trim`） | 源码树；**full 不常驻**，缺席时从 `X96_SRC_XZ` 现解压 |
| `X96_SRC_XZ` | `/opt/linux/src/linux-7.2.12.tar.xz` | 完整源码包（full 的解压源）|
| `X96_CLEAN_SRC` | `0` | `1` = 编完删掉解压出来的 `src-full`（省 1.8 G，下次自动再解）|
| `X96_KNAME` | full→`7.2.12-x96` / trim→`7.2.12-x96-trim` | 内核版本名（= `CONFIG_LOCALVERSION` + `7.2.12`）|
| `X96_KOUT` | full→`kbuild-7.2.12` / trim→`kbuild-trim` | O= 输出目录 |
| `X96_CFG` | `kernel/config-7.2.12-x96-<mode>` | 配置文件 |
| `X96_PKGS` | `$X96_BUILD_ROOT/pkgs/<mode>` | 本套四件套包仓 |
| `X96_BASE_IMAGE` | Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img | 基础镜像 |
| `X96_ROOT_LABEL` | `ROOTFS` | `flash-p1.sh` / `patch-bootargs.sh` 按 label 定位卡的 rootfs 分区（默认，换卡不用改）|
| `X96_ROOT_UUID` | 空 | 可选：按 UUID 精确定位（同 label 多张卡时区分）|

## 5. 还缺的（待补，见对话记录）

- ~~`_env.sh`~~：已由 `lib/mode.sh` 完成（两套参数唯一出处）。
- `build-rootfs.sh`：§16.1 源码 rootfs 构建目前还是手敲 `armbian-build/compile.sh` + `config-x96-source.conf`。
- `preflight.sh`：依赖自检（gcc/qemu/mkimage/zstd/parted/sudo、`/opt/linux/src` 已删的坑）。
- `postinstall-check.sh`：§19.8 安装后验证清单（启动项、网络、eMMC 分区、模块数）仍是手工。
- `rollback.sh`：§19.9 回滚（回到 U 盘启动 / 恢复 base 分区表）没脚本化。
- `dtb-fix.sh`：`dtbhs` 变体、USB 相关 dtb 改动目前是手工编辑 + 手工 `cp`。
- `serial-log.sh`：串口抓启动日志（`/dev/ttyUSB0` 115200）目前还是手工 `picocom`，掉盘/黑屏排查看的都是这份输出。
- `release.sh`：产物归档（img + 四包 + sha256 + 版本 README）尚未自动。
