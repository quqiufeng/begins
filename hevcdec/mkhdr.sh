#!/bin/sh
# mkhdr.sh —— 从 HDRI（EXR 线性 radiance）造一条「真 HDR」HEVC 测试片
#
# 为什么不用现成片源：手头唯一的 HDR 片是 4K 10bit 的 BluRay 搬运，而这块板子
# 4K 10bit 会撞 design_recover 那条硬解复位；之前用过的那条 /tmp/hdr1080.265 是
# **SDR 彩条重打 PQ 标签**，峰值全挤在 1000 nit、没有任何阴影子，判不出"灰蒙/
# 过曝"到底修到哪。HDRI 是真实场景的辐照度（太阳/柔光箱几千 nit，暗部零点几
# nit），走一遍线性→PQ 就是货真价实的 HDR 内容，且体积极小。
#
# 用法: ./mkhdr.sh <in.exr> <out.265> [秒=8] [fps=30]
#   可选环境变量: MKHDR_W/H(1080p) MKHDR_PEAK(1000) MKHDR_KNEE(200)
#                 MKHDR_MID(20，p50 落在多少 nit) MKHDR_CRF(16)
#
# 片子是静帧循环（HDR 判画质不需要运动），8 秒在盒子上足够抓帧、看节拍。
set -e

IN=$1; OUT=$2; SECS=${3:-8}; FPS=${4:-30}
W=${MKHDR_W:-1920}; H=${MKHDR_H:-1080}
PEAK=${MKHDR_PEAK:-1000}; KNEE=${MKHDR_KNEE:-200}; MID=${MKHDR_MID:-20}
CRF=${MKHDR_CRF:-16}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 1/4 取线性 radiance 帧（原尺寸解出，缩放交给 python —— ffmpeg 的 scale 会把 float 夹到 [0,1]，灯/太阳直接没了）"
INW=$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$IN")
INH=$(ffprobe -v error -show_entries stream=height -of csv=p=0 "$IN")
# EXR 原生就是 gbrpf32le，且它和 rgbaf32le 之间 ffmpeg 没有转换路径 ——
# 所以原样吐平面 float，重排交给 python（按交错读会读出横条，这是个真坑）
ffmpeg -v error -y -i "$IN" -pix_fmt gbrpf32le -frames:v 1 -f rawvideo "$TMP/lin.f32"

echo "== 2/4 双线性放大 + 居中裁到 $W x $H（只放大，不缩小），肩上压缩到 PQ 直方图"
python3 - "$TMP/lin.f32" "$INW" "$INH" "$W" "$H" "$PEAK" "$KNEE" "$MID" "$TMP/pq_lin.f32" <<'PY'
import sys, numpy as np
src, iw, ih, w, h, peak, knee, mid, dst = (sys.argv[1], *map(int, sys.argv[2:6]),
                                            *map(float, sys.argv[6:9]), sys.argv[9])
p = np.fromfile(src, dtype=np.float32).reshape(3, ih, iw)      # G,B,R 平面
a = np.stack([p[2], p[0], p[1]], axis=2).astype(np.float64)     # -> 交错 RGB

# 双线性放大到"刚好覆盖 W x H"，再居中裁（缩小会把高光平均掉，所以只放大）
k = max(w / iw, h / ih)
ow, oh = int(round(iw * k + 0.5)), int(round(ih * k + 0.5))
ys = (np.arange(oh) + 0.5) * ih / oh - 0.5
xs = (np.arange(ow) + 0.5) * iw / ow - 0.5
y0 = np.clip(np.floor(ys).astype(int), 0, ih - 1); y1 = np.clip(y0 + 1, 0, ih - 1)
x0 = np.clip(np.floor(xs).astype(int), 0, iw - 1); x1 = np.clip(x0 + 1, 0, iw - 1)
wy = np.clip(ys - y0, 0, 1)[:, None, None]; wx = np.clip(xs - x0, 0, 1)[None, :, None]
top = a[y0][:, x0] * (1 - wx) + a[y0][:, x1] * wx
bot = a[y1][:, x0] * (1 - wx) + a[y1][:, x1] * wx
a = (top * (1 - wy) + bot * wy)[(oh - h) // 2:(oh - h) // 2 + h, (ow - w) // 2:(ow - w) // 2 + w]

p50 = float(np.percentile(a, 50))
s = mid / max(p50, 1e-6)          # 让中位亮度落在 mid nit
nits = a * s
y = np.where(nits <= knee, nits, knee + (peak - knee) * (1 - np.exp(-(nits - knee) / 300.0)))
np.stack([np.clip(y / peak, 0, 1)[:, :, 1],          # 1.0 == peak nit，写回 G,B,R 平面
          np.clip(y / peak, 0, 1)[:, :, 2],
          np.clip(y / peak, 0, 1)[:, :, 0]], axis=0).astype(np.float32).tofile(dst)
print("   源 max=%.0f p99.9=%.1f p50=%.3f (相对单位) -> 缩放 %.1f nit/unit" %
      (a.max(), np.percentile(a, 99.9), p50, s))
for p in (50, 90, 99, 99.9):
    print("   内容亮度 p%-5s = %7.2f nit" % (p, np.percentile(y, p)))
PY

echo "== 3/4 线性 -> PQ / BT.2020 / 10bit（npl=$PEAK，1.0 线性 == 1.0*$PEAK nit）"
ffmpeg -v error -y -f rawvideo -pix_fmt gbrpf32le -s ${W}x${H} -i "$TMP/pq_lin.f32" \
	-vf "zscale=pin=bt709:tin=linear:p=bt2020:t=smpte2084:m=bt2020nc:npl=$PEAK,format=yuv420p10le" \
	-frames:v 1 -f rawvideo "$TMP/pq.yuv"

echo "== 4/4 编码 x265 10bit（VUI=bt2020nc/smpte2084/bt2020，master-display L(1000,1)）"
N=$((SECS*FPS))
ffmpeg -v error -y -f rawvideo -pix_fmt yuv420p10le -s ${W}x${H} -r $FPS -i "$TMP/pq.yuv" \
	-vf "loop=loop=$((N-1)):size=1:start=0" -frames:v $N \
	-c:v libx265 -pix_fmt yuv420p10le -crf $CRF -an \
	-x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=$PEAK,400:keyint=$FPS:min-keyint=$FPS:log-level=error" \
	"$OUT"

echo "== 回读校验（PQ -> 线性，看峰值是不是真的落在 $PEAK nit）"
ffprobe -v error -show_entries stream=width,height,pix_fmt,color_space,color_transfer,color_primaries,r_frame_rate \
	-of default=nw=1 "$OUT"
ls -l "$OUT"
