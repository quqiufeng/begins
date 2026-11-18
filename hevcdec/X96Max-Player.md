# X96Max Player

X96Max（Amlogic S905X2 / meson-vdec / panfrost G31 / 2560x1440@60）上的本地硬解播放器。
本文是**最终架构定稿**；具体实现细节、坑位记录、脚本用法仍见 `design_player.md`。

---

## 0. 核心原则

**这五条先于一切实现细节。任何代码与之冲突，改代码。**

核心原则：

- 音频设备实际播放位置决定媒体时间。
- 视频帧根据 PTS 判断是否应该显示。
- 过期帧丢弃。
- 未来帧等待。
- DRM vblank 决定具体提交显示的时机。

五条是一个闭环，不是五句口号：**音频给主钟（1）→ PTS 给判据（2）→ 落后丢弃（3）、超前等待（4）→ vblank 落地上屏（5）。**
拆开看，1 给时基，2 给判据，3/4 是两条纠偏动作，5 是唯一的落地时刻。

分工必须先分清：**第 2 条决定「显示哪一帧」，第 5 条决定「哪一刻 flip」。**
两者不可互推，所以 `target_vbl` 必须每帧按主钟反算（§6.2），不能让 `pc.n++` 累加——
帧的选择由 PTS 定，时机锚在 vblank，任何一方都不能被计数器替代。
这也是 §6.2 铁律「只调视频、绝不调音频」的正面陈述：音频那一侧本来就不该被调。

### 0.1 收紧成接口

例如：

```c
int64_t audio_clock_ns(void);
int64_t video_pts_ns(struct VideoFrame *frame);

void schedule_video(struct VideoFrame *frame)
{
    int64_t delta = video_pts_ns(frame) - audio_clock_ns();

    if (delta < -40000000) {          /* 落后 >40ms：过期帧，丢弃 */
        drop_frame(frame);
        return;
    }

    if (delta > 50000000) {           /* 超前 >50ms：未来帧，等待 */
        wait_until_due(delta);
    }

    renderer->render(frame);
}
```

| 原则 | 落点 |
|---|---|
| 1 音频设备实际播放位置决定媒体时间 | `audio_clock_ns()`，唯一时基来源（§2.1 / §2.1.1） |
| 2 视频帧根据 PTS 判断是否应该显示 | `video_pts_ns(frame)` 参与 `delta` 计算（§2.5） |
| 3 过期帧丢弃 | `delta < -40ms` → `drop_frame()` |
| 4 未来帧等待 | `delta > +50ms` → `wait_until_due()` |
| 5 DRM vblank 决定提交显示的时机 | `renderer->render(frame)` 内部按 `target_vbl` 提交（§6.2） |

### 0.2 这段例子有三处必须在实现时补齐

1. **`renderer->render()` 的返回值不能丢。** 它不是状态码，是**交接后谁回收 buffer**：
   `v4l2hevc.c:1640` 的 `if (rc >= 0) rendered = 1;` 就是这个语义——`rc < 0` 时解码器必须自己
   `V4L2 QBUF`。照抄成 `renderer->render(frame);` 会在交接失败时让 buffer 两头都不还，这是真漏。
   应写成 `if (renderer->render(frame) < 0) drop_frame(frame);`。
2. **`wait_until_due()` 不许用 `usleep`。** 主钟 τ 是单调时间，`usleep` 多为 `CLOCK_REALTIME`
   且不吃信号打断后的余量；用 `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, ...)`。
   它只做「不要过早提交」，**不负责对齐 vblank**——那是第 5 条。两件事不能互相替代，否则等待做了两头。
3. **门限口径与 §6.2 表格不一致，须择一。** 这里负侧 `-40ms`、正侧 `+50ms`（10ms 滞回，避免 `delta`
   在零附近回摆导致来回切分支）；§6.2 表格写的仍是对称的 `|d| ≤ 40ms`。滞回是有意的，但表格与代码
   必须是同一个数，否则调参时无从对齐。

以上三条是**局部修正**，都还默认了"时钟和提交瞬时完成"。真正的缺口在时序模型本身：
音频缓冲、显示提交、vblank 预测这三段延迟没进 `delta`，见下节 §0.3。

### 0.3 这段示意与实现之间的三个延迟项

**上面的代码只是调度逻辑示意，不是可以照抄的实现。** 它把 `audio_clock_ns()` 和
`renderer->render()` 都当成了"瞬时完成"的抽象调用，而真实链路上有两端各吃一段延迟，
中间还有一层要预测：

| 延迟项 | 物理含义 | 现值 / 出处 | 不补的后果 |
|---|---|---|---|
| **音频设备缓冲延迟** `L_a` | `aout` 写进 ALSA 的字节要等 DAC 取走才发声；`played` 必须扣掉 ring 里还没播的部分 | `played_ms = (written - delay)/rate`（`aout.c:348-349`），量化步长 = period 2048 帧 = **42.7 ms**（`aout.c:56`） | 用 `written` 当位置 → τ 恒定超前 43~100ms，视频永远"落后"，全程丢帧 |
| **显示提交延迟** `L_d` | `SETPLANE` 不是立即生效，要等下一个 vblank 才接管扫描 | 目标槽 T 实际在 **T+1** 被扫（`vout.c:584-587` `confirm_prev` 的账） | 把 T 当"上屏时刻"→ 整场晚一帧（60Hz 下 16.7ms），且与 `L_a` 同向叠加 |
| **vblank 预测** `P` | 帧必须在目标 vblank **之前**提交，而 "刷新率 × 序号" 是外推出来的 | `refresh` 取自 `mode.vrefresh`（`vout.c:470`，默认 60，是**无符号整数**）；序号来自 `DRM_IOCTL_WAIT_VBLANK` RELATIVE 0（`vout.c:112-137`）；换算在 `pts_slot()`（`vout.c:603-618`） | 整数 60 对 59.94 的偏差 0.1%，一小时后 vblank 槽偏离 **3.6 s**，且永远不会自愈 |

**这三项不能各自打补丁，必须在 `delta` 的定义里显式写出来**，否则每个调用点各减各的常数，
就退回 §2.2.1 那种五个钟并存的局面：

```
L_total = L_a + L_d                     /* 都是"媒体时间已经过去但还没被感知"的量，同向相加 */
d = pts_us - (τ_us + L_total)           /* 拿"即将被看到/听到的时刻"对齐，不是拿"已写入的时刻" */
target_vbl = slot(τ_us + L_total) - 1    /* 再往前让出 L_d 那一槽，否则一提交就已过期 */
```

三条落地要求：

1. **`audio_clock_ns()` 不许是常数减法。** `L_a` 由内核按 period 更新，是 43ms 的阶梯（§2.1 / §2.1.1），
   要用锚点 + 速率外推（`clock_anchor_audio()`），不能写成 `now - AUDIO_LAT_US`。
   这条是 §2.1.1 那张表第 1 行的直接后果，此处不重复推导。
2. **`renderer->render()` 的成功返回只代表"已入队"，不代表"已上屏"。** 完成反馈要等
   `confirm_prev()` 核到 `cur >= prev_latch`（`vout.c:594-602`），这才是回收 buffer 的依据；
   §0.2 第 1 条讲的返回值语义是"交接成功"，两者不是同一件事。
3. **`vblank` 的时基要实测，不要用标称刷新率外推长期。** 短期（一次 submit 内）用 `refresh` 反算槽位可以；
   长期必须靠 `reply.tval`（vblank 时间戳）或周期性重锚，否则整数 `refresh` 的 ppm 级误差会累积。
   §6.2 说 `target_vbl` 每帧按主钟重算，前提就是"主钟到 vblank 的映射"本身在漂——
   两者要一起更新，只更新前者不够。

**验收口径**：三项相加后 `L_a + L_d` 的典型值已经接近 §6.2 的 40ms 门限（42.7ms 量化 + 16.7ms 提交），
所以门限必须作用在**已扣延迟的 `d`** 上。若实测发现扣除后仍频繁触发丢弃，
说明 `L_total` 估小了，而不是门限太严——先查延迟项，再动门限。

## 1. Player Core

### 1.1 一句话

**一个时间轴，三个消费者，上下两层各管一件事。**
数据面回答"第几帧、什么颜色"；控制面回答"放什么、从哪放"。
位置只由 C 知道，壳不再用 `$(now) - START + OFF` 推算。

现状的反面是这样：位置由壳猜、节拍由 `ffmpeg -re` 假装、颜色由环境变量指定。
三者都不可观测，所以任何同步/seek 问题只能靠重开进程兜。

### 1.2 拓扑

```
┌─ 控制面（壳）─────────────────────────────────────┐
│ tvplay-node.sh   意图: play/pause/seek/stop       │
│   只写意图: URL GEO START PAUSE_AT                │
└───────────────────────────────────────────────────┘
       │ fork/exec                  │ mpvctl IPC
       ▼                            ▼
┌─ hevcplay (C, 一个进程三条线程) ──┐   ┌─ mpv --no-video ─┐
│                                   │   │  音频 + 主钟     │
│  T1 demux    mpegts → AU          │   └──────────────────┘
│      ├── PTS (90kHz) ─────┐       │            │
│      └── 色彩元数据 ──┐   │       │ ←──────────┘ 200ms
│  T2 vdec  V4L2 → NV12M│   │       │      time-pos
│  T3 present GLES3 ←───┴───┴───────┘
│      按 PTS 对齐主钟, on vblank 上屏
└───────────────────────────────────┘
```

T3 有三个输入：帧、该帧 PTS、当前音频钟。现在只存在第一个，
所以只能靠 `-re` 在上游节流——**这是整条链需要重构的唯一根因**。

### 1.3 三条不变式

| | 内容 | 反例（当前代码） |
|---|---|---|
| **I1** | 时间只来自音频主钟（§2.1） | `b.timestamp = g_au_seq/25` 假时间戳 |
| **I2** | 呈现由 vblank 驱动，不由解码速度驱动 | `drmModePageFlip` + `wait_flip_to(20)` 解多快翻多快，靠 `-re` 兜 |
| **I3** | 色彩元数据与 PTS 同源，同一个 NAL 扫描 | `HDR=1` 环境变量 + `TM_SRC_PEAK=1000` 常量 |

三条都不是"优化"，是把已经存在但不可观测的量变成可观测的。

### 1.4 模块边界

**不动**（已验证有效）：

- V4L2 ioctl 层、OUTPUT/CAPTURE 双队列、背压逻辑
- `tm_apply` 的 NEON 就地色调映射内核（方案 A 用）
- `glout` 的 EGL/GBM、`drmModePageFlip`、dmabuf → 纹理零拷贝
- 两遍渲染：pass1 源分辨率做 tone map → RGBA8 纹理，pass2 廉价放大
  （4K 时把 pass1 压到 1080p 量级，`GL1MAX`，这个判断是对的）

**新增/重构**：

| 模块 | 职责 | 约 |
|---|---|---|
| `demux.c` | mpegts → AU + PTS + 色彩元数据 | 400 行 |
| `clock.c` | mpv IPC 轮询、暂停感知、单调平滑 | 150 行 |
| `present` 改造 | 去 vsync、加 vblank 节拍、按钟丢帧/等待 | 改 200 行 |
| `state.c` | 状态机 + 位置上报 | 200 行 |
| `glout` 改造 | 元数据驱动色彩路径 + SDR 真旁路 | 改 150 行 |

关键收束点：`demux.c` 同时向 T2 递 `(AU, pts, primaries, transfer, matrix, full_range, maxcll)`。
方向 2（时间轴）和方向 3（色彩）**共用同一个实现入口**，不是两件事。

### 1.5 状态机

取代现在的 `g_reinit` + `g_hard_reset_on_reinit` 两个布尔混用：

```
PLAYING ──seek──→ SEEKING ──拿到 IRAP──→ PLAYING
   │                  └─超时─→ RECOVERING
   ├─12s 无帧────────→ RECOVERING ──→ PLAYING   (退避 ≤4 次)
   └─|pts-钟|>2s────→ RESYNC ──→ PLAYING       (丢帧追钟, 不重建)
```

新增 `RESYNC` 是核心：**落后两秒不该重建会话**。重建只用于"vdec 完全不吐帧"。
现在两种走同一条路，等于为 0.3 秒漂移付 0.8 秒黑屏。
`STALLSEC` 那条经验（127 分钟 poll 空转）保留，但射程收窄回真正该管的事：
阈值 12s → **1.5s**（实测正常段帧间隔 `qmax` 恒 0.03~0.04s，余量 37 倍），
并加 `au-got > 0` 守卫，供流打嗝不再误判成硬件挂死。

顺带接上**从未被调用过**的 SIGUSR1 热重建（`v4l2hevc.c:1525` 注册、
`:1649` 有处理、`:108` 有注释）：`SEEKING` 走会话内 flush → 等 IRAP，不重开进程/设备。

### 1.6 删除清单

架构变没变，看删了什么最清楚：

- `ffmpeg -re`，及 `tvplay-node.sh:74-77` 那段 4 行解释注释
- `b.timestamp = g_au_seq / 25`
- `g_hard_reset_on_reinit`
- `HDR=` 环境推断、`TM_SRC_PEAK` 默认 1000
- 壳里 `el = $(now) - START + OFF` → 改读 C 上报
- `play.sh` 里 ffprobe 判 HDR

### 1.7 迁移顺序

每步可单独回滚，盒子始终能放。

| 步 | 内容 | 验收 |
|---|---|---|
| **A** | 色彩旁路（§1.8，~10 行） | SDR 片子不再被二次转色 |
| **B** | `demux.c` + 真 PTS，换 `-f mpegts` | 删掉 `-re` 后 4K/1080p 速度都对 |
| **C** | `clock.c` + 色彩元数据（从 demux 免费得来） | 长时间不漂，`time-pos` 与画面内容对得上 |
| **D** | `state.c` + SIGUSR1 热重建 | seek 不再 0.8s 黑屏 |

