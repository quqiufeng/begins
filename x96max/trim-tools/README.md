# x96 源码树裁剪工具

配套文档：`~/kernel/X96max.md` **§5 源码树裁剪**（口径与四条规矩在那儿，这里只讲脚本怎么用）。

口径是 **Amlogic S905X2 盒子（arm64 交叉编译）**，不动 config、只删代码；主机 `~/kernel/tools/trim/`
那套是 `begin` 内核（改 config + 真机启动断言）。**判据单点在 `tools/trim/trimlib.py`**：
本目录的 `plan.py`/`prune_src.py` 都是薄壳（只定默认树路径 + 自己的 `rules.txt`），
`_trimpath.py` 通过 `realpath` 把 `../..` 找回去 import 它——所以两边**只有 `rules.txt` 该不同**，
改判据改 `trimlib.py` 一处，别在本目录复制逻辑。
`/x96-build/trim-tools` 是指向本目录的软链，老命令不用改（`_trimpath.py` 用 realpath，软链下也能找到 trimlib）。

## 环境

| 变量 | 默认 | 说明 |
|---|---|---|
| `KTREE` | `/x96-build/src-linux` | 被裁剪的源码树（原版 `/opt/linux/src/linux-7.2.12` 保持不动） |
| `KTREE_ORIG` | `/opt/linux/src/linux-7.2.12` | 补回切片的来源（`--apply` 只从这里读，不写） |
| `RESTORE` | 本目录 `restore.txt` | `--apply` 之后要拷回的切片清单，一行一个目录（见坑 4） |
| `RULES` | 本目录 `rules.txt` | `KILL <目录前缀>` / `FORCEKILL <目录前缀>`（跳过 `judge()` 直接删，只给「目标架构固定、编译日志里 0 命中」的目录）/ `PROTECT <目录>`（注意没有 `KEEP`，`read_rules()` 只认这三个） |
| `KCONFIG` | `<tree>/.config` → `x96max/kernel/config-7.2.12-x96-full` | 本机是 out-of-tree 构建，`src-linux` 里没有 `.config`，自动回退 |
| `SYM2KC` | `/tmp/sym2kc.tsv` | Kconfig 符号表，缺失时 `trimlib.sym2kc()` 自己扫树重建（`sym2kc.py` 只是它的命令行壳） |

## 用法（顺序）

```bash
cd ~/kernel/x96max/trim-tools
./sym2kc.py                                    # (可选) 建 /tmp/sym2kc.tsv，缺了会自动重建
./plan.py                 > /tmp/plan.txt      # 按 rules.txt 算出该 disable 的 CONFIG（只打印，不动树）
./prune_src.py            [--apply]            # 删「已没人用」的源码目录 + 清父 Kconfig 的 source 行
                                                # --apply 末尾按 restore.txt 补回 6 处硬引用切片
./fix_sources.py                               # 清掉指向已删目录的 source 行（含 $ 变量的行跳过）
./fix_makefiles2.py                            # 按逻辑行削父 Makefile 里指向已删目录的 obj-* 项
```

验证顺序固定（跳步会得到误导性的错误）：

```bash
cd /x96-build/src-linux
make O=/x96-build/kbuild-7.2.12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean      # 先暴露缺 Makefile
make O=/x96-build/kbuild-7.2.12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- syncconfig
make -j6 O=/x96-build/kbuild-7.2.12 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
grep -c 'undefined reference' 编译日志                                                  # 链接期才算数
```

## `prune_src.py` 的三层判据

**不能按目录名删 `=y` 子系统**，也**不能拿「符号 → 定义它的 Kconfig 所在目录」判归属**：
`NET_DEVLINK`/`ETHTOOL_NETLINK` 定义在 `net/Kconfig`、`DVB_CORE` 在 `drivers/media/Kconfig`、
`CGROUPS`/`PERF_EVENTS` 在 `init/Kconfig`，按归属算这些目录**永远 0 个活符号**。
所以任一命中即保留，三层都不命中才删（代码在 `~/kernel/tools/trim/trimlib.py:judge`，两个仓库共用这一份）：

1. **目录 Makefile** 的 `CONFIG_*` ∩ config 的 `=y/=m` —— 命中例：`net/sched`(INET)、`net/ethtool`(ETHTOOL_NETLINK)。
2. **父 Makefile** 的 `obj-$(CONFIG_X) += <dir>/` 且 X 在 config 里 `=y` —— 命中例：`net/devlink`
   （它自己的 Makefile 整份 `obj-y :=`，不带任何 CONFIG，活得由 `net/Makefile:26` 决定）。
