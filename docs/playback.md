# 高清播放：NAS 片源 → 盒子本地播放

一句话：**片子在 NAS（WebDAV），盒子自己解自己放，播放时不依赖任何外部主机。**

## 纠正旧结论：卡的是缩放，不是解码（2026-11-16 实测）

旧文档写的是「盒子硬解 4K HEVC10 只有 ~12fps，因为 mpv 无 `v4l2m2m` 零拷贝」。
**「硬解只有 ~12fps」是错的，但「mpv 没有 `v4l2m2m`」是对的**——这两件事必须分开看，
混在一起就是后面所有误判的源头（2026-11-19 复验）：

| 情形 | 判定 | 依据 |
|---|---|---|
| ffmpeg / 自写播放器走 `hevc_v4l2m2m` | **真零拷贝硬解，可用** | `ffmpeg -c:v hevc_v4l2m2m` 4K HEVC10：1200 帧 / 13.9s = **86fps**（3.5x 实时）；软解同片 17fps |
| `play.sh`（meson_vdec → NV12M dmabuf → GLES3） | **真零拷贝硬解，可用** | 2152 AU / 90.5s = **23.76fps**，drop=0；同段软解 6.06fps |
| mpv `--hwdec=v4l2m2m` | **该值在此构建里不存在** | 实测 `mpv --hwdec=v4l2m2m` → `Unsupported hwdec: v4l2m2m`。本机 mpv 0.40 只编了 `v4l2m2m-copy` |

即：**盒子有真硬解，只是 mpv 这条链路用不上**。下表 mpv 的 `--hwdec=v4l2m2m` 行是历史误记
（参数被 mpv 拒收，量到的是软解速度），保留仅作对照，勿据此下结论：

| 测法 | 结果 |
|---|---|
| `mpv --vo=null --hwdec=v4l2m2m-copy` | 21fps |
| ~~`mpv --vo=gpu --gpu-context=drm --hwdec=v4l2m2m`~~（值无效，实为软解） | ~~7.8fps~~ 作废 |
| `mpv --vo=drm --drmprime-video-plane=overlay`（DRM 直通，atomic EINVAL） | 7fps |
| `mpv --vo=drm --hwdec=v4l2m2m-copy` | 4fps |
| `mpv --vo=gpu-next` | >40s 未跑完（<6fps） |

解码有余量 3 倍，卡的是**后段**缩放。注意：下面 mpv 的数字全部是**软解**跑出来的
（含上面作废那行），它们证明的是「mpv 这条路走不通」，而不是「盒子解不动 4K」。
mpv 的 `vo=gpu` 在 Mali-G31 上只有 4–8fps，
原因不在「没有缩放硬件」这个笼统结论上，而是具体三条：

- 电视 EDID 实测只声明 1920×1080 / 1280×720（`X96-TV`，128 字节、无 CEA 扩展块）→ 4K 必须下采样
  （**这条是旧电视时代的**；现在盒子驱动的是 2560×1440@60 的 BenQ PD2500Q，见 §1.2.1）
- `/dev/video0`（meson-vdec）CAPTURE 报支持 144p–2160p 连续缩放，但 `v4l2-ctl` 设
  4K 入 + 1080p 出，驱动 rc=0 却**静默忽略**，格式回退 1280x720 VP9 → VPP 不给 M2M 缩放
- Mali-G31 无独立硬件缩放单元，只能 shader 逐像素读写；mpv 那条链还要顺带做
  插帧 / display-resample / 完整 tonemap，叠起来就掉到个位数 fps

> **旧结论作废**：上一版文档据此认定「4K 帧能解出来但无处安放，只能入库前转 1080p」。
> 这条已经推翻 —— 自写一条只做单 pass 缩放的 GLES3 路径就够了，见 §1.2。

## 三条路径

