# x96 源码树裁剪工具

配套文档：`~/kernel/X96max.md` **§5 源码树裁剪**（口径与四条规矩在那儿，这里只讲脚本怎么用）。

和 `~/kernel/tools/trim/` 不是同一套：那套是主机 `begin` 内核（改 config + 真机启动断言），
这套是 **Amlogic S905X2 盒子（arm64 交叉编译）**，口径是「不动 config，只删代码」。
`plan/prune_src/fix_sources/fix_makefiles` 四个脚本与 `tools/trim/` 同源，
**差别在 `rules.txt`（按 x96 的 config 核对）和 `fix_makefiles2.py` / `sym2kc.py`（这套独有，判据也升级了）**。
`/x96-build/trim-tools` 是指向本目录的软链，老命令不用改；**改脚本只改这里**，否则两边分叉。

## 环境

| 变量 | 默认 | 说明 |
|---|---|---|
| `KTREE` | `/x96-build/src-linux` | 被裁剪的源码树（原版 `/opt/linux/src/linux-7.2.12` 保持不动） |
| `RULES` | 本目录 `rules.txt` | `KILL <目录前缀>` / `KEEP <CONFIG 符号>` / `PROTECT <目录>` |
| `KCONFIG` | `<tree>/.config` → `/x96-build/config-x96-trimmed` | 本机是 out-of-tree 构建，`src-linux` 里没有 `.config`，自动回退 |
| `SYM2KC` | `/tmp/sym2kc.tsv` | Kconfig 符号表，`/tmp` 被清后 `plan`/`prune_src` 会自动重跑 `sym2kc.py` |

## 用法（顺序）

```bash
cd ~/kernel/x96max/trim-tools
./sym2kc.py                                    # (可选) 建 /tmp/sym2kc.tsv，缺了会自动重建
./plan.py                 > /tmp/plan.txt      # 按 rules.txt 算出该 disable 的 CONFIG（只打印，不动树）
./prune_src.py            [--apply]            # 删「已没人用」的源码目录 + 清父 Kconfig 的 source 行
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
所以任一命中即保留，三层都不命中才删：

1. **目录 Makefile** 的 `CONFIG_*` ∩ config 的 `=y/=m` —— 命中例：`net/sched`(INET)、`net/ethtool`(ETHTOOL_NETLINK)。
2. **父 Makefile** 的 `obj-$(CONFIG_X) += <dir>/` 且 X 在 config 里 `=y` —— 命中例：`net/devlink`
   （它自己的 Makefile 整份 `obj-y :=`，不带任何 CONFIG，活得由 `net/Makefile:26` 决定）。
3. **`rules.txt` 的 `PROTECT <dir>`** —— 给只被 `#include` 头文件的目录：`fs/squashfs`、`net/bridge`。

对**已裁剪过的树**跑 dry-run 应得「可删 0 个」；出非 0 就是判据又漏了，别 `--apply`。

## 三个必读坑

1. **`obj-y += 已删目录/` 会让 kbuild 直接失败**，必须用 `fix_makefiles2.py` 同步父 Makefile；
   它按逻辑行（`\` 续行）削尾部 token，删完只剩 `obj-$(X) +=` 就丢整句。
2. 误删 `=y` 子系统（`net/ethtool`、`net/sched`、`net/devlink`、`drivers/media/dvb-core`、
   `kernel/cgroup`、`kernel/events`）时**编译期全绿**，只有链接期炸 —— 本次 **238 条 `undefined reference`**。
3. **被无条件 `#include` 头文件的目录只删代码、留 `*.h`**，并补空的 `Makefile` + `Kconfig`
   （缺这两个文件会让 `make clean` / `syncconfig` 提前中断）：`fs/squashfs`、`net/bridge`。

## 本轮结果（2026-11-15）

树 1.8G / 94777 文件 → **821M / 69673 文件（45%）**；`config-x96-trimmed` 干净全量 `-j6`
**526 s（8m46s）rc=0**，`Image` 35.9 MB / `vmlinux` 44.9 MB。
**只验证了「能编」，Image 尚未在盒子启动过。**

## 待办

- `tools/trim/` 那套还留着旧的一层判据（`plan.py`/`prune_src.py` 的 `Kconfig` 归属 + 硬编码 `/tmp/sym2kc.tsv`），
  两边该收敛成同一套判据（主机那套同样会踩 `net/devlink` 这类父 Kconfig 定义）。
