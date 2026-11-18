# design_player.md — X96Max HEVC 硬解播放器：一个播放器，两种 Renderer

记录 `hevcdec/` 这套播放链的实现细节。范围：

- 前半段（两条方案共用）：`ffmpeg -re` 供流 → AU 切分 → meson-vdec V4L2 M2M 硬解
- **Renderer A（`drm`）**：NV12 dma-buf 直挂 KMS overlay plane，零拷贝 + vblank 节拍器（`vout.c`）
- **Renderer B（`gl`）**：EGL/GBM + panfrost GLES3，dmabuf 当纹理，shader 里做 HDR10→SDR（`glout.c`）
- 两者同一接口 `render.h`，运行期 `RENDER=drm|gl` 切换；**不存在两套播放器**
- **遥控器控制**：`rcinputd` → `tvplay-node.sh key` → 暂停/拖动/音量/退出

硬件：Amlogic S905X2（X96Max）/ meson-vdec `/dev/video0` / panfrost G31 /
DPU 主平面只收 RGB / HDMI 2560x1440@60（`video=HDMI-A-1:2560x1440@60`）。

---

## 0. 进程拓扑

```
ffmpeg -re -ss START -i URL -c:v copy -f hevc -     ← 解封装 + 按片源节拍供流
      │ pipe (Annex-B)
      ▼
v4l2hevc-aarch64 -                                  ← 本仓库（一个二进制，两个后端）
      ├─ AU 切分 → /dev/video0 (V4L2 M2M OUTPUT)
      ├─ 解 / 时间轴 / 配速 / 缓冲生命周期     （播放器，唯一一份）
      └─ Renderer（render.h，二选一，PLAY=1）
           ├─ drm  capture dmabuf → KMS PLANE 直显         （RENDER=drm，auto 优先）
           └─ gl   capture dmabuf → GLES3 → eglSwapBuffers （RENDER=gl）

mpv --no-video --ao=alsa ... --start=START           ← 只出声（独立进程）
rcinputd                                            ← EVIOCGRAB 独占遥控器
```

音画同步靠"两边都用同一个 `-ss START`"粗对齐，视频侧由 `-re` 提供长期节拍；
HEVC 链里没有 A/V clock 交互（见 §5.3 限制）。

### 0.1 分界线：播放器管时间，Renderer 管"变成光"

`render.h` 是唯一接口，播放器（`v4l2hevc.c`）里没有一行 DRM/EGL 代码：

| 归播放器 | 归 Renderer |
|---|---|
| AU 切分、喂/收、seek、会话重建 | 拿 dmabuf、决定怎么画到屏上 |
| 时间轴（锚点 + 帧号/配速）、背压 | 按 pts 找上屏槽、自己决定要不要排队 |
| capture buffer 生命周期 | 只在完成回调里把 owner 还回来 |

三道契约，两个后端都必须守：

1. **一次 submit 恰好一次 done 回调**（SHOWN / DROPPED / ABORTED），
   播放器在回调里才 QBUF → dma-buf 不会被解码器提前改写。
2. **能力用 caps 声明，不用 `if (后端==X)`**：`gl` 声明 `RENDER_CAP_HDR`
   （shader 里做色调映射），`drm` 不声明 → 播放器才在 CPU 上跑 `tm_apply`。
3. **同步/异步由后端自己如实表达**：`gl` 是同步（submit 返回即已 swap，
   回调就地触发，`pump/wait_shown` 空转）；`drm` 有队列和 vblank 节拍
   （`RENDER_DEPTH`，默认 3）。播放器不假设是哪一种。

---

## 1. 共同部分：解封装、AU 切分、V4L2 M2M 解码

### 1.1 Demux：职责劈在两处

一句话：**容器归 ffmpeg，码流归 hevcdec，而两者的交界处（管道）把边界信息全丢了。**

| 环节 | 谁做 | 产出 |
|---|---|---|
| 容器解析（MP4 / MKV / TS / HTTP） | ffmpeg | 裸 HEVC |
| 选流、定位、节流 | ffmpeg `-map 0:v:0 -ss -re` | Annex-B 字节流 |
| 起始码扫描、AU 切分 | hevcdec `stream_next_au()` | `(指针, 长度, 是否 IRAP)` |
| 参数集解析、真实宽高 | hevcdec `sps_size()` | `g_w / g_h` |

为什么把 demux 甩给 ffmpeg 而不是链 libavformat：

- 交叉编译（aarch64 静态链 libavformat 加一票依赖）比写一条命令贵太多；
- 只有一条视频流，`-c:v copy` 让 ffmpeg 退化成"转封装器"，CPU 接近 0，4K 也不掉帧；
- 代价是**容器级的元数据（PTS/DTS、duration、章节、音轨）随管道一起蒸发** ——
  见 §1.5，这是整个设计最大的一笔技术债，不是可以后补的细节。

这笔交易逐条称过价了：**§1.11**（不链的实际成本、真 PTS 能白拿什么、什么条件下翻案）。

### 1.2 供流命令与三个硬约束

```
ffmpeg -hide_banner -loglevel warning -re -ss "$START" \
       -i "$URL" -map 0:v:0 -c:v copy -f hevc -     | hevcdec -
```

- `-f hevc` → 裸 Annex-B。**没有容器 = 没有帧边界、没有时间戳**，hevcdec 只能自己扫起始码。
- `-c:v copy` → 不重编码，只转封装。ffmpeg 因此也不做任何时基修复或帧率重排，
  它只是"按原始时序把字节吐出来"。
- `-re` → 唯一节拍源。GL 路径没有 vblank 节拍器（§3.5），解码跑多快就播多快；
  DRM 路径自己有 vblank 节拍，`-re` 只是为了不把管道和 20 个 capture buffer 灌满。
- `-ss` 放在 `-i` **前面** → 快速定位，靠重新解封装到目标 GOP 头，而不是解码后丢帧。
  所以 seek 精度天然是 GOP 量级（实测 1–2 s），而且要整链重开（§5.4）。
- 直接后果：暂停只能 `SIGSTOP` 整条链（§5.3），位置由 shell 的 `PAUSE_AT` 冻结计时来记。

| 约束 | 原因 | 违反的后果 |
|---|---|---|
| 必须 `-c:v copy` | 4K 重编码跑不动 | CPU 打满、掉帧 |
| 必须 `-re`（GL 路径） | 没有节拍器 | 4K 快 15%，1080p 直接飞 |
| 必须一个 AU 一个 OUTPUT buffer | 驱动按 `vififo offset` 匹配 `sess->timestamps` | 帧号错位、花屏 |

### 1.3 流式 AU 切分

不整片读入：`s_buf / s_len / s_pos / s_au_start` 是一个**滑动窗口**，
只保留"当前 AU + 尚未扫完的尾巴"，因此能播任意长片源、能接 stdin。

- `s_fill()` 按需扩缓冲区（起始 4 MiB，不够就翻倍），单次 `read()` 最多要 1 MiB；
- 扫到 `00 00 01` 解析 NAL 头 `(b>>1)&0x3f`；4 字节起始码靠"前一个字节是 0"识别（`sc = s_pos-1`）；
- 切分判据：`vcl && 已见 VCL` 或 `iru && 已见 VCL` 就断 AU；
  `iru` = {32,33,34,35,39,41}（VPS/SPS/PPS/AUD/前缀 SEI）；
- AU 的随机接入点**存类型而不是布尔量**：`s_au_rap` = 0 或 16..21，`s_au_rasl` 记本 AU 是否含
  RASL(8/9)；交出后转存 `s_au_last_rap / s_au_last_rasl` 供调用侧判策略（返回前的清零不改）。
  返回 `2` 仍是"含 16..21"，主循环据此过闸门（§1.14 的状态机），
  新会话里非 RAP 帧直接丢弃直到第一个可接受 RAP。为什么要区分类型见 §1.10 的 CRA 记录；
- 交出 AU 后置 `s_release`，下一次调用 `s_compact()` 把前缀 `memmove` 掉。
  ⇒ 峰值内存 ≈ 最大 AU + 1 MiB，与片长无关（4K 关键帧几 MB，实测 RSS 稳定在十几 MB）。
  坑：`s_cap` 只增不减，遇到一次超大 AU 之后缓冲区不会缩回。

实测（`RAPDBG=1` + 只跑切分的独立 harness，4 个测试片源一致）：**片源是 open GOP**。
300 个 AU 里有 10 个 RAP：只有 AU#1 是 IDR(20)，其余 9 个（#30 #60 … #270）**全是 CRA(21)**，
每个 CRA 后面紧跟 1 个含 RASL 的 AU（#31 #61 …），全片 RASL 共 9 个。
⇒ "等一个 IDR"在这个语料上等于永远等不到；任何"只认 16..20"的严格策略都会一路退化到超时，
所以 CRA 必须算可起播（代价是每个 seek 多丢 1 个 RASL AU），strict 只能当诊断开关。

阻塞点是 `read()`，这也是 seek 的实现方式：`SIGUSR1` 打断 `read` 返回 `-1`，主循环转去重建会话。
所以注册 `SIGUSR1` 时必须关掉 `SA_RESTART` —— `signal()` 默认会带上，
否则 `read()` 被系统自动续上，seek 就变成"赌信号落在 poll 还是 read 上"的随机行为。

### 1.4 AU 判据与规范不一致（唯一没修的正确性 bug）

规范的 AU 边界由 slice header 首比特 `first_slice_segment_in_pic_flag` 决定，
**一帧可以有多个 slice，也就是多个 VCL NAL**。这里的实现是"见到第二个 VCL 就断"，
等于硬编码了单 slice 假设。

现有 4 个测试片源全是单 slice（脚本统计每个文件都是 `first=300 / nonfirst=0`），
所以一直没暴露。一旦片源开多 slice（x265 `--slices`、广播级 4K 常见），
一帧会被切成 N 个 AU → N 个 OUTPUT buffer → 驱动按 AU 记 `timestamps`，
帧号、POC、DPB 全部错位，表现是花屏/马赛克/丢帧，而不是"时间稍不准"。

修法很便宜：进 AU 判据前读 slice header 首字节最高位，`1` 才是新图（3 行）。
顺带两处小毛病：`t <= 31` 把 10–15、22–31 这些保留类型也算成 VCL；
`iru` 里含 39（前缀 SEI），若 SEI 出现在多 slice 帧中间也会误切。

### 1.5 没有 PTS 的连锁反应

管道里只有字节，`stream_next_au()` 只产出 `(指针, 长度, 是否关键帧)`，
时间维度只剩下一个 AU 序号。于是：

- **音画同步做不了**：视频靠 `-re` 跟随 wall clock，音频走 mpv 独立解码（`--no-video`），
  两路没有共享时钟，长片会缓慢漂移 —— 这是 §4.4 里的硬伤，根因在 demux 这一层。
- 不能按 PTS 丢帧/重复帧来补时基，递送节奏只能整体信任上游 ffmpeg。
- DRM 路径按 vblank 计数（§2.4），VFR 片源会越走越偏；GL 路径按 `-re` 的 wall clock，反而对 VFR 更稳。
- seek 没有 PTS 可用 ⇒ 只能重新解封装，精度归 GOP 所有（§5.4）。

想补 PTS 有两条路，都不便宜：
① 让 ffmpeg 输出 mp4/ts 到 fifo，hevcdec 自己当 demuxer —— 等于把 ffmpeg 的活重做一遍；
② 另起 `ffprobe -show_packets` 旁路，按 packet 序号对齐 —— 多一个进程 + 对齐失败风险，**不建议**。

