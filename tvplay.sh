#!/bin/bash
# tvplay.sh — 从极空间 NAS(WebDAV) 取片，在 X96 盒子上全屏播放到显示器
#
# 播放器按片源分流（2026-11-16 实测）：
#   HEVC ≤30fps  → hevcdec 硬解 + EGL/GLES3 上屏（4K 不转码）
#   其他          → mpv（沿用旧配置）
#
# 输出分辨率一律按显示器来，但**不写死**（当前这台是 BenQ PD2500Q 2560x1440@60）：
#   盒子 cmdline 已不再锁 video=/drm.edid_firmware=，模式由显示器真 EDID 决定；
#   需求值现场探测（fb0 applied 模式 → connector → EDID DTD），换屏/换线自动跟随。
#   GL 输出 / DRM 平面都按探测结果铺，片源比屏大或比屏小都等比缩放 + 居中黑边
#   （不改片源、不转码）。
#
# 用法:
#   tvplay.sh -i                # 重建索引
#   tvplay.sh -l [关键词]       # 只列表
#   tvplay.sh 关键词...         # 搜索并播放（多个命中会让你选）
#   tvplay.sh -p <dav路径>      # 直接播放
#   tvplay.sh -s                # 停止
#   tvplay.sh -t                # 查进度
#   tvplay.sh -d                # 重新部署 hevcdec 到盒子
#   tvplay.sh -f                # 兼容保留（现在一律从头播，等价无操作）
#   tvplay.sh -a <音轨号>       # 选音轨（默认 1）
#   tvplay.sh --no-audio        # 只出画面
#
# 环境: ~/.env 里 WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS / WEBDAV_MOVIES / X96_IP
set -uo pipefail
[ -f ~/.env ] && . ~/.env
BASE="${WEBDAV_URL:?缺 WEBDAV_URL}"; U="${WEBDAV_USER}"; P="${WEBDAV_PASS}"
AUTH="http://$U:$P@${BASE#http://}"
ROOT="${WEBDAV_MOVIES:-/sata11-18072858035}"
X96="${X96_IP:-192.168.1.121}"
IDX="$HOME/.cache/tvplay.index"
VID='\.(mkv|mp4|m2ts|ts|avi|rmvb|mov|wmv|flv)$'

# 落点 /root（ext4）：/tmp 是 tmpfs，122MB 级重启就没了，改一次 cmdline 就得重推一次；
# 盒端 play.sh / deploy.sh / x96-rc.service 早就统一在 /root，这里跟上。
HW_BIN=/root/v4l2hevc-aarch64
# 交叉产物名随 Makefile：CROSS=1 出 hevcdec/v4l2hevc-aarch64（drm+gl 同一二进制，RENDER= 选后端），
# 老名字 v4l2hevc-gl-aarch64 只是副本；两个名字都认，否则 "make 无需做任何事" 却 scp 找不到文件。
HW_LOCAL="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/hevcdec/v4l2hevc-gl-aarch64"
[ -x "$HW_LOCAL" ] || HW_LOCAL="${HW_LOCAL%/*}/v4l2hevc-aarch64"
NODE=/tmp/tvplay-node.sh          # 盒子上的常驻助手（probe/play/stop/state/disp）
# 兜底模式：仅当盒子探测不出当前显示模式时才用（正常走 node disp 现场探测）
DISP_W=2560; DISP_H=1440; DISP_HZ=60

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96")
SCP=(scp -o BatchMode=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

b64() { printf '%s' "$1" | base64 -w0; }
# VOUT_MODE 从 ~/.env 来，值只可能是 WxH@R/别名这类安全字符；转义一下再带过去，
# 否则宿主机改了偏好（比如 2160p），盒子上的 disp 还在按默认答，两边不一致。
node() {
  local vm=""
  case "${VOUT_MODE:-}" in
    *[!0-9a-zA-Z@x._-]*) VOUT_MODE= ;;
  esac
  [ -n "${VOUT_MODE:-}" ] && vm="VOUT_MODE=$VOUT_MODE "
  # 调参开关必须随命令过 ssh：盒端助手是 heredoc 推过去的脚本，本地 export
  # 传不过去（RENDER=gl 看着给了、盒子还跑 drm，就是这么来的）。
  # 只放白名单字符，避免拼进命令串后变成注入。
  local k v
  for k in RENDER TM TM_TARGET TM_SAT TM_GAIN TM_SRC_PEAK TM_KNEE TMTIME TMDIAG TMNOOP TMDITHER; do
    eval "v=\${$k:-}"
    case "$v" in ''|*[!0-9a-zA-Z._-]*) continue ;; esac
    vm="$vm$k=$v "
  done
  "${SSH[@]}" "$vm$NODE $*" 2>/dev/null
}

