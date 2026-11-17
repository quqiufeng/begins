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

### 解码器会话生命周期（vdec_open / vdec_close / vdec_resize）

一个会话 = `/dev/video0` 的 fd + 它的 OUTPUT/CAPTURE 队列、mmap、导出的
dmabuf、事件订阅、流开关。**只有这三个函数动这些资源**，其它地方（主循环、
SOURCE_CHANGE 回调、退出路径）一律不许自己拼 `stop_stream + close(fd) + REQBUFS`。

- 不变式：`fd >= 0` ⟺ 会话活着。任何失败都必须回到 `fd = -1`；半初始化的
  会话（队列在、流没开、dmabuf 半套）是"自激重建"的源头，一律不允许留下。
- 每个步骤（`S_FMT` / `REQBUFS` / `QUERYBUF` / `QBUF` / `STREAMON`）返回
  `0 / -errno`，不 `die()`；由调用方决定重试还是放弃。启动 3 轮、seek 重建
  8 轮，全失败才退出让上层重启。
- 关闭顺序固定：`STREAMOFF` → 作废 Renderer 手里的旧帧（`g_drop_owners`
  + `render_flush`）→ 关导出的 dmabuf fd → `REQBUFS(0)` → `close(fd)`。
  顺序反了就是把还在被纹理用的 dmabuf 关在脚下。
- 导出的 dmabuf fd 队列释放不会回收，每条 realloc/close 路径必须自己关，
  否则每次 seek 漏 `2 × cap_count` 个 fd。
- 硬复位（`/sys/module/meson_vdec/parameters/hard_reset`）只在会话 close
  之后写，重试 150×20ms=3s 等驱动 workqueue 收尾；**失败是硬错误**（旧版
  只打一行就照旧开流，后面每帧都失败，自愈循环刷屏）。
- 会话代数 `g_sess` 单调递增，日志里能一眼看出重建了几次。

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
