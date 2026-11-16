# meson-vdec — X96Max HEVC 硬解驱动（8bit 修复后的内核侧代码）

`drivers/staging/media/meson/vdec` 的完整驱动源码 + 编译好的 `meson-vdec.ko` + 一份可直接打在内核树上的补丁。
用户态验证工具在 `../hevcdec/`（那份只跑 V4L2 ioctl，不含内核代码）。

| 文件 | 说明 |
|---|---|
| `src/` | 22 个文件，编译该模块所需的全部 `.c/.h/Makefile/Kconfig`（无 `.o`、无 `.*.cmd`） |
| `0001-meson-vdec-hevc-8bit.patch` | 相对 `src-archive/linux-7.2.12-trim-src-20261115.tar.zst` 里原树的差量，`patch -p1` 可用于内核树根 |
| `meson-vdec.ko` | 已编好，130248 B，arm64，`CONFIG_LOCALVERSION="-x96-trim"`（不进 git，`*.ko` 被 `.gitignore` 忽略） |

## 相对上游 7.2.12 的改动范围（16 个文件）

补丁里 16 个 `+++ b/`：新增 `codec_hevc.c`（1482 行）+ `codec_hevc.h`，其余是修改。

| 文件 | 为什么改 |
|---|---|
| `codec_hevc.c` / `.h` | **新增**：HEVC 的 codec_ops 实现（8bit/10bit 位深判定、DPB、参考帧、SAO/DBLK 配置） |
| `codec_hevc_common.c/.h` | FBC/MMU/downsample 判定按 `is_10bit` 分叉 |
| `vdec.c` / `vdec.h` | 注册 `codec_hevc` ops、`pixfmt_cap` 协商 |
| `vdec_helpers.c/.h` | `amvdec_src_change()`、DPB 分配走 8bit 路径 |
| `esparser.c/.h` | 码流切分（HEVC NAL / start code） |
| `vdec_hevc.c` | 原 HEVC helper 与新的 `codec_hevc` 分工 |
| `vdec_platform.c` | 能力表（g12a）按 8bit 输出对齐 |
| `codec_h264.c` / `codec_vp9.c` / `hevc_regs.h` | 同一套 regs/尺寸宏调整 |
| `Makefile` | `meson-vdec-objs += ... codec_hevc.o` |

关键位置在 `codec_hevc.c:1330` 附近：`bit_depth` 决定 `is_10bit`，进而决定 `vdec_helpers` 里走 8bit 还是 10bit 的 fmt/FBC 分支。

## 用源码树重建

```bash
cd <解包后的 linux-7.2.12>            # 或 /x96-build/7.2.12-trim
cp -a /home/quqiufeng/kernel/meson-vdec/src/* drivers/staging/media/meson/vdec/
make O=/x96-build/kbuild-trim ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     M=drivers/staging/media/meson/vdec modules
```

或者只打补丁（等价）：

```bash
cd <内核树根>
patch -p1 < /home/quqiufeng/kernel/meson-vdec/0001-meson-vdec-hevc-8bit.patch
```

## 校验（打包时实测，非口头）

```bash
# 1) 补丁能从 trim 快照的原树打出，且结果与 /x96-build/7.2.12-trim 逐字节一致
tar --zstd -xf src-archive/linux-7.2.12-trim-src-20261115.tar.zst -C /tmp/x
cd /tmp/x/linux-7.2.12 && patch -p1 -s < .../0001-meson-vdec-hevc-8bit.patch
# vdec.c / vdec_helpers.c / esparser.c / codec_hevc.c / codec_hevc_common.c /
# codec_h264.c / codec_vp9.c / vdec_hevc.c / vdec_platform.c / Makefile / vdec.h
# → md5 全部与 /x96-build/7.2.12-trim 下同名文件相同
```

md5（前 32 位，本目录 `src/` 与压缩树内一致）：

```
45c283eee032cd4e9909750a0274cbb6  vdec.c
e0b8e8a3513e52bfbdb5d6f5cb0c653f  vdec_helpers.c
3b3bfc4ee88be946b5fc1fe023654d6a  esparser.c
9ce7e495a9f844b24ff9a1e37857c54a  codec_hevc.c
adf2a8bbe27008d6441a52c421d694bf  codec_hevc_common.c
```

调试用的 `DRBG`/`pr_info` 探针已全部清除，只剩上游自带的 `pr_debug`。

## 另两份存档（不在本仓库内）

| 位置 | 内容 |
|---|---|
| `/x96-build/7.2.12-trim/drivers/staging/media/meson/vdec/` | 实际在用的源码树（带 `.o`/`.ko`），`README-8BIT-FIX.md` 在里面 |
| `/x96-build/bak/vdec-8bit-fix-20261116/` | `meson-vdec.ko` + `src/` 快照 |

本目录就是这两处的可提交副本，`/x96-build` 丢了也不影响。