# ─────────────────────────── 远端助手脚本 ───────────────────────────
node_push() {
  cat > /tmp/tvplay-node-src.sh <<'EOS'
#!/bin/sh
# tvplay-node-v20  协议版本串：加/改子命令时同步改 ensure_node 里的匹配串
# v20: disp/drm_geo 先问播放器 `$HW -M`（probe+negotiate 唯一真源），sysfs 只兜底；
#      起播放器时 VOUT_MODE 钉成协商结果，壳和屏不再各算一套几何
# v19: 播放器落点 /root（老 /tmp 副本仍兼容）；进程匹配从 v4l2hevc-gl-aarch64 放宽到 [v]4l2hevc
#      （二进制改名成 v4l2hevc-aarch64 后老模式一个都匹配不上；中括号避免 pkill 打到自己的 sh）
# v18: disp 改成现场探测（fb0 applied 模式 → connector → EDID DTD），GEO 不再写死 2560x1440
# tvplay 盒端助手：所有参数 base64 进来，避免 ssh 嵌套引号
# v5: 供流(ffmpeg)与解码(hevcdec)拆成两个进程，中间走命名管道 VFIFO，
#     哑写者常驻占住写端 → seek 只换 ffmpeg，解码器读不到 EOF、DRM 不释放，
#     画面停在最后一帧而不是掉回内核控制台（消除 seek 黑屏/闪文字）
set -u
LOG=/tmp/tvplay.log
STATE=/tmp/tvplay.state
# 播放器路径：/root 优先（重启不丢），老 /tmp 副本兜底（升级过渡期）
for _h in /root/v4l2hevc-aarch64 /tmp/v4l2hevc-gl-aarch64 /tmp/v4l2hevc-aarch64; do
  [ -x "$_h" ] && { HW=$_h; break; }
done
: "${HW:=/root/v4l2hevc-aarch64}"
VFIFO=/tmp/tvplay.vfifo
dec() { printf '%s' "$1" | base64 -d; }
now() { date +%s; }

# ── 显示几何 / 刷新率：一律现场探测，不写死，也不依赖 cmdline ──
# 2026-11-18 拆掉 cmdline 的 video=HDMI-A-1:2560x1440@60e + drm.edid_firmware= 之后，
# 模式由显示器真 EDID 决定。两个坑：
#   ① /sys/class/drm/*/modes、/edid 都是虚拟文件，size=0，不能拿 -s 判存在；
#   ② meson dw-hdmi 的 connector status 会停在 "disconnected"（屏明明在出图），
#      所以不能像旧版那样"只认 status=connected"。
# 探测顺序：fb0 的 applied 模式 → connector mode/modes[0] → 任意有模式表的 connector。
edid_hz() {  # $1=edid 路径 → 首选 DTD 的刷新率 = pixclk/(htotal*vtotal)，pixclk 单位 10kHz
  local f=$1 e pc ha hbl va vbl ht vt
  e=$(od -An -tu1 -j54 -N18 "$f" 2>/dev/null) || return 1
  [ -n "$e" ] || return 1
  set -- $e
  [ $# -ge 18 ] || return 1
  pc=$(( $1 + $2 * 256 ))
  [ "$pc" -gt 0 ] || return 1
  ha=$((  $3 + (($5 & 0xf0) << 4) ));  hbl=$(( $4 + (($5 & 0x0f) << 8) ))
  va=$((  $6 + (($8 & 0xf0) << 4) ));  vbl=$(( $7 + (($8 & 0x0f) << 8) ))
  ht=$((  ha + hbl ));                 vt=$((  va + vbl ))
  [ "$ht" -gt 0 ] && [ "$vt" -gt 0 ] || return 1
  echo $(( (pc * 10000 + ht * vt / 2) / (ht * vt) ))
}
hw_geo() {  # 问播放器自己：`$HW -M` = O_RDONLY 探屏 + 同一份 negotiate 策略
  local m
  [ -x "${HW:-}" ] || return 1
  m=$(VOUT_MODE="${VOUT_MODE:-}" "$HW" -M 2>/dev/null | head -1)
  case "$m" in [0-9]*x[0-9]*@[0-9]*) printf '%s\n' "$m"; return 0;; esac
  return 1
}
drm_geo() {  # 当前生效的输出几何 WxH；取不到返回 1
  local d m
  # ① 播放器二进制说了算：probe+negotiate 只有一份（vout_mode.c），壳不再
  #    另写一套 sysfs 猜测。两套逻辑一旦不一致，DSTGEO 就会和播放器实际
  #    铺的模式错位 —— 画面缩到角上或上下黑边，事后极难归因。
  #    -M 失败（老二进制/没部署/没显示器）才往下走 sysfs 兜底。
  m=$(hw_geo) && { printf '%s\n' "${m%@*}"; return 0; }
  # ② fb0 的 U:WxHp 是内核真正 applied 的模式，最权威
  m=$(sed -n 's/^[A-Za-z]*:\([0-9][0-9]*x[0-9][0-9]*\)[pi].*/\1/p' \
        /sys/class/graphics/fb0/modes 2>/dev/null | head -1)
  [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  # ③ enabled 或 status=connected 的 connector
  for d in /sys/class/drm/card*-*; do
    m=$(head -1 "$d/modes" 2>/dev/null)
    [ -n "$m" ] || continue
    { [ "$(cat "$d/status" 2>/dev/null)"  = connected ] ||
      [ "$(cat "$d/enabled" 2>/dev/null)" = enabled   ]; } || continue
    [ -n "$(cat "$d/mode" 2>/dev/null)" ] && m=$(cat "$d/mode")
    printf '%s\n' "$m"; return 0
  done
  # ④ status 不可信时的最后兜底：任何有模式表的 connector
  for d in /sys/class/drm/card*-*; do
    m=$(head -1 "$d/modes" 2>/dev/null)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  done
  return 1
}
drm_hz() {  # 当前刷新率：cmdline 的 video= 优先（若哪天又写回去），否则 EDID DTD，最后 60
  local d h
  h=$(sed -n 's/.*video=[A-Za-z0-9_-]*:[0-9]*x[0-9]*@\([0-9][0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -1)
  [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }
  for d in /sys/class/drm/card*-*; do
    h=$(edid_hz "$d/edid") && { printf '%s\n' "$h"; return 0; }
  done
  printf '60\n'
}
disp_now() {  # 优先一次调用拿全 "WxH@R"（几何和刷新同源，别一半来自 sysfs）
  local g
  g=$(hw_geo) && { printf '%s\n' "$g"; return 0; }
  printf '%s@%s\n' "$(drm_geo || echo '?')" "$(drm_hz)"
}
# 解码器真身 pid：pgrep -f 会误配到"命令行里带这个名字"的 shell（ssh/bash -c、
# 甚至本脚本自己的等待循环），USR1 打到错进程上就是"按快进毫无反应 19 秒后整链重开"。
# 所以一律按 /proc/PID/exe 校验，并优先用 play 落进 state 的 DECPID。
decpid() {
  local p e
  # 首选 stdin 就是这个管道的那个：一场播放里只该有一个，旧链路的残留解码器
  # 也在跑同一个程序名，但它读的是别的管道/普通管道，认错就会打到死进程上。
  for p in $(pgrep -f '[v]4l2hevc' 2>/dev/null); do
    [ "$(readlink "/proc/$p/fd/0" 2>/dev/null)" = "$VFIFO" ] && { printf '%s\n' "$p"; return 0; }
  done
  for p in $(pgrep -f '[v]4l2hevc' 2>/dev/null); do
    e=$(readlink "/proc/$p/exe" 2>/dev/null)
    case "$e" in */v4l2hevc*) printf '%s\n' "$p"; return 0;; esac
  done
  return 1
}
decpid_ok() {  # $1=pid：还活着且确实是解码器
  [ -n "${1:-}" ] && [ -r "/proc/$1/cmdline" ] || return 1
  case "$(readlink "/proc/$1/exe" 2>/dev/null)" in */v4l2hevc*) return 0;; esac
  return 1
}

case "$1" in
probe)
  URL=$(dec "$2")
  exec ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate \
    -show_entries format=duration -of default=nw=1 "$URL"
  ;;