### 1.6 "上游死了"和"片尾了"无法区分

```
ffmpeg 崩/被杀 → pipe 关闭 → read() 返回 0 → s_eof=1 → stream_done → drain → exit 0
```

EOS 就是这么来的：**正常播完和 ffmpeg 挂掉走的是同一条路**。
壳（`tvplay-node.sh`）只把 `| hevcdec` 的退出码当整条链的结果，拿不到前半段。
表现是播到一半画面冻在最后一帧、`pos()` 还在走、遥控器"有反应但不生效"。

反例更糟：ffmpeg 卡住不吐字节（HTTP 断流、磁盘 IO hang）时，主循环阻塞在 `read()` 里，
而 `STALLSEC` 看门狗挂在 `poll()` 超时分支（§1.10），**永远走不到**，
只能靠用户按 seek 触发 `EINTR` 才醒。

**已修：饿死看门狗挪进 `s_fill()`。** 阻塞 `read()` 换成 `poll(fd, 100ms)` 分片：
- 每 100 ms 醒一次 → seek（`SIGUSR1`）、`quit` 都能立刻打断，不必再靠"恰好落在 read" 的运气；
- 无字节超过 `STARVESEC`（默认 12 s，`0` 关掉）就判供流挂死 → `player_starve_recover()`：
  打一行 `STARVE: …无新字节，供流疑似挂死 → 就地重连当前位`，然后走普通 seek 那条路
  （kill ffmpeg + 新 `-ss` 重开 + L2 重建会话），DRM/GL 不动，不闪黑不掉 buffer，
  OSD 说"供流卡住，已就地重连"而不是"跳到 x"；
- 只在 spawn 模式动手（纯文件/管道直供没有"重连"可言，喊一声就够）；
  `pctl` 暂停期间不计时（暂停本来就不喂流）；
- 不自限重试次数：ffmpeg 真死会 EOF（`got>0` 则整链退出，交上层重启），
  只有"活着但不吐字节"才会一轮轮重连，那正是要救的场景。
- 实测（盒子，`SPAWN` 吐 300 KB 后把管道挂着不写、`STARVESEC=2`）：
  `STARVE 2.1s → 就地重开 0.000 → first frame → 播 2.6s → STARVE 2.1s → 重开 2.613s …`，
  位置一路前移，画面自己回来。

**已修：播放器把"片尾"和"上游死"分开，壳据此就地重连。**

- 播放器侧（spawn 模式，ffmpeg 是它的子进程）：`s_eof && got > 0` 时 `waitpid` 收尸，
  退出码 0 = 片尾（只 vlog），非 0 = 上游死在半路：
  `UPSTREAM: ffmpeg 退出码 137，停在 6.5s —— 不是片尾`，然后把位置写进 `$POSFILE`
  （控制口 socket 随进程一起没了，壳问不到 `pos()`，只能落文件），`return 3`。
  `1` 留给参数错误、`2` 留给"一帧没出"，三者不混。
- 壳侧（`play.sh` 的 spawn 分支）：`sh -c` 里套一层循环，`rc == 3` 就读 `POSFILE`
  当新 `-ss` 整条链重开，并把 `SS=` 回写进 state（遥控 / `status` 的位置才对得上）；
  `RECONNECT_MAX`（默认 3）次还死就放弃，免得网络全断时原地空转。
  管道模式没有"上游退出码"可看（`sh` 没有 `pipefail`），保持原样：只喊一声。
- 实测（盒子，`/tmp/t90.ts` 1280x720 HEVC，播到 6s 时 `kill -9` 掉 ffmpeg）：
  ```
  UPSTREAM: ffmpeg 退出码 137，停在 6.5s —— 不是片尾
  UPSTREAM: 壳就地重连，从 6.525s 重开（第 1 次）
  ```
  位置从 6.5s 续上，画面自己回来；同一条命令播 5s 短片到真片尾时**没有**任何
  `UPSTREAM:` 行，也没有重连——两种结束分得开。

顺带修的两个壳侧/显示 bug：
- `pos_of()` 把 `pos_ms` 又加了一次 `SS`：`pos_ms` 是**绝对**的（播放器把时钟原点
  挪到了 `-SS`：`g_t_clock0 = t_play0 - g_ss0`），从 40s 起播会显示成 80s。
  靠 HB `t=` 的兜底分支才是相对量、需要补 `SS`。实测修好：`SS=40` 起播 6s 后报 45s。
- 心跳 `quiet` 在读到第一个字节之前打印成 `now_s()` 本身（开机单调时钟，几万秒），
  看着像卡死 28000s。`t_last_rx == 0` 时归 0。

### 1.7 参数集探测（SPS）

- 输入 `argv[1]` 可以是文件，也可以是 `-`（stdin 管道，`tvplay-node.sh` 用的就是这条）。
- 只预读一小段（`PREFILL`，默认 1 MiB）用于求 SPS；管道里还没读到 SPS 时再预读 4 MiB 重试一次。
- `sps_size()` 自己解析 VPS/SPS/PPS 取真实宽高，失败才用 `argv[2]/argv[3]` 或默认 640x360。
  坑：`conformance_window` 的 `crop_left/right/top/bottom` 必须**紧跟 flag** 读，
  放到 `bit_depth`/`poc` 之后会读到错位比特（宽度被误裁 8 像素）。
- 探测走的是全局 `stream/stream_size`，预读窗口期间临时指向 `s_buf/s_len`，用完立刻置回 NULL。

**编码格式探测（`codec_detect()`）：只看首个 NAL 是错的。** 它的活是回答
"这条裸流该喂 H.264 还是 HEVC 解码器"（`CODEC` 没显式给的时候）。老实现看第一个
起始码后的字节：HEVC 的 VPS/SPS/PPS(0x40/42/44) 与 H.264 的 SPS/PPS(0x67/0x68) 不撞，
于是"两者不会撞"。但 **x265 默认带 AUD**（`nal_unit_type 35` → 字节 0x46），按 H.264 读
正好是 SEI(6)，整条 HEVC 流被塞进 H.264 解码器：SPS 求不出、`au=0`、一帧不出，
日志里只有 `CODEC: 自动识别为 H.264` 一行，看上去像"片子坏了"。

改成对前若干个 NAL 投票，判据用 HEVC **二字节** NAL 头的强约束：

- HEVC 头第二字节 = `nuh_layer_id` 低 5 位 + `nuh_temporal_id_plus1`（3 位），
  常规流里 layer_id=0、temporal_id_plus1≥1 ⇒ **恰好落在 0x01..0x07**；
- H.264 的 VCL NAL 在同一位置是 `first_mb_in_slice` 的 ue(v)，首图像 first_mb=0
  ⇒ 首比特为 1 ⇒ 该字节 ≥0x80，落不进这 7 个值；
- 再叠加类型分：HEVC 的 32/33/34/35/39 前导权重高，H.264 的 SPS/PPS/AUD(7/8/9) 权重高。

单看第一个头字节不行：H.264 的非 IDR 参考帧 0x41 右移一位正好是 HEVC 的 VPS 码位 32，
反过来 HEVC 的 IDR(19→0x26) 按 H.264 读是 SEI(6)。实测三条流（`x265` 带 AUD、
`x265 --no-aud`、`libx264`）现在都判对。

### 1.8 OUTPUT / CAPTURE 队列

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

### 1.9 背压（只服务于"播放"，不服务"测吞吐"）

只有 `PLAY=1` 时启用：

| 变量 | 默认 | 含义 |
|---|---|---|
| `FPS` | 24 | 目标播放帧率；`0` 表示不限速（跑满解码器） |
| `LEAD` | 6 | 解码领先显示多少帧就停止喂流 |
| `NOPACE` | — | 置位等于 `FPS=0 LEAD=0` |

循环里 `if (play_pace > 0 && lead > 0 && au_idx - got >= lead) break;`
——解码器能跑 100 fps，但显示节拍由屏幕决定，领先太多只会把 20 个 capture
buffer 填满、在显示前丢帧。

### 1.10 自愈：`g_reinit` 重建 V4L2 会话

meson-vdec 的硬约束：**同一个 V4L2 会话里不能换码流**，seek/分辨率跳变/驱动 abort
都会 `"Unrecognized dec_status 0000000F / Aborting decoding session"`。
所以重建 = 关掉 `/dev/video0` 重开，但 DRM master、crtc/plane、GL 上下文都在别的 fd 上
→ **屏幕不黑**（方案 A/B 都靠这一点）。

重建流程要点：

1. 把管道里上一段流的残留读空（临时切 `O_NONBLOCK` 读到 `EAGAIN`），`s_len/s_pos/s_au_*` 清零。
2. 进 `RAP_WAIT`（§1.14）：必须等下一个可接受 RAP 才喂。续喂到 GOP 中间，驱动 ref list 是空的，
   每帧报 `"Couldn't find ref. frame 0"`，几帧内静默挂死（清零后实测 8 帧就死）。
   坑：①切分层只报类型（16..21），**收不收 CRA 是策略**；而 CRA 是 open GOP 的头，
   它后面的 RASL 帧参考 CRA 之前的帧 —— 新会话里没有那些帧，等于把上面的挂死重新走一遍。
   实测片源的 RAP 分布见 §1.3（10 个 RAP 里 9 个是 CRA），所以这不是理论问题，是常态路径。
   ② CRA 的 NAL 头里其实有 `HandleCraAsBlaFlag` 可用，但驱动不吃这个协商；能做的只有
   "跳过 RASL AU"（§1.3 已能识别）或"退回找 16..20"。策略与代价见 §6。
3. 只有固件真 hang 才走 `g_hard_reset_on_reinit`（VDEO 整块掉电复位）；seek 不付这个代价。
4. 触发源：
   - `SIGUSR1` → seek（`sa_flags = 0`，**不能带 SA_RESTART**，否则信号被延到下一帧数据，
     seek 白等几秒；`xioctl()` 里 `g_reinit` 时直接返回 `EINTR` 让主循环处理）；
   - `POLLERR` → 驱动 abort，自愈上限 `ERRREC`（默认 4），出帧后 `g_err_rec` 归零；
   - STALL 检测：`STALLSEC`（默认 1.5s）无新帧**且驱动手里压着 AU**（`au-got > 0`）；
     门控态（等 RAP / 跳 RASL）的超时归状态机自己管（§1.14 的超时表），不走这一路；
     只有 AU 压着却没吐帧才是驱动挂死——供流打嗝（`au-got == 0`）只打 `STARVE:`
     一行、不重建。`PLAY` 态的 poll 周期也从 2000ms 收到 200ms，否则看门狗
     （挂在 `pr==0` 分支）的检测分辨率就是 2s，阈值再小也没用；
   - `FORCEREINIT=N` 在第 N 帧主动走一遍自愈，用于确定性验证。

**暂停识别**：`tvplay` 的"暂停"是 `pkill -STOP` 整条链。进程被冻住期间
`CLOCK_MONOTONIC` 照走而主循环一轮都没转，不处理的话 resume 后第一次 poll 超时
会算出 `quiet = 暂停时长`，被误判成 STALL 去重建会话（闪黑 + 掉 buffer）。
做法：每轮记 `t_loop`，若本轮间隔 > 4s（正常最多一个 poll 周期 2s），
把 `t_last_rx` 重置为 `now-2.0`。

### 1.11 为什么不链 libavformat（决策记录）

§1.1 那句话说得很轻，实际是一笔明码标价的交易。结论：**当前不链；但这是可翻案的，
翻案条件写在最后。**

要自己 demux，就得把 ffmpeg 现在白送的这些重做一遍：