**B 是分水岭：B 之前一切同步/seek 都是猜，B 之后才是算。**

### 1.8 A 步实测修正（两条，含对我先前判断的纠正）

**① SDR 未真旁路 —— 确认成立。**
`tm.on=0` 时 `build_lut` 填恒等表（`glout.c:223-229`：`out[i]=i/255, gain=1`），
但 FSV[0]（`glout.c:282`，默认 `GLFS=0`）里的 **BT.2020→709 矩阵、逐通道 `clamp`、
`mix(lum, o, uSat)` 无条件执行**。

后果：每部 SDR BT.709 片子都被再乘一遍 2020→709，红更绿更"艳"，再被 `uSat` 压回。
看起来"还行"，所以一直没被发现。

修法：矩阵与 sat 的生效条件挂到 `tm.on`（或更好的，挂到 I3 的 `primaries`）。
不是"提成 uniform 就完事"——见下条。

**② `uSat` 其实已经是 uniform —— 我先前说错了。**
`glout.c:950` / `:1079` 已 `glUniform1f(..., "uSat", tp.sat)`。
真正的 bug 是 `tp.sat` 默认 **0.90**（`:208`），对 SDR 也生效。
所以 A 步的正确改动是：`sat` 默认 1.0，仅当检测到 HDR 时才降到 0.9，
而不是新增 uniform。矩阵那部分才是硬编码常量。

### 1.9 物理上限（先说清）

meson vdec 的 CAPTURE 只有 `NV12M` / `YUV420M`（`vdec.c:384/390`），**没有 P010**。
10bit 源在驱动里已被压成 8bit，量化噪声在 tone map 之前定型。

**在 8bit 量化上限内做最优近似**是这块板子能达到的目标；"完整 HDR 管线"做不到。
不要为 P010 去改驱动——那条路的尽头是硬件寄存器。

同理 `glout.c:116` 已实测：纹理采样型 LUT 每像素多 4.7ns（≈每屏 17ms），
4K 上加 33³ 三线性采样预算不够。色域压缩走解析式（约 6 条 FMA），不查 3D 表。

### 1.10 待定岔口（不由本文替你定）

**岔口一：控制面进程模型**

- **甲（推荐先做）**：壳保留，把位置权移交 C。改动最小、每步可回滚。
- **乙**：写 `tvplayd` 守护进程，壳退化成 20 行 CLI。彻底消灭"state 文件与真实进程不符"
  （脚本自己承认过）。代价是 B/C 期间盒子会有一段时间不稳定。

建议：甲跑通 A→D，守护进程留作 D 之后的独立重构。

**岔口二：音频是否继续外包 mpv**

- **保留 mpv**：省事，但保留"两进程读同一文件、seek 下两条命令"的耦合。
  且 mpv 的位置只能靠 IPC 抽样（§2.4 已论证它不配当主钟基准）。
- **换 ffmpeg 出音频**（`aout`）：需先解决 ALSA 缓冲——实测 8 秒 15 次 xrun，属硬件 period 问题，
  换 dmix/加大 period 才可能绕开。

**建议：过渡保留 mpv，终态换成 `aout`。** 这个岔口已经被 §2.1 的“音频主钟”定死了：
主钟的依据必须是采样级、可主动上报的位置，只有自己的 `aout` 有。
所以 mpv 只能当**过渡期的锚点来源**（B3 阶段用，外推 + 常量延迟补偿，接受 ±60ms），
`aout` 落地后立即替换；两条路都收敛到同一个 `clock.c` 接口，B3 不需要重写。
结构层面为什么“两个独立播放器”不能当终态、以及合并的触发条件与时序，见 §2.2。

**这两个岔口影响 B 步的写法和 A 步的上限**，定了才好继续。

---

## 2. Media Clock

### 2.1 主钟定为音频（Audio Master Clock）

一句话：**主时钟是音频；`clock.c` 定义唯一的 τ，全播放器只读这一个数；τ 的唯一物理依据是 `aout` 的 `played_ms`。**

“同步”一词的真正含义是**有一方必须被牺牲**——没人能既准又稳地同时跟随两个独立晶振。
所以先定角色，再写代码：这台播放器**只有一个主钟，且它永远是音频**。

| 候选主钟 | 依据 | 为什么不选 / 为什么选 |
|---|---|---|
| 墙钟（`-re`、直接拿 `CLOCK_MONOTONIC` 当播放时间） | 系统时间 | 与音频晶振无关，音频会持续欠载/溢出；且不可读（§2.2.1 M1） |
| 视频主钟 | 帧 PTS / vblank | 视频侧本来就有丢帧补帧的自由度，等于拿最不精确的一侧当基准；vblank 自身抖 ±1 帧 |
| 外部参考（PCR / NTP） | 码流或网络 | 直播才有意义，本机文件播放纯属多加一层不确定性 |
| **音频主钟** | **`aout` 的 `played_ms`（采样级）** | **唯一受硬件采样率约束、位置可自行上报、且人耳对它最敏感的量** |

**选音频的三条硬理由**（不是口味问题）：

1. **物理唯一性**：只有音频有“采样率 × 已播帧数”这个不可争辩的位置定义。
   §6.2 的铁律“只调视频、绝不调音频”能成立，正因为音频那一侧本来就不该被调。
2. **可观测性**：`aout` 是我们自己的进程，`played_ms = (written - delay)/rate` 每个 period 上报一次
   （`aout.c:348-349`，§1.13 决定 2/4）。误差上界由 period 决定，可测、可证。
3. **感知不对称**：视频丢一帧（24fps 下 41ms）人眼几乎看不出，音频跳采样/拉伸人耳立刻听出。
   把误差吸收在感知不敏感的一侧，是唯一正确的方向。

**主钟角色固定，运行期不许切换。** 这一条比任何实现细节都重要：
一旦允许“音频没了就切视频钟”，就回到了今天四个钟并存的状态。
无音轨、音频 EOF、`aout` 死掉，都**不改变主钟是谁**，只让主钟进入降级态
（`SOURCE=FREE` = 虚拟音频钟：单调时钟按 1.0 自走，视频依然是从动方）。
正常态与降级态的区别只在“锚点从哪来”，不在“谁跟谁”。

现在的局面（§2.2.1 有台账）是五个钟各自为政，“同步”靠 `-re` 把所有人压在墙上时钟上。
这一节把钟收成一个模块：**除它之外，谁都不许再自己算时间。**

**接口**（`clock.h`，实现 ~120 行，无依赖，x86 可单测）：

```c
/* 单位统一 µs，整数，不引入浮点 */
int64_t  clock_now(void);          /* τ：唯一读取入口 */
void     clock_anchor_audio(int64_t mono_ns, int64_t played_us, uint32_t seq); /* 唯一写者 */
void     clock_set_ppm(int32_t ppm);        /* 长期漂移校正，默认 0 */
void     clock_reanchor(int64_t media_us);  /* 起播/seek/换源：显式重锚，epoch++ */
void     clock_freeze(int on);              /* pause / 欠载 / 起播前 */
uint32_t clock_epoch(void);        /* 每次重锚 +1，给下游丢旧帧 */
int      clock_source(void);       /* AUDIO | FREE | FROZEN */
```

**τ 的模型只有两项**：一个锚点 + 一个速率。

```
τ(t) = anchor_media + (mono_now - anchor_mono) * (1 + ppm*1e-6)
```

锚点由 `aout` 每写满一个 period 上报一次。`aout.c` 已经把位置算对了
（`played_ms = (written - delay)/rate`，`aout.c:348-349`，§1.13 决定 2/4），
所以它只需在 `WRITEI_FRAMES` 返回后多记一行 `(CLOCK_MONOTONIC, played_frames, seg)`
推到 socket——这就是采样级的时间基，不需要任何 `AUDIO_LAT_US` 常量。

**为什么不直接把 `played_ms` 当钟**（本节最容易写错的地方）：

1. `delay` 由内核按 period 更新，`period = 2048 帧 = 42.7 ms`（`aout.c:56`）。
   直接读拿到的是**量化步长 43 ms 的阶梯**，而同步门限是 40 ms（§6.2）——阶梯比门限还大。
2. 走 IPC 读它（`aoutctl status`）又多一层调度延迟，且是抽样不是连续。
3. 所以：**`played_ms` 只当校准点，两次校准之间用单调时钟外推。**
   外推区间只有 43 ms，两个晶振在这个尺度上的分歧是 43 ms × 50 ppm ≈ 2 µs，可忽略；
   小时级的漂移交给 `clock_set_ppm()`，由锚点残差的一阶拟合估出来（§2.1 验收第 2 条）。

**三个来源，一个数字**：

| 源 | 何时 | τ 怎么走 |
|---|---|---|
| `AUDIO` | 有音轨且在播 | 锚点 + 外推（上面那条公式） |
| `FREE` | 无音轨（`AUDIO=0`）、`aout` EOF、`aout` 进程死了 | **虚拟音频钟**：锚点由最近一次 PTS 提供，速率 1.0 自走（等价于“音频隐含、采样率无穷”），节拍交给 vblank（`target_vbl`，§6.2）；角色仍是主钟，视频仍从动 |
| `FROZEN` | pause / 欠载 / 起播前 | τ 冻在最后值；`anchor_mono` 跟着 `mono_now` 推进，恢复时不产生跳变 |

**五条不变式**（违反任何一条都是 bug，且要在下游写成断言）：

1. **单调**：`clock_now()` 永不回退。内部钳 `τ = max(τ, τ_prev)`，唯一例外是 `clock_reanchor()`（同时 `epoch++`）。
2. **不跳**：正常播放期间两次连续调用之差 ≤ 调用间隔 + 1 ms 抖动。跳变只能来自 reanchor。
3. **冻结不等于停**：`FROZEN` 时 τ 不动，但单调底数继续走，恢复后立刻按公式接上，不补、不追。
4. **epoch 语义**：起播 / seek / 换源 / 音频重开一律 `epoch++`；下游见到 `frame.epoch != clock_epoch()` 直接丢，
   不额外加 flag。这条同时把 §5 里"flush 期间旧帧漏上屏"一起解决。
5. **降级不崩，主钟不变**：`aout` 死掉 → `SOURCE=FREE`（虚拟音频钟）+ 一行日志，绝不让视频停住。
   `FREE` 是**同一角色的降级态**，不是“换成视频主钟”；它也不会自己升回 `AUDIO`，
   必须由一次显式 reanchor（换源 / 恢复播放）带回。

**单一读取者纪律**（这条比代码更重要）：除 `clock_now()` 外，任何模块——`v4l2hevc`、`vout`、
`render_drm`、`render_gl`、壳、`rcinputd`——**不许**直接读 `aoutctl`、mpv `time-pos` 或
`CLOCK_MONOTONIC` 来当播放时钟。诊断输出允许，但必须带 `RAW` 前缀，好和 τ 分开看。
今天 `el = $(now) - START + OFF`、`g_au_seq/25`（`v4l2hevc.c:373-374`）都属于"第二个钟"，随 §2.2.1 / §2.4 一起删。

**谁消费 τ**：

- `v4l2hevc` 解码队列：只判 `pts - τ` 决定丢弃/背压（§1.9），不排上屏时间
- `vout`：`target_vbl = vbl_base + round((τ - τ0) * refresh)`，每帧重算，不累加（§6.2）
- 壳 / `rcinputd`：进度显示、`seek_target = τ + OFF`；**只读不写**，壳不参与时间
- 播放列表：换源时给 `clock_reanchor(0)` 提供媒体侧零点

**验收**（盒子上能跑的数，不是"感觉对了"）：

| 检查 | 方法 | 通过线 |
|---|---|---|
| 外推精度 | 每 200 ms 记一行 `τ - aoutctl.played_ms` | 误差 < 5 ms，无 43 ms 阶梯 |
| 长跑漂移 | 连播 10 min，τ 与 AU 的 PTS 做线性回归 | 残差 < 10 ms，斜率偏差 < 100 ppm |
| 暂停恢复 | pause 30 s 再 resume | τ 连续差 < 2 ms，epoch 不变 |
| 无音频 | `AUDIO=0` + 裸流 | τ 自走单调，2 h 漂不过一帧 |
| 音频死 | `kill -9 aout` | 切 `FREE`，一条日志，视频不停 |

**落地点**：`clock.c` + `aout` 的锚点发布（协议见 §2.1.1，不是“多一行”）。属于 §1.7 的 **C 步**，
且**必须在 B 步（真 PTS）之后**——PTS 是假的，τ 再准也无从对齐。

### 2.1.1 Audio Clock：锚点协议（`aout` → `clock.c`）

上一节说“`aout` 多一行 anchor 上报”。**这句话如果照字面实现，会写出三个 bug**，
所以这一小节把协议定死。三个陷阱都在 `aout.c` 现成的代码里能找到证据：

| 陷阱 | 证据 | 后果 |
|---|---|---|
| **写返回 ≠ 播到** | `write_all_frames()` 是阻塞写，返回时数据刚进 ring；ring 深度 = `g_buf` = 8192 帧 = **170.7 ms** | 拿 `write()` 返回时刻当锚点，τ 恒定超前 170 ms，且随 buffer 深度变 |
| **轮询 `status` 有量化** | `played_frames() = g_written - pcm_delay()`，`delay` 由内核按 period 更新，period = 2048 帧 = **42.7 ms** | 拿到 43 ms 阶梯，比同步门限还大（§2.1 已述） |
| **上报时刻 ≠ 采样时刻** | 锚点从 `play_thread` 里发出，中间可能被调度挂起 | 锚点自带 >1 ms 抖动，外推起点就是错的 |