| 路径 | 谁干活 | 外部依赖 |
|---|---|---|
| **A. 1080p 及以下 → `tvplay.sh` + 盒子 mpv**（日常主路） | 盒子 mpv（零拷贝硬解） | **无** |
| **B. 4K → `hevcdec` 自带 GLES3 输出**（4K 主路） | `v4l2hevc-gl-aarch64`，硬解 + shader 缩放 | **无** |
| **C. 4K 片源一次性转 1080p 入库**（保底/省电） | 任意一台机器跑 ffmpeg，转完就不用了 | 只在转码那一次 |

4K 原片现在**直接播**，走 B：V4L2 零拷贝解 → dmabuf → GLES3 等比缩放 + HDR10→SDR，
实测 3840×1600 10bit 跑满 23.8fps（24fps 配速、drops=0），不需要预转码、不需要第二台机器。
C 只在「想省盒子功耗」或「要长期归档小体积」时才用，写法见 §3。

---

## 0. 拓扑与固定值

| 角色 | 值 |
|---|---|
| 主机（仅旧推流路径用） | `192.168.1.10`（= `ip route get 192.168.1.121` 的 src，脚本自动取） |
| 盒子（显示端） | `192.168.1.121`，root，`7.2.12-x96-trim`，mpv v0.40.0 |
| 显示器 | BenQ PD2500Q，`card0-HDMI-A-1`，**2560×1440@60**（走真 EDID；cmdline 的 `video=`/`drm.edid_firmware=` 已于 2026-11-18 移除） |
| 片源 | 极空间 NAS WebDAV，索引根 `$WEBDAV_MOVIES` |
| 推流 | `tcp://0.0.0.0:5000?listen=1`（mpegts） |
| 凭据 | `~/.env`：`WEBDAV_URL/USER/PASS/MOVIES/SEARCH`、`X96_IP`、可选 `CAST_PORT/CAST_HOST` |

**脚本与配置在仓库根有一份快照备份**（`~/bin` 是运行位置，两者同内容，改完记得重新 cp）：

| 仓库内 | 运行位置 | md5 |
|---|---|---|
| `tvcast.sh` | `~/bin/tvcast.sh` | `073fe8bd42d3dd3e9009370150a06785` |
| `tvplay.sh` | `~/bin/tvplay.sh` | `ecafb0a834724f03479b22eabc8f9390` |
| `box-mpv.conf` | `~/bin/box-mpv.conf` → 盒子 `/root/.config/mpv/mpv.conf` | `d8495815c5eb42270bebe649f8aabfb0` |
| `box-stats.lua` | `~/bin/box-stats.lua` → 盒子 `/root/.config/mpv/stats.lua` | `2f95407f4458bebe46ec8127d5ab9e79` |

```bash
~/bin/tvcast.sh -t >/dev/null   # 任意跑一次即可确认运行副本没被改坏
diff ~/kernel/tvcast.sh ~/bin/tvcast.sh   # 空 = 两边一致
```

## 1. 命令

### 1.0 日常主路：`tvplay.sh`（盒子上自己播，无人帮忙）

```bash
~/bin/tvplay.sh -i            # 重建片库索引 →  ~/.cache/tvplay.index（BFS 3 层）
~/bin/tvplay.sh -l 关键词      # 只列表不播放
~/bin/tvplay.sh 关键词         # 搜片 + 在显示器上播（命中多首会让你选序号）
~/bin/tvplay.sh -p "/sata11-18072858035/电影/xxx.mkv"   # 直给完整 dav 路径
~/bin/tvplay.sh -s            # 停止
```

盒子 `mpv` 直接拉 NAS 的 WebDAV 地址播，**播放链路里没有任何其他机器**。
1080p 及以下的片源全部走这条；4K 片子走 §1.2 的 `hevcdec` 直放（同样是盒子自己干），
只有想省功耗 / 归档小体积时才按 §3 转成 1080p 再进来。

### 1.1 旧推流路径：`tvcast.sh`（可选，需要一台带 NVENC 的机器）

```bash
~/bin/tvcast.sh 关键词        # 搜片 + 起播（命中多首会列出来让你选序号）
~/bin/tvcast.sh 关键词 120    # 同上，从第 120 秒开始
~/bin/tvcast.sh -s            # 停止（杀主机 ffmpeg + 盒子 mpv）
~/bin/tvcast.sh -t            # 看进度/健康度（读盒子 /tmp/mpvstat.txt）
```

