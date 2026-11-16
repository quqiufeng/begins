# design_player.md — X96Max HEVC 硬解播放器：两条上屏方案 + 遥控器控制

记录 `hevcdec/` 这套播放链的实现细节。范围：

- 前半段（两条方案共用）：`ffmpeg -re` 供流 → AU 切分 → meson-vdec V4L2 M2M 硬解
- **方案 A**：DRM overlay plane 零拷贝直上屏（NV12 fb + vblank 节拍器）
- **方案 B**：EGL/GBM + panfrost GLES3 着色器做 HDR10→SDR 后上屏
- **遥控器控制**：`rcinputd` → `tvplay-node.sh key` → 暂停/拖动/音量/退出

硬件：Amlogic S905X2（X96Max）/ meson-vdec `/dev/video0` / panfrost G31 /
DPU 主平面只收 RGB / HDMI 2560x1440@60（`video=HDMI-A-1:2560x1440@60`）。

---

## 0. 进程拓扑

```
ffmpeg -re -ss START -i URL -c:v copy -f hevc -     ← 解封装 + 按片源节拍供流
      │ pipe (Annex-B)
      ▼
v4l2hevc-gl-aarch64 -                               ← 本仓库
      ├─ AU 切分 → /dev/video0 (V4L2 M2M OUTPUT)
      ├─ 方案 A：capture dmabuf → DRM PLANE 直显（PLAY=1，不带 GLPLAY）
      └─ 方案 B：capture dmabuf → GLES3 着色器 → GBM surface → eglSwapBuffers
                                                      （PLAY=1 GLPLAY=1）

mpv --no-video --ao=alsa ... --start=START           ← 只出声（独立进程）
rcinputd                                            ← EVIOCGRAB 独占遥控器
```

音画同步靠"两边都用同一个 `-ss START`"粗对齐，视频侧由 `-re` 提供长期节拍；
HEVC 链里没有 A/V clock 交互（见 §5.3 限制）。

---

## 1. 共同部分：解封装、AU 切分、V4L2 M2M 解码

### 1.1 供流

- 输入 `argv[1]` 可以是文件，也可以是 `-`（stdin 管道，`tvplay-node.sh` 用的就是这条）。
- 只预读一小段（`PREFILL`，默认 1 MiB）用于求 SPS；管道里读不到 SPS 时再预读 4 MiB 重试。
- `sps_size()` 自己解析 VPS/SPS/PPS 取真实宽高，失败才用 `argv[2]/argv[3]` 或默认 640x360。
  坑：`conformance_window` 的 `crop_left/right/top/bottom` 必须紧跟 flag 读，
  放到 `bit_depth`/`poc` 之后会读到错位比特（宽度被误裁 8 像素）。
- `stream_next_au()` 按 Annex-B 起始码切 AU，返回 `2` 表示这个 AU 带 IRAP（关键帧）。

### 1.2 OUTPUT / CAPTURE 队列

- 一个 AU 一个 OUTPUT buffer，`MAXAU` 默认 6 MiB，`sizeimage` 4 KiB 对齐；
  驱动用 `vififo offset` 匹配 `sess->timestamps` 里的帧，所以**不能合并多个 AU**。
- CAPTURE 申请 20 个 buffer（`CAPBUF`），必须 ≥ DPB（16，`V4L2_CID_MIN_BUFFERS_FOR_CAPTURE`），
  否则 `amvdec_src_change()` 无法续跑。
- 两块 plane 都是 `V4L2_MEMORY_MMAP`，各自 `VIDIOC_EXPBUF` 出 dmabuf fd
  （`capbuf[].dmabuf[0/1]`），方案 A/B 都消费这两个 fd，全程零拷贝。
- vdec 出的 NV12M 是**紧排**：Y pitch = w，CbCr 交织 pitch = w（不是 w/2）。
- 订阅 `V4L2_EVENT_SOURCE_CHANGE` 处理真实分辨率变化（`handle_event()` → 重配 capture）。
- capture plane0 按 64 行对齐（720 → 768），任何按行 dump 的地方必须按 stride 走，
  整块 `fwrite(len[0])` 会把 padding 写进文件，色度整体错位。

### 1.3 背压（只服务于"播放"，不服务"测吞吐"）

只有 `PLAY=1` 时启用：