结论：**锚点必须是一个三元组，且发布与读取都不许有系统调用。**

#### 通道：共享内存 + seqlock，不走 socket

`/tmp/aout.sock`（`g_sock`）保持只做控制（status/pause/vol/quit）。
把锚点塞进这条 socket 是错的：它是 C/S 往返，读取方要么阻塞要么轮询，
等于把“抽样 + 调度延迟”换个地方重演——这就是 §2.4 弃掉 mpv 方案的同一种病。

用一块 `MAP_SHARED` 匿名/文件映射的小结构（~64 B），单写者（`aout`）多读者，
seqlock 保证读到的三元组自洽。**读端零系统调用、零锁、无优先级反转。**

```c
/* clock_shm.h —— 布局固定，不许加字段（加就换 version，双方一起重编） */
struct aclk_shm {
	volatile uint32_t seq;         /* 奇数 = 写入中，偶数 = 稳定 */
	uint32_t          ver;         /* = 1 */
	uint32_t          rate;        /* 硬件实际采样率（取自 snd_pcm_hw_params） */
	uint32_t          flags;       /* bit0 EOS  bit1 XRUN  bit2 PAUSED  bit3 UNDERRUN */
	int64_t           frames;      /* played_frames：已播帧，累计，含 seek 前 */
	int64_t           mono_ns;     /* 该 frames 对应的 CLOCK_MONOTONIC（采样时刻，非发布时刻） */
	uint64_t          bytes;       /* 已消费的输入字节 → 上游算缓冲水位 */
};
```

写端（`aout`，仅 `play_thread` 与暂停/恢复路径）：

```c
static void aclk_publish(int64_t frames, int64_t mono_ns)  /* ~10 行 */
{
	__atomic_add_fetch(&shm->seq, 1, __ATOMIC_RELEASE);   /* → 奇数 */
	shm->frames = frames;  shm->mono_ns = mono_ns;
	__atomic_add_fetch(&shm->seq, 1, __ATOMIC_RELEASE);   /* → 偶数 */
}
```

读端（`clock.c`）：`do { s1 = seq; 读三元组; s2 = seq; } while (s1 != s2 || (s1 & 1));`
x86/arm64 上配 `__ATOMIC_ACQUIRE` 足够，不需 barrier 指令。

**`mono_ns` 必须是采样时刻**，取值点只有一个：**紧接 `SNDRV_PCM_IOCTL_DELAY` 返回之后**
（`pcm_delay()`，`aout.c:155-162`）。此时内核刚报出 `hw_ptr`，`now()` 与它的差
上界是一次 ioctl 的时间（µs 级），可忽略；先取 `delay` 再取 `now`，顺序不许反。

#### 发布时机：四个，不是只有一个

| 时机 | 在哪 | `frames` / `flags` |
|---|---|---|
| **每个 period 写完**（主路径） | `write_all_frames()` 返回后，`g_written += xf.result` 之后 | `played_frames()`，flags 清 PAUSED |
| **暂停生效** | `g_frozen_ms` 置位的同一临界区（`aout.c:386-390`） | 冻结值，置 PAUSED |
| **恢复播放** | `AOUT_PAUSE_OFF` 之后**首个** period 写完 | 真 `played_frames()`，清 PAUSED |
| **xrun / 欠载恢复** | `g_underruns_recovered++` 处 | 置 XRUN + 清 XRUN 各发一次（成对，见下） |

少发一次暂停锚点，读端就会把“硬件 PAUSE 后 `hw_ptr` 不动”误判成外推失控，
进而触发一次假 reanchor——这是最容易漏的一条。

#### 读取规则（`clock.c` 侧，五条，按顺序匹配）

```
1. shm 里没有活跃 aout（magic 不匹配 / 进程已死 / EOS）  → SOURCE=FREE，τ 自走
2. seq 变化 且 frames 在本段内单调不减                → 收下新锚点，重设外推
3. seq 不变                                          → τ = anchor + (now - anchor_mono)，不重设
4. frames 相对上一锚点回退，或 now < anchor_mono      → 锚点作废，继续用旧锚点外推（丢，不修）
5. flags & XRUN（成对上报中，看到置位而未见清除）      → 只记一行日志；不切 FREE
```

第 4 条对应 §2.1 不变式 2（不跳）：**迟到的旧锚点绝不许把 τ 拉回去**。
第 5 条是特意放宽的——xrun 期间 `hw_ptr` 会跳，`played_frames` 跟着跳，
但音频仍在播、只是位置有跳变，此时**宁可用旧锚点外推 43 ms 也不重锚**，
因为重锚会让 `epoch++`，下游白丢一帧。

#### 三个边界，各有一行硬规则

1. **起播 prefill**：`g_buf` = 170.7 ms，首个 period 写完后 `played_frames() == 0`。
   此时 `frames == 0` 是**合法锚点但不是有效锚点**——τ 必须停在首帧 PTS 上
   （`SOURCE=FROZEN`），**直到出现第一个 `frames > 0` 的锚点**才转 `AUDIO`。
   绝不拿 `g_written` 当钟（那正是“超前 170 ms”陷阱）。
2. **暂停**：`clock_freeze(1)` 由控制面和 `AOUT_PAUSE` **同一次请求**下发（§3.3 的唯一权威）。
   两者只差一个 ioctl 的时间，且 `FROZEN` 语义本来就是“τ 不动、底数继续走”，
   所以不需要跨进程同步——不要在 `aout` 里等 `clock` 确认。
3. **EOS**：输入 EOF 后 `aout` 还会把 ring 里剩下的播完（`aout.c:275-291` 的尾部 flush）。
   这段尾巴**仍是 AUDIO 主钟**，`frames` 继续报；只在最后 `g_quit = 1` 时置 EOS flag，
   读端见 EOS 才降 `FREE`。提前降级会让片尾最后 170 ms 的画面跑飞。

#### 长期漂移：`clock_set_ppm()` 怎么算

只在 `AUDIO` 有效段内做，取最近 **60 s** 的锚点（≈1400 个，43 ms 一个）：

```
残差 r_i = (frames_i - frames_0)/rate*1e6 - (mono_ns_i - mono_ns_0)/1000   /* µs */
一阶拟合 r(t) 的斜率 s（µs/s） → ppm = clamp(s, -200, +200)
```

残差序列本身是锯齿（每个锚点落在一个 period 边界上，锯齿幅度 ≈ 半边 period ≈ 21 ms），
拟合必须在整段上做，不许逐点差分。限幅 ±200 ppm 是因为超出去只能是 bug 不是晶振。
`FREE` 段一律 `ppm = 0`：那时候没有第二个晶振可比。

#### 验收（在 §2.1 那张表之外补三条）

| 检查 | 方法 | 通过线 |
|---|---|---|
| 锚点自洽 | 读端做 seqlock 校验，统计 `s1 != s2` 次数 | 重读率 < 0.1%（说明写端临界区够短） |
| 无系统调用 | `strace -c -p <player>` 跑 60 s | `clock_now()` 路径上 0 次 `clock_gettime` 以外的调用；`read` 数不随帧率增长 |
| 迟到锚点 | 人为在 `aclk_publish()` 前 `usleep(50ms)` | τ 不出现负步进，`epoch` 不变，日志有“stale anchor”一行 |

#### 改动清单（比 §2.1 的“多一行”更真实）

| 文件 | 改动 | 量 |
|---|---|---|
| `aout.c` | `mmap` 建 shm + `aclk_publish()` + 4 处调用点 | ~45 行 |
| `clock.c` | 读端 seqlock + 5 条规则 + ppm 拟合 | ~90 行（原估 120 行含此项） |
| `clock_shm.h` | 结构体 + 版本号（新文件） | ~20 行 |
| `aoutctl.c` | `status` 里带出 `shm_seq`，便于诊断对账 | ~5 行 |

`clock_shm.h` 的布局**一旦进盒子就不许改**——`aout` 和播放器是分别部署、分别重启的，
字段语义变化只能新开 `ver` 并同时发布两个版本，否则老 `aout` + 新播放器会读到错位数据。
这条比字段设计本身更重要。

### 2.2 不要继续使用两个独立播放器作为最终架构

一句话：**终态必须是一个进程；`mpv --no-video` + `hevcdec` 两条链并存只是过渡结构，不是架构。**

现状不是"一个播放器 + 一个音频工具"，而是**两个各自独立、互不知情的播放器**：
mpv 自己解容器、自己配 ALSA、自己计时、自己 seek（`tvplay-node.sh:83-88`）；
hevcdec 自己拉 ffmpeg 管道、靠 `-re` 被动流出、按帧计数上屏（`:93`）。
两者之间共享的东西只有三样：同一个 `$STATE` 文件、同一个 `$URL`、以及壳手工维护的 `START`/`OFF` 两个数。

壳的注释已经把这层窗户纸捅破了一次（`tvplay-node.sh:172-174`）：
"画面(v4l2hevc/ffmpeg)和声音(独立 mpv)是两个进程，只 toggle mpv 只会哑掉声音、画面照跑 ——
必须整条 STOP/CONT"。**"必须整条"就是架构在报警**：任何一次用户操作都得同时打到两条链上，
且没有任何一方知道另一方是否成功。

**结构性问题不是"多一个进程"，而是"多一条时间轴"。**
同步是闭环：观测从动方相对主钟的误差，再修正从动方。两个独立进程之间这个环是断的——
**没有任何一方能同时看到"音频播到哪"和"视频该出哪一帧"**，
于是只能各自猜测，再把猜测写进共享文件。
今天所有同步手段都是开环补偿，恰好三件套、恰好对应三个本该闭环的量：

| 开环补偿 | 位置 | 本该闭环的量 | 为什么开环修不了 |
|---|---|---|---|
| `-re` 上游节流 | `tvplay-node.sh:93` | **节拍** | 容器时间基在 ffmpeg 进程里，播放器读不到；换 VFR / 25÷1.001 片源就换节拍，无人观测（§2.2.1 M1） |
| `LEAD=6` 缓冲深度 | `v4l2hevc.c:1261`，判据 `:1469-1473` | **领先量 `pts - τ`** | 只限制"喂了几帧"，不知道"差多少毫秒"；掉帧与堆积都不可见 |
| `START`/`OFF` 的 `sed` 修补 | `:122`、`:201-202` | **位置** | 暂停时长、seek 目标靠事后改状态文件补齐，两条链各自重来一遍 |

**五个量各有两个写者**（这不是细节，是"两个播放器"的必然结果）：

| 量 | 写者 A | 写者 B | 现场症状 |
|---|---|---|---|
| 时间 | mpv `time-pos`（进程外，抽样） | `-re` + `g_au_seq/25` | 五个钟并存，§2.2.1 台账 |
| seek 目标 | `restart_at` 重开整条链（`:127-136`，1~3s 黑屏，`:150`） | mpv 自己 `seek`（`:199`） | 音视频各自算目标；HEVC 路径靠 `seek_guard` 3s 内合并（`:155-162`）硬扛 |
| 暂停态 | `SIGSTOP` 四个 pattern（`:109-112`） | `mpvctrl toggle`（`:178`） | 只停一边 = 哑声或画面照跑（`:172-174`） |
| 播放状态/EOF | `$STATE` 文件 | 真实进程 | "state 与真实进程不符"（`:169-171`），只能 `pgrep` 猜 |
| 起播基准 | mpv 开容器 + ALSA（~1s） | vdec 建会话（~0.6s） | 起播阶段声画必然错开，且错开量不可测，只能靠 `LEAD` 掩盖 |

**所以"调参"这条路是封死的**：上表每一行的两个写者都合法、都在工作、
都没有错——错在没人能同时看见两边。加一个参数只会多一个开环旋钮，
今天 `START`/`OFF`/`LEAD`/`FPS`/`-re` 五个旋钮已经互相补偿到没人能解释画面为什么对。

**为什么现在不立刻合并**：音频外包的唯一硬理由写在 `tvplay-node.sh:80`——
"ffmpeg 的 `-f alsa` 在这块板子上缓冲太浅（8s 15 次 xrun）"。
这个理由今天仍然成立，而它的解法不是"再找一个播放器"，是 `aout` 自己管 ring
（170 ms 缓冲 + 42.7 ms period 上报，§2.1.1）。**合并的前提是 `aout` 能替代 mpv 的音频能力，
而不是"合并"本身是目的。** 次序因此固定：

1. **B 步**：真 PTS 进 `v4l2hevc`（§2.5），先把视频侧的时间变成可观测的量
2. **C 步**：`aout` + `clock.c`（§2.1/§2.1.1），主钟移进本进程，mpv 退成可选
3. **D 步**：`state.c` 收口（§3），壳不再持有 `START`/`OFF`，seek 只发一个 `target_us`（§5）
4. **合并**：`hevcplay` 一个进程三条线程 + `aout`，mpv 只在"`aout` 不可用"时留作逃生路径

前三步任意一步跳过，"合并"都会变成把两个开环换成一个更大的开环。

**过渡期纪律**（合并之前，两条链还得继续跑，这三条必须守）：

1. **不许新增第三条链**：任何"先写个脚本兜一下"的方案，都会变成第四个写者。
   今天的 `seek_guard`、`resume` 里的 `sed` 已经是上限。
2. **每个量只许一个默认权威**：位置权威是 `$STATE` 的 `START+OFF`，进程是否在跑只许 `pgrep` 判，
   **不许再从 `PLAYER` 字段推断**（`:169-171` 就是这条被违反后的产物）。
3. **跨链操作必须原子化到一条命令**：`toggle`、`seek`、`stop` 各自只发一次，
   两条链的执行都挂在同一次调用里（今天 `toggle` 已经这样写，`seek` 还没有）。

**什么时候必须合并**（触发条件，达到任一条就别再拖）：