辅助：

```bash
~/bin/tvcast.sh -p "/sata11-18072858035/电影/xxx.mkv"    # 直接给完整 dav 路径，跳过搜索
~/bin/tvcast.sh -d            # 检查/部署盒子配置（scp mpv.conf + stats.lua 并打印 ls）
~/bin/tvplay.sh -i            # 重建片库索引 →  ~/.cache/tvplay.index（BFS 3 层）
~/bin/tvplay.sh -l 关键词      # 只列表不播放
```

> `-p` 和「关键词」都需要索引：没索引会提示 `缺索引，先跑: tvplay.sh -i`。

### 1.2 4K 直放：`hevcdec`（路径 B，硬解 + GLES3 缩放）

4K 不用再转码，也不必走 mpv。`hevcdec/v4l2hevc-gl-aarch64` 一个二进制搞定：
V4L2 M2M 零拷贝解 → dmabuf fd → EGL/GLES3 shader 单 pass 等比缩放 → DRM 上屏。

```bash
cd ~/kernel/hevcdec && make gl CROSS=1        # 产物 v4l2hevc-gl-aarch64
scp v4l2hevc-gl-aarch64 root@192.168.1.121:/tmp/

# 盒子上：读裸 HEVC 码流（Annex-B，含 VPS/SPS/PPS）
# NOWRITE=1 是看片必需项（否则写 /tmp/out.yuv，见下表）
ssh root@192.168.1.121 \
  'NOWRITE=1 PLAY=1 GLPLAY=1 /tmp/v4l2hevc-gl-aarch64 /tmp/movie.265'

# 长片不用先落盘：ffmpeg 直接从 WebDAV 拉。注意盒子上**没有 curl**，
# 别用 curl|ffmpeg；ffmpeg 自带 http 客户端。
# -re 必须：GL 输出路径没有节拍器，不靠它就会按解码速度播（见下表）
ssh root@192.168.1.121 \
  "ffmpeg -re -i 'http://user:pass@nas/路径' -map 0:v:0 -c:v copy -f hevc - \
   | NOWRITE=1 PLAY=1 GLPLAY=1 /tmp/v4l2hevc-gl-aarch64 -"
```

| 开关 | 作用 |
|---|---|
| `PLAY=1` | 配速播放（去掉就是全速抓帧，测吞吐用） |
| `GLPLAY=1` | 走 GLES3 输出（不置位则退回 DRM 平面直通） |
| `NOWRITE=1` | **看片必加**：否则每帧写 `/tmp/out.yuv`，4K 从 24fps 掉到 9.9fps（实测 write=18.6s/26s），还会撑爆 /tmp |
| `FPS=24` | 只对 DRM 平面路径有效。`GLPLAY=1` 时 GL 输出**没有节拍器，此开关被忽略**——节拍要用 ffmpeg `-re` 提供 |
| `LEAD=6` | 起播预垫帧数，卡首帧时可调大 |
| `NOPACE=1` | 不限速，纯测解码 + 缩放上限 |
| `SCALE=crop` / `DSTGEO` | 裁切填充 / 指定目标几何。默认等比 letterbox 到屏幕模式；`DSTGEO` 只对 DRM 平面路径生效，GL 路径按 connector `modes[0]` 全屏（见 §1.2.1） |
| `HDR=1` `TM_*` | HDR10→SDR tonemap（hable，峰值/目标/饱和度可调） |

### 1.2.1 输出分辨率与缩放：一律按显示器 2560×1440@60

**屏幕就是唯一的目标几何，片源只做等比缩放，不转码、不改容器。**