| 变量 | 默认 | 含义 |
|---|---|---|
| `FPS` | 24 | 目标播放帧率；`0` 表示不限速（跑满解码器） |
| `LEAD` | 6 | 解码领先显示多少帧就停止喂流 |
| `NOPACE` | — | 置位等于 `FPS=0 LEAD=0` |

循环里 `if (play_pace > 0 && lead > 0 && au_idx - got >= lead) break;`
——解码器能跑 100 fps，但显示节拍由屏幕决定，领先太多只会把 20 个 capture
buffer 填满、在显示前丢帧。

### 1.4 自愈：`g_reinit` 重建 V4L2 会话

meson-vdec 的硬约束：**同一个 V4L2 会话里不能换码流**，seek/分辨率跳变/驱动 abort
都会 `"Unrecognized dec_status 0000000F / Aborting decoding session"`。
所以重建 = 关掉 `/dev/video0` 重开，但 DRM master、crtc/plane、GL 上下文都在别的 fd 上
→ **屏幕不黑**（方案 A/B 都靠这一点）。

重建流程要点：

1. 把管道里上一段流的残留读空（临时切 `O_NONBLOCK` 读到 `EAGAIN`），`s_len/s_pos/s_au_*` 清零。
2. `g_need_irap = 1`：必须等下一个 IRAP 才喂。续喂到 GOP 中间，驱动 ref list 是空的，
   每帧报 `"Couldn't find ref. frame 0"`，几帧内静默挂死（清零后实测 8 帧就死）。
3. 只有固件真 hang 才走 `g_hard_reset_on_reinit`（VDEO 整块掉电复位）；seek 不付这个代价。
4. 触发源：
   - `SIGUSR1` → seek（`sa_flags = 0`，**不能带 SA_RESTART**，否则信号被延到下一帧数据，
     seek 白等几秒；`xioctl()` 里 `g_reinit` 时直接返回 `EINTR` 让主循环处理）；
   - `POLLERR` → 驱动 abort，自愈上限 `ERRREC`（默认 4），出帧后 `g_err_rec` 归零；
   - STALL 检测：`STALLSEC`（默认 12s）/ 等 IRAP 时 `IRAPWAIT`（默认 60s）无新帧；
   - `FORCEREINIT=N` 在第 N 帧主动走一遍自愈，用于确定性验证。

**暂停识别**：`tvplay` 的"暂停"是 `pkill -STOP` 整条链。进程被冻住期间
`CLOCK_MONOTONIC` 照走而主循环一轮都没转，不处理的话 resume 后第一次 poll 超时
会算出 `quiet = 暂停时长`，被误判成 STALL 去重建会话（闪黑 + 掉 buffer）。
做法：每轮记 `t_loop`，若本轮间隔 > 4s（正常最多一个 poll 周期 2s），
把 `t_last_rx` 重置为 `now-2.0`。

---

## 2. 方案 A：DRM overlay plane 零拷贝直上屏

代码：`v4l2hevc.c` 的 `USE_DRM` 段（`play_setup/play_rect/play_frame`）。
产物：`make drm` → `v4l2hevc-drm-aarch64`；`v4l2hevc-gl-aarch64` 也含这条路径。
开启：`PLAY=1` 且不设 `GLPLAY`。

### 2.1 点屏：透明 primary + NV12 overlay

meson 的 **primary plane 只收 RGB**（ARGB/ABGR/XRGB/XBGR/RGB888/RGB565），不收 NV12；
且 primary 的 zpos **高于** overlay。所以：

1. `CREATE_DUMB` 一张 `屏幕宽x高` 的 ARGB8888，`ADDFB2` 后 mmap，**逐像素清 0（alpha=0）**。
   不清零是脏像素，不透明会把视频层整个盖黑。
2. `SETCRTC`（`set.mode_valid = 1` 必须有，少这行内核 `mode=NULL` → EINVAL）。
3. 遍历 `GETPLANERESOURCES` + `GETPLANE`，**挑第一个支持 `DRM_FORMAT_NV12` 的 plane**
   （不能盲取 `ids[0]`）。调试：`PLANELIST=1` 打印全部 plane/格式，`PLANE=<id>` 强制指定。

### 2.2 frame buffer：vdec dmabuf 直接当 NV12 fb

`play_addfb(yfd, cfd, sw, sh)`：

```c
PRIME_FD_TO_HANDLE(yfd) → handles[0]
PRIME_FD_TO_HANDLE(cfd) → handles[1]
fb.pixel_format = DRM_FORMAT_NV12
fb.pitches[0] = fb.pitches[1] = sw;   /* 紧排，C pitch 也是 w */
ADDFB2
```