- 出现一次**无法用"重开"解释**的声画错位（即：重开后依然错，说明错在时间模型而非链路）
- 需要支持 VFR / 非整数帧率片源（`-re` 的容器时间基会与 `g_au_seq/25` 直接冲突）
- seek 精度需求进到 1s 以内（整条重开 1~3s，物理上做不到）
- 要接入第二块屏 / 第二路音频（两条链的 `STATE` 是单例文件，没有第二份）

**判定"合并成功"的唯一标准**：`pgrep -c mpv` 为 0 时，播放、暂停、seek、音量、
进度显示全部照常。今天这个测试会失败在"没声音"，而那正是本章要移除的结构。

### 2.2.1 台账：现在同时存在五个钟，彼此不一致

台账按**代码行号**核过一遍（`v4l2hevc.c` 1774 行、`tvplay-node.sh` 250 行，均当日版本）。
每一行都写清“谁写、谁读、删给哪一步”——只列名字不列行号的台账，一个月后就对不上代码了。

| 钟 | 写入点（证据） | 谁在读 | 单位/精度 | 问题 |
|---|---|---|---|---|
| **M1 供流节拍** | `ffmpeg -re`：`tvplay-node.sh:93` | 无人（隐式） | 不可读 | 隐式、随 ffmpeg 版本变；**今天真正的钟在这里** |
| **M2 帧时间戳** | `b.timestamp.tv_sec = g_au_seq/25`，`.tv_usec = (g_au_seq%25)*40000`（`v4l2hevc.c:373-374`） | `v4l2hevc` 自己 | 40 ms 固定步长 | **硬编码 25fps**，与 M3 的 24 差 4% |
| **M3 上屏节拍** | `g_play_fps = 24.0`（`v4l2hevc.c:1072/1260`） | 背压判据 `au_idx - got >= g_play_lead`（`:1472-1473`，`LEAD=6` 见 `:1073/1261`） | 帧计数 | 只限制**领先多少帧**，不决定**何时上屏**；24fps 是默认真假值 |
| **M4 音频** | mpv / `aout` | **没有人读** | 采样级（真值） | 唯一精确的钟，却没接进任何判据 |
| **M5 壳的进度** | `el = $(now) - START + OFF`（`tvplay-node.sh:244`；暂停分支 `:242`，`pos()` `:13-21`） | 壳、进度显示、seek | **整秒**（`date +%s`） | 墙钟差 + `START` 被 `sed` 改写（`:122`、`:201`）；秒级颗粒度比门限粗 40 倍 |

所以不是"四个钟"，是**五个**。M5 之前没被算进来，因为它躲在壳里、长得像"进度条逻辑"
而不是"时钟逻辑"——但 `seek_target = τ + OFF` 正是靠它算的（§2.1“谁消费 τ”第三条：`seek_target = τ + OFF`），
它就是第二个钟，必须一起删。

**25/24 的冲突为什么今天不显形**：M2 与 M3 差 4%，M5 只到秒，但它们没有一个真的在
决定"这一帧什么时候上屏"。上屏时机由 M1 的 `-re` 决定——视频按 ffmpeg 供流的节奏
被动流出，`LEAD` 只做了个**缓冲深度**限制（`:1472-1473`，领先 6 帧就别再喂），
根本不管时间。**真正的钟是 `-re`，而它连一个可读的数值都没有。**

这句话的严重性在于：`-re` 是按**容器时间基**供流，容器时间基是 ffmpeg 自己按
`avg_frame_rate` 算的。换个片源（VFR、25/1.001、29.97）它就换一个值，
而播放器侧没有任何人能观测到这次变化——**唯一的时间权威在别人的进程里，且不可读**。

#### 删除归属：每个钟死在哪一步

| 钟 | 删除动作 | 归属 | 判据（删掉后必须仍然对） |
|---|---|---|---|
| M1 `-re` | 退化为**限流阀**，不再承担时间：只保证管道水位，不保证节拍 | B 步（真 PTS） | `-re` 拿掉后仍按 PTS 播：`NOPACE=0 FPS=0` 跑 1080p60 不飘 |
| M2 `g_au_seq/25` | 整段删，`b.timestamp` 改由**码流 PTS** 填（§2.5） | B 步 | 25fps 与 29.97fps 片源各跑一次，`timestamp` 步长随之变 |
| M3 `g_play_fps` | 保留但**降级为纯背压参数**，不许参与上屏时间 | C 步（`clock.c`） | `FPS` 改成 60 时画面速度不变，只影响缓冲深度 |
| M4 音频 | 从"没人读"变成**唯一主钟** | C 步（§2.1.1） | §2.1 验收表 |
| M5 `el = now - START + OFF` | 改读 `clock_now()`，`START`/`OFF` 只管 seek 目标偏移 | C 步末 | 暂停 30 s 后 `pos()` 连续（今天靠 `sed` 改 `START` 才连续，`:122`） |

**顺序不能乱**：M2/M1 属于 B 步，M3/M4/M5 属于 C 步。若先做 C 步，`clock.c` 的锚点
对齐的是假 PTS（M2），τ 再准也只是把 40 ms 的错误量化得很精确——§2.1 落地点那句
"必须在 B 步之后"就是这条约束的重复。

#### 怎么证明删干净了（可脚本化）

单一读取者纪律（§2.1）靠人守不住，得靠 grep 门。三条，进 `chk.sh`：

```sh
# 1) 时间戳不许由计数器造
! grep -n "tv_sec *= *g_au_seq\|/ *25;" v4l2hevc.c
# 2) 壳不许自己算时间
! grep -n 'el=\$(( *\$(now)' tvplay-node.sh
# 3) 只有 clock.c 许调 clock_gettime（诊断须带 RAW 前缀）
[ "$(grep -rln clock_gettime *.c | grep -v '^clock.c$' | wc -l)" -eq 0 ]
```

第 3 条在迁移期会红——`v4l2hevc.c`（`now_s()`）、`aout.c`、`render_*.c` 都各有各的
`clock_gettime`。所以它**不是现在就要过的门，而是 C 步的完成定义**：
哪天这三条全绿，才算"只剩一个钟"。这比任何"感觉同步了"的验收都硬。

### 2.3 GL 路径：`FPS` 是假的

配速已改由播放器负责（`render.h` 的 caps：有节拍的后端自己排 vblank 槽，没有的由播放器按 FPS 睡），`-re` 只用来控制管道水位。
代码印证：`g_play_fps` 默认 24（`v4l2hevc.c:1072/1260`）只用于背压判据 `au_idx - got >= g_play_lead`（`:1472-1473`），
`LEAD=6`（`:1073/1261`）——它限制的是**解码器领先显示多少帧**，不是每帧什么时候上。
真正的速率上限来自 `-re`；`NOPACE=1` 时 `g_play_fps=0`（`:1263`），直接按解码速度飞。

**结论：GL 路径今天没有时钟。** 现在看起来对，是因为单路播放时 `-re` ≈ 片源帧率。

### 2.4 反例：曾打算让 mpv 当主钟（已弃）

`aout`（design_player.md §1.13）落地之前的方案是把 mpv 当主钟。思路本身对，
错在物理依据选了个隔了两层进程的东西。留在这里当决策记录：

```
τ = mpv.time-pos + (mono_now - mpv_reply_mono)      /* 插值，抵消 IPC 粒度 */
τ 冻结当 mpv.pause=true
τ 单调钳：τ_new < τ_old → 保持 τ_old（除非 SEEKING 显式重锚）
```

IPC 轮询的坑：200 ms 一次，直接拿 `time-pos` 当钟 → 量化误差 200 ms，
比同步门限（40 ms）大 5 倍。所以必须**插值**；`mpv` 的 `time-pos` 在每次回包时
当作校准点，两次回包之间用 `CLOCK_MONOTONIC` 外推。

第二条坑：`time-pos` 是"已送进 ALSA"的位置，不是"已听到"的位置。
ALSA 缓冲深度（`hw:0,0` 直出，无 dmix）是常数，一次性量出来存成 `AUDIO_LAT_US`
（默认给 60 ms，实测校准），作为常量偏移。**不要试图动态估。**

> 这两个坑都只在开发机 `mpv 0.37.0` 上验过：`time-pos` 的"已送进 ALSA"意味着它的语义
> 跟 `ao` 实现和版本走，`playback-time` 又是另一个量。**盒子上的 mpv 版本从未记录过**，
> 结论要按 §2.6 的方法当场确认，不能当规范引用。

**弃因三条**：① 量化 200 ms 由 IPC 粒度决定，改不了，只能靠外推硬撑；
② `AUDIO_LAT_US` 是个只能实测一次的魔数，换 buffer/period 就作废；
③ mpv 是独立进程，EOF、欠载、卡顿只能间接猜。
而 `aout` 的 `played_ms` 本身就是 `written - delay` 的采样级位置，三条一起消失。
一句话结论：**主钟必须有采样级、可主动上报的位置源；进程外的抽样值不配当主钟。**

它同时也是 §1.10 岔口二的判据：既然主钟必须是音频，那音频终归得是自己的进程。
mpv 版本只是把 `clock.c` 的 `clock_anchor_audio()` 从“period 上报”换成“IPC 回包插值”，
接口不变、上层不受影响——这就是先把接口定下来、再换实现的价值。

### 2.5 PTS 从哪来

这一节原来只有一句话（"`demux.c` 给每个 AU 附 `pts`"）。当场实测后，这句话必须改写：
**管道里根本没有 PTS，而且跨过 raw ES 边界就永久拿不回来。**

#### 先把现状钉死（`tvplay-node.sh:92-94`）

```
ffmpeg ... -re -ss "$START" -i "$URL" -map 0:v:0 -c:v copy -f hevc - | v4l2hevc -
```

输出是 **raw Annex B ES**。本机当场跑（ffmpeg 6.x，`/tmp/t.hevc`，源 320x240@30）：

| 观测 | 结果 |
|---|---|
| `ffprobe -show_packets` on raw ES | `pts=N/A`、`dts=N/A`，只有 `duration=40000`（**VUI 推的标称帧间隔**） |
| 同一流的帧率 | `r_frame_rate=30/1` 但 `avg_frame_rate=25/1` —— **连帧率都是猜的** |
| raw ES 再封装回 mpegts | `Timestamps are unset in a packet` → `first pts and dts value must be set` → `Error muxing a packet`，**失败** |
| 同上加 `-fflags +genpts -r 25` | 同样失败（genpts 挂在 demuxer 上，raw ES demuxer 不产时间） |

**硬结论**：raw ES 里只有码流，没有时间。容器时间戳在 `-f hevc -` 这一跳被 ffmpeg 丢掉，
之后的任何进程——包括 `demux.c`——都**没有东西可附**。所以 §2.2.1 的 M2 不是"填错了值"，
是"填的位置根本没有真值"；B 步也不是"改几行"，是**必须改管道**。

#### 三条路

| 方案 | 做法 | 能拿到什么 | 代价 | 判定 |
|---|---|---|---|---|
| **A 换容器** | `-f mpegts -` 代替 `-f hevc -`，`demux.c` 解析 PES | 真 PTS/PCR（65-bit，90kHz） | PES 解析 ~120 行；封装开销（见下） | 过渡，可先做 |
| **B 播放器内 demux** | `libavformat` 进 `v4l2hevc`，**删掉 ffmpeg 进程** | 真 PTS + `av_seek_frame` + 时长 + 音轨时间 | 引 libavformat 依赖（ARM 静态链） | **终局** |
| **C 留在 raw ES 猜** | 解析 SPS VUI 得标称帧率，POC 重排 | 只有标称帧率：无 VFR、无绝对时间、无 29.97 | 最小 | 只配当兜底 |

B 是终局的真正理由不是"省一个进程"，而是**一次改动同时解掉三处**：
§2.5（真 PTS）、§3.4（时长别再跑 ffprobe）、§5.2（`avformat_seek_file` 已经在 §1.4 的模块表里躺着）。
A 方案做的是同一件事的最小切片，接口可以完全一致（`demux.c` 对外只吐 `{au, pts_us, keyframe}`），
所以 A→B 不需要重写消费方——**先把接口钉住，再用哪个实现填是第二位的事**。

A 的封装开销：合成片上实测 raw ES 9,696 B → mpegts 26,884 B（2.8×），但那是 38 kbit/s 的
极低码率，开销由 padding 主导，**不能拿这个数下结论**。真实码率（几 Mbit/s）下主要是 TS 包头
（188 B 里 4 B，约 2.1%）+ 每 AU 一个 PES 头（19 B）。要写进文档的数必须用真片重测一次，
这里先记为**待测**，不填猜测值。

#### 方案 B 的实现决策：libavformat 怎么进来（2026-11-17 实测）

上一段把 B 定为终局，但"引一个依赖"这句话底下埋着一次真正的采购决策。当场量了三件事，
结论是：**不引发行版的库，自己 configure 一份最小 ffmpeg 静态库；而且必须与 §2.7 的音频解码
同一次 configure 做完，否则要交叉编译两遍。**

| 实测项（开发机，ffmpeg 6.1.1 / libavformat 60.16.100 / libavcodec 60.31.102 / libavutil 58.29.100） | 结果 |
|---|---|
| 归档体积（未 strip，x86_64） | `libavformat.a` 5.3 MB、`libavcodec.a` 23 MB、`libavutil.a` 1.6 MB |
| 写一个**只调** `avformat_open_input` + `av_read_frame` 的最小程序，静态链发行版 `.a` | **失败**：650 个未定义符号 |
| 那 650 个符号是谁 | ~30 个外部库：`va*`/`vulkan`/`OpenCL`/`dav1d`/`svt-av1`/`rav1e`/`x264`/`x265`/`gnutls`/`srt`/`zmq`/`libssh`/`xml2`/`rsvg`/`aom`/`vpx`/`opus`… |
| aarch64 侧交叉库 | `/usr/aarch64-linux-gnu/{lib,include}/libav*` **完全不存在**（`crosslib/` 只有 drm/EGL/GLESv2/gbm/GL/expat） |
| 盒子侧是否有 `libavcodec.so` | **未验证**——本次 `adb devices` 无设备在线，不填猜测 |

