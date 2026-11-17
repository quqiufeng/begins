#!/bin/sh
# tvplay-node-v4  协议版本串：加/改子命令时同步改 ensure_node 里的匹配串
# tvplay 盒端助手：所有参数 base64 进来，避免 ssh 嵌套引号
# v4: 加 key <动作> —— 遥控器（rcinputd）落到这里执行
set -u
LOG=/tmp/tvplay.log
STATE=/tmp/tvplay.state
HW=/tmp/v4l2hevc-aarch64
CTL=/tmp/mpvctl-aarch64
SOCK=/tmp/tvplay.sock
dec() { printf '%s' "$1" | base64 -d; }
enc() { printf '%s' "$1" | base64 -w0; }
now() { date +%s; }

# 播放位置（秒）。暂停期间冻结：PAUSE_AT>0 时用 PAUSE_AT 当"现在"。
pos() {
	. "$STATE" 2>/dev/null || return 1
	if [ "${PAUSE_AT:-0}" -gt 0 ]; then
		echo $(( PAUSE_AT - START + OFF ))
	else
		echo $(( $(now) - START + OFF ))
	fi
}

case "$1" in
probe)
  URL=$(dec "$2")
  exec ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate \
    -show_entries format=duration -of default=nw=1 "$URL"
  ;;

play)
  PLAYER=$(dec "$2"); URL=$(dec "$3"); START=$(dec "$4")
  TRACK=$(dec "$5");  AUDIO=$(dec "$6"); FPS=$(dec "$7")
  GEO=$(dec "${8:-}")   # 显示器输出几何 WxH
  RENDER=$(dec "${9:-}")  # 上屏后端 drm|gl|auto（缺省 gl）

  # 校验：宁可回落默认，也不要把解码失败的垃圾写进 state ——
  # 坏值会顺着 restart_at 再传一轮，逐次累积成二进制乱码。
  case "$AUDIO" in 0|1) ;; *) AUDIO=1 ;; esac
  case "$FPS"   in ''|*[!0-9]*) FPS=0 ;; esac
  case "$TRACK" in ''|*[!0-9]*) TRACK=1 ;; esac
  case "$GEO"   in [0-9]*x[0-9]*) ;; *) GEO=2560x1440 ;; esac
  case "$RENDER" in drm|gl|auto) ;; *) RENDER=gl ;; esac

  # 清场
  pkill -9 -f 'v4l2hevc-aarch64' 2>/dev/null
  pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
  pkill -9 -f 'mpv .*--no-video'    2>/dev/null
  pkill -9 -x mpv                   2>/dev/null
  rm -f "$SOCK"
  sleep 0.15

  # 状态文件可 source（KEY 用 base64，值里没有引号/空格）
  {
    printf 'START=%s\nOFF=%s\nPLAYER=%s\n' "$(now)" "$START" "$PLAYER"
    printf 'KEYB64=%s\n' "$(enc "$URL")"
    printf 'TRACKB64=%s\nAUDIO=%s\nFPS=%s\nGEO=%s\n' "$(enc "$TRACK")" "$AUDIO" "$FPS" "$GEO"
    printf 'RENDER=%s\n' "$RENDER"
    printf 'PAUSE_AT=0\nPAUSED_FOR=0\n'
  } > "$STATE"
  : > "$LOG"
  rm -f /tmp/tvplay.render   # 上一轮的路径记录不能留：宁可"未知"也别报错的

  if [ "$PLAYER" = mpv ]; then
    # 旧路径：整片交给 mpv（H.264 等非 HEVC）
    setsid nohup /usr/bin/mpv --vo=gpu --gpu-context=drm --hwdec=no \
      --vd-lavc-threads=4 --ao=alsa --audio-device=alsa/hw:0,0 \
      --audio-channels=stereo --no-osc --osd-level=0 --no-resume-playback \
      --input-ipc-server="$SOCK" \
      --aid="$TRACK" --start="$START" \
      "$URL" >>"$LOG" 2>&1 </dev/null &
    exit 0
  fi

  # ── HEVC 硬解路径 ──
  # 视频: ffmpeg 解封装 + -re 按片源节拍供流 → hevcdec 零拷贝解 → GLES3 上屏
  #   -re 保留：控制管道水位/seek 响应；配速已归播放器（FPS 两个后端都生效）
  #   音频交给 mpv：ffmpeg 的 -f alsa 在这块板子上缓冲太浅（8s 15 次 xrun）
  export START LOG HW
  if [ "$AUDIO" = 1 ]; then
    setsid nohup /usr/bin/mpv --no-config --no-video --vo=null \
      --ao=alsa --audio-device=alsa/hw:0,0 --audio-channels=stereo \
      --cache=yes --cache-secs=20 --input-ipc-server="$SOCK" \
      --aid="$TRACK" --start="$START" \
      "$URL" >>"$LOG" 2>&1 </dev/null &
  fi
  # NOWRITE=1 必须：否则 hevcdec 写 /tmp/out.yuv，4K 从 24fps 掉到 10fps
  # DSTGEO 只对 DRM 平面路径生效（GL 路径按 connector modes[0] 铺屏，两者都是 2560x1440）
  # RENDER 要挂在外层 env 上：管道里那个 RENDER= 是内层 sh 展开的，
  # 变量没 export 进去就成了空串 → 后端回落 auto（auto 会选 drm）。
  URL="$URL" GEO="$GEO" RENDER="$RENDER" setsid nohup sh -c 'ffmpeg -hide_banner -loglevel warning -re -ss "$START" \
      -i "$URL" -map 0:v:0 -c:v copy -f hevc - 2>>"$LOG" \
    | DSTGEO="$GEO+0+0" NOWRITE=1 PLAY=1 RENDER="$RENDER" "$HW" - >>"$LOG" 2>&1' \
    >>"$LOG" 2>&1 </dev/null &
  exit 0
  ;;