每个 capture buffer 的 idx 各自缓存一个 `fb_id`（`pc.fb[idx]`），只在首帧建一次。
`EXPBUF=1 DRMFB=1` 时还会额外跑一遍 `drm_import_test()` 单纯验证导入能力。

### 2.3 缩放策略：`SCALE`

| 值 | 行为 |
|---|---|
| `fit`（默认） | 等比缩到装得下，居中，四周黑边（CRTC 未覆盖处由 primary 的透明兜着） |
| `fill` | 铺满整个 CRTC，会变形 |
| `crop` | 目标矩形铺满，源采样区按屏幕宽高比内缩（等价"放大后裁边"），`src_*` 是 16.16 定点 |

目标矩形只跟源尺寸有关，`play_rect()` 里缓存（`rect_ok/rsw/rsh`）。
`DSTGEO=WxH+X+Y` 是**一次性**强制覆盖，用于单变量排查缩放/尺寸；
`tvplay-node.sh` 就是把显示器几何 `2560x1440` 从这里传进来。

### 2.4 节拍器：vblank 序列，不是 usleep

```c
play_vbl_seq()  // WAIT_VBLANK _DRM_VBLANK_RELATIVE, sequence=0 → 只回报当前序列号

target = vbl_base + round(n * refresh / fps);
if (cur < target)  WAIT_VBLANK _DRM_VBLANK_ABSOLUTE sequence=target;  // 一次 ioctl 睡到点
else if (cur > target + 2 帧)  vbl_base = cur - round(n*refresh/fps); // 落后太多，重锚
```

为什么不用 `usleep(1/fps)`：24 fps @ 60 Hz 天然是 2.5 个 vblank/帧，
按累计 ticks 取整就是标准 **3:2 拉片**，帧间隔在 2/3 之间交替，不会忽快忽慢。
`FPS=0` 时（或 `WAIT_VBLANK` 失败）退化成 `CLOCK_MONOTONIC` 时间节拍，
落后 0.5 s 就丢帧重锚（`pc.drops++`）。

> 注意：节拍器只存在于方案 A。方案 B（GL）路径没有 vblank 节拍，
> 必须靠 `ffmpeg -re` 供流限速（见 §3.5）。

### 2.5 无 GPU 时的 HDR 处理：就地软件色调映射

`tm_apply(idx, w, h)`（`USE_DRM && USE_TM`）直接在已 mmap 的采集缓冲上原地改：

- vdec 出的是 8 bit NV12，但内容是 PQ(SMPTE2084) + BT.2020（"码值是 HDR 的，容器是 8 bit 的"），
  直上屏是灰蒙蒙的低对比。
- Y 走 256 项 LUT：`PQ 码 → 线性光(nits) → 亮度压缩 → BT.709 OETF 编码`；
  Cb/Cr 按同点 Y 的 gain 等比缩放（保色相/饱和度）再乘色域压缩系数。
- 环境变量：`TM=0/1/off/on/clip/curve/reinhard/hable`（默认 HDR=1 时开 curve）、
  `TM_SRC_PEAK`(1000)、`TM_TARGET`(200)、`TM_SAT`(0.85)、`TM_KNEE`(0.7)、`TMDIAG=1`。
- CPU 代价高（Normal-NC 映射，实测 4K 一帧 ~800 ms，~11 MB/s），
  只适合低分辨率/兜底；真 4K 必须走方案 B。

---

## 3. 方案 B：EGL/GBM + GLES3 着色器（HDR10→SDR）

代码：`glout.c` + `v4l2hevc.c`（`USE_GLOUT`）。产物：`make gl` → `v4l2hevc-gl-aarch64`。
开启：`PLAY=1 GLPLAY=1`。

为什么上 GPU：meson DRM 没有 `GAMMA_LUT`/`CTM`（gamma 只在 DSI 通路），
显示器（BenQ PD2500Q）不吃 HDR，CPU 又太慢 —— 只剩 panfrost。

### 3.1 初始化顺序

```c
glout_set_drm_fd(pc.dfd);   // 复用方案 A 已经打开的 DRM master fd
glout_init(capw, caph);
```

**共用同一个 DRM fd 是关键**：一个设备只有一个 DRM master，GL 再自己 `open(card0)`
拿不到 master 就没法 `SETPLANE`/翻页。`kms_pick()` 取第一个 connected connector 的
`modes[0]`，然后：

