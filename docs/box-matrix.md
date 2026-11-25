# 多盒子播放适配矩阵（121 x96max / 123 x98h）

一份播放器源码，但**两个盒子在 V4L2 平面模式和 ffmpeg 硬解能力上不同**。适配不靠
写死假设，靠两层：① play.sh 运行期能力探测；② 每盒安装对应平面模式的播放器二进制。

## 1. 两盒差异（实测）

| | 121 x96max | 123 x98h |
|---|---|---|
| 内核解码驱动 | `meson-vdec` (Amlogic) | `sunxi-cedrus` |
| `device_caps` | **Multiplanar** | 单平面 |
| 接受的 V4L2 buf type | `*_MPLANE`（`NV12M`） | `VIDEO_CAPTURE/OUTPUT`（`NV12`） |
| request/stateless API | 否 | 是（`supports_requests=true`） |
| `/dev/media*` | **无** | `/dev/media0` |
| ffmpeg | 7.1.5 Debian，`-hwaccels` **无** `v4l2request` | `/opt/ffmpeg-hw/ffmpeg`，**有** `v4l2request` |
| 解码路径 | **播放器自解** | ffmpeg 硬解 → NV12 → 播放器 RAW 上屏 |
| 播放器二进制 | MPLANE 版 | 单平面版 |
| 实测 | 30.7 fps (1280x720 hevc) | 1080p 33fps / 4K 11fps |

## 2. 播放器二进制：平面模式是**编译期**

`v4l2hevc.c` 的 `CAP_T` / `OUT_T` 决定走哪种 buf type，改了它就改了整条 buffer
管理（num_planes、逐平面 mmap、逐平面 dmabuf）。cedrus 只实现单平面 ops，meson
只接受 MPLANE，二者不能在同一二进制里共存。所以**每盒装对应版本**：

| 盒子 | 二进制 | 来源 |
|---|---|---|
| 121 x96max | MPLANE 版 | `dist/hevcdec-20261119-1949-84d7124/v4l2hevc-aarch64`（md5 `c9245402…`，熟好版） |
| 123 x98h | 单平面版 | `hevcdec/v4l2hevc-aarch64`（仓库当前版） |

部署：`/root/v4l2hevc-aarch64`（play.sh 首选路径）。装错版本的现象：
- 单平面版装到 121 → `S_FMT OUT 失败: EINVAL`（meson 拒单平面）
- MPLANE 版装到 123 → `S_FMT CAP 失败: EINVAL`（cedrus 无 `_mplane`）

## 3. play.sh 能力探测（多盒通用，别写死）

play.sh 开头探测一次，决定解码路径和 ffmpeg 路径：

```sh
# 选 ffmpeg：优先能硬解 v4l2request 的，否则系统 ffmpeg（只解封装/音频）
FFMPEG=            # 自动：/opt/ffmpeg-hw/ffmpeg → /usr/local/bin → /usr/bin

# 硬解能力：ffmpeg 有 v4l2request 且存在 /dev/media*
HW_DEC=0
"$FFMPEG" -hide_banner -hwaccels 2>/dev/null | grep -qw v4l2request || HW_DEC=0
[ -n "$(ls /dev/media* 2>/dev/null)" ] && HW_DEC=1

RAWMODE=${RAWMODE:-$HW_DEC}   # 有硬解才走 RAW，否则播放器自解
[ "$HW_DEC" = 0 ] && RAWMODE=0
```

效果：
- 121：`HW_DEC=0` → `RAWMODE=0` → 播放器自解（meson MPLANE）。
- 123：`HW_DEC=1` → `RAWMODE=1` → ffmpeg 硬解 + RAW。
- `-hwaccel_device` 用实际 `/dev/media*`（`$MEDIA_DEV`），不再写死 `/dev/media0`。

## 4. 根因复盘（2026-11-25 121 播放回归）

改 123 时把共享代码改成只适配 cedrus，导致 121 两条路同时断：

1. `v4l2hevc.c` 从 MPLANE 改单平面（commit `3088149`）→ 121 的 meson 拒收。
2. `play.sh` 硬编码 `-hwaccel v4l2request -hwaccel_device /dev/media0` + `RAWMODE=1`
   默认 → 121 的 ffmpeg 报 `Unrecognized hwaccel: v4l2request`，`RAWIN: 结束 0 帧`。

修复：play.sh 能力探测（§3）+ 121 装回 MPLANE 二进制。实测 121 恢复 30.79 fps。

## 5. 待办：统一到 #if MPLANE

理想是**一份源码两种平面模式**（`-DMPLANE=1/0`），新修复同时惠及两盒，不必维护
两份二进制。拦路点：`v4l2hevc.c.bak-before-mplane`（11-24 新版加 `#if` 前的状态）
在 meson 上会 STALL（`got=0 inflight=6` 重建风暴），说明**新版共享代码对 meson
有回归**（刷新率切换 / STALL 重建 / 配速之一）。需先在 meson 上定位这个回归，
再上 `#if MPLANE`。当前先用 `84d7124` 熟好版顶上。