| 现在 ffmpeg 白送 | 自己链 libavformat 要写 |
|---|---|
| 容器探测（MP4/MKV/TS/HTTP/RTSP） | `avformat_open_input` + 各协议注册，还要处理 HTTP 重连 |
| 选流 | 扫 `fmt->streams[]` 找 `codecpar->codec_type==VIDEO` |
| 起始码 → AU | 不用写（`av_read_frame` 一个 packet 一帧），这是**唯一省事的** |
| `-ss` 定位 | `avformat_seek_file` + `avcodec_flush_buffers` + 等 IRAP |
| `-re` 节流 | 自己算 `pts - last_pts` 睡，等价于重写 `-re` |
| 送字节进管道 | 不用送，直接 `QBUF`，省掉一次拷贝和一整个进程 |
| 音轨抽取 | `-map 0:a` 交给 mpv 的那部分也要自己做（或继续让 mpv 直读 URL） |

四条现实成本，按"疼"排序：

**① 交叉编译环境里根本没有 libav。**
实测：`/usr/aarch64-linux-gnu/lib` 与 `/usr/aarch64-linux-gnu/include` 下
没有任何 `libav*`（连头文件都没有），只有 x86_64 的。所以"链 libavformat"的真实起点是
**先给 aarch64 编一份 ffmpeg 静态库**：configure + 交叉工具链 + `zlib/bz2/lzma/ssl`
一堆依赖，产物几十 MB。`crosslib/` 里现在躺着的 7 个 `.so` 是 EGL/GLES/gbm/drm/expat —— 
GL 那摊已经为"静态链"付过一次这样的学费了。

**② libavformat 给的是"字节 + PTS"，不是"上屏节拍"。**
`-re` 那套限速是 ffmpeg CLI 的特性，库里没有。链了库仍要自己写节流循环，
否则解码器照样跑满 —— 换句话说 **§3.5 的 `-re` 需求不会因为换 demux 而消失，只会换个人实现**。

**③ 进程隔离会丢。** 现在 ffmpeg 崩了是它自己崩，hevcdec 只是读到 EOF；
链成库之后 demux 崩 = 播放器崩，一个畸形 MKV 能带走整条链。

**④ seek 从"杀进程重开"变成状态机。**
现在是 `pkill` + `restart_at`（§5.4），逻辑粗糙但没有状态泄漏；
库里得自己管 flush、DPB 残留、目标帧之前的丢弃 —— 正是 `X96Max-Player.md` §1.5
要新建 `SEEKING/RESYNC` 两个状态的理由。

那收益值不值？**真 PTS 这一项就够格，因为现在的窟窿是硬的**：

- `v4l2hevc.c:379-380` 把 output buffer 的 timestamp 硬编码成 `g_au_seq / 25` —— 25 fps 是焊死的；
- 而配速默认值在 `:1599` 是 `24.0`，`tvplay-node.sh` 又按 `FPS=` 传 0（=不限速）；
- 也就是说**同一个片子，送帧时按 25 算、上屏时按 24 算或不限速**，两个数都跟片源无关。
  1080p 以下看不出（24/25 差 4%），4K 就是 §3.5 记的"快 15%"那类漂移的放大器。
- 附带白拿：`duration`（现在 `probe` 要 fork 一次 `ffprobe` 只为拿一个数，
  且 `-ss` 之后这数就不对了）、色彩传递元数据（§3.3 的 HDR 判定现在靠 `HDR=1` 环境变量猜）、
  以及多 slice 帧的 AU 边界（§1.4 那个补丁根本不用写）。

**为什么现在不翻案**：上面四个成本里 ①③ 是一次性但很重，②④ 是持续维护成本；
而当前离"能稳定看片"还差着 AU 判据和上游存活检测（§1.4/§1.6），
先修那两处能把体验拉直，成本是几行。

**翻案条件（任一触发就动手）**：
- 需要音画同步（多音轨/VFR 片源进场）；
- seek 精度要优于 GOP（现在是 1–2 s）；
- 要放本地 MKV/内嵌字幕，或要做预取播放列表（`X96Max-Player.md` §1.4）。

翻案不是重写，是替换 §1.1 表里的前两行：`X96Max-Player.md` §1.7 的 **B 步**
（`demux.c` + 真 PTS，删 `-re`）就是这件事的最小切口，C 步接时钟。**B 之前一切同步都是猜，B 之后才是算。**

顺带排除的中间态：**另起 `ffprobe -show_packets` 旁路补 PTS**。
多一个进程、多一次全片扫描、还要按 packet 序号和管道字节对齐，
对齐一旦失败就是静默的错帧 —— 比现状更差，不要走。

### 1.12 音频：整段外包给 mpv（决策记录）

一句话：**hevcdec 里没有一行音频代码**（`v4l2hevc.c` 全文 grep `audio|alsa` 为空），
声音由第二条命令 `mpv --no-video --ao=alsa --audio-device=alsa/hw:0,0` 独立出声，
两边唯一的约定是**同一个 `--start`**（`tvplay-node.sh:79-86`）。

| 环节 | 谁做 |
|---|---|
| 解封装 + 音频解码 + 重采样 + 声道映射 | mpv（自己再开一次 URL） |
| 音轨选择 | mpv `--aid=$TRACK`；注意 `TRACK` 是 mpv 的 aid，**不是列表游标** |
| 输出 | ALSA `hw:0,0` 直出，无 dmix、无 plug |
| 音量/静音 | `mpvctl` → `--input-ipc-server=/tmp/tvplay.sock` |
| 暂停 | `pkill -STOP/-CONT`（视频 2 个 pattern + mpv 2 个 pattern） |
| 位置 | **没人读 mpv 的 `time-pos`**；`pos()` 只算 wall clock |

**为什么不自己出声**：`docs/playback.md:182` 的实测 —— 这块板子上 `ffmpeg -f alsa`
单跑 8 秒就 15 次 xrun，属硬件 period 太浅（PLAN B §:160 同记）。这是硬证据不是偏好：
在没有 dmix/大 period 之前，自己在进程内出音必然断断续续。

**代价，按"用户能不能感觉到"排序**：

**① 同一个 URL 被读两遍。** ffmpeg 供视频、mpv 供音频，各自打开 `$URL`：
HTTP/WebDAV 源带宽 ×2、起播多一次握手，且 `--cache-secs=20` 让 mpv 的读位置
和视频**彻底脱钩**——它可以先跑 20 s，也能落后 20 s，没人管。

**② 同步是"对齐同一个 START"，不是时钟从动。** `-re` 按平均码率跟 wall clock，
ALSA 跟采样时钟，两个独立晶振（§4.4、`X96Max-Player.md` §:411 已记"漂移无界"）。
没有丢帧/补帧，只有缓慢分离；短片看不出，长片必然。

**③ seek 是两条路径。** HEVC 链在 spawn 模式下走播放器控制口（`pctl seek N` /
`seekto N`，就地跳，§5.4），接不住才 `restart_at` 整链重开（带新 `--start`）；
`PLAYER=mpv` 时走 `mpvctl seek`。两个目标位置**只能靠人手保持一致**，
`START/OFF/PAUSE_AT` 三个变量存在的唯一理由就是让 `pos()` 自洽（§5.4）。

**④ 暂停必须两个进程一起打。** 只 STOP 视频 = 画面冻住声音照放；只 STOP mpv = 哑掉。
`toggle` 的判据因此是 `pgrep v4l2hevc-aarch64` 而**不是 state**（实测 state 会撒谎：
HEVC 链在放、state 写着 mpv，于是 toggle 发给一条空 socket，什么都没发生）。

**⑤ 音量是一次 IPC 往返。** `mpvctl` 读 `get_property volume` 再 `set_property`：
必须 `MPVCTL_ECHO=1`，否则回显为空、每次都按 100 算（实测连按减 12 次只掉到 90）；
且必须夹 `0..100`，mpv 的 `add` 会累加，>100 削波（实测被连按到 130，晚上炸响）。

**⑥ `AUDIO=0` 的片源没有钟。** 无声片只剩 `-re`，既无音频钟可依，也没有人检测
"mpv 死了"（§1.6 那张表只覆盖上游 ffmpeg）。

**为什么不翻案**：mpv 白送解码/重采样/音轨切换/声道映射/变速，代码 0 行；
代价全部集中在上面三处用户可见的地方，且 §5.3/§5.4 已逐个堵过（合并 seek、双 pattern
暂停、音量夹取）。自己出声要先把 ALSA 深缓冲解决，那是另一条独立战线。

**翻案条件**：ALSA 缓冲问题被解决（dmix + 更大 period，或 mmap 大 period 直出），
音频进同一进程/同一时钟域 —— 那时 "①双读 ②漂移 ③双 seek ④双暂停 ⑤IPC 音量" 一次性全消失。
但顺序必须是**先修视频的钟**（§1.11 的 B 步、§3.5 的 `-re`）：两个错的钟做同步，
得到的不是同步而是更精致的漂移。

### 1.13 独立音频输出模块 `aout`（§1.12 的翻案第一步）

§1.12 把翻案条件写成"ALSA 缓冲问题被解决"。这一节就是那一半：
**不再让 mpv 出声，也不链 libasound**，自己写一个 400 行的 PCM 直出进程。
文件：`aout.c` / `aoutctl.c`（静态 aarch64 二进制 790 KB + 700 KB，零动态依赖）。

一句话定位：**`aout` 只做一件事——把 stdin 上的 PCM 灌进 `hw:0,0`，
并回答"我播到第几毫秒了"。** 解码/重采样/音轨选择仍然外包（给 ffmpeg），不重复 §1.12 的工作量。

```
ffmpeg -i "$URL" -map 0:v:0 -c:v copy -f hevc pipe:3 \
                -map 0:a:0 -ac 2 -ar 48000 -f s16le pipe:4  3> v.fifo  4>| aout
```

两个输出走 ffmpeg 的两个 fd（`pipe:N`，N>2 是 ffmpeg 支持的），所以
**URL 只读一遍**——§1.12 的代价 ① 直接消失，顺便拿到"视频音频同一个 `-ss`"这个天然对齐。

| 环节 | 谁做 | 说明 |
|---|---|---|
| 解封装 / 音频解码 / 重采样 / 下混 2.0 | ffmpeg（`-ac 2 -ar 48000 -f s16le`） | `aout` 要求输入已经是 48 kHz 立体声 s16le |
| 打开硬件、period/buffer、xrun 恢复 | `aout`（裸 `SNDRV_PCM_IOCTL_*`） | 不经过 `plug`/`dmix`/`pulse` 任何插件层 |
| 音量 | `aout` 内部整数增益 | 0..100，`vol +5` 的相对量**在模块内部算** |
| 暂停 | `aout`，两级降级 | 先 `SNDRV_PCM_IOCTL_PAUSE`，dai 不认就写静音占住 dma |
| 位置 | `aout` → `played_ms = (written - delay)/rate` | 从 `HWSYNC`+`DELAY` 读，不是推算 |

**接口**（一行一条，应答一行 JSON）：

```
$ aoutctl status
{"state":"RUNNING","pause":0,"played_ms":6198,"delay_ms":170,
 "buffer_ms":170.7,"period_ms":42.7,"vol":100,"xrun":0,"rate":48000,"ch":2,"written":...}
$ aoutctl vol +5      # 模块内部夹 0..100，绝不会像 mpv add 那样累到 130
$ aoutctl toggle
```