```
gbm_create_device(fd)
gbm_surface_create(dw, dh, GBM_FORMAT_XRGB8888, SCANOUT|RENDERING)
eglGetDisplay(GBM) → eglInitialize → eglChooseConfig → eglCreateContext(GLES3)
eglCreateWindowSurface(gs) → eglMakeCurrent
```

### 3.2 把 NV12 dmabuf 变成两张纹理

`import_tex(fd, w, h, pitch, fourcc)` → `EGL_LINUX_DMA_BUF_EXT` EGLImage
→ `glEGLImageTargetTexture2DOES`：

| plane | 格式 | 尺寸 | pitch |
|---|---|---|---|
| Y | `DRM_FORMAT_R8` | w × h | w |
| CbCr | `DRM_FORMAT_GR88` | w/2 × h/2 | w |

**按 fd 缓存**：20 个 capture buffer 轮转，每帧的 Y/C fd 都不一样，
所以 `g.tc[]` 用 `(fd_y, fd_c)` 做 key，每个 buffer 各导一次纹理之后复用；
表满（> N）或分辨率变化时 `drop_tex()` 统一销毁（顺带 `eglDestroyImageKHR`，
否则漏 dma_buf 引用）。导入失败要把成功的那半张也删掉。

顶点着色器里 `vUV = vec2(x*0.5+0.5, 0.5-y*0.5)` —— 竖直翻转一次，
因为 NV12 源是自上而下的行序而 GL 纹理原点在左下。

### 3.3 色调映射：CPU 建 LUT，GPU 查表

`build_lut()` 在 CPU 上算 256 项（每项 `R=输出码值, G=色度 gain`）：

```
code8 → 归一化 (v-16)/219 → PQ EOTF → nits
      → 亮度压缩（clip / curve / reinhard / hable，knee 拐点）
      → BT.709 OETF → 输出码值
色度 gain = f(同点亮度增益)，用于 Cb/Cr 等比缩放保色相
```

LUT 上传成 `RGBA32F` 纹理（`GLLUT8=1` 可退成 RGBA8 省带宽）。
另外用**7 次多项式**拟合 code/gain 两条曲线（`uPc/uPg`，`PDEG=7`，误差打印在
`GLOUT: poly 误差 ...`），供 `GLFS=8/10` 等"纯多项式、不查表"的变体用；
`GLFS=0..10` 选片元着色器变体，用于 A/B 对比不同映射曲线。

片元着色器主流程（`FS`）：

```
采样 Y、C（GR88 两通道）、LUT
→ YUV 有限范围(16/219,128/224) → RGB（BT.709 矩阵）
→ BT.2020 → BT.709 3x3 色域压缩
→ clamp → 按 uSat 向亮度混合（降饱和）
→ hash 抖动 ±0.5/255 消除渐变色带
```

`uSat` 即 `TM_SAT`（默认 0.85）。

### 3.4 两遍渲染（默认开）

`g.twopass = !GL1PASS`。`twopass_frame()`：

- **pass1**：按"屏幕装得下且不超过 1080p 量级"的尺寸（`GL1MAX` 可覆盖上限）
  渲染到 FBO 纹理 `tex_rgb`(RGBA8)。4K 全尺寸做色调映射是 8.3M 片元（~54 ms），
  缩到 1080p 只有 2M（~37 ms），肉眼看不出差别。
- **pass2**：`FS_COPY` 把这纹理按等比+黑边画到 GBM surface（`VS2` 不翻 UV，
  因为 pass1 的 VS 已经翻过一次，再套会上下颠倒）。
- 单遍路径（`GL1PASS=1`）直接在 surface 上用一句 `glViewport` 摆等比黑边。

最后 `eglSwapBuffers()` 提交；`flip_handler` + `wait_flip()` 可选地等 page flip 事件，
`GLTIME=1` 时 `glFinish()` 并统计 `t_sum/t_max`（片元耗时）。

### 3.5 为什么必须有 `-re`

方案 B 没有 vblank 节拍器（`FPS` 对它无效），谁先出帧谁上屏。
不靠 `ffmpeg -re` 就会按解码速度播放（4K 实测快 15%，1080p 会飞）。
`tvplay-node.sh` 因此在供流命令里硬编码 `-re`。

### 3.6 性能变体：GL 只做源分辨率映射，放大交给 DPU（未并入主干）

