# 高清播放：4K/HDR 片源 → 主机转码 → 盒子直显

一句话：**片子在 NAS（WebDAV），解码交给主机 RTX3080，盒子只当显示器。**
原因是盒子（X96，Mali-G31 panfrost）硬解 4K HEVC 10bit 实测只有 ~12fps：它的 mpv 构建
报 `Unsupported hwdec: v4l2m2m`（无零拷贝），只能 `-copy`，每帧 9MB CPU→GPU 上传扛不住。
所以 4K HDR 走「主机 cuda 解 + tonemap + 缩 1080p + nvenc → TCP → 盒子 mpv」。

实测（2026-11-16）：转码 1.56x 实时（148–160% CPU），盒子 `drop=0`、`A-V=0.000`。

---

## 0. 拓扑与固定值

| 角色 | 值 |
|---|---|
| 主机（转码端） | `192.168.1.10`（= `ip route get 192.168.1.121` 的 src，脚本自动取） |
| 盒子（显示端） | `192.168.1.121`，root，`7.2.12-x96-trim`，mpv v0.40.0 |
| 片源 | 极空间 NAS WebDAV，索引根 `$WEBDAV_MOVIES` |
| 推流 | `tcp://0.0.0.0:5000?listen=1`（mpegts） |
| 凭据 | `~/.env`：`WEBDAV_URL/USER/PASS/MOVIES/SEARCH`、`X96_IP`、可选 `CAST_PORT/CAST_HOST` |

**脚本与配置在仓库根有一份快照备份**（`~/bin` 是运行位置，两者同内容，改完记得重新 cp）：

| 仓库内 | 运行位置 | md5 |
|---|---|---|
| `tvcast.sh` | `~/bin/tvcast.sh` | `073fe8bd42d3dd3e9009370150a06785` |
| `tvplay.sh` | `~/bin/tvplay.sh` | `ada66329464408c864577b0cf283d5bc` |
| `box-mpv.conf` | `~/bin/box-mpv.conf` → 盒子 `/root/.config/mpv/mpv.conf` | `d8495815c5eb42270bebe649f8aabfb0` |
| `box-stats.lua` | `~/bin/box-stats.lua` → 盒子 `/root/.config/mpv/stats.lua` | `2f95407f4458bebe46ec8127d5ab9e79` |

```bash
~/bin/tvcast.sh -t >/dev/null   # 任意跑一次即可确认运行副本没被改坏
diff ~/kernel/tvcast.sh ~/bin/tvcast.sh   # 空 = 两边一致
```

## 1. 命令（日常只用这三条）

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

### 1.1 `-t` 输出怎么读

```
t=558.66 fps=23.976024 drop=4 mistimed=843 vo_drop=? vcache=61.27 disp_fps=60.000000 sync=display-resample hw=no
```

| 字段 | 正常 | 异常含义 |
|---|---|---|
| `t` | 递增 | 不涨 = 卡死/流断 |
| `fps` | 23.976 / 25 / 29.97（源帧率） | 远低于源帧率 = 主机转码跟不上 |
| `drop` | 冻结不涨（个位数） | 每秒 +3.7 → hwdec 用了 `-copy`；每秒 +21 → `vd-lavc-dr=yes` |
| `mistimed` | 缓慢增长 | 暴涨 = 输出模式与源不匹配 |
| `disp_fps` | 60 | 60 就是 23.976 源 → 3:2 pulldown 的来源 |
| `sync` | `display-resample` | 变 `audio` = 配置没生效（掉回旧参数） |
| `hw` | `no`（软解 158% CPU） | `v4l2m2m` 也可，`v4l2m2m-copy` 必掉帧 |

## 2. 盒子配置文件（唯二两份，部署到 `/root/.config/mpv/`）

真源在主机 `~/bin/box-mpv.conf`、`~/bin/box-stats.lua`；`tvcast.sh` 每次起播前 `ensure_box`
自愈（配置被删 / 盒子重刷后自动补回）。**盒子 mpv 启动只用 `--config-dir=/root/.config/mpv`，
不再传 `--no-config` 或一串散参数**；临时对照测试才用 `MPV_EXTRA`。

### 2.1 `/root/.config/mpv/mpv.conf`（825B，与 `~/bin/box-mpv.conf` 同内容）

