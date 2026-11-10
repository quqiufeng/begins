# src-archive — 裁剪后的内核源码快照

直接可玩的一份 Linux 7.2.12 裁剪树，解包即用，不必自己跑裁剪流程。

## 文件

| 文件 | 大小 | 说明 |
|---|---|---|
| `linux-7.2.12-begin-src-20261110.tar.zst` | 88.1 MB | 裁剪后源码树（60202 个文件，解包 550 MB） |
| `SHA256SUMS` | 106 B | 校验值 |

```bash
sha256sum -c SHA256SUMS
tar --zstd -xf linux-7.2.12-begin-src-20261110.tar.zst
cd linux-7.2.12
```

已执行 `make clean`，纯源码，无 `.o` / `.ko` / `vmlinux` 等产物；`.config` 保留，可直接 `make -j6`。

## 来路

| 项 | 值 |
|---|---|
| 上游 | `linux-7.2.12.tar.xz` |
| 上游 SHA256 | `bb18468a8dc8978aa00caa6446e753f7b6da3fee56b6b7f38b16f9430ba02d4f` |
| 裁剪规则 | `../tools/trim/rules.txt` |
| 禁用符号 | `../tools/trim/disable.list`（2265 个） |
| 基线配置 | `../notes/.config.before-trim`（6717 个 =y/=m 符号） |

压缩比：550 MB → 88.1 MB（6.2×，zstd -19）。

## 想自己复现

```bash
cd ../tools/trim
python3 plan.py            # 按 rules.txt 生成 disable.list
# 然后在源码树内按 disable.list 关掉对应 CONFIG，再 make
```

完整流程见仓库根 `README.md` 与 `docs/trim.md`。

## 为什么是整棵源码而不是补丁

补丁方式要求使用者先下载 153 MB 上游 tarball 再打补丁，且内核目录裁剪会删掉实体子目录，补丁极易因上下文不匹配而失败。整树快照多花 88 MB，换「解包就能编译」。