feed)
  # 只重启"供流"：ffmpeg 解封装 → 命名管道 → 常驻的解码器(play 里起的)。
  # seek 时调用。旧做法是整链重开，ffmpeg 一死解码器就读到 EOF 退出、
  # 释放 DRM，屏幕掉回内核控制台；拆开后解码器看不到 EOF，画面停在最后一帧。
  T=$(dec "$2")
  [ -f "$STATE" ] || exit 1
  . "$STATE" 2>/dev/null || exit 1
  URL=$(dec "$KEYB64")
  pkill -9 -f 'ffmpeg .*-f hevc' 2>/dev/null
  echo "feed: -ss $T" >> "$LOG"
  # 直接起 ffmpeg（不再套 sh -c）：$! 就是 ffmpeg 本体，看门狗要按它采样
  setsid nohup ffmpeg -hide_banner -loglevel warning -re -ss "$T" -i "$URL" \
    -map 0:v:0 -c:v copy -f hevc - > "$VFIFO" 2>>"$LOG" </dev/null &
  _fp=$!
  echo "feed: ffmpeg pid=$_fp" >> "$LOG"
  # 供流看门狗：WebDAV 偶发不回包时 ffmpeg 会僵在 read 上（rchar 一点也不涨），
  # 解码器则在"等 RAP"里无限等 —— 屏幕定格，遥控器怎么按都像"没用"。
  # 6 秒 rchar 不动就重起这一条供流（不碰解码器/DRM，不黑屏）。暂停(T 态)跳过。
  _rt=${FEED_RETRY:-0}
  if [ "$_rt" -lt 3 ]; then
    ( _i=0; _last=0
      while :; do
        sleep 1
        [ -d "/proc/$_fp" ] || break
        _st=$(awk '{print $3}' "/proc/$_fp/stat" 2>/dev/null)
        [ "$_st" = T ] && { _i=0; _last=0; continue; }   # 暂停中，不算卡
        _r=$(sed -n 's/^rchar: //p' "/proc/$_fp/io" 2>/dev/null)
        if [ "$_r" = "$_last" ]; then _i=$((_i+1)); else _i=0; _last=$_r; fi
        if [ "$_i" -ge 6 ]; then
          echo "watchdog: 供流 6s 无数据(rchar=$_r) → 重起 @${T}s（第$(( _rt+1 ))次）" >> "$LOG"
          kill -9 "$_fp" 2>/dev/null
          FEED_RETRY=$((_rt+1)) exec "$0" feed "$2"
        fi
      done ) >/dev/null 2>&1 &
  fi
  exit 0
  ;;