| 事实 | 值 / 位置 |
|---|---|
| 显示器 | BenQ PD2500Q，原生 **2560×1440@60**（`card0-HDMI-A-1`，`modes` 首行就是 2560x1440） |
| 模式由谁定 | **显示器真 EDID**（2026-11-18 已从 uEnv.txt 移除 `video=HDMI-A-1:2560x1440@60e` 与 `drm.edid_firmware=`）；内核按 CEA/DTD 首选模式起屏，换屏/换线自动跟随 |
| GL 路径取几何 | `glout.c: kms_pick()` 取 connector 的 `modes[0]` → 当前是 2560×1440（屏自己报的首选模式） |
| 壳怎么知道几何 | 盒端 `disp` 现场探测：`/sys/class/graphics/fb0/modes`（内核 applied 模式，最权威）→ connector `mode`/`modes[0]` → 任意有模式表的 connector；刷新率取 EDID 首选 DTD 的 `pixclk/(htotal*vtotal)`（`drm_hz`），cmdline `video=` 若回来了优先用它 |
| 两个已知坑 | ① `drm/*/modes`、`/edid` 是虚拟文件，`size=0`，不能用 `-s` 判存在；② meson dw-hdmi 的 connector `status` 会停在 `disconnected`（屏明明在出图），所以探测**不能只认** `status=connected` |
| DRM 平面路径兜底 | `tvplay.sh` 传 `DSTGEO=<探测值>+0+0`（GL 路径忽略它，两者结果一致）；探测失败才退 2560x1440/1920x1080 一类兜底值并打印告警 |
| 谁来缩放 | GL：GPU（Mali-G31 shader，单 pass）；DRM：显示控制器硬件 overlay 缩放 |

等比 letterbox（`SCALE` 默认 fit，居中黑边）在 2560×1440 上的落点：

| 片源 | 画面上屏矩形 | 黑边 |
|---|---|---|
| 3840×2160（16:9 4K） | 2560×1440 | 无，满屏（缩小 1.5x） |
| 3840×1600（2.4:1） | 2560×1067 | 上下各 186px |
| 1920×1080（FHD） | 2560×1440 | 无（**放大** 1.33x，GPU bilinear） |
| 720×480（4:3） | 2160×1440 | 左右各 200px |

- 要铺满/裁边就用 `SCALE=crop`（按屏比例内缩采样区，等价于放大后裁边）。
- 节拍：屏 60Hz，GL 路径**没有 vblank 节拍器**，23.976 源靠 `ffmpeg -re` 按时间轴供帧
  （实测 23.8fps、drops=0）；屏刷新率只决定 swap 时机，不决定帧率。
- `tvplay.sh` 起播会先探屏并打印 `输出: 2560x1440@60（显示器 现场探测）` + 一行
  `缩放: 3840x1600 → 2560x1067 + 上下黑边各 186`，起播后回读盒端日志里的
  `GLOUT: 屏幕 2560x1440@60` 作为**实际选中模式**的验收。探测失败才打 `兜底值⚠` 并用
  `DISP_W/DISP_H/DISP_HZ`（脚本顶部），不再默默假设某块屏。

实测（2026-11-16，X96Max / Mali-G31 / 3840×1600 10bit 源 → 2560×1440 输出）：

| 测法 | 结果 |
|---|---|
| GL + `ffmpeg -re` 全链（15s 片源） | 297~369 帧 / 13.7~15.1s ≈ **实时**，drops=0 |
| 不带 `-re` | 按解码速度播：4K 约 27.7fps（比 24 快 15%），1080p 更快 |
| 不带 `NOWRITE` | 9.9fps，瓶颈在写 `/tmp/out.yuv`（write=18.6s/26s） |
| 纯解码（`NOWRITE=1 NBUF_OUT=16`） | 104fps —— 瓶颈已不在解码 |
| GLES3 shader 缩放 | 单 pass 采样 + tonemap，是 23.8fps 里的主要成本；够 24p，不够 60p |