中间那行是本节的支点：**发行版的 `.a` 不是"能拖进自己程序的库"，而是"给静态 ffmpeg 可执行文件
准备的、把 `configure` 里所有 `--enable-*` 全算进去的归档"**。它连 `cairo_paint`、`zmq_send`、
`gnutls_handshake` 都在里面。所以"静态链 libavformat 只多 8~10 MB"这种估法是错的，
**那个数在发行版二进制上根本取不到**，只能由自己的 `configure` 决定。

##### configure 的最小集合（demux-only）

```
./configure --arch=aarch64 --cross-prefix=aarch64-linux-gnu- \
  --enable-static --disable-shared --disable-programs --disable-doc \
  --disable-everything --disable-autodetect --disable-network \
  --enable-protocol=file \
  --enable-demuxer=mpegts,mov,matroska,flv,hevc,h264 \
  --enable-parser=hevc,h264
```

三个开关的分工必须写清，否则下次有人加库又把 650 个符号领回来：

- **`--disable-everything`** 关掉全部组件白名单，只留上面列的；
- **`--disable-autodetect`** 是消除上面 650 个外部符号的**开关本体**——它让 `configure` 不去
  探测 vaapi/vulkan/opencl/gnutls/srt…，探测到就 `#if CONFIG_*` 编进去，静态链时全要你补；
- **`--disable-network --enable-protocol=file`** 还是 `--enable-network --enable-protocol=http,tcp`：
  **这一条本次没验清，不能拍**。`$URL` 是调用方 b64 传进来的
  （`tvplay-node.sh:27,34`：`URL=$(dec "$2")`），脚本里看不到 scheme——
  是裸路径、`file://` 还是 `http://` 只能在 `key` 分支（`:58,105`）那一侧确认。
  两条路都能走通，代价不同：开 network 就必须同时接上下面的 `AVIOInterruptCB`，
  否则 seek 阻塞后无解；关 network 则一旦将来改成推流就整个要重配重编。

##### 四个设计点，每个都能踩坏一处别的东西

| 点 | 规则 | 踩坏了什么 |
|---|---|---|
| **owner** | `AVFormatContext` **只许 T1 demux 线程碰**，其他线程只通过 §2.1.1 的 seqlock 读结果 | libavformat 不是线程安全的；两个人各调一次 `av_read_frame` 就是"两个播放器"在进程内复现（§2.2） |
| **可中断 IO** | `fc->interrupt_callback` 指向一个读 `seek_gen` 的判定函数，`avformat_open_input`/`av_read_frame` 前都设 | 今天 seek 靠 `kill` 进程（§5.1）；删掉进程后**没有可杀的东西**，阻塞在 `read(2)` 里就是永久 SEEKING |
| **时间换算** | `av_rescale_q(pkt->pts, st->time_base, AV_TIME_BASE_Q)`；`AV_NOPTS_VALUE` 时用 `dts`，再不行用"上一 AU 的 pts + 帧时长"，**绝不许填 0** | 填 0 会让 τ 倒跳一整部片；手写 `pts*100/9` 只在 mpegts 的 90 kHz 下成立，`mov` 的 `time_base` 是 1/1000 或 1/30000（§2.5 硬规则 1 在 B 下升级成"别手算"，不是"别截断"） |
| **EOF 与 EAGAIN** | 只有 `AVERROR_EOF` 切 `FREE`；`EAGAIN`/`AVERROR(EAGAIN)` 是"再读一次" | 片尾音轨比视频短（§6.5）时，把 EAGAIN 当 EOF 会提前 3~5 秒掉进 FREE |

##### 必须和 §2.7 合并做的一次 configure

音频解码器（`aac,ac3,eac3,dts,mp3,flac,opus`）+ `--enable-libswresample` 与上面的清单
**在同一次 `configure` 里**。理由很硬：交叉编译一遍 ffmpeg 的成本是"配环境 + 40 分钟构建"，
拆成两次就翻倍，而两份 `configure` 一旦分叉（有人只改了其中一份加了个 demuxer），
第二步的音视频就会在两个不同的解析语义上跑——这正是 §2.7「顺序约束」第 2 条要防的事。

##### 待实测（不填猜测值）

- 最小配置的 `.a` 总大小、`--static` + `strip` 后可执行文件增量（按 §2.7 要求，与 §3 的画质/内存一起在盒子上量）；
- `AVFormatContext` + `AVIOContext` 常驻内存（`avio` 的 IO 缓冲区大小可自定义，默认值与 `max_probe` 一起记）；
- 盒子侧是否存在可复用的 `libavcodec.so`（有的话可省掉静态链，但会锁死版本，与 §2.6 同一个坑）。

##### 验收（都能一行验）

```sh
grep -c 'ffmpeg' tvplay-node.sh          # 期望 0（进程没了，脚本里也不该留）
pgrep -c ffmpeg                          # 播放中期望 0（§2.2 判定标准的同一条）
ldd v4l2hevc-aarch64 | grep -c 'libav'   # 静态链时期望 0
grep -n 'av_rescale_q' demux.c           # 期望 ≥1；同时 grep -c '/ *90 *\* *1000' 期望 0
```

#### 三条硬规则（写代码时会被踩的三处）

1. **90kHz → us 必须先乘后除**：`us = pts * 100 / 9`（int64）。
   写成 `pts / 90 * 1000` 会先截断到整毫秒，每帧误差 ≤0.5 ms，10 分钟累计到秒级；
   写成 `pts / 9 * 100` 同病。除法只允许在最后一步做一次。
2. **`-ss` 在 `-i` 前是 input seek，PTS 带着原容器零点**（`start_time`）。
   不归一化，起播第一帧的 τ 就是原片第 37 分钟——`clock_reanchor()` 会被喂一个荒谬值。
   要么 `pts_us -= start_time_us`，要么显式 `-copyts` 并把这个偏移记进会话。
3. **`b.timestamp` 的 CAPTURE 回显信息量为零**：`V4L2_BUF_FLAG_TIMESTAMP_COPY`（`v4l2hevc.c:370`）
   的语义是"驱动把 OUTPUT 队列的时间戳原样抄到 CAPTURE"。它只能证明"这帧是我塞进去的那个"，
   不能当时间源。今天唯一读它的是 `:1610-1611` 的 verbose `printf`——**别把回显当测量**。
   真值只有两个来源：码流里的 PTS，或 `aout` 的 `played_ms`（§2.1）。

#### 验收

- 25fps 片源跑一次，`timestamp`（改成真 PTS 后）步长 = 40000 us；29.97fps 片源步长 = 33366/33367 交替。
  **步长随片源变**才算过；固定 40000 就是还在走 `g_au_seq/25`。
- 起播第一帧 τ ≈ 0（不是 `start_time`）。
- `grep -n "/ *25;" v4l2hevc.c` 无输出（与 §2.2.1 的 grep 门同一条）。
- 拿 `-f mpegts` 的真实封装开销数补上上面那个"待测"。

### 2.6 mpv 属性：可用性和语义都跟版本走，不能当常量

先摆事实：**本仓库没有任何一处记录盒子的 mpv 版本**（`grep -rn "mpv *0\.[0-9]\|mpv-version\|libmpv" .` 在 `hevcdec/` 下无命中，本文件也没有）。
盒子是 aarch64 的 Android/busybox 环境，它的 mpv 和开发机上的不是同一个二进制。
下面所有拿 mpv 属性当依据的论断——§2.4 的 `time-pos` 插值、§3.2 的 `pause`、§3.1 的 `aid`、`mpvctl` 的 `volume`/`mute`/`pause`——
**都只在一个版本上验过，不能当跨版本成立的定义**。

下表的"0.37"列是开发机 `mpv 0.37.0` 上 `--list-properties` / `--list-options` 的**实测输出，只作基线参考，不是盒子的答案**：

| 属性 / 选项 | 用在哪 | 版本敏感之处 | 0.37 实测 |
|---|---|---|---|
| `time-pos` | §2.4 插值、§4 台账 | 语义是"当前播放位置"，`--audio-delay` 参与在内；与 `playback-time`（文件内位置）在 delay≠0 时**不相等**。§2.4 里"已送进 ALSA 的位置"这个说法只对特定 ao 成立 | 存在 |
| `playback-time` | §2.4 备选锚点 | 与 `time-pos` 是两个量，混用会引入 delay 大小的恒定偏移 | 存在 |
| `pause` | §3.2「SIGSTOP 时 `pause` 恒 false」 | 这条结论只依赖"信号不改变属性"，与版本无关；但 `cycle pause` 是否连带冻 ao 随版本变过 | 存在 |
| `volume` / `volume-max` | `mpvctl vol ±N`（`add volume`） | `add` 会被 `volume-max` 夹取；选项在旧版叫 `--vol-max`，新版 `--volume-max`（分界版本待盒子确认） | `--volume-max` Float(100..1000) default 130 |
| `mute` / `ao-mute` | `mpvctl mute`（`cycle mute`） | `mute` 只动 mpv 内部标志，不动 ALSA 硬开关；`ao-mute` 是另一条路径，两者不联动 | 两个都在 |
| `aid` / `--aid` | §3.1 音轨 id、§3.3 入 C、§5 命令行 | **取值集合随版本变**：0.37 只有 `no｜auto｜<整数>`；较新版本才有 `auto-safe`。写出盒子不认的值 → mpv 直接报错退出，不降级 | `Choices: no auto (or an integer) (0..8190) default: auto` |
| `audio-device` | 音频输出选设备 | 值是平台相关的 `api/device` 串，跨版本/跨构建会改名 | 存在 |
| `paused-for-cache` | 欠载判定 | 只在起播/卡顿时为真，别拿它当"在放"的反面 | 存在 |
| `--start` | §5 起播定位 | 支持相对时间与百分比；与 `--hr-seek` 的交互在不同版本上有差异 | `Relative time or percent position` |
| `--hr-seek` | seek 精度 | 默认 `default`，其实际含义被调整过 | `no absolute yes always default (default: default)` |
| `--video-sync` | 若让 mpv 当主钟（§2.4 已弃） | 默认值改过；`display-resample*` 一族在版本间增删过成员 | default: `audio` |
| `--hwdec` | 硬解 | 可用值取决于**编译进去的后端**，`v4l2m2m` 不必然存在（本机 0.37 包里就没有这个值） | `String list (default: no)` |
| `--input-ipc-server` | `mpvctl` 的全部能力 | 一直存在，风险最低的一环 | `String [file]` |

**在盒子上当场确认**（busybox 也能跑，不需要额外装东西）：

```sh
mpv --version | head -1
mpv --list-properties | grep -x -e time-pos -e playback-time -e pause -e aid \
                                -e volume -e mute -e audio-device -e paused-for-cache
mpv --list-options    | grep -E '^ --(aid|volume-max|vol-max|hr-seek|video-sync|start|hwdec)\b'
# 播放中（socket 已建）:
mpvctl /tmp/tvplay.sock '{"command":["get_property","time-pos"]}'
mpvctl /tmp/tvplay.sock '{"command":["get_property","aid"]}'
mpvctl /tmp/tvplay.sock '{"command":["get_property","pause"]}'
```

由此得到四条硬约束：

1. **属性/选项名集中一处**：新建 `mpvprops.h`，不许在 `tvplay-node.sh` 里散着写 `--aid` / `--vol-max`。改名时只改一个头文件。
2. **启动自检，缺则降级**：逐个 `mpvctl get_property <name>` 探一遍，缺一个就在 `/tmp/tvplay.events` 记 `cap_missing=<name>` 并走降级分支——**不许静默继续**（§3.1 那种"写进去从没被读"的键就是这么来的）。
3. **文档不把版本相关的语义写成规范**：§2.4 关于 `time-pos` 的两条坑要标"待盒子版本确认"，否则下一版 mpv 一改，前提就假了，而论证还站在上面。
4. **`mpvctl` 只发稳定命令**：`get_property` / `set` / `add` / `cycle` 这类不受属性集合影响的命令优先；`cycle mute` 若在盒子上不生效，退回 `get_property mute` + `set mute` 两步。

### 2.7 第二步：把音频解码与输出纳入 Player Core

第一步只把**时间**这一个量从两个写者收敛成一个（锚点仍来自 mpv `audio-pts`，§2.4）。
第二步搬的是**剩下的那一半身体**：容器的音频轨、音频解码、重采样、ALSA 输出，
全部进 `hevcplay` 的地址空间。做完之后 mpv 不是"可选依赖"，而是**不存在**。

一句话：**`aout` 从"进程"降级成"线程 + ring"，解码从"ffmpeg 的另一个 fd"升进本进程，
`clock.c` 的锚点从"IPC 抽样"换成"`hw_ptr` 直读"——接口不变，所以第一步的代码不用改。**

#### 搬什么，不搬什么

| 环节 | 今天谁做 | 第二步 | 依据 |
|---|---|---|---|
| 容器解封装（含音频轨时间） | mpv | **搬**（`libavformat`，与 §2.5 方案 B 同一件事） | 音视频两条轨必须在**同一次** `av_seek_frame` 上对齐，跨进程做不到 |
| 音频解码（aac/ac3/eac3/dts/mp3/flac/opus） | mpv | **搬**（`libavcodec`） | 音频解码是纯 CPU、无硬件路径，唯一的搬移成本是依赖 |
| 重采样 / 下混 2.0 | ffmpeg `-ac 2 -ar 48000`（§1.13） | **搬**（`libswresample`） | 固定输出 48 kHz/2ch/s16le 的假设要留在进程内可见，不能靠命令行参数隐式成立 |
| ALSA 输出（period/buffer/xrun/暂停/音量） | mpv 的 `ao_alsa` | **已有**——`aout.c` 的 ioctl 层原样保留 | §1.13 已翻案过一次，不必再翻 |
| 位置锚点 | mpv `audio-pts` + 外推（第一步） | **换成** `played_frames` 直读 | §2.1 的三条硬理由；采样级、零 IPC |
| 视频解码 / 上屏 | `v4l2hevc` | 不动 | §1.4 "不动"清单 |