play)
  PLAYER=$(dec "$2"); URL=$(dec "$3"); START=$(dec "$4")
  TRACK=$(dec "$5");  AUDIO=$(dec "$6"); FPS=$(dec "$7")
  # 显示器输出几何 WxH：调用方没给就现场探测（不写死 2560x1440）
  GEO=$(dec "${8:-}"); [ -n "$GEO" ] || GEO=$(drm_geo) || GEO=1920x1080

  # 清场
  pkill -9 -f '[v]4l2hevc' 2>/dev/null
  pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
  pkill -9 -f 'mpv .*--no-video'    2>/dev/null
  pkill -9 -f 'sleep 999999999'     2>/dev/null   # 上次的管道哑写者
  pkill -9 -x mpv                   2>/dev/null
  rm -f "$VFIFO"
  sleep 0.4

  # 状态文件可 source（KEY 用 base64，值里没有引号/空格）
  # 全部播放参数都落进去：遥控器 seek 时要靠它原样重启（key 分支）
  printf 'START=%s\nOFF=%s\nPAUSE_AT=0\nPLAYER=%s\nTRACK=%s\nAUDIO=%s\nFPS=%s\nGEO=%s\nKEYB64=%s\n' \
    "$(now)" "$START" "$PLAYER" "$TRACK" "$AUDIO" "$FPS" "$GEO" \
    "$(printf '%s' "$URL" | base64 -w0)" > "$STATE"
  : > "$LOG"
  # 遥控器守护：按键 → 本脚本 key 分支
  # 必须显式给 RC_NODE：rcinputd 默认认 /root/play.sh（老助手），那样按键会走
  # 老链路的 state（/tmp/play.state 根本不存在）→ "遥控器：没有在放的片子"，
  # 表现就是按方向键毫无反应。另外先掐掉旧守护：旧版 grab 着设备，新实例
  # EVIOCGRAB 会 EBUSY 直接退出，于是"永远是那个指错路的进程"。
  pkill -9 -f 'rcinputd-aarch64' 2>/dev/null
  sleep 0.1
  _rc=/tmp/rcinputd-aarch64
  [ -x /root/rcinputd-aarch64 ] && _rc=/root/rcinputd-aarch64
  RC_NODE=/tmp/tvplay-node.sh setsid nohup "$_rc" >>/tmp/tvplay-rc.log 2>&1 </dev/null &
  VOL=$(cat /tmp/tvplay.vol 2>/dev/null || echo 100)

  if [ "$PLAYER" = mpv ]; then
    # 旧路径：整片交给 mpv（H.264 等非 HEVC）
    setsid nohup /usr/bin/mpv --vo=gpu --gpu-context=drm --hwdec=no \
      --vd-lavc-threads=4 --ao=alsa --audio-device=alsa/hw:0,0 \
      --audio-channels=stereo --no-osc --osd-level=0 --no-resume-playback \
      --aid="$TRACK" --start="$START" \
      "$URL" >>"$LOG" 2>&1 </dev/null &
    exit 0
  fi

  # ── HEVC 硬解路径 ──
  # 视频: ffmpeg 解封装 + -re 按片源节拍供流 → hevcdec 零拷贝解 → GLES3 上屏
  #   -re 必须：hevcdec 的 GL 输出路径没有 vblank 节拍器（FPS 对 GLPLAY 无效），
  #             不靠 -re 就会以解码速度播放（4K 实测快 15%，1080p 会飞）
  #   音频交给 mpv：ffmpeg 的 -f alsa 在这块板子上缓冲太浅（8s 15 次 xrun）
  export START LOG HW
  if [ "$AUDIO" = 1 ]; then
    rm -f /tmp/mpv.sock
    setsid nohup /usr/bin/mpv --no-config --no-video --vo=null \
      --ao=alsa --audio-device=alsa/hw:0,0 --audio-channels=stereo \
      --volume="$VOL" --input-ipc-server=/tmp/mpv.sock \
      --cache=yes --cache-secs=20 --aid="$TRACK" --start="$START" \
      "$URL" >>"$LOG" 2>&1 </dev/null &
  fi
  # NOWRITE=1 必须：否则 hevcdec 写 /tmp/out.yuv，4K 从 24fps 掉到 10fps
  # DSTGEO 只对 DRM 平面路径生效（GL 路径按 connector modes[0] 铺屏）
  #
  # 供流与解码拆成两个进程，中间用命名管道：
  #   旧写法 'ffmpeg | HW' 是一条普通管道，ffmpeg 一死(seek 重启) 解码器立刻
  #   读到 EOF 退出、释放 DRM，屏幕掉回内核控制台 —— seek 的黑屏+闪文字就是这么来的。
  #   现在由哑写者(exec 9<>fifo)常驻占住写端，解码器永远等不到 EOF，全程不退；
  #   seek 只重启 ffmpeg(feed 子命令)，最后一帧一直留在屏上。
  rm -f "$VFIFO"
  mkfifo "$VFIFO" || exit 1
  # 哑写者：O_RDWR 打开管道后 exec 成 sleep —— 同一个进程，fd 9 一直占着写端
  setsid nohup sh -c "exec 9<>'$VFIFO'; exec sleep 999999999" \
    >/dev/null 2>&1 </dev/null &
  # VOUT_MODE 钉成已协商出的几何：DSTGEO（壳画的框）和播放器实际切/沿用的模式
  # 同源，屏幕不支持时 vout_open 会打「降级 → …」并照常播，不会静默换分辨率。
  # TM/TM_*/RENDER 一并透传：HDR 片源在盒子上 CPU 色调映射极吃 CPU（4K 一行
  # tonemap 比解码本身贵一个量级），调参/关 TM 对比必须能从壳里直接给。
  HW="$HW" VFIFO="$VFIFO" GEO="$GEO" LOG="$LOG" \
    TM="${TM:-}" TM_TARGET="${TM_TARGET:-}" TM_SAT="${TM_SAT:-}" \
    TM_GAIN="${TM_GAIN:-}" TM_SRC_PEAK="${TM_SRC_PEAK:-}" TM_KNEE="${TM_KNEE:-}" \
    TMTIME="${TMTIME:-}" TMDIAG="${TMDIAG:-}" \
    RENDER="${RENDER:-}" \
    VOUT_MODE="${VOUT_MODE:-$GEO}" setsid nohup sh -c \
    'DSTGEO="$GEO+0+0" NOWRITE=1 PLAY=1 GLPLAY=1 "$HW" - < "$VFIFO" 2>>"$LOG"' \
    >>"$LOG" 2>&1 </dev/null &
  sleep 0.25
  # 把解码器 pid 落到 state：遥控器 seek 靠它精确打信号（见 decpid 注释）
  _dp=$(decpid)
  if [ -n "$_dp" ]; then
    sed -i '/^DECPID=/d' "$STATE"
    echo "DECPID=$_dp" >> "$STATE"
  fi
  "$0" feed "$(printf '%s' "$START" | base64 -w0)"
  exit 0
  ;;

stop)
  pkill -9 -f 'rcinputd-aarch64'    2>/dev/null
  pkill -9 -f '[v]4l2hevc' 2>/dev/null
  pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
  pkill -9 -f 'mpv .*--no-video'    2>/dev/null
  pkill -9 -f 'sleep 999999999'     2>/dev/null   # 管道哑写者
  pkill -9 -x mpv                   2>/dev/null
  rm -f "$VFIFO"
  chvt 1 2>/dev/null
  exit 0
  ;;