```ini
# X96 盒子播放配置  tvcast 固化版本
# 起因: 内核 cmdline 锁 video=HDMI-A-1:1920x1080@60e, 且 force=on 跳过 EDID,
#       模式表只有 CVT 兜底, 无 24Hz。23.976fps 源在 60Hz 上 3:2 pulldown 抖动。
# 解法: display-resample 对齐 vsync + GPU 插帧补到 60Hz。
#       hwdec 必须零拷贝 v4l2m2m: v4l2m2m-copy 的 per-frame 上传吃掉带宽, 插帧会掉帧。
video-sync=display-resample
interpolation=yes
tscale=oversample
scale=bilinear
dscale=bilinear
cscale=bilinear
hwdec=v4l2m2m
# vd-lavc-dr=yes 会破坏零拷贝直出(实测 drop 21/s), 保持默认 no
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

## 3. 主机转码命令（`tvcast.sh` 的核心，可直接抄）

```bash
ffmpeg -hide_banner -loglevel warning -re \
  [-ss 起始秒] \
  -hwaccel cuda -hwaccel_output_format cuda -i "http://user:pass@nas/路径" \
  -map 0:v:0 -map 0:a:1? \
  -vf "hwdownload,format=p010le,scale=1920:-2:flags=bilinear,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
  -c:v h264_nvenc -preset p4 -b:v 8M -maxrate 12M -bufsize 16M -g 48 -bf 2 \
  -c:a aac -b:a 192k -ac 2 \
  -f mpegts "tcp://0.0.0.0:5000?listen=1"
```

逐段为什么这么写：

| 片段 | 作用 |
|---|---|
| `-re` | 按源速度读，不当成批处理冲满带宽 |
| `-hwaccel cuda -hwaccel_output_format cuda` | 帧留在显存里，不回落内存 |
| `-map 0:v:0 -map 0:a:1?` | 只取第一条视频 + 第 2 条音轨（`?` = 没有也不报错） |
| `hwdownload,format=p010le` | 10bit 从显存拉回交给 zscale |
| `scale=1920:-2` | 缩到 1080p（电视 EDID 最高 1920x1080，必须下采样） |
| `zscale=t=linear:npl=100 … tonemap=hable` | HDR→SDR hable 映射 |
| `-c:v h264_nvenc -preset p4 -b:v 8M` | 8M 码率，盒子零拷贝解码余量充足 |
| `-f mpegts tcp://…?listen=1` | ffmpeg 当服务端，盒子主动来连 |

## 4. 已知坑（都是实测踩出来的）

1. **`vd-lavc-dr=yes` 绝对不要开**：破坏零拷贝直出，`drop` 从 210 涨到 702（21/s）。
2. **`hwdec=v4l2m2m-copy` 在 60Hz 必掉帧**：每帧上传吃带宽，`drop` 每秒 +3.7；要么零拷贝要么软解。
3. **根因不是「丢帧」而是「没有 24Hz 模式」**：内核 cmdline `video=HDMI-A-1:1920x1080@60e` +
   debugfs `force=on` → 完全跳过 EDID（`edid` 0 字节，`edid_override` 写了也不生效），模式表只剩
   CVT 兜底（1920x1080/1024x768/800x600/848x480）。23.976fps 上 60Hz 就是 3:2 pulldown 抖动，
   所以 `drop=0` 但看着晃。当前用 display-resample + 插帧消掉。
4. **字幕**：内封 ASS 特效字幕 `osd_render` 要 11.4ms/帧，纯文本约 5ms。需要省 CPU 时指定
   `--sid=<纯文本轨> --sub-auto=no`。
5. **4K 直推盒子 ≠ 解决**：h264 8M 1080p 是当前唯一稳定档；想回到 4K 需要盒子侧零拷贝修好。

## 5. 一次完整的验证流程

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

## 6. 日志与临时覆盖

```bash
tail -f /tmp/tvcast.log        # 主机 ffmpeg（-loglevel warning，正常很安静）
ssh root@192.168.1.121 'tail -f /tmp/mpvcast.log'   # 盒子 mpv
MPV_EXTRA="--no-config" ~/bin/tvcast.sh 关键词       # 绕开固化配置做对照实验
MPV_EXTRA="--sid=5 --sub-auto=no" ~/bin/tvcast.sh 关键词   # 临时锁字幕轨
```

`MPV_EXTRA` 是**唯一**该用的临时覆盖口；不要改 `tvcast.sh` 里的散参数——那部分已经搬进
`mpv.conf`，两边同时改会互相打脸。
