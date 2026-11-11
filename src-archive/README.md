# src-archive — 裁剪后的内核源码快照

直接可玩的一份 Linux 7.2.12 裁剪树，解包即用，不必自己跑裁剪流程。

## 文件

| 文件 | 大小 | 说明 |
|---|---|---|
| `linux-7.2.12-hwreal-src-20261111.tar.zst` | 68.9 MB | 当前装机内核（`7.2.12-20261111-hwreal`）对应的源码树，32195 个文件，解包 510 MB |
| `SHA256SUMS` | 107 B | 校验值 |

```bash
sha256sum -c SHA256SUMS
tar --zstd -xf linux-7.2.12-hwreal-src-20261111.tar.zst
cd linux-7.2.12
```

已清空构建产物（`.o` / `.ko` / `.mod` / `.mod.c` / `.*.cmd` / `vmlinux` / `System.map` /
`Module.symvers` / `modules.order` / `include/config` / `include/generated`），纯源码；
`.config` 保留，与 `/boot/config-7.2.12-20261111-hwreal` 逐字节一致，可直接 `make -j6`。

## 来路

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