state)
  [ -f "$STATE" ] || exit 1
  . "$STATE" 2>/dev/null || exit 1
  PA=${PAUSE_AT:-0}; [ "$PA" -gt 0 ] 2>/dev/null || PA=0
  if [ "$PA" -gt 0 ]; then el=$(( PA - START + OFF )); else el=$(( $(now) - START + OFF )); fi
  n=$(pgrep -f '[v]4l2hevc|mpv' 2>/dev/null | wc -l)
  printf '%s %s %s %s %s\n' "$el" "${PLAYER:-?}" "${n:-0}" "${KEYB64:-}" \
    "$([ "$PA" -gt 0 ] && echo 1 || echo 0)"
  ;;

key)
  # 遥控器动作（rcinputd 调用）：toggle/fwd/back/fwdmore/backmore/volup/voldn/mute/quit
  ACT=${2:-}
  [ -f "$STATE" ] || exit 1
  . "$STATE" 2>/dev/null || exit 1
  URL=$(printf '%s' "${KEYB64:-}" | base64 -d 2>/dev/null)
  PA=${PAUSE_AT:-0}; [ "$PA" -gt 0 ] 2>/dev/null || PA=0
  b64() { printf '%s' "$1" | base64 -w0; }
  cur() {  # 当前播到第几秒（暂停时时间冻结）
    if [ "$PA" -gt 0 ]; then echo $(( PA - START + OFF )); else echo $(( $(now) - START + OFF )); fi
  }
  save_pa() { sed -i "s/^PAUSE_AT=.*/PAUSE_AT=$1/" "$STATE"; }
  mpvctl() {  # mpv IPC：盒子上只有 perl 能做 unix socket
    printf '%s\n' "$1" | perl -MIO::Socket::UNIX -e '
      my $s = IO::Socket::UNIX->new(Peer => "/tmp/mpv.sock") or exit 7;
      my $l = <STDIN>; print $s $l; $s->close;' 2>/dev/null
    _rc=$?
    [ "$_rc" -ne 0 ] && echo "key: mpvctl rc=$_rc 失败：$1" >> "$LOG"
    return $_rc
  }
  audio_start() {  # $1=起点秒：重开音频进程（IPC 死掉时的自愈路径）
    # 实测连做几次 seek 后 mpv 的 IPC 监听会拒连（ECONNREFUSED），此后 pause/
    # seek/volume 全部静默失效 —— 声音留在原地，画面已经跳走，几十秒后就是
    # "画面在前进、声音还是老地方"。没有 IPC 就只能重开 mpv 并给它 --start。
    pkill -9 -f 'mpv .*--no-video' 2>/dev/null
    sleep 0.2
    rm -f /tmp/mpv.sock
    _v=$(cat /tmp/tvplay.vol 2>/dev/null || echo 100)
    setsid nohup /usr/bin/mpv --no-config --no-video --vo=null \
      --ao=alsa --audio-device=alsa/hw:0,0 --audio-channels=stereo \
      --volume="$_v" --input-ipc-server=/tmp/mpv.sock \
      --cache=yes --cache-secs=20 --aid="${TRACK:-1}" --start="$1" \
      "$URL" >>"$LOG" 2>&1 </dev/null &
    echo "key: 音频进程重开 @$1s（IPC 不可用）" >> "$LOG"
  }
  restart() {  # $1=起点秒：seek 只能重启管线（码流是 ffmpeg -re 现推的）
    rmdir /tmp/tvplay.seek.lock 2>/dev/null
    pkill -9 -f 'rcinputd-aarch64'    2>/dev/null
    pkill -9 -f '[v]4l2hevc' 2>/dev/null
    pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
    pkill -9 -f 'mpv .*--no-video'    2>/dev/null
    sleep 0.3
    exec "$0" play "$(b64 "$PLAYER")" "$(b64 "$URL")" "$(b64 "$1")" \
      "$(b64 "${TRACK:-1}")" "$(b64 "${AUDIO:-1}")" "$(b64 "${FPS:-0}")" \
      "$(b64 "${GEO:-$(drm_geo || echo 1920x1080)}")"
  }
  softseek() {  # $1=目标秒：重建 V4L2 会话，DRM/控制台全程不释放
    _t=$1
    # 串行化：seek 要重建 V4L2 会话（100~600ms）。连按方向键时下一个 seek 若
    # 同时进行，两个重建互相踩，且 cur() 还读着没更新的 START/OFF ——
    # 实测连按 3 次只净进 3 秒，用户看到的就是"快进没有用"。因此：
    #   ① 拿到锁再动；② 先把目标乐观写进 state，后来的按键从目标继续加。
    _lk=/tmp/tvplay.seek.lock
    _w=0
    while ! mkdir "$_lk" 2>/dev/null; do
      _w=$((_w+1))
      if [ "$_w" -gt 100 ]; then rm -rf "$_lk"; fi   # 10s 抢不到 = 上把卡死
      sleep 0.1
    done
    echo "softseek → $_t (暂停=$PA)$([ "$_w" -gt 0 ] && echo " 排队$((_w*100))ms")"
    echo "key: softseek $_t (等锁 $((_w*100))ms)" >> "$LOG"
    START=$(now); OFF=$_t
    sed -i "s/^START=.*/START=$START/; s/^OFF=.*/OFF=$OFF/" "$STATE" 2>/dev/null
    # 1. 只冻声音；画面留屏（解码器不停，DRM master 一直是我们的）
    #    IPC 连不上就重开音频进程：mpv 的 --input-ipc-server 在一段时间/几次
    #    连接后会拒连，命令全丢，声音和画面就此脱节（差 70 秒那种）。
    if mpvctl '{"command":["set_property","pause",true]}'; then
      # 2. 声音先在暂停态 seek 到位：mpv 找索引+填缓存 ~600ms，
      #    正好和下面重建会话重叠，等首帧出来它已经就位。
      mpvctl "{\"command\":[\"seek\",$_t,\"absolute\"]}"
      _audio_new=0
    else
      audio_start "$_t"
      _audio_new=1
    fi
    # 3. 掐旧供流（残留字节由解码器自己在重建时读掉，不用 cat 排空）
    pkill -9 -f 'ffmpeg .*-f hevc' 2>/dev/null
    # 4. 让解码器重建 V4L2 会话：meson-vdec 不能在同一会话里接新码流
    #    （内核会 Unrecognized dec_status 0x0F → Aborting session），
    #    必须重开 /dev/video0；DRM/GL 不动，所以不黑屏。
    # 4~6. 重建会话 + 起新供流 + 等首帧；meson-vdec 偶发重建后仍
    #      "Aborting decoding session"，那就再重建一次；两次不行退回整链重开
    #      （会闪一下，但保证出画，不会停在没有画面的黑屏上）。
    _att=1
    while : ; do
      _dpid=${DECPID:-}
      decpid_ok "$_dpid" || _dpid=$(decpid)
      [ -z "$_dpid" ] && { echo "key: 解码器已退出，整链重开" >> "$LOG"; restart "$_t"; }
      echo "key: 目标解码器 pid=$_dpid" >> "$LOG"
      pkill -CONT -f '[v]4l2hevc' 2>/dev/null   # 暂停态下也能响应信号
      _n=$(wc -c < "$LOG" 2>/dev/null || echo 0)
      kill -USR1 "$_dpid" 2>/dev/null
      _i=0; _next=20
      while [ "$_i" -lt 150 ]; do
        sleep 0.02
        tail -c +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: ready' && break
        # 补发：解码器若正卡在"等 RAP"的读重试里，SIGUSR1 的 EINTR 会被那个
        # 内层循环吞掉（实测连按第二次能丢 10s），每 400ms 再敲一次，让它
        # 在真正的读/poll 边界上收到。事务中间收到不算失败、也不吃预算。
        if [ "$_i" -ge "$_next" ]; then
          kill -USR1 "$_dpid" 2>/dev/null; _next=$((_i+20))
        fi
        _i=$((_i+1))
      done
      echo "key: 会话重建 $((_i*20))ms (第${_att}次)" >> "$LOG"
      "$0" feed "$(b64 "$_t")"
      _j=0
      while [ "$_j" -lt 250 ]; do
        sleep 0.02
        tail -c +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: first frame' && break
        decpid_ok "$_dpid" || break                      # 解码器死了别等满超时
        _j=$((_j+1))
      done
      echo "key: 首帧就绪 $((_j*20))ms (第${_att}次)" >> "$LOG"
      tail -c +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: first frame' && break
      _att=$((_att+1))
      [ "$_att" -gt 2 ] && { echo "key: 重建两次未出帧，退回 restart" >> "$LOG"; restart "$_t"; }
      pkill -9 -f 'ffmpeg .*-f hevc' 2>/dev/null
      sleep 0.15
    done
    sleep 0.04                      # 让这一帧真正翻上去（flip 排队）
    # 7. 计时以"真的开始出画"为准
    START=$(now); OFF=$_t
    sed -i "s/^START=.*/START=$START/; s/^OFF=.*/OFF=$OFF/" "$STATE"
    # 8. 按原状态收尾
    if [ "$PA" -gt 0 ]; then
      save_pa "$(now)"
      pkill -STOP -f '[v]4l2hevc' 2>/dev/null
      pkill -STOP -f 'ffmpeg .*-f hevc'    2>/dev/null
      echo "softseek: 保持暂停 @${_t}s"
    else
      [ "${_audio_new:-0}" = 1 ] || mpvctl '{"command":["set_property","pause",false]}'
      echo "softseek: 续播 @${_t}s"
    fi
    rmdir "$_lk" 2>/dev/null
  }

  case "$ACT" in
  toggle|pause|resume)
    if [ "$PA" -gt 0 ]; then
      save_pa 0
      pkill -CONT -f '[v]4l2hevc' 2>/dev/null
      pkill -CONT -f 'ffmpeg .*-f hevc'    2>/dev/null
      mpvctl '{"command":["set_property","pause",false]}'
      echo "resume $(cur)"
    else
      save_pa "$(now)"
      pkill -STOP -f '[v]4l2hevc' 2>/dev/null
      pkill -STOP -f 'ffmpeg .*-f hevc'    2>/dev/null
      mpvctl '{"command":["set_property","pause",true]}'
      echo "pause $(cur)"
    fi ;;
  fwd|back|fwdmore|backmore)
    case "$ACT" in
      fwd) d=30;; back) d=-10;; fwdmore) d=600;; backmore) d=-300;;
    esac
    t=$(( $(cur) + d )); [ "$t" -lt 0 ] && t=0
    echo "$ACT → $t"
    # 有常驻解码器 + 命名管道时走软 seek（无黑屏）；否则退回整链重开
    if [ -p "$VFIFO" ] && { decpid_ok "${DECPID:-}" || decpid >/dev/null; }; then
      softseek "$t"
    else
      restart "$t"
    fi ;;
  volup|voldn|mute)
    V=$(cat /tmp/tvplay.vol 2>/dev/null || echo 100)
    VP=$(cat /tmp/tvplay.vol.prev 2>/dev/null || echo 100)
    case "$ACT" in
      volup) V=$((V+5));;
      voldn) V=$((V-5));;
      mute) # 静音键是开关：0 → 还原上次音量（旧做法一律置 0，按一下就再也
            # 回不来，只能靠 + 键一点点加；而且那次"快进顺带静音"就是它）
            if [ "$V" -gt 0 ]; then
              printf '%s\n' "$V" > /tmp/tvplay.vol.prev
              V=0
            else
              V=$VP; [ "$V" -gt 0 ] || V=100
            fi ;;
    esac
    [ "$V" -lt 0 ] && V=0; [ "$V" -gt 150 ] && V=150
    printf '%s\n' "$V" > /tmp/tvplay.vol
    mpvctl "{\"command\":[\"set_property\",\"volume\",$V]}"
    echo "vol $V" ;;
  quit)
    exec "$0" stop ;;
  esac
  exit 0
  ;;