注意"搬"的判据不是"哪个更容易"，而是**哪一个量必须被同一双眼睛看见**。
音频轨时间与音频输出位置都是主钟的输入，它们必须在同一个进程里——这条把上表前三行钉死了。

#### `aout.c` 哪些能直接复用，哪些不能

现成的 563 行里有四块是对的，一步都不用改：

- **hw params 直接指定** period/buffer（`aout.c:105-150`，`iv_set` 精确卡 `PERIOD_SIZE`/`PERIODS`）：
  这是绕开「8 s 15 次 xrun」（`docs/playback.md:182`，`tvplay-node.sh:80`）的唯一手段，`plug`/`dmix` 拿不到。
- **xrun 恢复**：`EPIPE` → `PREPARE` 继续，不退出（`aout.c:207-215`），`ESTRPIPE/EBADFD` 同路（`:227-230`）。
  `g_underruns_recovered` 就是 §2.1.1 里 XRUN flag 的来源。
- **暂停两级降级**：`PAUSE` ioctl 失败才写静音占 dma（`g_pause_mode` 1→2，`aout.c:389-406`）。
- **位置定义**：`played_ms = (g_written - pcm_delay())/rate`（`:155-171`），先取 delay 再取 `now()`。

只有一处**必须**拆掉：**`read(STDIN_FILENO, ...)` 是主路径**（`aout.c:271`）。
单向管道没有"丢弃已缓冲数据"这个操作，于是 seek 只能杀掉上游 ffmpeg 重开——这正是
§2.2 说的"两个播放器"最后一块砖。换成 ring 之后，flush 是一个指针赋值。

#### 数据面：一个 ring，两个水位，不许混用

```
adec ──► ring (音频样本队列) ──► sink 线程 ──► ALSA buffer ──► hw_ptr
        └ 决定"解码器能领先多少"   └ 决定"已写未播"（g_buf = 170.7 ms）
```

- **ALSA buffer 不变**：`g_buf` = 8192 帧 = 170.7 ms，`g_period` = 2048 帧 = 42.7 ms（`aout.c:56`）。
  它只负责一件事：让 `hw_ptr` 的更新粒度（43 ms）和抗抖动余量（170 ms）成立。
- **ring 另算**：容量按时间给，**约 0.5 s**：48 kHz × 2ch × 2B × 0.5 s = 96 KB，取 128 KB 对齐。
  它负责"解码器领先量"，与音频稳定性**无关**——把这两个水位混成一个数是这类播放器最常见的错。
- **ring 只有三个指针**：`w`（adec 写）、`r`（sink 读）、`f`（flush 点，seek 时 `r = w = f`）。
  `w - r` 就是 §2.1 里"上游算缓冲水位"要的那个数（`aclk_shm.bytes` 的替代）。
- **线程模型**：`adec` 与 sink **必须分开**。合成一个线程的话，`WRITEI_FRAMES` 阻塞期间解码停摆，
  ring 深度 = ALSA buffer 深度，seek 响应与抗抖动又被绑死在一起。
  今天 `v4l2hevc.c` 里 **0 处 `pthread_create`**（单线程 loop），这套线程是第二步的前置，见"顺序约束"。

#### 时间：锚点从 IPC 换成 `hw_ptr` 直读

第一步的 `clock.c` 里，`clock_anchor_audio(mono_ns, played_us, seq)` 的实参来自 mpv 回包插值。
第二步换成采样级，写法就是 §2.1.1 那一套——但**有一个结构性简化必须说明**：

§2.1.1 之所以要共享内存 + seqlock，是因为 `aout` 是**独立进程**（"读端零系统调用"是对跨进程说的）。
音频进线程后，`aclk_shm` 变成一个普通全局结构体，seqlock 退化成"读一次 `frames`/`mono_ns` 对"。

**但五条读取规则一条都不许删**（§2.1.1：无活跃源→FREE、新锚点收下、seq 不变不重设、
回退作废、XRUN 只记日志）。它们描述的是**语义陷阱**，不是跨进程的偶然复杂度：
迟到锚点、`frames` 回退、暂停后 `hw_ptr` 不动，换到进程内照样发生。
保留 `clock_shm.h` 的布局与 `ver` 字段，让 `aout` 仍能以独立进程方式编译（`-DAOUT_STANDALONE`）——
**"自家音频坏了还能退回 mpv"这条逃生路径，必须靠同一个 header 保留，而不是靠记忆保留。**

`played_frames` 的发布时机仍是四个（§2.1.1 表）：每个 period 写完、暂停生效、恢复后首个 period、
xrun 置位/清除成对。第二个（暂停锚点）最容易漏：漏了读端就会把"`hw_ptr` 不动"误判成外推失控。

#### 控制面：pause / seek / 音量各收成一处

| 操作 | 今天 | 第二步之后 |
|---|---|---|
| 暂停 | `pkill -STOP` 四个 pattern（`tvplay-node.sh:109-112`）+ `mpvctrl toggle`（`:178`） | `state.c` 内三行：`ring` 保持不动 → `AOUT_PAUSE` ioctl（失败走 `g_pause_mode=2`）→ `clock_freeze(1)`。**同一次请求，同一次失败** |
| seek | 视频重开整链 + mpv 自己 `seek`（`:193`），两边各算目标（§5.5） | 一个 `target_us`：`av_seek_frame`（音频轨与视频轨同一次）→ 丢 ring 至关键帧 → `epoch++` → 等 `|τ - target| < 200 ms` |
| 音量 | `mpvctl add volume`（`volume-max` 会夹到 130，`mpvctl vol +5` 读旧值写新值会丢连按） | `aout` 内部整数增益（`aout.c:176-190` 的 `scale_s16/32`，调用点 `:308`），一条命令一次写，无往返 |
| 音轨选择 | mpv `aid`（取值集合随版本变，§2.6 表） | `av_find_best_stream` + 显式 index；换轨 = `epoch++` + hw params 重协商 |

音量与音轨这两行走的不是"顺手挪"，而是**删掉一个写者**：§2.6 那张属性表里
`volume`/`volume-max`/`mute`/`ao-mute`/`aid` 五行在这一步整行作废，`mpvprops.h` 跟着缩。

#### 顺序约束（这三条决定能不能开工）

1. **先拆线程**。`hevcplay` 今天是一个 `while` 循环里 demux→vdec→present 串着跑
   （`v4l2hevc.c` 无任何 `pthread_create`）。第二步要四条：`demux` / `adec` / `vdec` / `present`。
   先有 `demux` 线程，才有"另一条线程从同一个 `AVFormatContext` 读另一条轨"这件事。
2. **再换容器**。第二步的音频轨来自 `libavformat`，与 §2.5 方案 B 是**同一个改动**。
   若先只做音频进来、视频仍走 `ffmpeg -f hevc -`，就是两个 demuxer 读同一个 URL 两遍，
   §2.2 的"两进程读同一文件"原样复现，只是搬到了进程内——**这种中间态不许停留超过一个提交**。
3. **依赖先落地**。`crosslib/` 里今天只有 `libdrm` / `libEGL` / `libGLESv2` / `libgbm`，
   **没有任何 `libav*`**；盒子上跑的是 ffmpeg 可执行文件（`tvplay-node.sh:92-94`）。
   要么静态链 `libavformat+libavcodec+libswresample`（`-static`，与 `aout` 现状一致，二进制约 +8~10 MB，**待实测**），
   要么盒子有可分发的 `libavcodec.so`（**待确认**：`ls /usr/lib/*/libavcodec*`）。
   这条不确认，第二步的估算就是空的。

#### 删除清单（这一步删什么）

- `mpv --no-video` 整条命令，及 `tvplay-node.sh:83-88` 的 `--aid/--volume/--cache/--audio-device`
- `tvplay-node.sh:80` 那句「ffmpeg 的 `-f alsa` 在这块板子上缓冲太浅」——**理由消失，注释一起删**
- `mpvctl` 的 `volume`/`mute`/`pause` 子命令（保留 `get_property` 当诊断）
- `aout` 的 `read(STDIN_FILENO, ...)` 主路径（`aout.c:271`）；stdin 模式只留作独立进程模式
- ffmpeg 命令行的 `-map 0:a:0 -ac 2 -ar 48000 -f s16le pipe:4` 四个参数（改由 `swr` 配置表达，可读可测）
- §2.6 属性表 5 行（`volume`/`volume-max`/`mute`/`ao-mute`/`aid`）

**不删**：`aout.c` 的 ioctl 层、`AOUT_BUFFER`/`AOUT_PERIOD` 两个旋钮、`/tmp/aout.sock` 控制口
（独立进程模式的逃生路径还要用）。逃生模式存在不等于架构里有两个播放器——
判据是"默认路径上有几个进程"，不是"仓库里能编译出几个二进制"。

#### 验收（盒子上能跑的数）

| 检查 | 方法 | 通过线 |
|---|---|---|
| mpv 真的没了 | `pgrep -c mpv` | 0，且播放/暂停/seek/音量/进度全正常（§2.2 判定标准） |
| 不欠载 | 30 min 连续播，`aoutctl status` 的 `xrun` | 0；不为 0 依次试 `AOUT_PERIOD=4096 AOUT_BUFFER=16384`（85/341 ms），并把结果写回本文 |
| 主钟精度 | 每 200 ms 记 `τ - played_ms`（进程内，无 IPC） | 误差 < 5 ms，无 43 ms 阶梯（§2.1 表第一条） |
| 暂停 | `pause` 30 s 后 `resume` | τ 连续差 < 2 ms，`epoch` 不变，`xrun` 不涨（`aout-test.sh` 第 3 项即此测试的进程版） |
| seek 精度 | 从 30 s 处 seek 到 90 s，量音画对齐 | 首帧出声与首帧上屏差 < 40 ms；1 s 以内可重复（§5.5 目标） |
| 采样率协商 | 44.1 kHz 片源接 48 kHz 硬件 | `swr` 定长转换，音高不变，`epoch++` 一次，无爆音 |
| 换轨/无音轨 | `aid` 切换、`AUDIO=0` 裸流 | 切换后 τ 由 `AUDIO`/`FREE` 正确切换（§2.1 不变式 5），不崩 |
| CPU | `top -H -p <pid>` 看 `adec`/`sink` 两线程 | **待实测**（本机 x86 数不能当盒子数用，§2.6 同理） |

第一条是关键：它是本章**唯一**一条用户可直接感知的验收，也是唯一一条今天必然失败的。

#### 三条真实风险（不是"注意一下"）

1. **44.1 kHz → 48 kHz 的重采样延迟会进锚点**。`swr` 有内部缓冲（默认几十 ms，**待量**），
   而锚点必须描述"`hw_ptr` 对应的**源**时间"。做法：把 `swr` 输出帧数映射回输入帧数，
   锚点用**输出侧**帧（硬件时钟），换算只在 `clock.c` 里做一次；不要让 `swr` 缓冲深度变成
   第二个 `AUDIO_LAT_US` 式的魔数（§2.4 弃因 ② 就是这么死的）。
2. **设备消失 / HDMI 热插拔**：`aout.c` 今天对 `ENODEV` 是"打现场然后 `return -1`"（`:216-225`），
   没有重开设备的路径。以前这是 mpv 的活。第二步必须补：`close + open + hw_params` 重来一次，
   `epoch++`，失败再降 `SOURCE=FREE`。**这条不做，拔一次 HDMI 就得重启播放器。**
3. **片尾音轨比视频短**（§6.5 已列）：`τ` 必须显式切 `FREE`，否则最后一帧等一个永不到来的锚点。
   第二步把音频搬进来之后，这件事从"猜 mpv 是否 EOF"变成"`av_read_frame` 返回 `AVERROR_EOF`"，
   判据终于有了，但**代码得写**。

#### 与 §6.4 那条前提的关系

§6.4 写的是：「mpv `--cache=20` 提供了"音频不欠载"这个前提；换成自家 `aout` 时，
这条前提要由更大的 ALSA period + 预充缓冲来保证。」第二步就是兑现这句话的时刻，
兑现方式有三个具体动作，缺一不可：

- `AOUT_PERIOD` 从 2048 帧起，欠载就往上加（不是加 ring）
- 起播 **prefill**：ring 填到 ≥ 2×period 再 `START`，等价于 mpv 的 cache 预充，但量可读
- `xrun` 计数进 `/tmp/tvplay.events`（一次一行），让"主钟被打穿"变成可回溯事件而不是感觉

---

## 3. 播放状态

### 3.1 现状：状态在壳里，且壳自己不信它

唯一的状态是 `/tmp/tvplay.state`。实际写入 **11 个键**（`tvplay-node.sh:56-62`）：
`START OFF PLAYER KEYB64 TRACKB64 AUDIO FPS GEO RENDER PAUSE_AT PAUSED_FOR`。
注意 URL 不留原文只留 `KEYB64`，音轨 id 存成 `TRACKB64` 而不是 `TRACK`。
读的时候 `.` 一下就信了（`:17`、`:104`、`:240`），没有校验、没有锁、没有版本号。

四个症状，全部在源码注释或行为里自承：