key)
  # 遥控器动作入口。rcinputd 只负责按键→动作名，语义全在这里。
  ACT="${2:-}"
  [ -f "$STATE" ] || exit 1
  . "$STATE" 2>/dev/null || exit 1
  URL=$(dec "$KEYB64")
  P=$(pos)

  pause_video() {
		pkill -STOP -f 'v4l2hevc-aarch64' 2>/dev/null
		pkill -STOP -f 'ffmpeg .*-f hevc'    2>/dev/null
		pkill -STOP -f 'mpv .*--no-video'    2>/dev/null
		pkill -STOP -x mpv 2>/dev/null
		sed -i '/^PAUSE_AT=/d' "$STATE"; echo "PAUSE_AT=$(now)" >> "$STATE"
		echo "key: pause" >> "$LOG"
  }
  resume_video() {
		pkill -CONT -f 'v4l2hevc-aarch64' 2>/dev/null
		pkill -CONT -f 'ffmpeg .*-f hevc'    2>/dev/null
		pkill -CONT -f 'mpv .*--no-video'    2>/dev/null
		pkill -CONT -x mpv 2>/dev/null
		# 把暂停时长记进 START，pos() 才能连续
		sed -i '/^START=/d' "$STATE"; echo "START=$(( START + $(now) - PAUSE_AT ))" >> "$STATE"
		sed -i '/^PAUSE_AT=/d' "$STATE"; echo "PAUSE_AT=0" >> "$STATE"
		echo "key: resume" >> "$LOG"
  }
  # 重启整条链到指定秒。HEVC 路径没有 IPC，只能重开（约 0.8s 黑屏）
  restart_at() {
		echo "key: seek -> $1" >> "$LOG"
		# 每个参数都必须 enc：play 侧一律 dec，传明文会被当 base64 解成
		# 垃圾/空（实测 AUDIO 解空 → 重开后没有音频 mpv；GEO 解出二进制 →
		# state 文件被写坏）。TRACK/AUDIO/GEO 还需能容忍旧 state 的空值。
		sh "$0" play "$(enc "${PLAYER}")" "$KEYB64" "$(enc "$1")" \
			"$(enc "${TRACK:-1}")" "$(enc "${AUDIO:-1}")" \
			"$(enc "${FPS:-0}")" "$(enc "${GEO:-2560x1440}")" \
			"$(enc "${RENDER:-gl}")"
  }

  # 音量必须夹在 0..100：mpv 的 add 会一路累加，
  # >100 之后开始削波失真（实测被连按到 130，晚上炸响）。
  vol_step() {
    # MPVCTL_ECHO=1 必须加：不加则 mpvctl 不回显回复，cur 永远是空，
    # 退化成每次都按 100 算（实测连按减 12 次只掉到 90）。
    cur=$(MPVCTL_ECHO=1 "$CTL" "$SOCK" '{"command":["get_property","volume"]}' 2>/dev/null \
          | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
    [ -n "$cur" ] || cur=100
    want=$(awk -v c="$cur" -v d="$1" 'BEGIN{v=c+d; if(v<0)v=0; if(v>100)v=100; printf "%d", v}')
    "$CTL" "$SOCK" "{\"command\":[\"set_property\",\"volume\",$want]}"
  }

  # HEVC 路径 seek 只能整条重开（1~3s），期间 DRM 被释放，屏幕掉回
  # 内核控制台文本。而 rcinputd 是 wait(NULL) 串行处理的：按住 ▶ 时的
  # 连发事件排在队列里，松开后仍会逐个补跑，每个都重开一次 ——
  # 表现就是"播放界面消失变成命令行，松开才慢慢恢复"。
  # 所以重开前先看时间戳，3s 内的重复 seek 直接丢弃（合并成一次）。
  seek_guard() {
    _s=/tmp/tvplay.seek.stamp
    _n=$(now); _p=$(cat "$_s" 2>/dev/null || echo 0)
    case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
    if [ $(( _n - _p )) -lt 3 ]; then
      echo "key: seek 合并（距上次 $(( _n - _p ))s，丢弃重复）" >> "$LOG"
      return 1
    fi
    echo "$_n" > "$_s"
    return 0
  }

  case "$ACT" in
  toggle)
    # 判定依据是「实际在跑哪条链」，不能只看 state 的 PLAYER：
    # 实测 state 会与真实进程不符（HEVC 链在放，state 却写着 mpv），
    # 于是 toggle 被发到一条空 socket，画面上什么都没发生。
    # 而且 HEVC 链的画面(v4l2hevc/ffmpeg)和声音(独立 mpv)是两个进程，
    # 只 toggle mpv 只会哑掉声音、画面照跑 —— 必须整条 STOP/CONT。
    if pgrep -f 'v4l2hevc-aarch64' >/dev/null 2>&1; then
      if [ "${PAUSE_AT:-0}" -gt 0 ]; then resume_video; else pause_video; fi
      exit 0
    fi
    if "$CTL" "$SOCK" toggle >/dev/null 2>&1; then exit 0; fi
    # 无 HEVC 链、socket 也不通：按 state 兜底，别让按键变成哑巴
    if [ "${PAUSE_AT:-0}" -gt 0 ]; then resume_video; else pause_video; fi
    ;;
  fwd)      D=10 ;;
  back)     D=-10 ;;
  fwdmore)  D=60 ;;
  backmore) D=-60 ;;
  volup)  vol_step 10;  exit $? ;;
  voldn)  vol_step -10; exit $? ;;
  mute)   "$CTL" "$SOCK" mute;    exit $? ;;
  quit)   sh "$0" stop; exit 0 ;;
  menu|home) echo "key: $ACT (无 UI，忽略)" >> "$LOG"; exit 0 ;;
  *) echo "key: 未知动作 $ACT" >> "$LOG"; exit 1 ;;
  esac

  # 到这里只剩 fwd/back/fwdmore/backmore
  T=$(( P + D ))
  [ "$T" -lt 0 ] && T=0
  if [ "$PLAYER" = mpv ]; then
    # mpv 自己能 seek，不用重开
    "$CTL" "$SOCK" seek "$D"
    [ "$T" -lt 0 ] && T=0
    sed -i '/^START=/d' "$STATE"; echo "START=$(now)" >> "$STATE"
    sed -i '/^OFF=/d'   "$STATE"; echo "OFF=$T" >> "$STATE"
    exit 0
  fi
  WASPAUSED=${PAUSE_AT:-0}
  seek_guard || exit 0
  restart_at "$T"
  # 暂停中拖动：重开后再压回去，保持"暂停"语义
  if [ "$WASPAUSED" -gt 0 ]; then
    . "$STATE" 2>/dev/null
    pause_video
  fi
  ;;