disp)
  # 当前显示模式 WxH@Hz：现场探测（见 drm_geo/drm_hz）。
  # 不再"只认 status=connected"，也不再从 cmdline 的 video= 里抠刷新率——
  # 那条 video= 已从 uEnv.txt 移除，旧写法会固定吐 "?@60"。
  disp_now
  ;;

alive)
  pgrep -f '[v]4l2hevc|mpv' 2>/dev/null | wc -l
  ;;

log)
  tail -"${2:-8}" "$LOG" 2>/dev/null
  ;;
esac
EOS
  "${SCP[@]}" /tmp/tvplay-node-src.sh root@"$X96":"$NODE" >/dev/null && \
  "${SSH[@]}" "chmod +x $NODE" >/dev/null
}

# 版本不符也重推：助手常驻 /tmp，只判 -x 会让旧协议一直生效（踩过：disp 子命令拿不到模式）
ensure_node() { "${SSH[@]}" "test -x $NODE && grep -q tvplay-node-v20 $NODE" 2>/dev/null || \
  node_push || { echo "✘ 无法部署盒端助手" >&2; return 1; }; }

# ─────────────────────────── 索引 ───────────────────────────
davlist() { # $1=dir → "size|解码路径" 每行一条(目录 size 为空)
  curl -s -m 40 -u "$U:$P" -X PROPFIND -H 'Depth: 1' \
    -H 'Content-Type: text/xml' \
    --data-binary '<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/></a:prop></a:propfind>' \
    "$BASE$1" 2>/dev/null \
  | python3 -c 'import sys,re,urllib.parse
base=sys.argv[1].rstrip("/")
raw=sys.stdin.read()
for blk in raw.split("<D:response>")[1:]:
    h=re.search(r"<D:href>([^<]+)",blk)
    if not h: continue
    path=urllib.parse.unquote(h.group(1))
    if path.rstrip("/")==base: continue
    sz=re.search(r"<D:getcontentlength>([0-9]+)",blk)
    isdir="<D:collection>" in blk
    print("%s|%s"%(("" if isdir else (sz.group(1) if sz else "0")),path))' "$1"
}