`glscale.inc`：把 pass1 的目标从 surface 换成 **3 个轮转的 dumb buffer**
（`NRT=3`，各 `EGLImage` + `FBO`），渲染完直接 `SETPLANE` 让 DPU 硬件放大到屏幕。
片元数从屏分辨率降到源分辨率（720p 源 = 1/4 工作量），实测 **28 fps → 55 fps+**。
独立实验代码，`glout.c` 目前没有 include 它。

---

## 4. 两条方案对比

| 维度 | 方案 A（DRM plane） | 方案 B（GLES3） |
|---|---|---|
| 上屏路径 | vdec dmabuf → NV12 fb → overlay plane | dmabuf → EGLImage 纹理 → FBO/GBM → 翻页 |
| 色彩处理 | 无（或 CPU 就地 LUT，很慢） | GPU 着色器 PQ→SDR + 2020→709 + 抖动 |
| HDR10 片源 | 灰蒙/过曝，不可用 | 正确，可调曲线/峰值/饱和度 |
| 缩放 | DPU 硬件缩放（免费） | pass2 GPU 缩放；或用 `glscale.inc` 交回 DPU |
| 节拍 | vblank 绝对序列，3:2 拉片精确 | 靠 `ffmpeg -re`，无帧级节拍 |
| 4K 能力 | 受 CPU 色调映射限制（~800ms/帧） | 37~54ms/帧（pass1 限 1080p） |
| seek 恢复 | DRM 不释放，**不黑屏** | 同（GL 上下文不随 V4L2 会话销毁） |
| 依赖 | 裸 ioctl，无 libdrm | EGL/GLESv2/gbm/drm（交叉编译用 `crosslib/` 里的板端 .so） |
| 典型用途 | 低分辨率/无 HDR 片源、逐帧一致性验证 | 实际观影（HDR10 4K） |

一致性的结论（README）：与 ffmpeg 软解逐帧 md5 比对，640x360/720p/1080p
各 ~300 帧全部 bit-exact；纯解码吞吐 105~140 fps（`NBUF_OUT=16 NOWRITE=1`）。

---

## 5. 遥控器控制播放

### 5.1 三段式

```
2.4G 遥控器 (evdev /dev/input/eventN)
   │  rcinputd（EVIOCGRAB 独占）
   ▼  exec /tmp/tvplay-node.sh key <动作名>
tvplay-node.sh key   ← 语义全在这里（暂停/拖动/音量/退出）
   ├─ pkill -STOP/-CONT 整条 HEVC 链（视频 + ffmpeg + 音频 mpv）
   ├─ mpvctl + /tmp/tvplay.sock（mpv IPC：音量/静音）
   └─ 重新执行 play 子命令（seek = 整链重开）
```

### 5.2 `rcinputd`：按键 → 动作名

- 扫 `/dev/input/event*`，取 `EVIOCGNAME` 含 `RC_MATCH`（默认 `XING WEI`）的设备；
  `RC_MATCH=*` 抓全部（含 meson-ir）。
- `EVIOCGRAB` 独占，避免按键同时被 console 吃掉（光标/终端乱跳）；
  `RC_NOGRAB=1` 只读不抢。
- **必须 `FD_CLOEXEC`**：`rcinputd` 每按一次键就 fork+exec 播放助手，
  播放链（ffmpeg/v4l2hevc）会继承设备 fd 从而一直持有 grab；
  守护进程重启后新实例 grab 全 `EBUSY`，而持锁的播放进程从不 read，
  按键全被丢进没人读的缓冲区 —— 表现就是"遥控器按键无用"。
  fork 之后还额外 `for (j=3;j<256;j++) close(j)` 双保险。
- 标定/调试：
  - `rcinputd -t` 只打印 `code/名字/val`（`-T` 连非 KEY 事件也打），用来认键；
  - `MSC_SCAN` 硬件扫描码会被记下来（有些键内核映射不出 KEY 码，报 `code=0`），
    填 `COMBO_SCAN[]` 表兜底；
  - 日志 `/tmp/tvplay-rc.log`：每次 `open`、每个键的 `code/mods/scan/val → 动作`
    或 `→ 忽略`。