环境变量：`AOUT_DEV`(默认 `/dev/snd/pcmC0D0p`) `AOUT_RATE` `AOUT_CH` `AOUT_FMT`
`AOUT_BUFFER`(默认 8192 帧=170 ms) `AOUT_PERIOD`(默认 2048 帧=43 ms) `AOUT_SOCK` `AOUT_VOL`。

**四个设计决定，都是为了不重犯 §1.12 的病**：

1. **不链 libasound。** 板上只有 `libasound.so.2` 运行时（`/usr/lib/aarch64-linux-gnu/`），
   没有头文件也没有交叉库；更要紧的是 `snd_pcm_set_params()` 会替你定 period ——
   mpv 的 ao_alsa 就是这么拿到 200 ms 浅缓冲的。这里直接用内核 uapi
   `sound/asound.h`（架构无关，交叉编译零成本），参数由 `AOUT_BUFFER/AOUT_PERIOD` 说了算。
2. **阻塞写当时钟。** `SNDRV_PCM_IOCTL_WRITEI_FRAMES` 在 ring 满时阻塞，
   等于内核按采样率节流：喂到第 N 帧 = 播到第 N 帧 - `delay`。不需要 `usleep` 自己算节拍，
   也就不需要 `-re` 那种按平均码率猜的钟（§3.5 的病根）。
3. **音量在样本上做，不在 IPC 上做。** §1.12 代价 ⑤ 的根因是 `mpvctl` 读旧值写新值；
   这里 `vol +5` 一支命令、一次应答，连按 12 次就是 12 次 ±5，不会丢。
4. **xrun 自己吞。** `EPIPE` → 计数 + `PREPARE` 重来，进程不退出、播放器不用管
   （§1.6 那张表里"上游死了"和"片尾了"分不清的问题，音频侧不再制造新的噪声）。

**板子实测（`aoutprobe`，见 `aoutprobe.c`）**：

- `card0 = axg-sound-card X96-MAX`，三个 playback 设备，但 **`D1`/`D2` 打不开**
  （`open` 返回 `EINVAL`，dai-link 无 pcm ops），实际只有 **`D0`** 能用 —— 与 mpv 用的 `hw:0,0` 一致。
- `D0` 是**独占单 subdevice**，mpv 正在播时再 `open()` 不返回 `EBUSY` 而是**直接挂住**
  （实测两次 `timeout 6` 被打断，stderr 一个字都没有，连 `SNDRV_PCM_IOCTL_INFO` 都没跑到）。
  运维含义：**任何探测/切换前必须先停掉占用的进程**，别指望 `fuser` 看到就能优雅抢占。
- 这个内核的 `/proc/asound/card0/` 下没有 `pcm0p/` 目录（只剩 `id`/`eld#7`），
  想看 `hw_params`/`status` 只能自己 ioctl —— `aoutctl status` 就是为这个补的洞。

**未验证 / 风险**（不在这一节吹牛）：

- 大 buffer 能否真的压掉 `docs/playback.md:182` 的"8 s 15 次 xrun"——`aoutprobe` 已写好三种规模
  （2048/512、8192/2048、32768/8192）对比，**必须在声卡空闲时跑**（上面那条挂住的坑）。
- `SNDRV_PCM_IOCTL_PAUSE` 在 axg 上是否支持：不支持会自动降级为写静音，代价是
  暂停期间 dma 仍在跑（功率、以及"暂停位置上 `hw_ptr` 还在前进"要靠 `g_frozen_ms` 冻结）。
- 硬件是否给 32768 帧的 buffer（AXG fifo 深度通常只到几十 KB）；给了才有 170 ms 以上的
  抖动余量，不给就把 `AOUT_BUFFER` 压回 8192 并接受更紧的调度。
- **音画同步还没接。** `played_ms` 出去了，但视频侧还没拿它当从时钟（§1.11 B 步）。
  现在只是把"能测的钟"造出来，从动逻辑仍归视频那边。

---

### 1.14 RAP 门控状态机：转移、错误边、超时

§1.3 的结论是"类型要当策略输入"，一个 `g_need_irap` 布尔量不够用：它表达不了
"收了 CRA 还得连带丢 RASL"、"strict 等不到 IDR 多久该降级"、"等 RAP 等多久算真没有"。
所以门控做成三状态机（`v4l2hevc.c`：`RAP_PLAY / RAP_WAIT / RAP_RASL` +
`rap_enter / rap_accept / rap_tick`）。

**状态与不变式**

| 状态 | 含义 | 不变式 |
|---|---|---|
| `PLAY` | 正常喂流 | 只有它会触发 `STALLSEC` 看门狗 |
| `WAIT` | 新会话/seek 后等 RAP | 进来的 AU 全丢（`g_rap_drop++`），只有 `rap_accept()` 放行的 RAP 能出去 |
| `RASL` | 已收 CRA，正在丢它后面的 RASL | 出现一个非 RASL AU 才回 `PLAY` |

`rap_accept(rap)`：16..20（BLA/IDR）恒收；21(CRA) 在 `RAPMODE=cra`（默认）或已降级时收，
`strict|idr` 只在降级后收；其余不接受。

**正常转移（由下一帧的类型触发）**

| 边 | 触发 | 动作 |
|---|---|---|
| `WAIT → PLAY` | 收到 16..20 | 喂这一帧 |
| `WAIT → RASL` | 收到 21 且策略允许 | 喂 CRA，标记接下来丢 RASL |
| `RASL → PLAY` | 非 RASL AU（`s_au_last_rasl == 0`） | 喂这一帧，转入正常播放 |
| `PLAY → WAIT` | `g_reinit`（seek / POLLERR / STALL / FORCEREINIT） | 重建后必然回 `WAIT`，计数器归零 |

**错误转移（不是"下一帧类型"能表达的那些）**

| 边 | 触发条件 | 后果 |
|---|---|---|
| `WAIT → WAIT`（丢） | 收到 P/B，或 strict 下的 CRA | 只丢不重建；计时器**不**重算，避免"一直有垃圾数据流入"把超时无限推后 |
| `RASL → WAIT` | RASL 段超预算（> `RAPRASLMAX` AU 或 > `RAPRASLSEC`） | "CRA 后只有 RASL"的假设不成立，退回重等；`g_rap_rasl_over++` |
| `RASL → 退出` | 同一会话里第 3 次超预算 | 判死（`rap_tick` 返回 2），避免"退→等→又超"死循环 |
| `WAIT → 重建` | 超过 `IRAPWAIT` | **软**重建（`g_hard_reset_on_reinit = 0`）：RAP 缺失是流的问题，掉电复位治不了；计入 `g_err_rec`，超过 `ERRREC` 退出 |
| `任何 → 清计数` | 真出帧 | `g_err_rec = 0`（原有自愈归零语义不变） |
| 流 EOF（`r == 0`）且不在 `PLAY` | 上游结束 | 打一行"流里没有可用 RAP（丢 N AU，原因）"再收尾，而不是静默等超时 |
| seek（`r < 0`） | `SIGUSR1` 打断 `stream_next_au` | 状态**不动**（下一轮重建会 `rap_enter(WAIT)`），避免重建前误判 |

**超时表**（全部可 env 覆盖，`0` = 不限）

| 变量 | 默认 | 作用域 | 超时后 |
|---|---|---|---|
| `RAPSTRICT` | 3.0 s | `WAIT` + `RAPMODE=strict` | 每会话降级一次：接受 CRA，计时器重算 |
| `IRAPWAIT` | 60 s | `WAIT` 的绝对上限 | 软重建（计入 `ERRREC`） |
| `RAPRASLMAX` | 8 AU | `RASL` | 回 `WAIT`；累计 3 次判死 |
| `RAPRASLSEC` | 1.5 s | `RASL` | 同上 |
| `STALLSEC` | 1.5 s | 仅 `PLAY` 且 `au-got > 0` | 硬复位重建（原语义） |

两个必须一起改的地方，否则互相打架：

1. **暂停（`pkill -STOP`）**：`t_loop` 间隔 > 4s 时除了把 `t_last_rx` 挪到 `now-2.0`，
   还要把门控计时 `g_rap_t0` 一起挪（§1.10），否则 resume 后第一轮就撞
   `RAPSTRICT/IRAPWAIT` 去重建（闪黑 + 掉 buffer）。
2. **STALL 与门控互斥**：`STALLSEC` 只在 `PLAY` 生效。门控态按定义不出帧，
   用"无新帧"判死会在长 GOP 上无限重建（GOP > 12s 的片源存在）。

`RAPDBG=1`（或 `VERBOSE=1`）打印每条转移：`RAP WAIT -> RASL (CRA) drop=0`，
配合 §1.3 的 `RAPDBG au=.. rap=.. rasl=..` 能把"丢了多少、为什么丢"对到具体 AU。

### 1.15 重建一次到底丢多少（实测，不是估算）

上面全是"该怎么走"，没人量过"走一遍的代价"。量法：`FORCEREINIT=N` 在第 N 帧主动
走一遍「固件死 → L3 复位 → 等 RAP → 续播」（同一段码流，正常播放不会出现），
`SYNC=1` 每 24 帧打一行：

```
SYNC got=312 audio_ms=14634 frame_pos=13.00 audio_pos=14.56 d=+1560ms
```

`d` = 音频走过的时长 − 画面帧号走过的时长；`RAP WAIT -> PLAY (… ) drop=N` 给出
被跳过的 AU 数。4K 片源（Sicario，`-ss 3400`）两次实测：

| 次 | 丢掉 AU | 画面跳过内容 | TX 重建 | 事件前后 `d` |
|---|---|---|---|---|
| #1（落到 CRA 前 3 s） | 74 AU | 3.08 s | 228 ms | −1.80 s → +1.55 s |
| #2（紧挨 IDR 之后） | 29 AU | 1.21 s | 199 ms | −1.82 s → +0.02 s |

把 `d` 拆开才不会读错：`d = s(t) − s0 + S`（`s` = 真实声画内容差，`S` = 累计被跳过的
画面内容）。两次的 `s` 都仍然等于 `s0 − 1.2…1.5 s`——那个 −1.5 s 是起播锚点的固定
偏置（音频 ring 预灌，`got=24` 时 `played_ms` 才 74 ms），事件前后没变。也就是说：

> **重建的语义是"整条时间轴一起跳过去"，不是"画面掉队"。** 声画关系不变，
> 没有累积错位；代价是这一跳里**两边都少了一段**，而且这段长度就是
> "从挂死点等到下一个 RAP"的时长。

本片 RAP 间隔实测（`ffprobe -skip_frame nokey`，3400–3450 s 一段）2.2 / 2.4 / 3.5 /
3.8 / 4.7 / 4.9 / 6.1 / 10.0 s，最大值 10.0 s——GOP 长度本身就不齐，
所以一次自愈的用户可见代价 = `STALLSEC`（1.5 s 冻帧）+ 到下一个 RAP 的等待
（0 ~ 10 s，上界是一个 GOP）。**瓶颈在等 RAP，不在重建**：L3 复位 + COMMIT 只花
200 ms，把 `STALLSEC` 从 12 s 收到 1.5 s 省下的是冻帧，跳段长度一点没变。

要不跳段只剩一条路：挂死后**退回上一个 RAP 重解**（`seek` 回 `pos − GOP`）。代价是
整链重开（~0.8 s 黑屏，§5.4）+ 重放一段，与"自愈不黑屏"的目标直接冲突，当前不做。
`SYNC=1` 这个探针留着：以后要改自愈策略，先用它证明声画关系没被改坏。

---

## 2. Renderer A（`drm`）：KMS overlay plane 零拷贝直上屏