build_index() { # BFS 最多 3 层
  : > "$IDX"
  local q=("$ROOT") d=0 sz p
  while [ ${#q[@]} -gt 0 ] && [ $d -lt 3 ]; do
    local nq=()
    for cur in "${q[@]}"; do
      while IFS='|' read -r sz p; do
        [ -z "$p" ] && continue
        if [ -z "$sz" ]; then
          case "$(basename "$p")" in .*) continue;; esac
          nq+=("$p")
        elif [[ "${p,,}" =~ $VID ]]; then
          printf '%s|%s\n' "$sz" "$p" >> "$IDX"
          printf '  + %6.1fG  %s\n' "$(awk -v s="$sz" 'BEGIN{print s/1073741824}')" "$(basename "$p")" >&2
        fi
      done < <(davlist "$cur")
    done
    q=("${nq[@]}"); d=$((d+1))
    echo "  ...第 $d 层完成, 累计 $(wc -l < "$IDX") 部" >&2
  done
  sort -t'|' -k1,1nr "$IDX" -o "$IDX"
  echo "索引完成: $(wc -l < "$IDX") 部 → $IDX" >&2
}

# ─────────────────────────── 部署 ───────────────────────────
deploy_hw() {
  if [ ! -x "$HW_LOCAL" ]; then
    echo "本地产物不存在，交叉编译…" >&2
    ( cd "$(dirname "$HW_LOCAL")" && make gl CROSS=1 ) || return 1
  fi
  "${SCP[@]}" "$HW_LOCAL" root@"$X96":"$HW_BIN" && \
  "${SSH[@]}" "chmod +x $HW_BIN; \
    rm -f /tmp/v4l2hevc-gl-aarch64 /tmp/v4l2hevc-aarch64" && \
  echo "已部署 $HW_BIN（已清 /tmp 老副本）"
}

# ─────────────────────────── 播放 ───────────────────────────
play() { # $1=dav path $2=强制起点(可空)
  local path="$1" start="${2:-}" track="${TRACK:-1}"
  local url="$AUTH$path" info codec w h fps dur player saved

  ensure_node || return 1

  echo "▶ 探显示器…"
  local dsc dmode dhz dfb=0
  dsc=$(node disp 2>/dev/null); dhz="${dsc##*@}"; dmode="${dsc%@*}"
  case "$dmode" in
    [0-9]*x[0-9]*) ;;                                     # 盒子现场探测成功（屏自己报的）
    *) dmode="${DISP_W}x${DISP_H}"; dhz="$DISP_HZ"; dfb=1
       echo "  ⚠ 取不到盒子显示模式，按兜底 ${dmode}@${dhz} 播" >&2;;
  esac
  local DW="${dmode%x*}" DH="${dmode#*x}"

  echo "▶ 探片源…"
  info=$(node probe "$(b64 "$url")" \
    | awk -F= '/^codec_name=/{c=$2} /^width=/{w=$2} /^height=/{h=$2}
        /^r_frame_rate=/{split($2,a,"/"); f=a[2]?a[1]/a[2]:$2}
        /^duration=/{d=$2}
        END{ if(c=="") exit 1; printf "%s %s %s %.3f %.0f", c,w,h,f,d }')

  if [ -z "$info" ]; then
    echo "  ⚠ 探测失败，按 mpv 处理" >&2
    info="unknown 0 0 0 0"
  fi
  read -r codec w h fps dur <<<"$info"

  # 分流：HEVC 且 ≤30fps 走 hevcdec（更高帧率硬解+GL 跟不上）
  if [ "$codec" = hevc ] && awk -v f="$fps" 'BEGIN{exit !(f>0 && f<=30)}'; then
    player=hw
  else
    player=mpv
  fi

  echo "  片源: $codec ${w}x${h} ${fps}fps$([ "${dur:-0}" -gt 0 ] && awk -v d="$dur" 'BEGIN{printf "  %.0f分钟", d/60}')"
  echo "  播放器: $([ "$player" = hw ] && echo 'hevcdec 硬解 (GLES3)' || echo 'mpv')"
  echo "  输出: ${DW}x${DH}@${dhz}（显示器 $([ "$dfb" = 1 ] && echo '兜底值⚠' || echo 现场探测)）$(
    awk -v sw="$w" -v sh="$h" -v dw="$DW" -v dh="$DH" 'BEGIN{
      if (sw<=0 || sh<=0) exit;
      if (SCALE_MODE=="crop") { printf "  缩放: 裁切铺满 %dx%d", dw, dh; exit }
      as=sw/sh; ad=dw/dh;
      if (as>ad) { dW=dw; dH=int(dw/as+0.5) } else { dH=dh; dW=int(dh*as+0.5) }
      printf "  缩放: 等比 %dx%d → %dx%d", sw, sh, dW, dH;
      if (dH<dh) printf " + 上下黑边各 %d", int((dh-dH)/2);
      if (dW<dw) printf " + 左右黑边各 %d", int((dw-dW)/2);
      if (sw<dw) printf " (放大)"; else if (sw>dw) printf " (缩小)";
    }' SCALE_MODE="$([ "$player" = hw ] && echo fit)")"

  # 不做续播：每次开播一律从 0 开始（-f 已无意义，保留兼容）
  [ -z "$start" ] && start=0

  if [ "$player" = hw ]; then
    "${SSH[@]}" "test -x $HW_BIN" 2>/dev/null || { echo "  部署 hevcdec…"; deploy_hw || return 1; }
  fi

  node play "$(b64 "$player")" "$(b64 "$url")" "$(b64 "$start")" \
       "$(b64 "$track")" "$(b64 "$([ "$player" = hw ] && echo "${AUDIO_ON:-1}" || echo 0)")" \
       "$(b64 "$fps")" "$(b64 "${DW}x${DH}")" >/dev/null

  sleep 2
  local n
  n=$(node alive || echo 0)
  if [ "${n:-0}" -gt 0 ]; then
    echo "✔ 已在显示器上播放 (盒端播放器进程数=$n)"
    local scr
    scr=$(node log 40 2>/dev/null | grep -o 'GLOUT: 屏幕 [0-9]*x[0-9]*@[0-9]*' | tail -1)
    [ -n "$scr" ] && echo "  ${scr#GLOUT: }（hevcdec 实际选中的模式）"
    echo "  进度: $0 -t    停止: $0 -s"
  else
    echo "✘ 启动失败，盒端日志:"
    node log 10
    return 1
  fi
}

