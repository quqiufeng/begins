#!/bin/bash
# tvplay.sh — 从极空间 NAS(WebDAV) 取片，在 X96 盒子上全屏播放到显示器
#
# 播放器按片源分流（2026-11-16 实测）：
#   HEVC ≤30fps  → hevcdec 硬解 + EGL/GLES3 上屏（4K 不转码）
#   其他          → mpv（沿用旧配置）
#
# 输出分辨率一律按显示器来（BenQ PD2500Q，2560x1440@60）：
#   盒子 cmdline 锁 video=HDMI-A-1:2560x1440@60e + drm.edid_firmware=...benq-pd2500q.bin，
#   所以 connector 的 modes[0] 就是 2560x1440，GL 输出 / DRM 平面都按这块屏铺。
#   片源比屏大或比屏小都等比缩放 + 居中黑边（不改片源、不转码）。
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

HW_BIN=/tmp/v4l2hevc-gl-aarch64
HW_LOCAL="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/hevcdec/v4l2hevc-gl-aarch64"
NODE=/tmp/tvplay-node.sh          # 盒子上的常驻助手（probe/play/stop/state/disp）
# 显示器（BenQ PD2500Q）默认输出模式；盒子取不到当前模式时用它兜底
DISP_W=2560; DISP_H=1440; DISP_HZ=60

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96")
SCP=(scp -o BatchMode=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

b64() { printf '%s' "$1" | base64 -w0; }
node() { "${SSH[@]}" "$NODE $*" 2>/dev/null; }

# ─────────────────────────── 远端助手脚本 ───────────────────────────
node_push() {
  cat > /tmp/tvplay-node-src.sh <<'EOS'
#!/bin/sh
# tvplay-node-v10  协议版本串：加/改子命令时同步改 ensure_node 里的匹配串
# tvplay 盒端助手：所有参数 base64 进来，避免 ssh 嵌套引号
# v5: 供流(ffmpeg)与解码(hevcdec)拆成两个进程，中间走命名管道 VFIFO，
#     哑写者常驻占住写端 → seek 只换 ffmpeg，解码器读不到 EOF、DRM 不释放，
#     画面停在最后一帧而不是掉回内核控制台（消除 seek 黑屏/闪文字）
set -u
LOG=/tmp/tvplay.log
STATE=/tmp/tvplay.state
HW=/tmp/v4l2hevc-gl-aarch64
VFIFO=/tmp/tvplay.vfifo
dec() { printf '%s' "$1" | base64 -d; }
now() { date +%s; }

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
  URL="$URL" T="$T" VFIFO="$VFIFO" LOG="$LOG" setsid nohup sh -c \
    'ffmpeg -hide_banner -loglevel warning -re -ss "$T" -i "$URL" \
       -map 0:v:0 -c:v copy -f hevc - > "$VFIFO" 2>>"$LOG"' \
    >>"$LOG" 2>&1 </dev/null &
  exit 0
  ;;

play)
  PLAYER=$(dec "$2"); URL=$(dec "$3"); START=$(dec "$4")
  TRACK=$(dec "$5");  AUDIO=$(dec "$6"); FPS=$(dec "$7")
  GEO=$(dec "${8:-}"); [ -n "$GEO" ] || GEO=2560x1440   # 显示器输出几何 WxH

  # 清场
  pkill -9 -f 'v4l2hevc-gl-aarch64' 2>/dev/null
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
  HW="$HW" VFIFO="$VFIFO" GEO="$GEO" LOG="$LOG" setsid nohup sh -c \
    'DSTGEO="$GEO+0+0" NOWRITE=1 PLAY=1 GLPLAY=1 "$HW" - < "$VFIFO" 2>>"$LOG"' \
    >>"$LOG" 2>&1 </dev/null &
  sleep 0.2
  "$0" feed "$(printf '%s' "$START" | base64 -w0)"
  exit 0
  ;;

stop)
  pkill -9 -f 'rcinputd-aarch64'    2>/dev/null
  pkill -9 -f 'v4l2hevc-gl-aarch64' 2>/dev/null
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
  n=$(pgrep -f 'v4l2hevc-gl-aarch64|mpv' 2>/dev/null | wc -l)
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
      my $s = IO::Socket::UNIX->new(Peer => "/tmp/mpv.sock") or exit 1;
      my $l = <STDIN>; print $s $l; $s->close;' 2>/dev/null
  }
  restart() {  # $1=起点秒：seek 只能重启管线（码流是 ffmpeg -re 现推的）
    pkill -9 -f 'rcinputd-aarch64'    2>/dev/null
    pkill -9 -f 'v4l2hevc-gl-aarch64' 2>/dev/null
    pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
    pkill -9 -f 'mpv .*--no-video'    2>/dev/null
    sleep 0.3
    exec "$0" play "$(b64 "$PLAYER")" "$(b64 "$URL")" "$(b64 "$1")" \
      "$(b64 "${TRACK:-1}")" "$(b64 "${AUDIO:-1}")" "$(b64 "${FPS:-0}")" \
      "$(b64 "${GEO:-2560x1440}")"
  }
  softseek() {  # $1=目标秒：重建 V4L2 会话，DRM/控制台全程不释放
    _t=$1
    echo "softseek → $_t (暂停=$PA)"
    echo "key: softseek $_t" >> "$LOG"
    # 1. 只冻声音；画面留屏（解码器不停，DRM master 一直是我们的）
    mpvctl '{"command":["set_property","pause",true]}'
    # 2. 声音先在暂停态 seek 到位：mpv 找索引+填缓存 ~600ms，
    #    正好和下面重建会话重叠，等首帧出来它已经就位。
    mpvctl "{\"command\":[\"seek\",$_t,\"absolute\"]}"
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
      _dpid=$(pgrep -f 'v4l2hevc-gl-aarch64' | head -1)
      [ -z "$_dpid" ] && { echo "key: 解码器已退出，整链重开" >> "$LOG"; restart "$_t"; }
      pkill -CONT -f 'v4l2hevc-gl-aarch64' 2>/dev/null   # 暂停态下也能响应信号
      _n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
      kill -USR1 "$_dpid" 2>/dev/null
      _i=0
      while [ "$_i" -lt 150 ]; do
        sleep 0.02
        tail -n +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: ready' && break
        _i=$((_i+1))
      done
      echo "key: 会话重建 $((_i*20))ms (第${_att}次)" >> "$LOG"
      "$0" feed "$(b64 "$_t")"
      _j=0
      while [ "$_j" -lt 150 ]; do
        sleep 0.02
        tail -n +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: first frame' && break
        pgrep -f 'v4l2hevc-gl-aarch64' >/dev/null 2>&1 || break   # 解码器死了别等满超时
        _j=$((_j+1))
      done
      echo "key: 首帧就绪 $((_j*20))ms (第${_att}次)" >> "$LOG"
      tail -n +"$((_n+1))" "$LOG" 2>/dev/null | grep -q 'REINIT: first frame' && break
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
      pkill -STOP -f 'v4l2hevc-gl-aarch64' 2>/dev/null
      pkill -STOP -f 'ffmpeg .*-f hevc'    2>/dev/null
      echo "softseek: 保持暂停 @${_t}s"
    else
      mpvctl '{"command":["set_property","pause",false]}'
      echo "softseek: 续播 @${_t}s"
    fi
  }

  case "$ACT" in
  toggle|pause|resume)
    if [ "$PA" -gt 0 ]; then
      save_pa 0
      pkill -CONT -f 'v4l2hevc-gl-aarch64' 2>/dev/null
      pkill -CONT -f 'ffmpeg .*-f hevc'    2>/dev/null
      mpvctl '{"command":["set_property","pause",false]}'
      echo "resume $(cur)"
    else
      save_pa "$(now)"
      pkill -STOP -f 'v4l2hevc-gl-aarch64' 2>/dev/null
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
    if [ -p "$VFIFO" ] && pgrep -f 'v4l2hevc-gl-aarch64' >/dev/null 2>&1; then
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
  # 当前显示模式 WxH@Hz：/sys/class/drm/*/mode 常为空，退化取 modes 首行；
  # 刷新率从 cmdline 的 video=HDMI-A-1:WxH@Hz[e] 里取
  for d in /sys/class/drm/card*-HDMI*; do
    [ -r "$d/status" ] || continue
    [ "$(cat "$d/status" 2>/dev/null)" = connected ] || continue
    D=$(cat "$d/mode" 2>/dev/null)
    [ -n "$D" ] || D=$(head -1 "$d/modes" 2>/dev/null)
    break
  done
  H=$(sed -n 's/.*video=HDMI[^:]*:[0-9]*x[0-9]*@\([0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -1)
  printf '%s@%s\n' "${D:-?}" "${H:-60}"
  ;;

alive)
  pgrep -f 'v4l2hevc-gl-aarch64|mpv' 2>/dev/null | wc -l
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
ensure_node() { "${SSH[@]}" "test -x $NODE && grep -q tvplay-node-v10 $NODE" 2>/dev/null || \
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
  "${SSH[@]}" "chmod +x $HW_BIN" && echo "已部署 $HW_BIN"
}

# ─────────────────────────── 播放 ───────────────────────────
play() { # $1=dav path $2=强制起点(可空)
  local path="$1" start="${2:-}" track="${TRACK:-1}"
  local url="$AUTH$path" info codec w h fps dur player saved

  ensure_node || return 1

  echo "▶ 探显示器…"
  local dsc dmode dhz
  dsc=$(node disp 2>/dev/null); dhz="${dsc##*@}"; dmode="${dsc%@*}"
  case "$dmode" in
    [0-9]*x[0-9]*) ;;                                    # 正常拿到 2560x1440
    *) dmode="${DISP_W}x${DISP_H}"; dhz="$DISP_HZ"
       echo "  ⚠ 取不到盒子显示模式，按显示器默认 ${dmode}@${dhz} 播" >&2;;
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
  echo "  输出: ${DW}x${DH}@${dhz}（显示器 $([ "$dmode" = "${DISP_W}x${DISP_H}" ] && echo 原生 || echo 非预期⚠)）$(
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