stop)
  pkill -9 -f 'v4l2hevc-aarch64' 2>/dev/null
  pkill -9 -f 'ffmpeg .*-f hevc'    2>/dev/null
  pkill -9 -f 'mpv .*--no-video'    2>/dev/null
  pkill -9 -x mpv                   2>/dev/null
  rm -f "$SOCK"
  rm -f /tmp/tvplay.render
  chvt 1 2>/dev/null
  exit 0
  ;;

render)
  # 上屏路径：只有播放器知道真相（RENDER=auto 到底选了谁、HDR 是 CPU 转还是
  # shader 转），它写 /tmp/tvplay.render，这里只读。没有文件就是"还没起来"，
  # 顺手把 state 里请求的后端报出来，别让人以为它在 GL 上跑。
  if [ -f /tmp/tvplay.render ]; then
    cat /tmp/tvplay.render
  else
    . "$STATE" 2>/dev/null
    printf 'RENDER=%s\nMODE=unknown\n' "${RENDER:-?}"
  fi
  ;;

state)
  [ -f "$STATE" ] || exit 1
  . "$STATE" 2>/dev/null || exit 1
  if [ "${PAUSE_AT:-0}" -gt 0 ]; then
    el=$(( PAUSE_AT - START + OFF ))
  else
    el=$(( $(now) - START + OFF ))
  fi
  n=$(pgrep -f 'v4l2hevc-aarch64|mpv' 2>/dev/null | wc -l)
  printf '%s %s %s %s %s\n' "$el" "${PLAYER:-?}" "${n:-0}" "${KEYB64:-}" "${PAUSE_AT:-0}"
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
  pgrep -f 'v4l2hevc-aarch64|mpv' 2>/dev/null | wc -l
  ;;

log)
  tail -"${2:-8}" "$LOG" 2>/dev/null
  ;;
esac