> **`tvplay.sh` 已接入（2026-11-16）**：HEVC 且 ≤30fps 走
> `ffmpeg -re 供流 | hevcdec(GL) 出画 ＋ mpv --no-video 出声`，其余仍走 mpv。
>
> 踩过的坑：① 这块板子 `ffmpeg -f alsa` 缓冲太浅（单跑 8s 就 15 次 xrun），
> 音频只能交给 mpv；② `WEBDAV_URL` 只含 `http://host:port`，凭据要自己拼，
> 且本机口令是 `$$` 开头，**不能把 URL 塞进 `sh -c "..."`**（内层 shell 会把
> `$$` 展成 PID），必须用环境变量传；③ 盒子 rootfs 没有 curl，取流用 ffmpeg。
> 待修（C 侧）：GL 路径缺 vblank 节拍器、GL 不累加 `pc.flips`、DRM 路径
> CPU tonemap 对 10bit 源 190ms/帧。

### 1.3 `-t` 输出怎么读

```
t=558.66 fps=23.976024 drop=4 mistimed=843 vo_drop=? vcache=61.27 disp_fps=60.000000 sync=display-resample hw=no
```

| 字段 | 正常 | 异常含义 |
|---|---|---|
| `t` | 递增 | 不涨 = 卡死/流断 |
| `fps` | 23.976 / 25 / 29.97（源帧率） | 远低于源帧率 = 渲染/缩放跟不上（4K 走 mpv 必然如此，改走 §1.2） |
| `drop` | 冻结不涨（个位数） | 每秒 +3.7 → hwdec 用了 `-copy`；每秒 +21 → `vd-lavc-dr=yes` |
| `mistimed` | 缓慢增长 | 暴涨 = 输出模式与源不匹配 |
| `disp_fps` | 60 | 60 就是 23.976 源 → 3:2 pulldown 的来源 |
| `sync` | `display-resample` | 变 `audio` = 配置没生效（掉回旧参数） |
| `hw` | `no`（本机 mpv 0.40 没有 `v4l2m2m` 这个值，**仅指 mpv 这条链路**，见 §2.1 结论 2） | 出现 `v4l2m2m` = 换了 mpv 构建；出现 `v4l2m2m-copy` = 必掉帧。要 4K 真硬解走 `hevcdec`/`play.sh`（§1.2），实测 23.76fps |

## 2. 盒子配置文件（唯二两份，部署到 `/root/.config/mpv/`）

真源在主机 `~/bin/box-mpv.conf`、`~/bin/box-stats.lua`；`tvcast.sh` 每次起播前 `ensure_box`
自愈（配置被删 / 盒子重刷后自动补回）。**盒子 mpv 启动只用 `--config-dir=/root/.config/mpv`，
不再传 `--no-config` 或一串散参数**；临时对照测试才用 `MPV_EXTRA`。

> 注意：`tvplay.sh` 的 mpv 分支（H.264 等非 HEVC 片源）**自带散参数**启动（`--hwdec=no` 软解），
> 没读这份 `mpv.conf`。1080p 软解跑得动，但白烧 CPU。
>
> **不要**把它改成 `--hwdec=v4l2m2m`——本机 mpv 0.40 该值是**无效值**，不报错直接静默回退软解，
> 改了等于没改（这是旧文档留下的错误建议，已实测证伪，见 §2.1 结论 2）。
> 要省电只有一条路：HEVC 片走 `hevcdec`/`play.sh` 的 V4L2 M2M 真硬解链路（§1.2）。

### 2.1 `/root/.config/mpv/mpv.conf`（2005B，11-17 全面实测重写）

> 三份同内容、md5 一致：盒子 `/root/.config/mpv/mpv.conf`、主机 `~/bin/box-mpv.conf`、仓库 `box-mpv.conf`。
> 旧版（825B，`hwdec=v4l2m2m` + `interpolation=yes`）已被实测推翻，仓库副本已同步，避免 `ensure_box` 把旧配置刷回盒子。