代码：`vout.c`（提交/队列/节拍/完成反馈）+ `render_drm.c`（薄适配）。
产物：就是 `v4l2hevc-aarch64` 本身，`RENDER=drm`（`auto` 时优先）。
播放器侧已无 DRM 代码：只有 `render_submit()` / `render_pump()` 两个调用点。

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

### 2.5 统一帧队列：提交 / 队列 / 槽位 / 完成反馈（`vout.c`）

老接口 `vout_frame()` 是同步的：等 vblank → SETPLANE → 返回。24 fps 下每帧
被 vblank 卡住 16~41 ms，解码线程和上屏线程只能串行。四个概念拆开之后才对：

| 概念 | 在哪 | 代价 |
|---|---|---|
| 提交 `vout_submit()` | `PRIME_FD_TO_HANDLE` + `ADDFB2` | 几十 µs，不等 vblank |
| 队列（深度可配，默认 1） | 环形缓冲，只存 fb_id 引用 | 每多一帧多一帧显示延迟 |
| 槽位 `pts_slot()` | `(pts-pts_base)*refresh` → 绝对 vblank 序号 | 一次 `WAIT_VBLANK(ABSOLUTE)` |
| 完成反馈 `cb` | 下一轮 pump 核 `cur >= prev_latch` | 粒度 1 帧（legacy ioctl 拿不到 flip event） |

**一次 submit 恰好换一次回调**（`VOUT_SHOWN` / `VOUT_DROPPED` / `VOUT_ABORTED`），
这是调用方能安全回收 dma-buf 的唯一依据：submit 只拿 GEM handle 引用，fd 交回
调用方没问题，但**内存不能被解码器 QBUF 回收改写**——`vdec` 复用那张 buffer，
屏上就是花屏。所以深度 >1 时必须等回调再 `QBUF`；深度 1（同步）沿用老规矩，
返回即可回收。清队/`flush`/`close` 都逐帧发 `VOUT_ABORTED`，绝不静默吞帧。

**丢帧**分两处，都是"新的赢"：

```c
/* 提交时：目标槽已经过去 ≥2 个 vblank → 不上屏 */
if ((long long)slot - (long long)cur <= -2) { drops++; stales++; return VOUT_DROPPED; }
/* 入队时：队列满 → 丢最老的那张，给新帧腾位置 */
if (qn >= qmax) { 丢 q[qh]; }
```

24 fps @ 60 Hz 每帧只吃 2~3 个槽，补一帧就连累后面一串，丢掉反而更稳
（H.265 短 P 链少一帧很耐看）。队列满时丢最老而不是阻塞生产者，
是为了不让延迟越攒越大——阻塞会让"慢 1 帧"变成"慢 1 秒"。

**完成反馈怎么核**：`SETPLANE` 不会立即生效，要下一个 vblank 才接管扫描，
所以目标槽 T 的帧真正开始扫描是 T+1。下一轮 pump 拿当前序号比：

- `cur >= prev_latch` → 确实吃到了 vblank，回调 `VOUT_SHOWN` 并给出真序号；
- `cur < prev_latch` → 两次 SETPLANE 挤进同一个 vblank，后一次盖掉前一次，
  前帧**一帧都没被扫过** → `misses++`，按 `VOUT_DROPPED` 回报。

这条 `miss` 计数就是"flips 在涨但人眼看不到"的唯一探针。要更细的时序就得换
atomic（flip event），见 §2.1 / 文件头注释里的取舍。

用法（`./vout-selftest queue` 会验这套账）：

```c
vout_set_queue(v, 2);
vout_set_displayed_cb(v, on_shown, ctx);       /* 回调里 owner 还回 vdec */
for (;;) {
	vout_submit(v, fd, w, h, yp, cp, pts, buf);  /* 几十 µs */
	vout_pump(v, 0);                             /* 非阻塞：该翻的翻，不等 */
}
vout_wait_shown(v, 200);                       /* 暂停/收流前把画面钉住 */
```

---

### 2.6 无 GPU 时的 HDR 处理：就地软件色调映射

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

## 3. Renderer B（`gl`）：EGL/GBM + GLES3 着色器（HDR10→SDR）

代码：`glout.c`（绘制）+ `render_gl.c`（薄适配）。产物：同一个 `v4l2hevc-aarch64`。
开启：`PLAY=1 RENDER=gl`（`auto` 只在这些后端里挑第一个可用的，不做"源是 HDR 就自动换"）。

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
→ clamp → 抖动（降饱和不在这里：sat 已进 LUT 的色度增益）
→ hash 抖动 ±0.5/255 消除渐变色带
```

色度增益来自 LUT 的 G 通道：`gain = 1 + sat*(nout/n-1)`（`hc_build`，与软映射
`hc_chroma709` 同一规则，`sat` 默认 0.90 / `TM_SAT` 可覆盖）。**不在片元里 mix 到
亮度**——那样暗饱和色被压暗、亮饱和色给缺失通道灌能量，且与软映射出图不一致。
片元的 `uSat` 恒为 1.0，只保留成恒等 mix 的兼容壳。

### 3.4 两遍渲染（默认开）

`g.twopass = !GL1PASS`。`twopass_frame()`：

- **pass1**：按"**源尺寸**、封顶 `GL1MAX`（默认 1920x1080）"渲染到 FBO 纹理
  `tex_rgb`(RGBA8)。注意是源尺寸而不是屏幕尺寸 —— 720p 源在 1080p 屏上，
  pass1 就是 1280x720，之后 pass2/DPU 才放大；所以 `DPUSCALE` 省不到 pass1
  的钱（§4.1.4 结论五有实测）。4K 源全尺寸做色调映射是 8.3M 片元（~54 ms），
  被 `GL1MAX` 压到 1080p 只有 2M（~37 ms）；1080p 源再往下压到 720p 是
  6.8 ms/帧、5.8 fps 上限，画质 PSNR 37.7 dB（能看出软），默认不压。
- **pass2**：`FS_COPY` 把这纹理按等比+黑边画到 GBM surface（`VS2` 不翻 UV，
  因为 pass1 的 VS 已经翻过一次，再套会上下颠倒）。
- 单遍路径（`GL1PASS=1`）直接在 surface 上用一句 `glViewport` 摆等比黑边。

最后 `eglSwapBuffers()` 提交；`flip_handler` + `wait_flip()` 可选地等 page flip 事件，
`GLTIME=1` 时 `glFinish()` 并统计 `t_sum/t_max`（片元耗时）。

#### 3.4.1 实测（`glselftest run`，2560x1440@60，Mali-G31 Panfrost）

彩条，`GLTIME=1` 的绘制耗时与每帧墙钟（墙钟含 `wait_flip`，按 vblank 量化）：

| 源尺寸 | 路径 | GPU 绘制 | 墙钟 | 实际帧率 | 判读 |
|---|---|---|---|---|---|
| 1280x720 | 两遍（默认） | 14.9 ms | 16.7 ms | 59.5 fps | 刚好装进一个 vblank，余量 1.8 ms |
| 1280x720 | 单遍 `GL1PASS=1` | 33.2 ms | 33.4 ms | 30 fps | 整屏做完整色调映射 → 掉到 2 个 vblank |
| 1920x1080 | 两遍 | 25.0 ms | 33.4 ms | 29.9 fps | pass1 超预算 50%，被量化成 2 个 vblank |
| 3840x2160 | 两遍 | 26.5 ms | 33.4 ms | 29.6 fps | pass1 被 `GL1MAX` 卡在 1080p，和 1080p 源同价 |

`eglSwapBuffers()` 本身只要 0.13 ms，其余时间全在 `wait_flip()` 里——所以 GL 通路
**有显示侧节拍（每帧等 flip 完成），没有片源侧时钟（`glout_frame()` 连 pts 参数都没有）**。
两者的差别就是"FPS 是假的"那句话的真意：它不丢帧，只会整条流水线一起慢。

1080p 停在 33.4 ms 这一点很险：24fps 的预算是 41.7 ms，只剩 8 ms；
上屏侧多蹭一个 vblank 就变 50 ms = 20fps。真实播放日志
（`PERF tm = 33.57 ms/frame`，1080p24）与彩条几乎重合，说明瓶颈在 GPU 而不在测试卡。

### 3.5 为什么必须有 `-re`

方案 B 没有 vblank 节拍器（`FPS` 对它无效），谁先出帧谁上屏。
不靠 `ffmpeg -re` 就会按解码速度播放（4K 实测快 15%，1080p 会飞）。
`tvplay-node.sh` 因此在供流命令里硬编码 `-re`。

### 3.6 性能变体：GL 只做源分辨率映射，放大交给 DPU（未并入主干）

`glscale.inc`：把 pass1 的目标从 surface 换成 **3 个轮转的 dumb buffer**
（`NRT=3`，各 `EGLImage` + `FBO`），渲染完直接 `drmModeSetPlane` 让 DPU 硬件放大到屏幕。
片元数从屏分辨率降到源分辨率（720p 源 = 屏的 1/4）。

**状态如实**：这份代码从未被编译进任何目标文件 —— 全仓库除自身外零引用
（`grep -rn glscale` 无输出），`glout.c` 没有 include 它，文件内全是 `static` 函数。
注释里"实测 28 fps → 55 fps+"是从 §3.4.1 两遍路径搬过来的数字，
不是这条路径的实测值（两者机制的差别见 §4.1）。它自己能跑（`glFinish`(145) →
`SetPlane`(154)，等比黑边 `dx/dy`(148-152) 都是完整的），缺的是接入时要解决的
三件事：从未被 include、`S.cur` 盲轮转不等扫描输出(129)、以及 `pick_primary_plane()`
抢的就是正常路径那张透明 primary —— 和 `eglSwapBuffers` 争同一个 crtc。逐条见 §4.1.1。
**2026-11-19 补**：两条最省事的落地路径已在盒子上量过了（§4.1.5）。
结论是 `glscale` 这套 dirty 的三缓冲/SetPlane 躲不掉——把渲染目标缩小再走
`eglSwapBuffers`（形态 A）会被驱动直接挡住（legacy `SetCrtc` 收小 fb → ENOSPC）。

---

## 4. 渲染方案：A、B 与最终管线

A / B 是两条已经跑通的实现，**都不是终点**：§4.1 是两者收敛后的目标形态
（A 的上屏/节拍 + B 的色彩），A、B 各自的毛病记在 §4.2/§4.3，作为取舍依据保留。

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
| 缺点 | 无色彩处理 + 平台绑死（见 §4.2） | 无节拍 + 吃 GPU + 依赖重（见 §4.3） |
| 典型用途 | 低分辨率/无 HDR 片源、逐帧一致性验证 | 实际观影（HDR10 4K） |

一致性的结论（README）：与 ffmpeg 软解逐帧 md5 比对，640x360/720p/1080p
各 ~300 帧全部 bit-exact；纯解码吞吐 105~140 fps（`NBUF_OUT=16 NOWRITE=1`）。

### 4.1 最终渲染管线

**一句话**：片元只在**源分辨率**上跑，放大和上屏交给 DPU；GPU 唯一的活是把 HDR 变成 SDR。

```
vdec dmabuf (NV12) ──EGLImage──▶ 纹理 y/c
                                     │
                          FBO @ 源分辨率
                     （逐通道 LUT 色调映射，§3.3）
                                     │
                        GBM surface 或 dumb buffer
                                     │   fence（关键，见下）
                                     ▼
                     DPU plane 硬件放大 + 黑边 ──▶ 面板