- 这台遥控器（XING WEI 2.4G；`rcinputd.c` 注释里引用的 `docs/remote.md` 键位图当前仓库未包含）实测是**键盘模式**：
  上排功能键发 `Ctrl+1..Ctrl+5`，不是标准媒体键。`COMBO[]` 表：

  | 组合 | 动作 |
  |---|---|
  | Ctrl+2 | `mute` 🔇 |
  | Ctrl+3 | `menu` ≡（无 UI，忽略） |
  | Ctrl+4 / Ctrl+5 | `volup` / `voldn` |
  | Ctrl+1 | 首页 —— 按需求**不响应**，只记一行"忽略"日志 |

  普通键：OK/ENTER/SPACE → `toggle`；▶/FASTFWD/NEXTSONG → `fwd`；
  ◀/REWIND/PREVSONG → `back`；▲/PGUP → `fwdmore`；▼/PGDN → `backmore`；
  STOP/BACK/ESC/EXIT → `quit`。

- 长按（`value==2`）处理：
  - `toggle` 只认按下那一下 —— 长按连发会把播放/暂停反复来回切（实测一次长按 4~5 个 val=2）；
  - 其它动作按秒节流，但换键必须生效（音量+ 之后的音量− 不能被上一键的时间戳吃掉）；
  - 有些键会报离谱 value（`code=4 val=458976`），`value > 2` 直接丢。

### 5.3 `tvplay-node.sh` 的动作语义

状态文件 `/tmp/tvplay.state`（可 `source`，URL/TRACK 用 base64 存，值里没有引号空格）：

```
START=<开始播放的 epoch>  OFF=<seek 偏移秒>  PLAYER=hevc|mpv
KEYB64=<base64 URL>  TRACKB64=…  AUDIO=0|1  FPS=…  GEO=2560x1440
PAUSE_AT=0|<暂停时刻 epoch>  PAUSED_FOR=…
```

位置计算 `pos()`：暂停期间冻结（`PAUSE_AT>0` 时用 `PAUSE_AT` 当"现在"）：

```sh
elapsed = (PAUSE_AT>0 ? PAUSE_AT : now) - START + OFF
```

| 动作 | 实现 |
|---|---|
| `toggle` | 先判"实际在跑哪条链"（`pgrep v4l2hevc-gl-aarch64`），**不能只看 state**：HEVC 链的画面(v4l2hevc/ffmpeg)和声音(独立 mpv)是两个进程，只 toggle mpv 会哑掉声音、画面照跑 → 必须整条 `pkill -STOP/-CONT` |
| 暂停 `pause_video` | `STOP` v4l2hevc-gl / ffmpeg / mpv，写 `PAUSE_AT=now` |
| 继续 `resume_video` | `CONT` 三者，把暂停时长并进 `START`（`START += now - PAUSE_AT`），`PAUSE_AT=0`，`pos()` 才连续 |
| `fwd`/`back`/`fwdmore`/`backmore` | ±10s / ±60s。`PLAYER=mpv` 走 mpv IPC `seek`；HEVC 链只能 **整链重开**（~0.8s 黑屏） |
| `volup`/`voldn` | `mpvctl` 读 `volume` 再 `set_property`，步进 ±10，**夹在 0..100**（mpv 的 `add` 会累加，>100 削波，实测被连按到 130 晚上炸响） |
| `mute` | `mpvctl <sock> mute` |
| `quit` | `stop`：kill 三个进程 + 删 socket + `chvt 1` |
| `menu`/`home` | 日志"无 UI，忽略" |

`vol_step` 必须 `MPVCTL_ECHO=1`：不加则 mpvctl 不回显回复，读到的 `cur` 永远是空、
退化成每次按 100 算（实测连按减 12 次只掉到 90）。

### 5.4 seek：整链重开 + 合并连发

HEVC 路径没有 IPC，`seek` = `restart_at <T>` = 用 state 里的参数重新执行
`play hevc <KEYB64> <T> …`（每个参数都必须 `enc`，play 侧一律 `dec`；
传明文会被当 base64 解成垃圾，实测 `AUDIO` 解空 → 重开后没有音频 mpv、
`GEO` 解出二进制 → state 文件写坏，坏值还会顺着 restart_at 再传一轮）。

- **`seek_guard`**：`/tmp/tvplay.seek.stamp` 记上次 seek 时间，3 s 内的重复 seek 直接丢。
  原因：`rcinputd` 是 `wait(NULL)` 串行处理的，按住 ▶ 时连发事件排在队列里，
  松开后仍会逐个补跑，每个都重开一次链 —— 表现是"播放界面消失变成命令行，
  松开才慢慢恢复"。合并成一次即可。