```ini
# X96 盒子播放配置  tvcast 固化版本
# 2026-11-17 全面实测重写。四项关键结论:
#
# 1) 输出面板原生 2560x1440, 但 Mali 只渲染 1920x1080, 由 meson 主平面做硬件放大。
#    这不是"退回 1080p", kernel debugfs 已证实平板在放大:
#      primary plane: fb=1920x1080  src-pos=1920x1080  crtc-pos=2560x1440+0+0
#    实测丢帧:
#      Mali 直接渲 1440p            → 11.2 帧/秒
#      Mali 渲 1080p + 平面放大 1440p → 0 帧/秒, AV=+0
#    所以 drm-draw-surface-size=1920x1080 是必须的, 不是妥协。
#
# 2) 【仅限 mpv 这条链路】没有真硬解可用。警告: 盒子本身有真零拷贝硬解, 走的是
#    play.sh -> V4L2 M2M (meson_vdec -> NV12M dmabuf -> GLES3), 实测 4K HEVC10 23.76fps
#    (drop=0), 同一段码流 ffmpeg 软解只有 6.06fps。本条结论只对 mpv 成立, 不要外推。
#    本机 mpv 0.40 只编了 v4l2m2m-copy, "v4l2m2m" 是无效值,
#    mpv 不报错直接静默回退软解。实测 v4l2m2m-copy 虽然 CPU 从 238% 降到 92%,
#    但 AV 同步持续漂移(5秒冲到 +0.72, 30秒涨到 +1.12, 约 0.016/秒 = 每小时 58 秒),
#    长片必然音画不同步, 故弃用。软解 CPU 偏高但 AV 恒定 +0。
#    vo=drm + drmprime 视频平面的直出通路在这台盒子上是断的:
#      退 1440p 时 atomic commit EINVAL, hwdec-current 始终 = no。
#
# 3) interpolation=yes 在本机一律负收益, 已关。实测开插帧丢帧 13.2/秒(1080p输出)。
#
# 4) 23.976fps 也实测过(本地转码样本 24000/1001, 1439帧):
#    不插帧 丢 0 / 抖 0; 开插帧 丢 5.6/秒 + 抖 8.4/秒。故与 29.97 一致, 一律不插帧。
#    注意: interpolation=no 时 mpv 报 mistimed=(unavailable), 应以 frame-drop-count=0 为准。

video-sync=audio
interpolation=no

# 1440p 输出 + 1080p 渲染面(见上文结论 1, 两条必须成对出现)
drm-mode=2560x1440
drm-draw-surface-size=1920x1080

hwdec=no

scale=bilinear
dscale=bilinear
cscale=bilinear
# vd-lavc-dr=yes 会破坏直出通路(实测 drop 21/s), 保持 no
vd-lavc-dr=no

vo=gpu
gpu-context=drm
cache=yes
demuxer-max-bytes=64MiB
cache-pause=yes
cache-pause-wait=1

aid=1
ao=alsa
audio-device=alsa/hw:0,0
audio-channels=stereo

osc=no
osd-level=0
script=/root/.config/mpv/stats.lua
```

### 2.2 `/root/.config/mpv/stats.lua`（状态探针，`-t` 的数据源）

```lua
-- tvcast 状态探针: 每 2s 落盘 /tmp/mpvstat.txt, 供 tvcast.sh -t 读取
local function t(k) return mp.get_property(k) or "?" end
mp.add_periodic_timer(2, function()
  local f = io.open("/tmp/mpvstat.txt", "w")
  if not f then return end
  f:write(string.format(
    "t=%.2f fps=%s drop=%s mistimed=%s vo_drop=%s vcache=%s disp_fps=%s sync=%s hw=%s\n",
    mp.get_property_number("time-pos") or 0, t("estimated-vf-fps"),
    t("frame-drop-count"), t("mistimed-frame-count"), t("vo-drop-frame-count"),
    t("demuxer-cache-duration"), t("display-fps"), t("video-sync"), t("hwdec-current")))
  f:close()
end)
```

手工重装（`-d` 失效时的兜底）：

```bash
scp ~/bin/box-mpv.conf  root@192.168.1.121:/root/.config/mpv/mpv.conf
scp ~/bin/box-stats.lua root@192.168.1.121:/root/.config/mpv/stats.lua
ssh root@192.168.1.121 'chmod 644 /root/.config/mpv/*'
```

盒子侧手工起播（调试用）：

```bash
ssh root@192.168.1.121 "mpv tcp://192.168.1.10:5000 --config-dir=/root/.config/mpv"
```

