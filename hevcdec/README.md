# hevcdec — X96Max V4L2 M2M HEVC 硬解验证

用 `meson-vdec` 驱动做 V4L2 M2M 解码的冒烟/一致性测试工具。

> **本目录只含用户态测试工具，不包含内核模块源码。**
> 编译产物是普通用户态 ELF，不编 `.ko`、不需要 `insmod`，只要 `/dev/video0` 存在即可运行。
>
> ```
> hevcdec/v4l2hevc            本目录 —— 用户态，open("/dev/video0") + V4L2 ioctl
>         │
> meson_vdec.ko               系统自带（drivers/staging/media/meson/vdec）
>         │                    V4L2 M2M 框架，调度硬件 VPU
>         ▼
> /dev/video0   name="meson-video-decoder"
> ```
>
> 想改内核侧（`vdec.c` / `vdec-hevc.c` / `codec_hevc.c`）属于另一条路径：
> 在内核树里 `make M=drivers/staging/media/meson/vdec modules`，替换 `.ko` 后重载。
> 本工具的存在是为了**验证**驱动解码是否正确（见文末结论），未改动驱动任何代码。

## 构建

```bash
make            # 本机（静态）
make CROSS=1    # aarch64 交叉编译 → v4l2hevc-aarch64
```

## 运行

```bash
scp v4l2hevc-aarch64 root@<box>:/tmp/
ssh root@<box> /tmp/v4l2hevc-aarch64 /tmp/test720.265
```

可选参数 / 环境变量：

| 项 | 说明 |
|---|---|
| `argv[1]` | 裸 HEVC 码流（Annex-B，需含 VPS/SPS/PPS） |
| `argv[2] argv[3]` | 强制宽高（一般不用，靠 SPS / SOURCE_CHANGE） |
| `NBUF_OUT` | OUTPUT 队列深度，默认 8；性能测试用 16 |
| `NOWRITE` | 置位则不落盘，只解码，用于测纯解码吞吐 |
| `FRAMES` | 期望帧数，用于收尾校验 |
| `SPSDBG` | 打印 SPS 解析中间值 |

## 设计要点

- 一个 AU 一个 OUTPUT buffer，驱动靠 `vififo offset` 与 `sess->timestamps` 匹配帧。
- capture 侧至少申请 DPB（16）个 buffer，`amvdec_src_change()` 才能直接续跑。
- 订阅 `V4L2_EVENT_SOURCE_CHANGE` 处理真实分辨率变化。
- **capture plane0 按 64 行对齐**（720 → 768），必须按 stride 逐行取；整块
  `fwrite(len[0])` 会把 padding 写进文件，色度整体错位（表现为亮度对、颜色全错）。

## 踩过的坑

1. **SPS `conformance_window` 顺序**：`crop_left/right/top/bottom` 必须紧跟
   `conformance_window_flag` 读取，放到 `bit_depth`/`poc` 之后会读到错误比特，
   导致宽度被误裁 8 像素（报 `crop l=4 b=4`）。
2. **dump 按 stride 逐行写**，原因见上。
3. `timeout -s KILL` 会在 fwrite 途中杀进程，造成最后一帧看起来"不一致"，
   比对时不要用它。

## 验证结论（2026-11-16，X96Max / meson-vdec）

与 ffmpeg 软解逐帧 md5 比对，整帧全量比对：

| 序列 | 帧数 | 结果 |
|---|---|---|
| 640×360 | 293 | 全部 bit-exact |
| 1280×720 | 300 | 全部 bit-exact |
| 1920×1080 | 297 | 全部 bit-exact |

吞吐（`NBUF_OUT=16 NOWRITE=1`）：

```
640x360   140 fps   resets=0   300/300 AU
1280x720  125 fps   resets=0   300/300 AU
1920x1080 105 fps   resets=0   300/300 AU
```

写盘模式受 IO 限制约 30 fps，与硬解能力无关。