- 暂停中拖动：重开后若 `WASPAUSED>0` 再 `pause_video()` 压回去，保持"暂停"语义。
- 重开期间 DRM 没被释放（`v4l2hevc` 内部只是重建 V4L2 会话），但整链重启时
  进程确实退出 → 屏幕会短暂回到内核控制台文本（约 0.8 s）。
  更好的做法是把 `SIGUSR1` 接上（`v4l2hevc.c` 已支持 seek 不黑屏），
  目前 `tvplay-node.sh` 还没走这条。

### 5.5 前端协议（ssh）

所有子命令参数 **base64**，避免 ssh 嵌套引号：

| 子命令 | 参数 |
|---|---|
| `probe` | URL → ffprobe JSON 风格 `key=value` |
| `play` | PLAYER URL START TRACK AUDIO FPS GEO |
| `key` | 动作名（`rcinputd` 用） |
| `stop` | — |
| `state` | → `elapsed player 进程数 KEYB64 PAUSE_AT` |
| `disp` | → 当前显示模式 `WxH@Hz`（`/sys/class/drm/*/mode` 常为空，退化取 `modes` 首行；刷新率从 `/proc/cmdline` 的 `video=HDMI-A-1:WxH@Hz` 取） |
| `alive` | → 进程数 |
| `log` | `tail -N /tmp/tvplay.log` |

版本串 `tvplay-node-v4` 写在脚本头部，加/改子命令时前端 `ensure_node` 的匹配串要同步改。

### 5.6 起播与部署

```bash
rc-up.sh [起始秒]     # 盒端：杀掉裸管道链 → node play → 拉起 rcinputd
```

播放链命令（`play hevc` 分支）：

```sh
ffmpeg -hide_banner -loglevel warning -re -ss "$START" -i "$URL" \
       -map 0:v:0 -c:v copy -f hevc - \
 | DSTGEO="$GEO+0+0" NOWRITE=1 PLAY=1 GLPLAY=1 /tmp/v4l2hevc-gl-aarch64 -
```

- `NOWRITE=1` 必须：否则写 `/tmp/out.yuv`，4K 从 24 fps 掉到 10 fps。
- 音频单独一条 `mpv --no-video --ao=alsa --audio-device=alsa/hw:0,0 --cache-secs=20`。
  为什么不用 `ffmpeg -f alsa`：这块板子缓冲太浅（实测 8 s 内 15 次 xrun）。
- `DSTGEO` 只对方案 A 生效；方案 B 按 connector `modes[0]` 自行等比铺屏（两者都是 2560x1440）。

### 5.7 排查

```bash
pgrep -fa 'v4l2hevc-gl-aarch64|ffmpeg .*-f hevc|mpv|rcinputd'
cat /tmp/tvplay.state
tail -5 /tmp/tvplay.log; tail -5 /tmp/tvplay-rc.log
sh /tmp/tvplay-node.sh state
grep -E 'HB|STALL|POLLERR|REINIT' /tmp/tvplay.log    # 心跳/自愈
```

`v4l2hevc` 每 10 s 打一行心跳：

```
HB t=120 au=2880 got=2874 out_nfree=7/8 quiet=0.0 rec=0
```

`quiet` 飙起来 + `rec` 增长 = 自愈循环，配合 `STALL:` 行定位是固件 hang 还是
IRAP 等不到。

---

## 6. 已知限制 / 下一步

1. **A/V 同步是粗对齐**：只靠两边同一个 `-ss`，长片会有漂移，没有丢帧/补帧机制。
2. **seek 会黑 0.8 s**：整链重开；`v4l2hevc` 的 `SIGUSR1` 热重建路径已实现，
   让 `tvplay-node.sh` 改成发信号即可做到不黑屏。
3. **拖动精度受 GOP 限制**：`-ss` 落在关键帧前需等 IRAP（`IRAPWAIT` 60s 兜底）。
4. **方案 B 无帧级节拍**，完全信任 `-re`；网络源抖动会直接体现为卡顿。
5. `glscale.inc` 的 DPU 硬件放大变体（28→55 fps）尚未并入主干。
6. 遥控器部分键没有标准 KEY 码（`code=0`），需按 `MSC_SCAN` 补 `COMBO_SCAN` 表。
7. 方案 A 的 CPU 色调映射不可用于 4K（~800 ms/帧），仅作兜底/验证。
