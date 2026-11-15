# 源码树裁剪记录（/x96-build/7.2.12-trim）

## 0. 环境

| 项 | 值 |
|---|---|
| 目标树 `KTREE` | `/x96-build/7.2.12-trim`（裁前 **1783 MB / 94775 文件**） |
| 源包 | linux-7.2.12.tar.xz（上游 7.2.12） |
| config `KCONFIG` | `~/kernel/x96max/kernel/config-7.2.12-x96-full`（180029 B） |
| 工具 | `/x96-build/trim-tools` → `~/kernel/x96max/trim-tools`（`prune_src.py` / `fix_sources.py` / `fix_makefiles2.py`，判据单点在 `~/kernel/tools/trim/trimlib.py`） |
| 规则 `RULES` | `trim-tools/rules.txt`（469 行：`KILL` / `FORCEKILL` / `PROTECT`） |
| 补回源 `KTREE_ORIG` | **改用 `/x96-build/.trim-orig`**（从同一 tar.xz 抽出的 6 处切片）。原默认 `/opt/linux/src/linux-7.2.12` 在本机**不存在**，而 `prune_src.py --apply` 必须从它补回。 |
| 时间 | 2026-11-15 19:46 CST |

判据（`trimlib.judge`，任一命中即保留）：① 目录 Makefile 的 `CONFIG_*` ∩ config `=y/=m`；② 父 Makefile
`obj-$(CONFIG_X) += dir/` 且 X 在 config 里 `=y`；③ `rules.txt` 的 `PROTECT`（只删代码留头文件的目录）。
三者都不命中才删。`FORCEKILL` 跳过判据直接删，删完按 `restore.txt` 补回。

## 1. 谁可以裁减（23 个目录，逐项列依据）

`prune_src.py` dry-run：**可删 23 个，合计 328 MB / 3906479 行**；另 323 个候选目录因仍有活符号保留（见 §1.2）。

判定链：`trimlib.judge` 三层判据（①目录 Makefile 的 `CONFIG_*` ∩ config `=y/=m`；②父 Makefile
`obj-$(CONFIG_X) += dir/` 且 X 在 config 里 `=y`；③`rules.txt` 的 `PROTECT`）任一命中即保留；
`rules.txt` 里的 `FORCEKILL`/`KILL` 有否决权（先删，再按 `restore.txt` 补回切片）。

### 1.1 待删清单

| # | 体积 | 行数 | 目录 | 谁判定可裁 | 补回/注意事项 |
|---|---|---|---|---|---|
| 1 | 8M | 156110 | `rust` | rules.txt `FORCEKILL rust`（顶层 Makefile clean 目标引用 rust/libmacros.so → 整删+整目录补回） | 整目录补回 7.1M/585 |
| 2 | 103M | 1418891 | `tools` | rules.txt `KILL tools`（scripts/Makefile 只要 tools/include，其余 1400 万行全删） | 补回 `tools/include` 2.0M/255 |
| 3 | 5M | 84154 | `arch/sh` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 4 | 2M | 26885 | `arch/arc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 5 | 39M | 288892 | `arch/arm` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/arm/boot/dts` 27M/2916 |
| 6 | 17M | 473371 | `arch/x86` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/x86/entry/syscalls` 44K/3 |
| 7 | 1M | 14134 | `arch/csky` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 8 | 7M | 152577 | `arch/m68k` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 9 | 13M | 292211 | `arch/mips` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 10 | 5M | 118487 | `arch/s390` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 11 | 3M | 53339 | `arch/alpha` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 12 | 1M | 9183 | `arch/nios2` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 13 | 5M | 68489 | `arch/riscv` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | 补回 `arch/riscv/boot/dts` 1.2M/130 |
| 14 | 5M | 123602 | `arch/sparc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 15 | 3M | 63928 | `arch/parisc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 16 | 2M | 32845 | `arch/xtensa` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 17 | 1M | 10105 | `arch/hexagon` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 18 | 18M | 439820 | `arch/powerpc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 19 | 1M | 11409 | `arch/openrisc` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 20 | 84M | 1031 | `Documentation` | rules.txt `KILL Documentation`（build/clean/Image 均不读；`dt_binding_check` 才读 yaml） | 另需删顶层 Makefile:1332 `clean-dirs` 里的 Documentation，否则 `make clean` 直接 Error 2；代价：`make htmldocs`/`dt_binding_check` 不可用 |
| 21 | 3M | 49580 | `arch/loongarch` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 22 | 1M | 13778 | `arch/microblaze` | rules.txt `FORCEKILL`（第 2 轮，证据 logs/timed-0058.log：`arch/*` 只出现 `arch/arm64` 689 次，其他 0 次；judge 被 `CONFIG_64BIT=y` 误判） | — |
| 23 | 1M | 3658 | `drivers/block/aoe` | rules.txt `KILL drivers/block/aoe`（config 无 CONFIG_ATA_OVER_ETH） | 无外部引用（ATA over Ethernet，config 里 CONFIG_ATA_OVER_ETH 未开） |

