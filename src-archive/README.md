# src-archive — 内核源码快照

直接可玩的 Linux 7.2.12 源码树，解包即用，不必自己跑裁剪流程。两份快照，各对应一个真机内核：

| 文件 | 大小 | 对应内核 | 说明 |
|---|---|---|---|
| `linux-7.2.12-hwreal-src-20261111.tar.zst` | 68.9 MB | `7.2.12-20261111-hwreal` | 本机装机内核的裁剪树，32195 文件，解包 510 MB |
| `linux-7.2.12-sandy-dbg2-src-20261112.tar.zst` | 77.2 MB | `7.2.12-sandy-dbg2-20261111` | 小机箱追踪/调试内核，33007 文件，解包 516 MB |
| `SHA256SUMS` | 173 B | — | 两个包的校验值 |

```bash
sha256sum -c SHA256SUMS
tar --zstd -xf linux-7.2.12-hwreal-src-20261111.tar.zst     # 或 sandy-dbg2 那个
cd linux-7.2.12
make -j6                     # 两份包的 .config 都已就位
```

已清空构建产物（`.o` / `.ko` / `.mod` / `.mod.c` / `.*.cmd` / `vmlinux` / `System.map` /
`Module.symvers` / `modules.order` / `include/config` / `include/generated`），纯源码；
`.config` 保留，与 `/boot/config-7.2.12-20261111-hwreal` 逐字节一致，可直接 `make -j6`。

## 来路（hwreal 包）

| 项 | 值 |
|---|---|
| 上游 | `linux-7.2.12.tar.xz` |
| 上游 SHA256 | `bb18468a8dc8978aa00caa6446e753f7b6da3fee56b6b7f38b16f9430ba02d4f` |
| 裁剪规则 | `../tools/trim/rules.txt` |
| 禁用符号 | `../tools/trim/disable.list`（2265 个） |
| 基线配置 | `../notes/.config.before-trim`（6717 个 =y/=m 符号） |
| 配置规模 | 3310 个 `CONFIG_` 行（`=y` 2243、`=m` 924），`CONFIG_LOCALVERSION="-20261111-hwreal"` |

压缩比：510 MB → 68.9 MB（7.4×，zstd -19，56 s）。

## 与上一版快照的区别

上一版 `linux-7.2.12-begin-src-20261110.tar.zst`（88.1 MB / 60202 个文件 / 解包 550 MB）已删除替换。
这一版更小，原因不是删了源码功能，而是：

- 后续裁剪把 `Documentation/`、`rust/`、`samples/` 三个实体目录删掉了；
- 清场时连带清掉了 `include/generated`、`arch/x86/include/generated` 等生成头与 `.*.cmd`
  （对照旧包共 28156 个条目），这些 `make` 时自动重建，不进快照。

## 来路（sandy-dbg2 包）

给 i5-2400 小机箱（192.168.1.68）编的追踪/调试内核源码树，`CONFIG_LOCALVERSION="-sandy-dbg2-20261111"`。

| 项 | 值 |
|---|---|
| 上游 | `linux-7.2.12.tar.xz`（同一份，SHA256 见上表） |
| 起点 | `x86_64_defconfig` → `configs/sandy-from-zero-20261111.fragment` |
| 叠加 | `configs/netfilter.fragment` → `configs/sandy-dbg-20261111.fragment` → `configs/sandy-dbg2-20261111.fragment` |
| 应用方式 | `tools/kernel/apply-fragment.sh <tree> <fragment>`（每步 `olddefconfig` 验收） |
| 完整配置 | `configs/config-7.2.12-sandy-dbg2-20261111`（133 KB，与本包内 `.config` 逐字节一致，也与目标机 `/boot/config-7.2.12-sandy-dbg2-20261111` 一致） |
| 配置规模 | `=y` 1616、`=m` 110 |
| 关键开关 | `FTRACE` / `TRACEPOINTS` / `KPROBE_EVENTS` / `UPROBE_EVENTS` / `DEBUG_INFO_BTF` / `BPF_SYSCALL` / `NF_TABLES` 全开 |

本包里除了 `.config` 还多留了一个 `defconfig`（`make savedefconfig` 出来的最小配置，1 KB 级），
当"只想知道开了哪些非默认项"的索引看，比啃 133 KB 的 `.config` 快。

压缩比：516 MB → 77.2 MB（6.7×，zstd -12 -T6，5 s）。归档可复现：`--sort=name --owner=0 --group=0
--numeric-owner --mtime='2026-11-12 00:00:00'`。

**验证**（删原树前做的，不是嘴上说）：

```bash
tar --zstd -xf ... && cd linux-7.2.12
sha256sum .config      # cea17a14… == configs/config-7.2.12-sandy-dbg2-20261111 == 目标机 /boot/config
make -j6 olddefconfig  # rc=0
make -j6 prepare       # rc=0，objtool / resolve_btfids 正常编出
make -j6 fs/ext4/namei.o kernel/sched/core.o drivers/net/ethernet/realtek/r8169_main.o   # rc=0
```

## 已知坑：`make clean` / `mrproper` 会报错

`Documentation/`、`rust/` 被删后，`scripts/Makefile.clean` 仍会按 makefile 里的目录列表 descend 进去，于是：

```
scripts/Makefile.clean:12: rust/Makefile: 没有那个文件或目录
make[3]: *** 没有规则可制作目标"rust/Makefile"。 停止。
make: *** [Makefile:248: __sub-make] 错误 2
```

而且它**在 `rust/` 处就中断**，后面的目录全没清——这正是本树 `make clean` / `make mrproper`
看上去"能跑但不删 `.o`"的真正原因。要真清场，别依赖 make，用 `../tools/trim/clean-build.sh`
（它先 `make mrproper || true`，再 `find -name '*.o' -delete` 兜底），或者：

```bash
find . \( -name '*.o' -o -name '*.ko' -o -name '*.a' -o -name '.*.cmd' -o -name '*.mod' \
        -o -name '*.mod.c' -o -name 'modules.order' \) -type f -delete
rm -rf include/config include/generated arch/x86/include/generated
```

**正常构建不受影响**（`CONFIG_RUST` 关闭，`make -j6` 全程无错），只有 clean 系列会踩。

## 想自己复现

```bash
cd ../tools/trim
python3 plan.py            # 按 rules.txt 生成 disable.list
# 然后在源码树内按 disable.list 关掉对应 CONFIG，再 make
```

完整流程见仓库根 `README.md` 与 `docs/trim.md`。

## 为什么是整棵源码而不是补丁

补丁方式要求使用者先下载 153 MB 上游 tarball 再打补丁，且内核目录裁剪会删掉实体子目录，补丁极易因上下文不匹配而失败。整树快照多花 69 MB，换「解包就能编译」。