3. **`rules.txt` 的 `PROTECT <dir>`** —— 给只被 `#include` 头文件的目录：`fs/squashfs`、`net/bridge`。

对**没加 `FORCEKILL` 的目录**，已裁剪过的树跑 dry-run 应得「可删 0 个」；出非 0 就是判据又漏了，别 `--apply`。
`FORCEKILL` 目录（20 个非 arm64 架构 + `Documentation`/`tools`/`rust`）按定义**永远**列在「可删」里，
所以看最后一行 **`净体积`**：≈0 就说明这棵树已是裁剪后的稳态（删掉的那些本来就要补回/本来就不在）。

## 四个必读坑

1. **`obj-y += 已删目录/` 会让 kbuild 直接失败**，必须用 `fix_makefiles2.py` 同步父 Makefile；
   它按逻辑行（`\` 续行）削尾部 token，删完只剩 `obj-$(X) +=` 就丢整句。
2. 误删 `=y` 子系统（`net/ethtool`、`net/sched`、`net/devlink`、`drivers/media/dvb-core`、
   `kernel/cgroup`、`kernel/events`）时**编译期全绿**，只有链接期炸 —— 本次 **238 条 `undefined reference`**。
3. **被无条件 `#include` 头文件的目录只删代码、留 `*.h`**，并补空的 `Makefile` + `Kconfig`
   （缺这两个文件会让 `make clean` / `syncconfig` 提前中断）：`fs/squashfs`、`net/bridge`。
4. **`FORCEKILL` 是「整删再按 `restore.txt` 补切片」，不是「留着」**：`arch/um`(198 文件)、
   `arch/x86/entry/syscalls`(3)、`tools/include`(255)、`arch/arm/boot/dts`(2916)、`arch/riscv/boot/dts`(130)、
   `rust`(585) 六处在 `--apply` 删完后立刻从 `$KTREE_ORIG` `cp -a` 回来，表就是 `restore.txt`
   （每行上方写了谁引用它，日志行号在 `~/kernel/X96max.md` §5.3）。
   `KILL Documentation` 还必须同时删掉顶层 `Makefile` 的 `clean-dirs` 里那一项，否则 `make clean` 报
   `scripts/Makefile.clean:12: Documentation/Makefile: 没有那个文件或目录`。
   2026-11-15 08:33 实测 `--apply` 幂等：删 5 目录 + 补 6 切片后仍是 **545M / 37911 文件**，
   6 处切片与原树 `diff -r` 零差异。加条目的判据只有一条：**编译链在 `clean`/`syncconfig`/`dtbs`
   阶段硬引用它，而 `judge()` 看不见**。

## 两轮结果（2026-11-15）

| 轮次 | 源码树 | 干净全量 `-j6` | 日志 |
|---|---|---|---|
| 第一轮（判据收敛） | 1.8G/94777 → **821M / 69673（45%）** | rc=0，**526 s (8m46s)** | `logs/timed-0058.log` |
| 第二轮（删非 arm64 架构 + `Documentation`） | → **545M / 37911（27%）** | rc=0，**495 s (8m15s)** | `logs/timed-clean-0815.log` |

config 是 `config-7.2.12-x96-full`（当时副本名 `config-x96-20261115`）；`Image` 35.8 MB / `Image.gz` 13.3 MB / `vmlinux` 44.9 MB。
**两轮都只验证了「能编」，Image 尚未在盒子启动过。**

第二轮用 `FORCEKILL` 删掉 20 个非 arm64 架构目录（证据：`timed-0058.log` 里 `arch/*` 只有 `arch/arm64`
命中 689 次，其余为 0）与 `Documentation`（84M），但有 **6 处必须补回的硬引用**、**1 处必须同步改的 Makefile**，
缺任一都会在 `make clean` / `syncconfig` / `dtbs` 阶段直接断——清单、体积与症状见
`~/kernel/X96max.md` **§5.3「第二轮」表**；`rules.txt` 里每个 `FORCEKILL` 目录也标了要不要补切片。

## 待办

- ~~两边判据收敛~~ 已做（2026-11-15）：判据/解析/config 定位全搬进 `tools/trim/trimlib.py`，
  本目录与 `tools/trim/` 的 `plan.py`/`prune_src.py` 只留默认路径；主机树 dry-run 同样得「可删 0 个」
  （剩下的 `sound/atmel`、`drivers/video/fbdev/aty` 是空目录，0 文件）。
- `fix_sources.py`/`fix_makefiles.py` 本来就与判据无关（只清指向不存在目录的引用），两边仍是各自拷贝。