| 症状 | 位置 | 原文 / 机制 |
|---|---|---|
| 与真实进程不符 | `:169-171` | "实测 state 会与真实进程不符（HEVC 链在放，state 却写着 mpv）" |
| 写坏 | `:129-131` | "GEO 解出二进制 → state 文件被写坏" |
| 参数解空 | `:130` | "AUDIO 解空 → 重开后没有音频 mpv" |
| 键写进去从不被读 | `:61` | `PAUSED_FOR=0` 是全文唯一一处 `PAUSED_FOR`（`grep -n PAUSED_FOR` 仅 1 行） |

这些不是编码 bug，是**把可变状态放在一个非原子的、无 schema 的、跨进程的文件里**的必然结果。

比"写坏"更硬的两条：

1. **`sed -i` + `echo >>` 是两步**（`:113`、`:122-123`、`:201-202`），中间那个瞬间 state 里没有 `START=`。
   `pos()`（`:16-23`）里只有 `PAUSE_AT` 用了 `${PAUSE_AT:-0}`，`START`/`OFF` 是裸引用，
   而脚本头是 `set -u`（`:5`）——正好在窗口里按遥控器，`pos()` 报 unbound variable、整条命令 255 退出，
   按键被吞。这不是"读到旧值"，是**按键消失**。
2. **seek 静默丢音轨**：`restart_at`（`:127-136`）传音轨用的是 `${TRACK:-1}`，但 state 里只有 `TRACKB64`，
   key 分支只解了 `KEYB64`（`:105`），从没解过 `TRACKB64`。`set -u` 下 `${TRACK:-1}` 恒回落成 1，
   于是用户选的音轨在每次 seek 后被重置回 id 1，且日志里看不出来。

`state` 子命令（`:238-247`）输出 5 个空格分隔字段，其中前 3 个都不代表真相：
`el` 是 `now()` 减出来的（与屏幕上第几帧无因果）；
第 3 个字段是 `pgrep -f 'v4l2hevc-aarch64|mpv'` 的计数，而 HEVC 链实际是 `v4l2hevc` + `ffmpeg` 两个进程，
`ffmpeg` 不在这个 pattern 里，所以它也不是"在场进程数"。

状态不可信的代价已经外化成两个人工胶带脚本：`resume.sh`（state 说在暂停、进程却在跑 → 补发一条
`key toggle` 把 `START` 修回来）和 `chk.sh`（盲发 `pkill -CONT` 把被误停的进程捞回来）。
**需要专门写脚本来纠正状态，就是状态本身不可信的判据。**

### 3.2 暂停的实现暴露了架构

`pause_video`（`:108-115`）四条 SIGSTOP：

```
pkill -STOP -f 'v4l2hevc-aarch64'
pkill -STOP -f 'ffmpeg .*-f hevc'
pkill -STOP -f 'mpv .*--no-video'
pkill -STOP -x mpv
```

四个 pattern 里有两个都在打 mpv。`resume_video`（`:116-125`）对称 SIGCONT，然后把暂停时长
补贴进 `START`（`:122`）——**用时间戳算术来修补一个被冻住的进程的语义**。
暂停中 seek 要先重开、再重新 `pause_video` 压回去（`:205-212`），这个补丁本身就说明
"暂停"不是一个状态，是一次性的信号投递。

再加一层：SIGSTOP 打的是 pattern，不是 pid 集合。`pkill -STOP -f 'v4l2hevc-aarch64'` 会命中命令行里
带这个串的**任何**进程，包括正在执行这条命令的 ssh shell——`chk.sh:2-3` 的注释就是为了这个
才把匹配串放进变量。一个播放状态，需要靠"别让模式串出现在命令行里"来避免自杀。

目标：`SIGSTOP` 消失。暂停是状态机里的一个状态，代价只是"T3 不取帧、`pos` 冻结"。

### 3.3 目标：唯一权威在 C，壳只读

```
struct player {
	enum { IDLE, PLAYING, PAUSED, SEEKING, RESYNC, RECOVERING } st;
	int64_t  pos_us;        /* 主钟位置，唯一真相 */
	int64_t  dur_us;        /* 时长，demux 时拿到，不是 ffprobe 再跑一遍 */
	uint64_t upos_us;       /* 上次上报墙钟，让读者能自己插值 */
	int      idx, n;        /* 播放列表游标 */
	int      aid;           /* 选中音轨：和 pos 一样属于状态，不属于命令行 */
	char     src[512];
};
```

对外只有三条出口：

- **读**：`state` 子命令输出**一行键值**（`pos=… st=… idx=… n=… aid=… paused_ms=…`），
  不是现在 `printf '%s %s %s...'`（`:247`）那种空格分隔——一旦某个字段含空格，整行错位。
- **写**：`key <动作>`，与现在同一入口，`rcinputd` 不用改。
- **事件**：`/tmp/tvplay.events`（append-only，每行一个状态跃迁），给前端做 OSD 和日志。

壳里 `pos()`、`el=`、`PAUSE_AT` 全部删除。**位置只能被算出来，不能被拼凑出来。**
`aid` 必须跟着进 C：把音轨留在命令行/state 里的直接后果就是 §3.1 第 2 条，换个实现照样会重演。
`aid` 本身是 mpv 属性，**取值集合与可写性随版本变**（0.37 只认 `no|auto|<n>`），见 §2.6。

### 3.4 时长别再跑 ffprobe

`probe` 现在 `exec ffprobe`（`:26-31`）拿 duration。demux 时 `avformat` 早就有
`fmt->duration`，白跑一次进程只为拿一个数，且这数与 `-ss` 之后的剩余时长无关。
播放列表进度需要总时长时，从 C 读。

---


## 4. 播放列表

### 4.1 现在完全没有

`rcinputd.c` 的键位表（`:112-120`）只有 10 个动作：`mute/menu/volup/voldn/toggle/fwdmore/backmore/fwd/back`，
`tvplay-node.sh:184` 把 `menu|home` 直接丢弃（"无 UI，忽略"）。
`TRACK/AUDIO` 是 mpv 的音轨 id，不是列表游标。一次只能放一个 URL。

后果：连续剧只能一次次从 SSH 起播，每次都是完整冷启动 + 黑屏。

### 4.2 设计：列表在控制面，切换走 seek 不走重启

```
/tmp/tvplay.list   一行一项：<b64url>|<title>
/tmp/tvplay.idx    当前下标
```

- `next` / `prev` → 改 `idx` → **走 §5 的进程内 seek 路径**（新源、`START=0`）。
  这一步依赖 §2.1 的主钟重锚，不依赖任何进程重启。
- `fwdmore` 在最后一项时变 `next`（遥控器上"长按 → → 下一集"最自然，
  比占用新键好；且现有键位不用改）。
- **预取**：T1 demux 线程在 `pos > dur - 30s` 时预先 `avformat_open_input` 下一个源，
  只做 probe 不做解码。切集时省掉 0.3~1s 的探测延迟。
- 列表为空时 `next/prev` 是 no-op（不报错，不退出）。

### 4.3 一项做完就删

列表项从哪来（目录扫描 / 前端推送 / NFS 清单）**不在 Player Core 职责内**：
`play` 子命令已经能收任意 URL，前端把列表写进 `/tmp/tvplay.list` 即可。
C 不认识 m3u，也不认识 `E01.mkv` 命名规则。

---

## 5. seek

### 5.1 现状：seek = 杀掉整条链再起一条

`restart_at`（`:131-138`）重新 `sh $0 play ...`，整条链重开。代价链：

```
pkill 全部 4 个进程
  → DRM master 释放 → 屏幕掉回内核控制台文本（用户能看见！）
  → ffmpeg 重新 -ss + 容器探测（0.3~1s）
  → vdec 会话重建（meson-vdec 不接受旧会话接新流，见 design_player.md §1.4）
  → mpv 重新打开 + ALSA 重配
  → 画面回来：0.8~3s
```

围绕这个代价堆了四层补丁：

| 补丁 | 位置 | 本质 |
|---|---|---|
| `seek_guard` 3s 合并 | `:149-157` | 用时间戳去重，掩盖"一次 seek 太贵" |
| `rcinputd` 串行 `wait(NULL)` | `:144-148` 注释 | 连发事件排队，松开后逐个补跑 |
| 暂停中 seek 要重压 | `:204-207` | 状态不是状态 |
| mpv 单独 seek + 重写 `START/OFF` | `:192-196` | 音视频两条 seek 命令必须手工保持一致 |

**四个补丁全部指向同一个事实：seek 贵，所以要在外面撒胶带。**

### 5.2 已经写好了但从未被调用的东西

`v4l2hevc.c` 里 SIGUSR1 热重建**完整存在**：

- `:1525` `sigaction(SIGUSR1, ...)` 注册
- `:1649` "收到 SIGUSR1：换新码流。meson-vdec 不接受在旧会话上接新流"
- `:108` 注释指向 `g_reinit` 重建路径
- `:1838` "SIGUSR1 会打断 poll。以前这里直接 break 退主循环..." —— 已经修过

也就是说**进程内换流的机制已经通了，只是没人发这个信号**。
`ffmpeg | hevcdec` 那条管道里，壳没法只换上游而不换下游，于是这个能力闲置。

### 5.3 目标：三层 seek，代价递增

| 层 | 触发 | 动作 | 代价 |
|---|---|---|---|
| **L1 时钟 seek** | `\|Δ\| ≤ 2s` | 只改 τ，帧照常放（丢/等几帧） | 0 |
| **L2 会话 flush** | 2s `< \|Δ\| `，同文件 | demux seek 到关键帧 + `g_need_irap=1` + 会话内 flush | ~150ms |
| **L3 会话重建** | 换源 / 解码器无响应 | `g_reinit`（现在的 `SIGUSR1` 路径） | ~600ms |

L1 必须存在——现在 2 秒内的小漂移也会走 L3，这是"落后两秒付 0.8 秒黑屏"的根源。
`g_need_irap` 的 NAL 级等待（`:1822-1826`，`r==2` 时丢 P/B 直到关键帧）已经实现了
L2 需要的"等 IRAP"语义，不用新写。

### 5.4 L2 的关键：DRM 不能释放

`restart_at` 最刺眼的不是 0.8s，是 `pkill` 之后 **DRM master 掉了、屏幕变命令行**。
L2 全程 `card0` fd 和 plane 都活着，只是暂停 flip（或继续 flip 最后一帧），
屏幕保持当前画面。用户感知从"播放器崩了"变成"卡了一下"。

### 5.5 音频的 seek 必须被同一个目标驱动

现状：视频重启 + mpv 单独 `seek $D`（`:193`），两边各自算目标位置，
只用 `START/OFF` 两个变量手工对齐。`design_player.md` §5.4 已记"整链重开 + 合并连发"。

目标：控制面发**一个** `target_us`，T1 demux 与 mpv 各执行一次，
然后 `SEEKING` 状态等两边都到（`|τ - target| < 200ms`）才回 `PLAYING`。
（第二步 §2.7 之后音频侧的"执行者"不再是 mpv，而是同一次 `av_seek_frame` 上的音频轨：
一个目标、一次调用、一个判据。这里保留 mpv 写法是为了让第一步可单独验收。）
超时（>2s）→ `RECOVERING`。**一个意图，两个执行者，一个完成判据。**

### 5.6 防抖还要留，但理由变了

`seek_guard` 从"掩盖昂贵操作"变成"合并按键连发"：
一次 L2 seek 要解到关键帧（最长一个 GOP），连按 5 次会积压 5 个目标。
保留 300ms（不是 3s）的窗口，且**取最后一次的目标**（现在是直接丢弃后续，方向相反）。
`rcinputd` 的串行 `wait(NULL)` 应改成投递即返回，让 C 侧做合并——队列语义归状态机。

---

## 6. 音视频同步

### 6.1 现在：靠"两个进程被同一句话启动"来同步

```
ffmpeg -re -ss "$START" -i "$URL" -c:v copy -f hevc -   →  v4l2hevc
mpv --no-video --start="$START" --aid="$TRACK" "$URL"   →  音频
```

这条命令行同时压了两个版本敏感项：`--start` 的定位语义、`--aid` 的取值集合。
两者都按 §2.6 在盒子上 `--list-options` 当场确认，不要照抄开发机的值。

唯一的同步机制是**两边 `START` 相同**。问题：

1. **起播延迟不同**：mpv 要开容器 + ALSA 配置（~1s），hevcdec 要建 vdec 会话（~0.6s），
   两边各自从 `START` 开始，但"从 `START` 开始的第 0 帧"真正出现在屏幕/耳朵上的时刻差几百 ms。
   **每次 seek 后唇音都会偏一次**，且偏向随机器负载随机。
2. **漂移无界**：`-re` 的节拍与 ALSA 采样时钟是两个独立的硬件晶振（板载 24MHz 分母不同）。
   实测两小时片子末端可差数百 ms 到秒级。没有任何机制发现它。
3. **暂停是"幸运的正确"**：`SIGSTOP` 同时冻住两边，所以暂停期间反而对齐。
   但 `resume` 补贴 `START` 的算术一旦有一边没被 STOP 到（4 个 pkill pattern 里
   漏一个就静默失效），就永久错位。

### 6.2 目标：音频单主钟 + 单向从动

铁律：**只调视频，绝不调音频。** 音频拉伸/跳采样会被听出来，视频丢一帧不会。

```
                  |
          +-------+-------+
          |               |
          v               v
      Video PTS       Audio PTS
          |
          v
   Frame Scheduler
          |
          v
     DRM VBlank
          |
          v
       Display
```

左列是**从动**的一条：`Video PTS` 只用来算 `d`，真正决定"第几帧、哪个 vblank"
的是 `Frame Scheduler` 按主钟反算出来的 `target_vbl`，最后落在 `DRM VBlank` 上屏。
右列的 `Audio PTS` 是**主钟源头**（`aout` → `clock.c` → `τ`，见 §2.1.1），
本图只到 PTS 为止；它不参与任何回调驱动，只被读取。