```

#### 为什么是这条

GPU 上真正必须做的只有色彩（§4.2 第 1 条：DPU 完全没有色彩管理，meson 无
`GAMMA_LUT`/`CTM`）。缩放是 DPU 的免费能力（方案 A 已经在用）。而当前默认的两遍路径
（§3.4）把缩放也放在 GPU 上做，于是第二遍要为**每一个屏像素**采样一次纹理 ——
这一遍的全部作用只是"把图搬大"，纯属浪费。把它砍掉，片元数就只跟源走：

| 源 → 2560x1440 | 单遍（`GL1PASS=1`） | 两遍 pass1 | 本方案 |
|---|---|---|---|
| 1280x720 | 100% | 25% + 100% | **25%** |
| 1920x1080 | 100% | 56% + 100% | **56%** |
| 3840x2160 | 100% | 56%(限 1080p) + 100% | **56%**(限 1080p) |

结论只到"比两遍少一整遍整屏采样"，具体帧率**待测**（见 §4.1.4），不在这里填数。
注意 1080p 源占屏 56% 而不是 25%：`glscale.inc:2` 注释里那组"1/4"
只对 720p 成立，换成 1080p 片源时不要沿用那个预期。

#### 4.1.1 三条硬约束（缺一条这条管线就不成立）

1. **fence 是前提，不是优化**。`glscale.inc:145` 的 `glFinish()` 不是随手写的：
   后面接的是 legacy `drmModeSetPlane`，它**没有 fence 参数**，内核不知道 panfrost
   画完了没有，去掉 `glFinish` 就等于让 DPU 去读正在被渲染的显存。二选一：
   留着 `glFinish`（CPU 每帧阻塞到 GPU 收工，省下的片元被等待吃掉），
   或改 atomic、填 `IN_FENCE_FD`。目前仓库里 atomic 一条都没用
   （`grep -rn AtomicCommit *.c` 无输出），但 `crosslib/libdrm.so.2` 导出了
   `drmModeAtomicCommit`，能力上有。
2. **缓冲轮转必须等扫描输出**。`glscale.inc:129` 的 `S.cur = (S.cur + 1) % NRT` 是盲轮转，不查上一帧是否
   已经扫出去。渲染比扫描快时必然写回正在被 DPU 读的那块 —— 撕裂。
   `vout.c` 的翻页机制解决的就是这件事，本方案不能绕过它。
3. **呈现出口只留一个**。现状已有三个：`eglSwapBuffers`（`glout.c:1066`）、
   `drmModePageFlip`（`glout.c:1108`）和 `SetCrtc` 兜底（`glout.c:1090`，重试失败转 `:1124`）。
   `glscale` 的 `SetPlane` 会是第四个，且和 `eglSwapBuffers` 打同一个 crtc。

#### 4.1.2 两种落地形态

| | A：缩小 surface + `eglSwapBuffers` | B：atomic + `SetPlane` |
|---|---|---|
| 做法 | `gbm_surface_create(sw, sh)`（`glout.c:576` 已是一行之差） | 保留 dumb buffer 轮转，补 `IN_FENCE_FD` |
| fence | **隐式**，EGL 自己带 | 手填，要按名字取属性 id |
| 三缓冲/翻页 | 复用现有 `drmModePageFlip` + `flip_handler` + `wait_flip_to` 硬截止 | 自己实现，等于重写一遍 `vout.c` |
| 宽高比 | 只能等屏宽高（page flip 无法指定 plane 子矩形） | 可 letterbox（`dest_x/dest_y/dest_w/dest_h`） |
| 改动量 | 个位数 diff | 一个模块 |

选哪条不由偏好定，由**需不需要 letterbox** 定：16:9 源配 16:9 屏就是 A；
要任意宽高比的等比+黑边就只能 B。上盒子跑一次 `drmprops`（仓库里有）能看到
primary plane 的属性表里有没有 `IN_FENCE_FD`、缩放上下限多少 —— 这是 A/B 的判据。

#### 4.1.3 顺序约束：先管线，后 LUT

逐通道三通道 LUT（§3.3 目标形态：现在按 Y 索引的单 LUT 换成分别索引 Y/U/V 的三张）
会让取样次数翻倍。只有在源分辨率片元预算下这笔账才划算 —— 在屏分辨率上做，
两遍路径立刻掉一个 vblank 档。所以**先把这条管线跑通并量到帧率，再换 LUT**。
反过来做，一旦掉帧就分不清是计算域改坏了还是渲染架构没撑住。

#### 4.1.4 验收（数字留空，实测后回填）

| 项 | 怎么测 | 要求 |
|---|---|---|
| 帧率 | 同一彩条/同一片源，`GLTIME` 关（它插 `glFinish`，会抹掉异步收益） | 记 `frames/秒`，不记 `t_sum` |
| 撕裂 | 1280x720 源（渲 25% 帧时间，远快于 60Hz）静置观察摇镜 | 无横向错位 |
| 黑边 | 2.39:1 源 | 等比居中，四边等宽 |
| 色彩 | 与 §3.4 两遍路径同帧对比 | 逐像素一致（同一套 LUT，只该换几何） |
| CMA | `cma-watch.sh` 播放 5 分钟 | 不单调上涨 |

#### 4.1.5 实测：这块 meson 的平面能力（2026-11-19，x96 盒上）

§4.1.2 的 A/B 判据一直写着"上盒子跑一次 `drmprops` 看一眼"，现在跑完了。
三个探针都在仓库里，盒子上一跑就能复现：

| 探针 | 干什么 |
|---|---|
| `drmplane2.c` → `drmplane2-aarch64` | 列每个 plane 的格式表和全部属性（名+当前值） |
| `scaletest.c` → `scaletest-aarch64` | 直接 `drmModeSetPlane` 试各种 src→dst |
| `crtctest.c` → `crtctest-aarch64` | 只做一件事：legacy `SetCrtc` 挂一张比 mode 小的 fb |

编译（三个都链盒子上的 libdrm，和 glout 同一条命令行）：
`aarch64-linux-gnu-gcc -O2 -Wall -idirafter /usr/include -idirafter /usr/include/libdrm -o X-aarch64 X.c crosslib/libdrm.so.2`
（`drmplane.c` 是裸 ioctl 版，留作"不链 libdrm"的参照，实际用 `drmplane2`）

**结论一：`IN_FENCE_FD` 有，atomic 有。** 两张平面（primary 40：`AR24 AB24 XR24
XB24 RG24 RG16`；overlay 43：`YUYV NV12 NV21 …`）的属性表里都有 `IN_FENCE_FD`，
`drmSetClientCap(DRM_CLIENT_CAP_ATOMIC)` 也成功。§4.1.1 第 1 条那个
"留 `glFinish` 还是填 `IN_FENCE_FD`"的二选一，**能力上可以选后者**。
但 `OUT_FENCE_PTR` 不在这两张平面上，它在 CRTC 上——§4.1.1 第 2 条
（轮转等扫描输出）要从那里取。

**结论二：屏是 1920x1080，不是 2560x1440。** §4.1 那张"源 → 2560x1440"的表
按现在这台盒子的 EDID 得整体重算：720p 源占屏 25%（1/4 成立），1080p 源占屏
**100%**（不是 56%）。也就是说在这台盒子上，"DPU 放大"只对 720p 及以下的源
有收益，1080p 源天然就是 1:1，没有可省的片元。

**结论三：legacy `SetCrtc` 不接受比 mode 小的 fb。**
`drmModeSetCrtc(crtc, fb=1280x720, …, mode=1920x1080)` → **ENOSPC**。
这就是GL 目标缩到 720p 后播放器报 `GLOUT: SetCrtc 失败: No space left on
device` 的原因，和 CMA 无关（`CmaFree` 还有 1GB）。`drmModePageFlip` 走同一条
plane 校验，所以"小 surface + eglSwapBuffers"（§4.1.2 形态 A）在这块驱动上
**直接不成立**。

**结论四：`SetPlane` 能缩放，但 dst 必须是整屏。**

| # | src | dst | 结果 |
|---|---|---|---|
| 1 | 1280x720 | 1280x720（1:1） | EINVAL |
| 2 | 1280x720 | 1920x1080（放大 1.5x） | **成功** |
| 3 | 1280x720 | 1680x960 @(0,0) | EINVAL |
| 4 | 640x360 | 1920x1080（放大 3x） | **成功** |
| 5 | 1920x1080 | 1920x1080 | **成功** |
| 6 | 1920x1080 | 960x540（缩小） | ERANGE |

三条定死了设计：
1. **放大可用**，1.5x/3x 都行——720p 源省下的 75% 片元是真能省。
2. **不能缩小**（ERANGE），比屏大的源只能 GPU 缩。
3. **dst 只能是整屏**，给子矩形就 EINVAL——所以 letterbox 不能靠 plane 矩形，
   必须把黑边画进渲染 target 里（DPU 再把整张一起放大，比例不变）。
   §4.1.2 表里"B 能 letterbox"这一格要改：靠 `dest_w/h` 做不到。

**结论五：接上去之后到底快多少（X96Max 实机，1920x1080@60 屏）。**

上屏换成 atomic 之后（`ATOMIC=1`，`IN_FENCE_FD` 可用 → 不 `glFinish`），
`t720.265`（1280x720）在 24fps 片源下：`submit=300 shown=300 drop=0 abort=0`，
commit 失败 0 次。GPU 每帧（`PERF=1`，含 `glFinish`）：

| 配置 | 渲染 target | `glFinish`/帧 | 吞吐（`NOPACE=1` 量渲染侧上限） |
|---|---|---|---|
| `DPUSCALE=0` | 1920x1080 | 9.0 ms | 24.1 fps（片源节拍顶住） |
| `DPUSCALE=3` | 1280x720 | 8.5 ms | 24.4 fps |

**只有 0.5 ms，不是早先测的 6.2 ms。** 差别在 pass1：`twopass_frame()` 现在是
「源尺寸封顶 `GL1MAX`」，720p 源的 pass1 本来就是 1280x720 —— 以前那 6.2 ms 里
大部分是 pass1 从 1080p 降到 720p 省下来的，而现在的代码一开始就没渲到 1080p。
DPU 能省的只剩 pass2 那次放大（1080p→720p 的拷贝），0.5 ms 是它的真价。
**所以 DPUSCALE 的收益不是"省 40% 片元"，是省扫描输出带宽 + 让 atomic/fence
这条路成立**；指望它救帧率会失望。

**DPU 放大真正值钱的地方是 `GL1MAX`（pass1 尺寸）**，1080p 源实测：

| `GL1MAX` | pass1 | `glFinish`/帧 | 吞吐上限 | 画质（对全尺寸参考） |
|---|---|---|---|---|
| 1080 | 1920x800（1:1） | 13.9 ms | 48.9 fps | 参考 |
| 720 | 1280x534 | 7.1 ms | 54.7 fps | PSNR 37.7 dB，水平差分 -43% |
| 540 | 960x400 | 6.5 ms | 55.8 fps | PSNR 37.5 dB，水平差分 -58% |

读法：`GL1MAX=720` 拿 6.8 ms 换 5.8 fps 上限，代价是 37.7 dB 的软（文字/细纹理
一眼能看出）。24fps 片源本来就装得下（13.9 ms vs 41.7 ms 预算），**默认值应留在
`GL1MAX=1080`**，`GL1MAX` 只作 50/60fps 1080p 的逃生舱。另测 `PERF=1`（逐帧
`glFinish`）只吃掉 1 fps 上限（48.9 vs 49.8），对 24fps 播放无感，不用为它改默认。

**结论六：dst 给子矩形，atomic 也照样 EINVAL（`DSTFIT` 实验）。**
想法是"target 用源比例、dst 用等比内容框、黑边交给屏"，`1920x800` 的 2.35:1 源
在 16:9 屏上 dst 给 `1920x800+0+140`。结果：**192 帧、192 次
`atomic commit 失败: Invalid argument`**，`shown=192 drop=0` 全靠 legacy
兜底上屏才没黑屏。所以结论四（dst 必须整屏）在 atomic 下同样成立，
黑边只能画进 target。反过来说：**target 必须与屏幕同比例**，否则 DPU 把整张
拉成全屏 —— 2.35:1 的片子就是纵向 1.35 倍变形。

`glout.c` 因此按下面两条定默认（`ATOMIC=1` 时 `DPUSCALE` 默认 4）：
1. 只有 atomic 起来了才缩 target（legacy `SetCrtc` 小 fb → ENOSPC）；
2. 源比例与屏幕差 > 0.5% 就直接用整屏 target（GL 自己画黑边），不硬放。

比例一律按**显示宽高比**算，不是容器宽高比：`spscolor.c` 顺手把 VUI 的
`aspect_ratio_info` 解析出来（idc 1..16 查表 + `Ext_SAR` 取显式分子分母），
存进 `ColorMetadata.sar_num/sar_den`；`render_gl.c` 每帧 `glout_set_par()`
刷给 `glout.c`，两处黑边计算（`twopass_frame` 的 pass2 和单 pass 路径）都
走 `src_ar(w,h) = w*par/h`。`glout_init` 里的比例守卫仍然只决定 target 尺寸，
非方形像素的源按"像素比例 ≠ 屏比例"退回整屏 target —— 这是保守但正确的一侧
（不变形，只是不省片元），有需要再让 target 跟着显示宽高比走。
实测分两段，第二段才是真链路：

1. **GL 侧**（盒子上测试卡 720x576，`GLDUM` 出 PPM 量内容框）：`PAR=1:1` 内容框
   1261 宽，`PAR=16:15` 变成 1345 宽，比值 1.0667 = 16/15，说明黑边按 SAR 撑开了。
   注意 `PAR=` 只存在于 `GLOUT_NO_MAIN` 那支测试卡 main 里，播放器进程**不认**
   这个环境变量，所以它只能证明 `glout.c` 的几何，不能证明 SAR 从码流接进来了。
2. **整链**（2026-11-19，真 ES + `PLAY=1 RENDER=gl GLDUM`）：拿 `ffmpeg -vf
   setsar=16/15` 把 720p 测试流转成 `/tmp/sar1615.265`，
   `SPSDBG=1` 打印 `sar=16:15`（VUI 解析通了），上屏后量 PPM 内容框：

   | 片源 | 内容行 | 高 | 结论 |
   |---|---|---|---|
   | 1280x720（无 VUI SAR，1:1） | 0..1079 | 1080 | 满屏 |
   | 1280x720 + SAR 16:15 | 34..1045 | 1012 | 上下各 34px 黑边 |

   1012 = 1920 / (1280·16 / 720·15) = 1012.5，与理论一致：SAR 走的是等比
   letterbox，不是水平拉伸。顺带记一句流程坑：**不开 `PLAY=1` 就不建 Renderer**，
   没有 `RENDER:` 也没有 `GLDUM`，那是纯解码跑分；`RENDER=drm` 后端不支持 `GLDUM`。

**旋转**不在 HEVC 码流里（只有容器/显示矩阵才有），裸 ES 播放不涉及，不做。

**下一步**：
1. ~~上屏换 atomic~~（已做：`FB_ID`+`IN_FENCE_FD`+`CRTC_W/H=整屏`+`SRC_W/H=target`，
   翻页事件照旧，`out_fence=有`）。
2. ~~打通后量真实播放帧率回填 §4.1.4~~（已回填上表：720p/1080p 都是 `drop=0`）。
3. 真 HDR 片源（PQ+BT.2020，非测试彩条）跑一遍，确认 `DSTFIT` 之外没有别的
   几何问题（~~aspect 守卫不看 SAR~~ 已做：VUI SAR 已接入显示宽高比，
   见上；旋转不在 ES 里，不做）。HDR 这边 2026-11-19 只走到**半程**：
   拿 1080p 测试流重编成 `yuv420p10le` + `bt2020nc/smpte2084/bt2020` +
   `master-display L(10000000,1)` + `max-cll=1000,400`（`/tmp/hdr1080.265`），
   播放链路自己是对的 —— `SPSDBG` 打 `色域=BT.2020(9) tf=16 bd=10`、
   `RENDER: mode=gles tonemap=shader`、`COLOR: 峰值=1000 nits(SEI144 maxCLL)
   母版=1000/0.0001`、`GLOUT: TM on tf=PQ curve=1 peak=1000(sei) target=200
   sat=0.90 knee=0.70`，抓帧内容行 0..1079 满屏（10 bit + HDR 不引入几何偏移），
   逐通道过曝（≥250）从 `TM=0` 的 78.5% 降到 28.0%。
   **但片源本体还是 SDR 彩条重打的 PQ 标签**，看不出"灰蒙/过曝"到底修到什么程度，
   要判画质仍得找一条真 HDR 母版（且 10 bit 4K 母版会撞上 `design_recover` 那条
   硬解复位，先从 1080p 母版验）。

---

### 4.2 方案 A 的缺点

1. **完全没有色彩管理**。这是硬伤：DPU 这条路径只能把 YUV 原码值直送显示器，
   meson 又没有 `GAMMA_LUT`/`CTM`。HDR10 片源（PQ + BT.2020）出来就是灰蒙/过曝，
   不是"效果差一点"，是**不可用**。唯一的补救是 §2.6 的 CPU 就地 LUT，
   4K 一帧 ~800 ms（~11 MB/s），只够当兜底和验证。
2. **尺寸/性能二选一**。CPU 色调映射随像素线性增长，1080p 也已经很勉强；
   想开 HDR 映射就得降分辨率，想 4K 就只能不做色彩处理。
3. **点屏逻辑脆**。primary plane 只收 RGB 且 zpos 比 overlay 高，必须先铺一张
   alpha=0 的 ARGB dumb —— 忘了清零、或 `SETCRTC` 少写 `mode_valid`，
   表现分别是"全黑"和"EINVAL"，都不带任何提示。
4. **选 plane 靠扫**。没有 NV12 plane 就直接没戏，扫描策略错了要人工
   `PLANELIST=1` 看、`PLANE=<id>` 兜；换一块板/换内核 DPU 布局就得重来。
5. **单层，没有合成能力**。整条路径只占一个 overlay，没有字幕/OSD 层，
   也没有透明混合；要叠任何东西都得先烧进片源或用 GL 路径。
6. **缩放质量不可控**。缩放交给 DPU，算法和滤波由硬件定，没有开关
   （`fit/fill/crop` 只决定几何，不改滤波），动画/字幕边缘偏软也无从调整。
7. **节拍器假设恒定帧率**。`FPS` 是外部给的定值，VFR 片源、24/23.976 混淆、
   显示器刷新率变化（`video=` 没生效时）都会让累计 ticks 漂；
   `WAIT_VBLANK` 失败就静默退化成时间节拍。
8. **3:2 拉片的固有抖动**。24p 在 60 Hz 上不管怎么算都是 2:3 pulldown，
   每个 5 帧周期里必有 3 个 vblank 的间隔，横向摇镜能看出来 —— 硬件上限，不是实现问题。
9. **平台绑死**。"NV12 紧排、Cb pitch = w"、"primary 只收 RGB"、"vdec 的
   `vififo offset` 匹配"全是 meson/amvdec 的特有行为，换 SoC 整段要重写。

### 4.3 方案 B 的缺点

1. **没有帧级节拍**。所有平滑度都押在 `ffmpeg -re` 上：网络抖动 = 画面卡顿，
   `-re` 被去掉/源比实时快就按解码速度飞（实测 4K 快 15%）。
   方案 A 的 vblank 重锚（落后就丢帧）这里一样都没有。
2. **吃 GPU、吃带宽、发热**。pass1 4K 全尺寸 54 ms，缩到 1080p 才 37 ms ——
   性能是靠**牺牲清晰度**换的，4K 片源实际是按 1080p 做色调映射再放大。
   两遍渲染多一次 FBO 往返，G31 一直在线，功耗和温度都比纯 DPU 路径高（未量化）。
3. **降饱和 + hash 抖动都是近似**。输出仍是 8 bit，`sat=0.90` 是人工折中
   （色度增益插值，亮度守恒，色度幅度只能粗放地按 LUT 的 nout/n 缩），
   抖动只是拿噪声换掉色带的视觉近似，不是真 10 bit 管线。
4. **色调映射参数只做到半自动**。峰值不再写死：`build_lut()` 先看 `TM_SRC_PEAK`
   （人工覆盖，日志峰值来源打 `env`），否则 `csig_peak()` 按 `maxCLL` →
   母版 `maxLuminance` → 0 的顺序取值（打 `sei`），全都没有才 1000 兜底并靠
   `tm_peak_sync()` 在首帧 SEI 到达后补建 LUT。色域只有 2020/709 两档
   （`hc_sat_from_primaries` → 0.90 / 1.0）。仍然**只吃静态元数据**：
   maxFALL 没参与计算，HDR10+ / Dolby Vision 的逐帧 metadata 完全不认，
   `target=200`、`knee=0.7` 还是人工折中，不同片源想调仍得改环境变量。
5. **依赖重、现场难改**。EGL + GLESv2 + gbm + drm 四个板端 `.so`（`crosslib/`），
   着色器、LUT、纹理缓存任何一环坏掉都表现为"黑屏/花屏"，没有中间态；
   必须复用方案 A 已经拿到的 DRM master fd，GL 自己 `open` 拿不到 master。
6. **纹理缓存有生命周期坑**。按 `(fd_y,fd_c)` 缓存，表满或 `SOURCE_CHANGE`
   要 `drop_tex()`；漏 `eglDestroyImageKHR` 就是 dma_buf 引用泄漏
   （20 个 buffer 轮转 + seek 重开，很快就会把 CMA 吃干净）。
7. **初始化更慢**。EGL init + 着色器编译 + LUT 上传 + 建 FBO，
   起播和 seek 都要多摊一份时间；在"整链重开"的 seek 语义下这笔开销每次都要付。
8. **色彩链路自成一套**。PQ/BT.2020 转换只活在片元着色器里，不跟系统/显示器
   色彩配置联动，也没法让别的程序复用；想加真实 HDR 直通（换 HDR 显示器）
   得再写一条完全不同的路径。

### 4.4 两条方案共同的缺点

- **A/V 同步是粗对齐**：只靠两边同一个 `-ss`，没有音频时钟驱动视频丢帧/补帧，
  长片必然缓慢漂移；`-re` 本身也是按平均码率，不做音频对齐。
- **seek 不再黑屏，但只在新壳上**：`play.sh key` 现在先问播放器控制口
  （spawn 模式下 kill 子 ffmpeg + 新 `-ss` 重开 + 重建 V4L2 会话，DRM/GL 不放手，
  §5.4），接不住才退回整链重开。老前端 `tvplay-node.sh` 仍直接 `restart_at`，
  走的是整链重开（~0.8 s 黑屏）。
- **不能换码流**：一个 V4L2 会话只能吃一条流，任何跳变都走 `g_reinit`
  （重开 `/dev/video0`），固件真 hang 时还要 `g_hard_reset_on_reinit` 整块复位。
- **拖动精度受 GOP 限制**：`-ss` 落在关键帧前要等 IRAP，最长 60 s（`IRAPWAIT`）兜底。
- **都没有 UI**：无 OSD、无进度条、无字幕选择，交互只有遥控器那几个动作和 ssh 协议。

### 4.5 选型口径

- 片源是 SDR / 低分辨率 / 要逐帧校验 → **A**：零拷贝、vblank 精确、依赖最少。
- 片源是 HDR10 或 4K → **B**：宁可用 GPU 换正确色彩，接受 `-re` 的节拍风险。
- 两条路都别指望"开箱即用"：A 卡在色彩，B 卡在节拍与依赖。
- 长期只留一条：**§4.1 的最终管线**（A 的上屏/节拍 + B 的色彩，GL 只做源分辨率映射）。
  `glscale.inc` 是它的半成品原型，不是另一个方案；在它并入主干之前，A、B 两条都得留着兜底。

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
   └─ 重新执行 play 子命令（seek 先试控制口就地跳，接不住才整链重开）
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
- 键位表**只写一处**：`hevcdec/rcmap.h`（x-macro，`RC_KEY(修饰, KEY_码, 动作)`）。
  播放器把它展开成查表函数，同一张表再通过 `player -K` 打印出来；脚本不抄表，
  `play.sh keys` 就是去问播放器要（`play.sh key <动作>` 的未知动作提示也从这取）。
  改一个键只改 `rcmap.h`，二进制和脚本同时生效。
- 这台遥控器（XING WEI 2.4G）实测是**键盘模式**：上排功能键发 `Ctrl+1..Ctrl+5`，
  不是标准媒体键（`Ctrl+1` 首页键按需求不登记，按下静默）。完整表以
  `player -K` 为准，当前是：

  | 键 | 动作 |
  |---|---|
  | Ctrl+2 / Ctrl+3 / Ctrl+4 / Ctrl+5 | `mute` / `menu`（无 UI，忽略）/ `volup` / `voldn` |
  | OK·ENTER·SPACE·PLAYPAUSE | `toggle` |
  | ▶·FASTFWD·NEXTSONG / ◀·REWIND·PREVSONG | `fwd` / `back` |
  | ▲·PGUP / ▼·PGDN | `fwdmore` / `backmore` |
  | VOLUMEUP / VOLUMEDOWN / MUTE | `volup` / `voldn` / `mute` |
  | STOP·BACK·ESC·EXIT·HOMEPAGE | `quit` |

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
| `toggle` | 先判"实际在跑哪条链"（`pgrep v4l2hevc-aarch64`），**不能只看 state**：HEVC 链的画面(v4l2hevc/ffmpeg)和声音(独立 mpv)是两个进程，只 toggle mpv 会哑掉声音、画面照跑 → 必须整条 `pkill -STOP/-CONT` |
| 暂停 `pause_video` | `STOP` v4l2hevc / ffmpeg / mpv，写 `PAUSE_AT=now` |
| 继续 `resume_video` | `CONT` 三者，把暂停时长并进 `START`（`START += now - PAUSE_AT`），`PAUSE_AT=0`，`pos()` 才连续 |
| `fwd`/`back`/`fwdmore`/`backmore` | ±10s / ±60s。`PLAYER=mpv` 走 mpv IPC `seek`；HEVC 链先 `pctl seek N` 就地跳（spawn 模式，屏幕不黑），接不住才整链重开 |
| `volup`/`voldn` | `mpvctl` 读 `volume` 再 `set_property`，步进 ±10，**夹在 0..100**（mpv 的 `add` 会累加，>100 削波，实测被连按到 130 晚上炸响） |
| `mute` | `mpvctl <sock> mute` |
| `quit` | `stop`：kill 三个进程 + 删 socket + `chvt 1` |
| `menu`/`home` | 日志"无 UI，忽略" |

`vol_step` 必须 `MPVCTL_ECHO=1`：不加则 mpvctl 不回显回复，读到的 `cur` 永远是空、
退化成每次按 100 算（实测连按减 12 次只掉到 90）。

### 5.4 seek：就地跳优先，整链重开兜底

两档，按"控制口能不能接住"分：

**① 就地跳（spawn 模式，默认）。** `play.sh key fwd` → `pctl seek 10`（相对）
或 `pctl seekto 120`（绝对）。播放器回 `{"ok":1,"seek":"inplace"|"abs"}`，
壳就直接返回，**不重开整条链**：播放器 kill 掉子 ffmpeg、带新 `-ss` 重开、
重建 V4L2 会话并 `s_fill` 预读，DRM/GL 一路不放手 —— 屏幕不黑、buffer 不重建。
实测（盒子，`t720long.mp4` 95.9 s）：`key fwd` 后 PID 不变，日志只有
`SEEK: 就地重开供流 → 15.797 s（DRM/GL 不动）`。
复测（2026-11-19，NAS 上 4K HEVC 3840x1608 正片，`-r gl`，spawn）：`key seekto:300`
后播放器 PID 不变，`status` 位置 301 s → 303 s 继续走，日志 `SEEK: ffprobe 片长
7037.5s` + `SEEK: 就地重开供流 → 300.000 s（DRM/GL 不动）`；紧接着连按两次
`key fwd` 合并成一次 `→ 328.086 s`（末次目标基准生效，没有跳回旧位置）。

- 相对量交给播放器算：它有"末次目标"基准（`g_seek_to`），连按 ▶▶ 从上次
  目标接着加，不会因为 `pos()` 还停在旧位置而跳错。
- 目标位置由播放器钳住：知道片长（`DUR`）或探到过片尾（`g_end_hi`）就停在
  片尾前 1 s，OSD 说一句"已到片尾"（实测 `seekto 200` → 94.914 s）。
- 暂停中 seek 不需要壳再压一次：`spawn_reseek()` 把暂停时长并进
  `g_t_clock0`，暂停态原样保留。

**② 整链重开（非 spawn / 老二进制 / socket 不通）。** `restart_at <T>` = 用
state 里的参数重新执行 `play hevc <KEYB64> <T> …`（每个参数都必须 `enc`，play
侧一律 `dec`；传明文会被当 base64 解成垃圾，实测 `AUDIO` 解空 → 重开后没有
音频 mpv、`GEO` 解出二进制 → state 文件写坏，坏值还会顺着 restart_at 再传一轮）。

- **`seek_guard`**：`/tmp/tvplay.seek.stamp` 记上次 seek 时间，3 s 内的重复 seek 直接丢。
  原因：`rcinputd` 是 `wait(NULL)` 串行处理的，按住 ▶ 时连发事件排在队列里，
  松开后仍会逐个补跑，每个都重开一次链 —— 表现是"播放界面消失变成命令行，
  松开才慢慢恢复"。合并成一次即可。
- 暂停中拖动：重开后若 `WASPAUSED>0` 再 `pause_video()` 压回去，保持"暂停"语义。
- 整链重开时进程确实退出 → 屏幕会短暂回到内核控制台文本（约 0.8 s）。
  所以这条路是兜底，正常路径是上面的就地跳；`tvplay-node.sh`（老前端）仍
  直连这条，没走控制口。

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
 | DSTGEO="$GEO+0+0" NOWRITE=1 PLAY=1 RENDER=gl /tmp/v4l2hevc-aarch64 -
```

