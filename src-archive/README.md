# src-archive — 内核源码快照

直接可玩的 Linux 7.2.12 源码树，解包即用，不必自己跑裁剪流程。三份快照，各对应一个真机内核：

| 文件 | 大小 | 对应内核 | 说明 |
|---|---|---|---|
| `linux-7.2.12-hwreal-src-20261111.tar.zst` | 68.9 MB | `7.2.12-20261111-hwreal` | 本机装机内核的裁剪树，32195 文件，解包 510 MB |
| `linux-7.2.12-sandy-dbg2-src-20261112.tar.zst` | 77.2 MB | `7.2.12-sandy-dbg2-20261111` | 小机箱追踪/调试内核，33007 文件，解包 516 MB |
| `linux-7.2.12-trim-src-20261116.tar.zst` | 91.3 MB | `7.2.12-x96-trim` | 同上并含 10bit HEVC / STOP 死锁修复源码，**最新**，50438 条目 |
| `SHA256SUMS` | 323 B | — | 上面三份包的校验值 |

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
| 叠加 | `configs/netfilter.fragment` → `configs/sandy-dbg-20261111.fragment` → `configs/sandy-dbg2-20261111.fragment`（**该 fragment 已于 2026-11-14 删除**，dbg3 的重导出片段见 `configs/sandy-dbg3-20261114.fragment`；本包内容不受影响，`.config` 快照仍在 git 03c3419） |
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

## 来路（trim 包 20261115 — 压缩包已删除，只留记录）

`/x96-build/7.2.12-trim` 的快照，`CONFIG_LOCALVERSION="-x96-trim"`，留作下一轮裁剪的起点。
它本身是 x96 出树构建（`O=/x96-build/kbuild-trim`）的源码树，树内**没有** `.config`；
构建产物只剩 3 个就地生成的残留（`scripts/module.lds`、`scripts/mod/devicetable-offsets.h`、
`scripts/mod/elfconfig.h`），`make` 会覆盖重建，无需手工清。

| 项 | 值 |
|---|---|
| 状态 | **2026-11-16 删除**（`rm`，腾 91.3 MB）。内容与 `20261116` 包只差 9.8 KB，源树 `/x96-build/7.2.12-trim` 仍在，需要时可重打 |
| 打包命令 | `tar -C /x96-build --transform 's,^7\.2\.12-trim,linux-7.2.12,' --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-11-15 00:00:00' -cf - 7.2.12-trim \| zstd -19 -T6` |
| 压缩比 | 750 MB → 91.3 MB（8.2×，zstd -19 -T6，91 s） |
| 内容 | 50437 条目 = 47248 常规文件 + 3167 目录 + 22 符号链接（其中 11 个是 `scripts/dtc/include-prefixes/*` 的悬空链接，上游本身如此） |
| 配置 | 包内无 `.config`（与另两个包不同）。权威副本在仓库 `configs/config-7.2.12-x96-trim-final-20261115`（223939 B，git `f0a7fd9`），与本包对应的 `/x96-build/kbuild-trim/.config` 逐字节一致（SHA256 `c4c802d5d9a3f68b7a07636cc9a863f81962aabd6f17fb06d1fe2dbd0996482a`）。解包后 `cp ../../configs/config-7.2.12-x96-trim-final-20261115 .config` 即可 |
| 裁剪标记 | `.trimmed`（`pruned 2026-11-15 21:02:58  dirs=15`）与 `.trim-drivers-removed-20261115.txt` 一并保留 |

与上游全量源码树（`/x96-build/src-pristine`，101078 条目 / 1783 MB）的**实测**差异：

| 顶层目录 | 条目 pristine → trim | |
|---|---|---|
| `Documentation` | 12037 → 6 | 只留 `Kconfig` 相关骨架 |
| `tools` | 10403 → 335 | 仅留构建必需的 `objtool`/`bpf`/`build` 等 |
| `arch` | 19456 → 4221 | 非 x86/arm64 架构分支 |
| `drivers` | 39971 → 27528 | 大量二/三级目录被削到只剩 `Kconfig`+`Makefile` 骨架（`xen` 79→2、`vdpa` 57→2、`thunderbolt` 41→2），另有 4 个顶层目录整体删除（`dio` `nubus` `ps3` `tc`，共 4 MB） |
| `fs` | 2468 → 1846 | 未用文件系统 |
| `net` | 1994 → 1764 | |
| `sound` | 3169 → 3152 | |
| `scripts` | 770 → 773 | 多出的 3 个是就地残留的生成物 `mod/devicetable-offsets.h`、`mod/elfconfig.h`、`module.lds`，`make` 会重建 |