## 3. 4K 片源一次性转 1080p（路径 C，可直接抄）

**不是必需品**——4K 已经能直放（§1.2）。只在两种情况下才转：想省盒子功耗，
或者要长期归档小体积版本。跑一次就不需要任何转码机。**不绑定 GPU**：
CPU 软解 + libx264 即可（有 N 卡时把 `-c:v libx264 -preset veryfast -crf 20`
换成 `-c:v h264_nvenc -preset p4 -b:v 8M -maxrate 12M -bufsize 16M`，速度快，仅此而已）。

```bash
ffmpeg -hide_banner -i "http://user:pass@nas/路径" \
  -map 0:v:0 -map 0:a:1? \
  -vf "scale=1920:-2:flags=bilinear,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
  -c:v libx264 -preset veryfast -crf 20 -g 48 \
  -c:a aac -b:a 192k -ac 2 \
  -movflags +faststart "out-1080p.mp4"
```

| 片段 | 作用 |
|---|---|
| `-map 0:v:0 -map 0:a:1?` | 只取第一条视频 + 第 2 条音轨（`?` = 没有也不报错） |
| `scale=1920:-2` | 缩到 1080p 省码率/省解码。**不是为了适配屏幕**——屏是 2560×1440，1080p 会被 GL 放大 1.33x；想让画面与屏幕 1:1 就改 `scale=2560:-2` |
| `zscale=t=linear:npl=100 … tonemap=hable` | HDR→SDR hable 映射（SDR 源可整段删掉） |
| `-c:v libx264 -crf 20` | 1080p 8–10M 量级，盒子零拷贝解码余量充足 |
| `-movflags +faststart` | 转完直接丢 NAS，`tvplay.sh` 拿到的就是普通 1080p 片 |

转完的片子放回 NAS 同一目录（改名或加 `-1080p` 后缀），`tvplay.sh -i` 重建索引即可。

> 旧路径 `tvcast.sh`（主机实时转码 → TCP 推流 → 盒子直显）仍留在仓库里，属于历史方案：
> 它要求一台带 NVENC 的机器常驻在播放链路上，只在该机器恰好就在旁边时才值得用。
> 命令与参数见 `tvcast.sh` 头部注释；不再作为推荐路径。

## 4. 已知坑（都是实测踩出来的）

1. **`vd-lavc-dr=yes` 绝对不要开**：破坏零拷贝直出，`drop` 从 210 涨到 702（21/s）。
2. **`hwdec=v4l2m2m-copy` 在 60Hz 必掉帧**：每帧上传吃带宽，`drop` 每秒 +3.7；要么零拷贝要么软解。
3. **60Hz 屏上没有 24Hz 模式，只能靠配速消除抖动**：（旧）内核 cmdline `video=HDMI-A-1:2560x1440@60e`
   + debugfs `force=on` 跳过真 EDID；（2026-11-18 起）走真 EDID，模式表更全，
   但 23.976/24Hz 依旧要显示器自己支持，BenQ 这条 HDMI 口仍只给 50/60。mpv 路径用 display-resample + 插帧；
   `hevcdec` GL 路径没有节拍器，靠 `ffmpeg -re` 按时间轴供帧（实测 drops=0，看着不晃）。
4. **字幕**：内封 ASS 特效字幕 `osd_render` 要 11.4ms/帧，纯文本约 5ms。需要省 CPU 时指定
   `--sid=<纯文本轨> --sub-auto=no`。
5. **4K 直推盒子不是解码问题，是缩放问题**：零拷贝解码 86fps（`hevcdec` 侧 104fps）够看，
   卡在 Mali-G31 缩 4K→屏幕（2560×1440）——`mpv --vo=gpu` 只有 4–8fps，且 VPP 不给 M2M 缩放。**绕过办法不是转码，而是别用 mpv 的输出链**：`hevcdec` 的
   GLES3 单 pass 缩放实测 23.8fps（§1.2）。转码（§3）只用于省功耗/归档。

## 5. 一次完整的验证流程（旧推流路径）