**小计：23 个目录 / 328 MB / 3906479 行**；其中 `rules.txt` 显式指定 23/23（20 个 arch + rust + tools + Documentation + aoe），纯自动判据得出的 0 个——即本轮每一刀都有人工确认过。

> `rules.txt` 的对应行：`FORCEKILL` 424–465、`KILL tools` 464、`KILL Documentation` 469、
> `KILL drivers/block/aoe` 12。20 个非 arm64 架构同属一条人工结论。

### 1.2 被保留的 323 个候选（有活符号，不能整删）

| 保留原因 | 数量 | 说明 |
|---|---|---|
| 目录 Makefile 出现 `=y/=m` 的 `CONFIG_*` | 51 | 判据①命中，例：`fs/fat` 4 个 `=y/=m` 符号 |
| Kconfig 归属的 `=y/=m` 符号 | 2 | 判据①变体 |
| 父 Makefile `obj-$(CONFIG_X) += dir/`，config 里没有 X | 213 | 判据②只认父 Makefile 字面；X 不在 config 时仍保留（保守），典型：`fs/9p`、`fs/ext2`、`fs/xfs`、`net/9p` |
| 其它（Makefile 引用 `COMPAT`/`SYSCTL` 等 =y 符号） | 57 | 例：`fs/nfs`、`fs/fuse`、`fs/xfs` |

这 213 + 57 项是**下一轮的真实增量空间**：它们要么靠 config 里根本不存在的 CONFIG、
要么靠 `obj-$(COMPAT)` 这类非配置符号被粘住，需要逐个人工确认后才能进 `FORCEKILL`。

## 2. `--apply` 后必须补回的 6 处切片（restore.txt，42 MB）

| 体积 | 切片 | 谁硬引用它 |
|---|---|---|
| 27M | `arch/arm/boot/dts` | arm64 allwinner dtsi 跨架构 `#include <arm/allwinner/sunxi-h3-h5.dtsi>`（`make dtbs`） |
| 8M | `rust` | 顶层 Makefile clean 目标列了 `rust/libmacros.so` |
| 2M | `arch/um` | `fs/Makefile` 无条件 `obj-y += hostfs/`，`fs/hostfs/Makefile` 末行 include |
| 2M | `tools/include` | `scripts/Makefile:32-38` 给 `elf-parse.o`/`sorttable.o` 加 `-I$(srctree)/tools/include` |
| 2M | `arch/riscv/boot/dts` | arm64 `sophgo/sg2000.dtsi` include `riscv/sophgo/cv180x.dtsi` |
| 1M | `arch/x86/entry/syscalls` | `scripts/checksyscalls.sh` 读 `syscall_32.tbl` |

**净体积预估 = 328 MB − 42 MB = 286 MB** → 树应从 1783 MB 降到约 1497 MB。

## 3. 执行步骤

1. 从 tar.xz 抽出 6 处切片到 `/x96-build/.trim-orig`（充当 `KTREE_ORIG`）；
2. `KTREE=/x96-build/7.2.12-trim KTREE_ORIG=/x96-build/.trim-orig ./prune_src.py --apply`
   （删 23 目录 + 清父 Kconfig 的 `source` 行 + 补回 6 切片）；
3. `./fix_sources.py`（清指向已删目录的 `source` 行，含 `$` 变量的行跳过）；
4. `./fix_makefiles2.py`（按逻辑行削父 Makefile 里 `obj-* += 已删目录/`，否则 kbuild 直接失败）；
5. `KILL Documentation` 还要删顶层 `Makefile` 的 `clean-dirs` 那一项，否则 `make clean` 报
   `scripts/Makefile.clean:12: Documentation/Makefile: 没有那个文件或目录`；
6. 复跑 dry-run 验证：去掉 `FORCEKILL` 项后应「可删 0 个」，净体积 ≈ 0。

## 4. 实测结果

（`--apply` 之后补填）