```
d = pts_us - τ                       /* 正=视频超前，负=落后 */

|d| ≤ 40ms            → 按 vblank 上屏，不动
40ms < |d| ≤ 400ms    → 视频侧吸收：超前就多等 vblank，落后就丢帧
400ms < |d| ≤ 2s      → RESYNC：以 τ 为锚重算 vblank 基准，一次性跳
|d| > 2s              → SEEKING/RECOVERING（真的错了）
```

40ms ≈ 1 帧 @24fps 的一半，是裸眼可辨的门限；400ms 是"跳一下但能接受"的上限。
门限写死不用环境变量——现在的 `FPS/LEAD/STALLSEC/TM_*` 已经太多旋钮，
每个都是"有人调过一次就再没人知道正确值"。

这张表就是 §0 核心原则 3/4 的量化：`d < 0` 走丢帧（原则 3），`d > 0` 走等待（原则 4），
而"等多久、丢哪一帧"全由 §0 的判据（原则 2）和 vblank（原则 5）决定，两条分支都不许自行造时间。
注意 §0.1 的示例代码用了 `-40ms / +50ms` 的滞回，与本表对称的 `|d| ≤ 40ms` 不同口径，
落地时二者必须统一成同一个数。

`play_frame` 现有的 vblank 锚点数学（`vbl_base + n*refresh/fps`，`:1400-1401`）
**可以留**，只是把 `n` 从"自增计数"改成"由 τ 反算的目标 vblank 序号"：

```
target_vbl = vbl_base + round((τ - τ0) * refresh)   /* 每帧按主钟重算，不再累加 */
```

这样它天然是自校正的：一次丢帧不会让后面所有帧永久偏移（现在 `pc.n++` 累加，
丢一帧就永久早一帧）。`:1413-1416` 那段"落后超过两帧就重锚"的补丁也就自动消失。

### 6.2.1 视频调度器：读音频钟，逐步收敛

先修正一处引文：本节与 §0.3 引的 `play_frame`、`:1400-1401`、`:1413-1416` 在当前树上
**已经不存在**——`v4l2hevc.c` 现在 1774 行，`play_frame` 这个名字全文无命中，`:1400` 一带
是 REINIT 的会话清零。留下来的 `vbl_base + n*refresh/fps` 语义在 `vout.c:606-617` 的
`pts_slot()` 里，而那一段**恰恰已经不是自增累加**，是每帧按绝对时间重算。所以 §6.2 末尾
"现在 `pc.n++` 累加"这段描述是按旧树写的，落地时以 `pts_slot()` 为准。

**调度器的职责只有一句**：每帧读一次 `clock_now()`，把这一帧放到离它最近的 vblank 槽上；
除了下面那个受限的 `slew` 累加器，它不保存任何时间状态。

#### 为什么"同步"只能在整帧粒度上表达

屏幕只认 vblank 扫描，τ 再连续，落地点也只能是槽。于是能用的手段只有三种：

| 手段 | 粒度 | 能吸收什么 | 代价 |
|---|---|---|---|
| 选槽（`target_vbl` 加整数） | 1 帧 = 16.7 ms @60Hz | 任意大的误差 | 一次跳整数帧，连跳就是"跳一下" |
| 重复 / 丢弃一帧 | 1 帧 | 同上，且不必改时间轴 | 单帧可见（24fps 下丢一帧约 41 ms 的空档） |
| 映射速率 `slew`（ppm 级） | 亚帧 | **只有速率误差**，吸收不了阶跃 | 速率偏离可感知，必须限幅 |

所以"逐渐建立同步"不是某种连续插值，而是：**每帧只动最少的槽，靠帧数堆出收敛**；
阶跃误差用选槽/丢帧，长期漂移（两块晶振的 ppm 差）才交给 `slew`。反过来做——
拿 `slew` 去追 400 ms 的阶跃——就是让画面以 3% 的速率跑十几秒，唇音全程在飘。

#### 控制器

```
d   = pts - τ                      /* §6.2 已定义，未滤波，逐帧算 */
F   = 1e6 / refresh                /* 一槽的长度 us，60Hz → 16667 */

/* 死区：量化误差以内不动，否则 d 在零附近回摆就变成每帧都在修 */
if (|d| <= F/2)        n_slot = 0
else if (|d| <= K*F)   n_slot = (d > 0 ? +1 : -1)        /* 每帧最多一槽 */
else                   n_slot = (d > 0 ? +K : -K)        /* K = 2：斜率上限，不许更大 */
```

但 `n_slot` 只是**解释**，不是实现：真正要算的是"这一帧该等第几个槽"，
而槽号来自 `vbl_seq()` 的绝对序号，不是自己累加。准确写法是：

```
v_now      = vbl_seq()                                  /* vout.c:113-127 */
slot_want  = v_now + round((τ + slew_for_sched - pts_ref) / F)   /* 目标时刻 → 槽 */
slot_use   = clamp(slot_want, v_now + 1, v_now + K)     /* 下限 1：不许排到已经过去 */
```

`clamp` 的上界 `K` 就是**收敛斜率**：`K=2` 含义是"每秒最多追 2 秒"，视觉上是快放 2 倍，
40 ms 的误差 1~2 帧就吃掉，400 ms 要 20 帧（24fps 下 0.8 s）。下界 1 是硬约束：
排到 `≤ v_now` 的槽等于当场丢弃，DRM 也不会接受过去的 ABSOLUTE 序号。

`slew` 是**状态**，只能这样更新（积分、限幅、不回推）：

```
slew += clamp(d, -SLEW_STEP_MAX, +SLEW_STEP_MAX)   /* 仅在 |d| ≤ F/2 时积分 */
slew  = clamp(slew, -SLEW_MAX_US, +SLEW_MAX_US)    /* SLEW_MAX_US ≈ F/2 */
```

即：死区内把残差慢慢攒进 `slew`，让它在下一帧的槽计算里被提前吃掉；超出死区就清零
（一旦有阶跃，`slew` 里的旧残差已经没有意义，留着会把收敛过程变成二阶振荡）。
`SLEW_STEP_MAX` 决定长期漂移的跟随能力：60 Hz 下每帧 100 µs 相当于 6000 ppm，
远超两块 24 MHz 晶振的典型偏差（几十到几百 ppm），所以这个上界不构成瓶颈，
真正要限的是 `SLEW_MAX_US`——超过半帧的偏置会让死区失去意义。

#### 三条不变式（都可以在代码里查）

1. **纯读者**：调度器不许写 τ、不许自己 `clock_gettime`、不许按帧计数推时间（§2.1 单一读取者纪律）。
   `slew` 是唯一例外，且它是**调度器的**状态，不是时钟的——`clock_epoch()` 一变（`:361`），`slew` 立即清零。
2. **槽号单调**：`slot_use` 严格大于上一帧的 `slot_use`；相等就丢这一帧（两帧挤一个槽，
   `confirm_prev` 会把前帧记成 `miss`，`vout.c:598`）。这条不许靠 `clamp` 兜底——兜底会静默变成丢帧风暴。
3. **反馈不回灌**：`confirm_prev` 的 `misses` / `stales` / `late` 只进统计，**不参与 `d` 的计算**。
   把"上一帧没上屏"当"我落后了"再加大修正，就是正反馈；`d` 的唯一输入是 `pts` 与 `τ`。
   这条是本设计里最容易写错的地方，因为它是"看起来更聪明"的那种错。

#### 与 §6.2 门限表的冲突，必须收窄

§6.2 表里 `400ms < |d| ≤ 2s → RESYNC：一次性跳`，与本节的斜率上限直接冲突：
一次性跳正是"3% 速率跑十几秒"的反面，但跳 400 ms 也是肉眼可见的错位。
收窄成：

```
|d| ≤ F/2                    不动
F/2 < |d| ≤ 2s               渐进：每帧最多 K 槽，靠帧数收敛（本节）
|d| > 2s                      RESYNC（一次性重锚 vbl_base），只此一处
```

并把"是否真的错了"作为额外条件，而不是幅度：**连续 8 帧 `|d|` 不下降**才升格到 RESYNC，
否则哪怕 `|d|` 一时很大（seek 刚回来、音频刚起播）也按渐进走。这样 §6.2 表里那一条
自有其位，不再和渐进路径抢同一段误差区间。

#### 收敛有多快，怎么验

上界：`T ≈ ceil(|d0| / (K*F)) * F`。K=2、60 Hz 时每帧最多消 33 ms，
40 ms → 2 帧；400 ms → 13 帧（约 0.22 s）。这个量级和"一次跳 400 ms"在观感上不是一回事：
前者是画面快了 2 倍不到半秒，后者是整段内容错位。

验收口径（全部落在现有字段上，不新增计数器）：

- 每帧打一行 `d_before / slot_use - v_now / correction`。`|d_before|` 的包络要单调下降；
  **反弹即错**——反弹只可能来自 `slew` 没清零或反馈回灌。
- `vout_stats.late` / `t_late_max`（`vout.h:69-70`）应该是"起播头几帧非零、之后归零"。
  持续非零说明 `slew` 限幅太大或 τ 本身有恒定偏移（去查 §0.3 的 `L_a`，别在这里调参）。
- `stales`（`vout.h:68`）持续非零说明 `K` 太大：先把槽排到了过去，再被自己丢——`K` 降回 1 再看。
- **锁不住的那种"锁住"要认出来**：`SOURCE=FREE`（无音轨 / `aout` EOF，§2.1 不变式 5）时
  τ 由 PTS 自己给，`d` 恒等于零。此时"同步良好"是恒等式，不是成果，
  日志里要显式打 `sync=none(free)`，否则片尾那几十秒会被当成"收敛成功"。

### 6.3 抖动抑制

`τ` 带 200ms IPC 量化 + ALSA 缓冲，`pts` 是精确的 90kHz。
直接用 `d` 控制会抖。做法：

- `τ` 外推已平滑（§2.1），残差只剩单调时钟读数噪声（µs 级）
- `d` 过一阶低通（α≈0.1）**仅用于 L2 决策**（是否该丢/等）；
  L1 上屏时机永远用未滤波的即时值，否则会引入相位滞后
- 累计偏差单独计：`trend += (d - trend) * 0.02`，`|trend| > 300ms` 说明是系统性问题
  （片源 PTS 有洞 / 音频时钟慢了），记日志而不是继续硬追
- 低通**不参与槽选择**。§6.2.1 的 `slot_use` 只用即时 `d`：滤波值滞后于阶跃，
  拿它算槽位就是给自己制造一个一阶延迟环，表现为过冲再回摆。低通的唯一用途是
  统计口径（趋势 `trend` 与"是否真的错了"的判定），且这两项与 §6.2.1 的死区
  + 连续 8 帧不下降条件是同一个东西的两种写法，落地时只保留一套，别两边各调一次。

### 6.4 实测数据（盒子上跑，可复现）

`docs/playback.md` 里已记：`ffmpeg -f alsa` 在 hw:0,0 上 8 秒 15 次 xrun，
所以音频才外包给 mpv（`tvplay-node.sh:77` 有注释）。这件事没变。
mpv `--cache=20` 意味着音频侧有 20s 余量，**几乎不可能欠载**——
所以“音频是主钟”（§2.1）在这条链上不仅语义正确，也是唯一稳定的那一侧。
**前提是音频侧不能欠载**——mpv `--cache=20` 提供了这个前提；换成自家 `aout` 时，
这条前提要由更大的 ALSA period + 预充缓冲来保证，否则 8s 15 次 xrun 会直接打穿主钟。

### 6.5 udev 之外的坏情况

- **变帧率（VFR）片源**：PTS 不均匀，`target_vbl` 会算在半帧上，取最近整数即可。
  不要引入"固定 fps"假设——`g_au_seq/25` 就是死在这上面。
- **PTS 回绕 / 空洞**：`avformat` 已处理回绕；空洞（缺帧）表现为 `d` 突跳，
  走 L2 门的 `RESYNC` 而不是狂追。
- **音频流比视频短**（片尾音乐先结束）：`τ` 停住 → 视频会一直"超前"被等。
  需要 `τ` 在音频 EOF 后切到降级态（`SOURCE=FREE`，虚拟音频钟，§2.1 不变式 5），
  这条要显式实现，否则片尾会卡住。`FREE` 只改锚点来源，不改主钟角色。

---

## 7. 本节对 §1 的修订

§1.6 删除清单追加 4 项：

- `SIGSTOP/SIGCONT` 暂停四连 + `PAUSE_AT` 补贴算术（`tvplay-node.sh:109-124`：`pause_video()` 四条 `pkill -STOP`，`resume_video()` 用 `START += now - PAUSE_AT` 补时间）
- `/tmp/tvplay.state` 的 8 个变量与 `sed -i` 改写（`pos()`、`el=`）
- `g_au_seq / 25` 假时间戳（`v4l2hevc.c:373-374`）
- `seek_guard` 的 3s 窗口（改 300ms，语义从"丢弃"改"取最后"）

§1.4 模块表追加：`playlist.c`（~120 行）、`demux.c` 增加 `avformat_seek_file` + 预取钩子。

**§1.7 的 B 步因此可以拆得更细**：

```
B1  demux.c + 真 PTS，仍用 -re           → M2/M3 一致，25/24 矛盾消失
B2  去掉 -re，GL 路径接 vblank 节拍       → 这是真正分水岭
B3  接音频主钟 + 单向从动（§6.2）         → 音画首次有因果
    过渡锚点用 mpv 位置插值（§2.4），`aout` 就绪后原地换实现，接口不变
```

B1 可单独验证（日志打 `pts` 与 `τ` 之差，`-re` 在场时应恒小）；
B2 会暴露一切隐藏的时间假设（这是好事，趁早）；B3 才是用户能感知的那一步。