```bash
~/bin/tvcast.sh 关键词           # 起播，结尾会打印 "盒子 mpv=1"
sleep 20 && ~/bin/tvcast.sh -t   # 看 drop 是否冻结、sync 是否 display-resample
~/bin/tvcast.sh -t               # 再等 30s 复看，drop 不涨即过关
~/bin/tvcast.sh -s               # 收工；确认 ss -tnp | grep :5000 为空
```

停止后的干净判定（三条都要成立）：

```bash
ss -tnp | grep :5000                                     # 无 ESTABLISHED
pgrep -af "ffmpeg .*tcp://0.0.0.0:5000"                  # 无进程
ssh root@192.168.1.121 'pgrep -c mpv; ls /tmp/mpvstat.txt'  # 0 + 文件已删
```

## 6. 日志与临时覆盖（旧推流路径）

```bash
tail -f /tmp/tvcast.log        # 主机 ffmpeg（-loglevel warning，正常很安静）
ssh root@192.168.1.121 'tail -f /tmp/mpvcast.log'   # 盒子 mpv
MPV_EXTRA="--no-config" ~/bin/tvcast.sh 关键词       # 绕开固化配置做对照实验
MPV_EXTRA="--sid=5 --sub-auto=no" ~/bin/tvcast.sh 关键词   # 临时锁字幕轨
```

`MPV_EXTRA` 是**唯一**该用的临时覆盖口；不要改 `tvcast.sh` 里的散参数——那部分已经搬进
`mpv.conf`，两边同时改会互相打脸。

## 7. 音画同步：闸门 + 真值探针（hevcdec 内建 aout）

症状：起播时"声音比画面快一两秒"，之后全程保持这个差。

病根不在 ffmpeg，也不在配速公式，而在**起播顺序**：音频那条 ffmpeg 一 spawn 就按 `-re`
往前灌 PCM，而视频这边还要预读 1 MB、解析 SPS、开 V4L2 会话、等 RAP 才能出首帧。
音频的 `played_ms` 已经从 0 跑到几百毫秒，画面才刚上屏；配速又锚在"首帧 = 音频此刻"，
这段错位就被永久写进这条片子的时间轴里。

修法（两道，缺一不可）：

1. **闸门**（`aout_set_gate`，`AUDIO_GATE=0` 可关掉做对照）：首帧没上屏前 aout 不往上读
   FIFO，ffmpeg 写满管道就停住（背压），音频内容最多超前一个管道深度，播不出去。
2. **开闸时机**：首帧 **submit + render_pump 之后**才开闸（`g_gate_wait` 回执），不是首帧
   拿到就开——GL 的 swap 才是"已在屏上"，提前开闸等于白送一次 swap 的时长（实测 90~130 ms）。

量法（`SYNC=1`，只认 `RENDER_SHOWN` 回调，绝对值不比相对值）：

```
AVSYNC2 shown=240 err=+40ms 音频=10.00s 画面=9.96s
```

`err = aout_played_ms() - (shown-1)*1000/fps`，正数 = 声音跑到画面前头。盒子实测量级：

| 配置 | err（起播后恒定） |
|---|---|
| 闸门开 + 首帧上屏后开闸 | **+40 ms**（= 1 帧 @24fps，感知不到） |
| `AUDIO_GATE=0`（旧行为） | **+823 ms**（就是"声音快"的听感） |

要点：`err` 必须用**绝对**位置算。拿"首帧那一刻的 played"当 0 的相对量永远得 0，
因为它把起播错位一起减掉了——早期版本就这么自欺过一次。

盒子上跑这套测试前必须让桌面让出 DRM master，否则 `GLOUT: 拿不到 DRM master` +
`SetCrtc: Permission denied`，一帧都不上屏，所有 SYNC 数字全是假的：

```bash
ssh root@X96 'systemctl stop desktop.service console-wall.service; systemctl mask --runtime desktop.service'
# 测完必须还原
ssh root@X96 'systemctl unmask --runtime desktop.service; systemctl start console-wall.service desktop.service'
```