注：`.trimmed` 记的 `dirs=15` 是当时 `prune_src.py` 那一次运行写下的数，与上面逐目录实测对不上，**以实测为准**。
`.trim-drivers-removed-20261115.txt` 列了 58 个候选 drivers 子树，实际只剩 4 个未在树里，其余 54 个仍在（说明该文件是候选清单而非执行结果）。

**验证**（打包后直接做，未抽检）：

```bash
zstd -t linux-7.2.12-trim-src-20261115.tar.zst          # frame OK（包已删，命令留作记录）
tar --zstd -xf ... -C /tmp/x                              # 50437 条目，0.99 s
diff -rq /tmp/x/linux-7.2.12 /x96-build/7.2.12-trim       # 无差异
rsync -rlpc --dry-run /x96-build/7.2.12-trim/ /tmp/x/linux-7.2.12/
# Number of regular files transferred: 0   ← 47248 个常规文件逐字节一致
```

SHA256：`0a358c87077b8259a95879ca7563958ae184ab8b2f9c7f8db8bce3f6b5f8d938`

## 来路（trim 包 20261116 — 当前最新）

同一棵 `/x96-build/7.2.12-trim` 的重新快照，相对 20261115 包的唯一区别是**又长了一轮源码改动 + 清场更彻底**：

| 项 | 值 |
|---|---|
| 清理掉的构建产物 | 71 个 = `drivers/staging/media/meson/vdec` 37 + `fs/pstore` 19 + `lib/reed_solomon` 15（`.o` / `.ko` / `.mod` / `.mod.c` / `.mod.o` / `.*.cmd` / `modules.order` / `Module.symvers`），总计约 2.0 MB |
| 另外删除 | `scripts/module.lds`、`scripts/mod/devicetable-offsets.h`、`scripts/mod/elfconfig.h`（`make` 会重建；20261115 包是留着的） |
| 清理后体积 | 750 MB / 50438 条目（47249 常规文件 + 3167 目录 + 22 符号链接） |
| 打包命令 | `tar -C /x96-build --transform 's/7.2.12-trim/linux-7.2.12/' --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-11-16 00:00:00' -cf - 7.2.12-trim \| zstd -19 -T6` |
| 压缩比 | 630.8 MB 内容 → 91.3 MiB（95 738 573 B，约 96 s，window 8 MiB，与 20261115 包同参数；那个包 95 728 750 B，仅差 9.8 KB） |
| 内容 | 与源树逐字节一致，含 `README-8BIT-FIX.md`、`NOTES-drain-deadlock.md` 等本轮文档 |
| 配置 | 仍无树内 `.config`（出树构建于 `/x96-build/kbuild-trim`），权威副本 `../configs/config-7.2.12-x96-trim-final-20261115` |

**验证**（实测，非推断）：

```bash
zstd -t linux-7.2.12-trim-src-20261116.tar.zst        # 699381760 B 解压，frame OK
tar --zstd -tf ... | head -1                          # linux-7.2.12/  ← 根目录已改名
tar --zstd -xf ... -C /tmp/verify-trim                # 1.08 s
rsync -rlpc --dry-run --itemize-changes /x96-build/7.2.12-trim/ /tmp/verify-trim/linux-7.2.12/
# 输出为空 ← 47249 个常规文件逐字节一致
```

`diff -rq` 会报 11 条 `scripts/dtc/include-prefixes/*` 与 `scripts/kernel-doc` 的"没有那个文件或目录"，
那是上游本身带的悬空符号链接（`Documentation/` 被裁后），两边报错一一对应，无实际差异，故用 rsync 比对。

SHA256：`fc72a9419ae46074a18012ba3d94d1517b200d65d665b891c888c236732e59b1`

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