- `NOWRITE=1` 现在可省：凡 `PLAY=1` 且没显式给 `OUTYUV`，播放器**默认不落盘**，
  `PHASE write` 恒 0。历史上默认是写 `/tmp/out.yuv`（1080p 3.1 MB/帧），
  实测 `hdr1080.265` 漏设时 e2e 18.2 fps、`PHASE write=8.76s`，设了才 23.6 fps
  贴住 24 fps 源速——这是当时唯一的"丢帧"来源，不是 decode 慢也不是 GL 慢
  （draw 恒 7.2 ms）。4K（3840x1600，80 帧实测）同样：不落盘 e2e 23.53 fps，
  显式 `OUTYUV` 落盘 e2e 9.16 fps、`PHASE write=6.42s`；一直写下去 1.9 G 的
  tmpfs 二十几秒就满。改默认的连带影响：纯解码（不带 `PLAY`）照旧落
  `/tmp/out.yuv`，边播边存要显式 `OUTYUV=`（会打 `OUT:` 行确认）。
- 音频单独一条 `mpv --no-video --ao=alsa --audio-device=alsa/hw:0,0 --cache-secs=20`。
  为什么不用 `ffmpeg -f alsa`：这块板子缓冲太浅（实测 8 s 内 15 次 xrun）。完整决策与代价见 **§1.12**。
