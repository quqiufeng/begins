# x96max — X96 Max（S905X2 / meson-g12a）构建、打包、安装脚本总目录

所有自己写/改过的 sh 脚本都放这里；`/x96-build` 只当**构建工作区**（源码、产物、日志），
不再放脚本，原有路径已改为指向本目录的软链（`/x96-build/{pack-kernel,flash-p1,run-timed}.sh`）。

文档：`../X96max.md`（§19 是端到端流程，脚本注释里标的 §x.y 对应它）。

## 1. 脚本清单（按流水线顺序）

| 阶段 | 脚本 | 作用 |
|---|---|---|
| **开工** | `preflight.sh` | **只读自检 19 项**（源码树钩子三连 / 配置 `=y` / 两份配置同源 / 工具链 / 脚本可执行），全绿才开建，对应 `X96max.md` §0.2 第 0 步 |
| 环境 | `mkbase.sh` | 用源码 rootfs 造 rebuild 需要的基础镜像 `base-own.img`（2560M ext4 + base-boot-backup） |
| 裁剪 | `kernel/gen-trim.sh` → `kernel/x96-trim.fragment` | 从 `config-7.2.12-x96` 扫出激进裁剪 fragment（2896 个 `=m` → ~1100） |
| 裁剪 | `trim-tools/*.py` | 源码树裁剪工具箱（`prune_src.py` 删目录、`fix_makefiles*.py` 补 Makefile、`plan.py`、`sym2kc.py`），规则见 `trim-tools/rules.txt` |
| 编译 | `build-kernel.sh` | 只编内核（§19.3）：olddefconfig + Image + modules + dtb + modules_install，带计时、`rc`/`sec` 落盘（原 `/x96-build/run-timed.sh`） |
| initrd | —（在 `rebuild-from-zero.sh --from initrd`） | loop 挂 base → chroot qemu → `depmod` + `update-initramfs` → `mkimage` 出 uInitrd |
| 打包 | `pack-kernel.sh` | 只打四件套（§19.5）：boot/dtb/modules/header + `sha256sums`，输出到 `$ROOT/pkgs` |
| 镜像 | `build-image.sh` | ophub rebuild 出可刷镜像（rootfs 裁剪 + 注入首启 service），可 `--skip-rootfs`、`--write` |
| 镜像 | `rebuild-from-zero.sh` | 全流程 §19.3→§19.6，支持 `--from kernel|initrd|pkgs|image`、`--no-clean` |
| 写卡 | `write-card.sh` | 安全写整盘镜像 + 文件系统层校验（关 automount/udisks2，逐文件 sha256） |
| 写卡 | `flash-p1.sh` | 只把新 `Image` 写进已启动 U 盘 p1（按 rootfs UUID 定位父盘），快速试内核 |
| 写卡 | `patch-bootargs.sh` | 改卡上 p1 `uEnv.txt` 的 `APPEND`：幂等追加/删除内核参数，`--usb-fix VID:PID` 一键禁 UAS + 关 USB 自动挂起（§10.2.2）|
| 校验 | `verify-card.sh` | 卡 vs 备份镜像：两侧 `ro,noload` 挂载逐文件 sha256 对拍（不用裸盘 cmp） |
| 备份 | `backup-card.sh` | 把已验证可启动的卡备份成可还原镜像 |
| 安装 | `x96-autoinstall.sh` + `x96-autoinstall.service` | 首启自动 `armbian-install` 装到 eMMC（防 apt 吃 stdin、done 标记只在成功后写） |
| 配置 | `kernel/config-7.2.12-x96` | 实编归档的最终 .config |
| 配置 | `config-x96-source.conf` | armbian-build 的 rootfs 构建参数（BLOCK 列表在此） |

第三方工具（不是我们写的，别改）：`/x96-build/{armbian-build, amlogic-s9xxx-armbian, pyamlboot, radxa-aml, aml-flash-tool}`。

## 2. 常用命令

```bash
# 从零重建全套（约 10 分钟级）
./x96max/rebuild-from-zero.sh

# 只改配置后快速验证
./x96max/build-kernel.sh                       # 只编，看 rc/耗时
sudo ./x96max/flash-p1.sh                      # 换到 U 盘 p1 试跑

# 换 initrd / 重打包 / 只做镜像
./x96max/rebuild-from-zero.sh --from initrd
./x96max/pack-kernel.sh
./x96max/rebuild-from-zero.sh --from image

# 写卡与校验
sudo ./x96max/write-card.sh /x96-build/recovery/x96src-autoinstall.img.gz /dev/sdb
sudo ./x96max/backup-card.sh /dev/sdb
sudo ./x96max/verify-card.sh ~/x96-backup/usb-stick-XXXX /dev/sdb

# 只改卡上的启动参数（不重写分区）
sudo ./x96max/patch-bootargs.sh -l                    # 看当前 APPEND
sudo ./x96max/patch-bootargs.sh --usb-fix 346d:5678   # U 盘读一半掉线时先加保险
```

> 盒子从 U 盘起不来、串口里是 `reset ... high-speed` + `cmd_age=30s` + `hostbyte=0x03`，
> 那是链路超时不是卡坏（PC 上校验全绿即可排除卡）。排查顺序见 `../X96max.md` §10.2.2：
> 换蓝色 USB3 口直插 → 有源 HUB → `--usb-fix` → 改走 microSD。

## 3. 公共环境变量（各脚本都认）

| 变量 | 默认 | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/x96-build` | 构建工作区 |
| `X96_KSRC` | `$X96_BUILD_ROOT/src-linux` | 裁剪后的源码树（545M）|
| `X96_KNAME` | `7.2.12-x96` | 内核版本名（`LOCALVERSION`）|
| `X96_KOUT` | `$X96_BUILD_ROOT/kbuild-7.2.12` | O= 输出目录 |
| `X96_BASE_IMAGE` | Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img | 基础镜像 |
| `X96_ROOT_LABEL` | `ROOTFS` | `flash-p1.sh` / `patch-bootargs.sh` 按 label 定位卡的 rootfs 分区（默认，换卡不用改）|
| `X96_ROOT_UUID` | 空 | 可选：按 UUID 精确定位（同 label 多张卡时区分）|

## 4. 还缺的（待补，见对话记录）

- `_env.sh`：把上面这些默认值收敛到一处，现在每个脚本各写一遍，改版本号要逐个改。
- `build-rootfs.sh`：§16.1 源码 rootfs 构建目前还是手敲 `armbian-build/compile.sh` + `config-x96-source.conf`。
- `preflight.sh`：依赖自检（gcc/qemu/mkimage/zstd/parted/sudo、`/opt/linux/src` 已删的坑）。
- `postinstall-check.sh`：§19.8 安装后验证清单（启动项、网络、eMMC 分区、模块数）仍是手工。
- `rollback.sh`：§19.9 回滚（回到 U 盘启动 / 恢复 base 分区表）没脚本化。
- `dtb-fix.sh`：`dtbhs` 变体、USB 相关 dtb 改动目前是手工编辑 + 手工 `cp`。
- `serial-log.sh`：串口抓启动日志（`/dev/ttyUSB0` 115200）目前还是手工 `picocom`，掉盘/黑屏排查看的都是这份输出。
- `release.sh`：产物归档（img + 四包 + sha256 + 版本 README）尚未自动。