stop_play() {
  local line el
  ensure_node >/dev/null
  line=$(node state)
  if [ -n "$line" ]; then
    el=$(echo "$line" | cut -d' ' -f1)
    local key
    key=$(echo "$line" | cut -d' ' -f4 | base64 -d 2>/dev/null)
    # 不记录进度：下次开播一律从 0 开始
  fi
  node stop >/dev/null
  echo "已停止"
}

status_play() {
  local line el player n key
  ensure_node >/dev/null
  line=$(node state)
  if [ -z "$line" ]; then echo "当前没有在播"; return; fi
  el=$(echo "$line" | cut -d' ' -f1)
  player=$(echo "$line" | cut -d' ' -f2)
  n=$(echo "$line" | cut -d' ' -f3)
  key=$(echo "$line" | cut -d' ' -f4 | base64 -d 2>/dev/null)
  if [ "${n:-0}" -gt 0 ]; then
    echo "播放中[$player]: $((el/60))分$((el%60))秒（墙钟推算）  进程数=$n"
    echo "  $(basename "${key:-?}")"
  else
    echo "已结束或未启动（上次记录 $((el/60))分$((el%60))秒）"
  fi
  echo "--- 日志尾 ---"
  node log 3
}

# ─────────────────────────── 主流程 ───────────────────────────
TRACK=1; AUDIO_ON=1; FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a) TRACK="${2:-1}"; shift 2;;
    -f) FORCE=0; shift;;   # 兼容保留：现在一律从 0 开始
    --no-audio) AUDIO_ON=0; shift;;
    *) break;;
  esac
done

case "${1:--l}" in
  -i) build_index; exit 0;;
  -d) deploy_hw; exit $?;;
  -p) shift; play "$1" "$FORCE"; exit $?;;
  -s) stop_play; exit 0;;
  -t) status_play; exit 0;;
esac

[ -s "$IDX" ] || { echo "首次使用，建索引..."; build_index; }
kw="$*"; kw="${kw#-l}"; kw="${kw# }"
mapfile -t hits < <(while IFS='|' read -r sz p; do
    if [ -z "$kw" ] || echo "$(basename "$p")" | grep -qiE "$kw"; then printf '%s|%s\n' "$sz" "$p"; fi
  done < "$IDX")
if [ ${#hits[@]} -eq 0 ]; then echo "没找到匹配「$kw」"; echo "试试: $0 -l | head -40"; exit 1; fi
i=0
for h in "${hits[@]}"; do i=$((i+1)); printf '%2d) %5.1fG  %s\n' "$i" "$(echo "$h" | cut -d'|' -f1 | awk '{print $1/1073741824}')" "$(echo "$h" | cut -d'|' -f2-)"; done
[ "$1" = "-l" ] && exit 0
if [ ${#hits[@]} -eq 1 ]; then sel=1; else read -rp "选第几个(回车=1)? " sel; sel="${sel:-1}"; fi
play "$(echo "${hits[$((sel-1))]}" | cut -d'|' -f2-)" "$FORCE"