- `DSTGEO` 只对方案 A 生效；方案 B 按 connector `modes[0]` 自行等比铺屏（两者都是 2560x1440）。

### 5.7 排查

```bash
pgrep -fa 'v4l2hevc-aarch64|ffmpeg .*-f hevc|mpv|rcinputd'
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
2. **整链重开的 seek 会黑 0.8 s**（只发生在兜底路径）：黑屏的因是 `restart_at()`
   打死持 DRM master 的进程（屏幕掉回控制台），**不是 V4L2 会话重建**——所以这一条
   与 `design_recover.md` §3.3 的软重置研究正交，不要等软重置。spawn 模式下的
   就地跳不黑屏，已接进 `play.sh key`（§5.4）；老的 `tvplay-node.sh` 还没接。
   但**不能**靠"让 `tvplay-node.sh` 发 `SIGUSR1`"解决：seek 要的是新字节位置，位置只在
   `ffmpeg -ss` 参数里，而 `SIGUSR1` 只重建已有 fd 上的会话（`v4l2hevc.c:1908`）。
   现在 `ffmpeg | v4l2hevc` 是兄弟进程，杀上游下游就 EOF。真正的改法是把 ffmpeg 收成
   `v4l2hevc` 的子进程（C 侧 kill + 带新 `-ss` 重开），动的是进程模型，不是脚本。
   验收拆两条互不依赖的轨，见 `design_recover.md` §3.3.7。
3. **拖动精度受 GOP 限制**：`-ss` 落在关键帧前需等 IRAP（`IRAPWAIT` 60s 兜底）。
4. **方案 B 无帧级节拍**，完全信任 `-re`；网络源抖动会直接体现为卡顿。
5. `glscale.inc` 的 DPU 硬件放大变体（28→55 fps）尚未并入主干。
6. 遥控器部分键没有标准 KEY 码（`code=0`），需按 `MSC_SCAN` 补 `COMBO_SCAN` 表。
7. 方案 A 的 CPU 色调映射不可用于 4K（~800 ms/帧），仅作兜底/验证。
8. **H.264 在这块板子上解不出帧**（2026-11-19 实测，720p x264 8bit 4:2:0 mkv）：
   会话能开、`S_FMT` 全对（1280x720 / NV12）、喂进 6 个 AU，`DQBUF` 一个都不出，
   1.6 s 后被 `STALL` 看门狗重建会话，连着重试 5 次后播放器退出（`STALL: 连续 5 次
   自愈失败，退出`）；dmesg 里每次都只有 `meson-vdec: hard reset n=6`，没有别的错。
   播放器侧参数是对的（`CODEC=h264` + `V4L2_PIX_FMT_H264`，`ffprobe` 也报了
   `h264,1280,720`），所以怀疑 `meson-vdec/codec_h264.c` 这条路（staging 里的
   H.264 分支从来没有在这颗 S905X2 上跑通过）。**当前别拿 H.264 片源验播放链**，
   表现是"位置在走、遥控有反应、屏幕全黑"——`play.sh` 现在会在起播前明喊一句。
   要真支持 H.264，得先在核里把 codec_h264 打通，与用户态无关。
