# V4L2 M2M HEVC 解码 + 播放（meson-vdec / X96Max）
#
#   make            本机编译（只有 drm 渲染后端，没有 GL 库）
#   make CROSS=1    aarch64 交叉编译：同一份播放器，drm + gl 两个后端都链进去
#   make clean
#
# 一个播放器二进制，两种 Renderer（render.h）：
#   RENDER=drm  NV12 dma-buf 直挂 overlay plane，零拷贝（vout.c）
#   RENDER=gl   EGL/GBM + GLES3，shader 里做 HDR→SDR（glout.c）
#   RENDER=auto 默认，drm 优先
# 不再有 v4l2hevc-drm / v4l2hevc-gl 两个"播放器"——那是同一份播放器的两种输出。
#
# 部署：scp v4l2hevc-aarch64 root@<box>:/tmp/  然后 /tmp/v4l2hevc-aarch64 - xx.265

CROSS   ?= 0
CC_HOST ?= cc
CC_CROSS?= aarch64-linux-gnu-gcc

ifeq ($(CROSS),1)
  CC  := $(CC_CROSS)
  BIN := v4l2hevc-aarch64
else
  CC  := $(CC_HOST)
  BIN := v4l2hevc
endif

LDLIBS ?= -lm	# tone mapping 的 pow/exp

# glout 需要的 aarch64 .so（盒子 scp 下来的，只用于链接）
CROSSLIB := crosslib
GL_LIBS  := $(CROSSLIB)/libEGL.so.1 $(CROSSLIB)/libGLESv2.so.2 $(CROSSLIB)/libgbm.so.1 \
            $(CROSSLIB)/libdrm.so.2 $(CROSSLIB)/libGLdispatch.so.0 $(CROSSLIB)/libexpat.so.1

GL_CFLAGS := -O2 -Wall -Wformat

# 播放器 = 主循环 + Renderer 分发 + 两个后端 + vout
PLAY_SRC := v4l2hevc.c spscolor.c render.c render_drm.c render_gl.c vout.c aout.c pctl.c osd.c
PLAY_HDR := render.h vout.h hdrcolor.inc csig.h spscolor.h aout.h pctl.h rcmap.h osd.h

.PHONY: all clean drm gl vout voutprobe glselftest aout aoutprobe hdrselftest mpvctl rcd

all: $(BIN)

# 本机：只有 drm 后端（没有 EGL/GBM 开发包），render_gl.c 编成 stub
ifeq ($(CROSS),0)
$(BIN): $(PLAY_SRC) $(PLAY_HDR)
	$(CC) $(CFLAGS) -DUSE_DRM -DAOUT_EMBED -pthread -o $@ $(PLAY_SRC) $(LDLIBS)
else
# aarch64：两个后端都在同一个二进制里，运行期 RENDER= 选
$(BIN): $(PLAY_SRC) glout.c $(PLAY_HDR) $(GL_LIBS)
	$(CC) $(GL_CFLAGS) -DUSE_DRM -DAOUT_EMBED -DHAVE_GLOUT -DGLOUT_NO_MAIN -pthread -o $@ \
	  $(PLAY_SRC) glout.c \
	  -idirafter /usr/include -idirafter /usr/include/libdrm -lm $(GL_LIBS)
endif

# 老命令的别名：drm/gl 不再是两个二进制，只是同一个二进制的两个后端
drm: $(BIN)
gl: $(BIN)

# GL 路径自检（EGL/GBM/panfrost/dmabuf 导入 + vblank 量化），不动 glout.c 的 API
GLSELF := glselftest-aarch64

glselftest: $(GLSELF)

$(GLSELF): gl-selftest.c glout.c osd.c $(PLAY_HDR) $(GL_LIBS)
	aarch64-linux-gnu-gcc $(GL_CFLAGS) -DGLOUT_NO_MAIN -o $@ gl-selftest.c glout.c osd.c \
	  -idirafter /usr/include -idirafter /usr/include/libdrm -lm $(GL_LIBS)

# aout: 独立音频输出模块（裸 ALSA ioctl，不用 mpv/libasound 做输出）
AOUT_BIN := aout$(if $(filter 1,$(CROSS)),-aarch64,)
AOUTCTL_BIN := aoutctl$(if $(filter 1,$(CROSS)),-aarch64,)

aout: $(AOUT_BIN) $(AOUTCTL_BIN)

$(AOUT_BIN): aout.c
	$(CC) -O2 -Wall -pthread -static -o $@ $<

$(AOUTCTL_BIN): aoutctl.c
	$(CC) -O2 -Wall -static -o $@ $<

# mpvctl：给音频 mpv 的 --input-ipc-server 发一行命令（音量/静音/quit 全靠它）
# 二进制名随 CROSS 变：一个目标名只能有一条规则，否则 make 会报警覆盖配方。
MPVCTL_BIN := mpvctl$(if $(filter 1,$(CROSS)),-aarch64,)
RC_BIN     := rcinputd$(if $(filter 1,$(CROSS)),-aarch64,)

mpvctl: $(MPVCTL_BIN)
$(MPVCTL_BIN): mpvctl.c
	$(CC) -O2 -Wall -static -o $@ $<

# 遥控器守护：evdev → /tmp/play.sh key <动作>
rcd: $(RC_BIN)
$(RC_BIN): rcinputd.c
	$(CC) -O2 -Wall -static -o $@ $<

# 硬件能力探测（period/buffer 上限、大 buffer 能不能压掉 xrun）
aoutprobe: aoutprobe-aarch64

aoutprobe-aarch64: aoutprobe.c
	aarch64-linux-gnu-gcc -O2 -static -Wall -o $@ $<

# vout 单独成 .o（自检用；播放器里直接编进去）
VOUT_OBJ := vout.o
ifeq ($(CROSS),1)
  VOUT_OBJ := vout-aarch64.o
  VOUT_CC  := $(CC_CROSS)
  VOUT_ARGS:= -static
else
  VOUT_CC  := $(CC_HOST)
endif

vout: $(VOUT_OBJ)

vout.o: vout.c vout.h
	$(VOUT_CC) -O2 -Wall -Wextra $(VOUT_ARGS) -c -o $@ $<

vout-aarch64.o: vout.c vout.h
	aarch64-linux-gnu-gcc -O2 -Wall -Wextra -static -c -o $@ $<

# 自检：probe 只读（桌面在跑也安全），run 会接管 CRTC
voutprobe: vout-selftest.c vout.c vout.h
	$(CC_HOST) -O2 -Wall -Wextra -o $@ vout-selftest.c vout.c -lm

voutprobe-aarch64: vout-selftest.c vout.c vout.h
	aarch64-linux-gnu-gcc -O2 -Wall -Wextra -static -o $@ vout-selftest.c vout.c -lm

# 提示条离线自检（osd.c 的同一份代码烘 PPM，改文案/字形后肉眼看一遍）
osdtest: osd-selftest.c osd.c osd.h
	$(CC_HOST) -O2 -Wall -Wextra -o $@ osd-selftest.c osd.c -pthread

# HDR 色彩路径自检（纯数学：PQ/曲线/LUT/增益/矩阵，主机上直接跑，不需要设备）
# 以前没有规则，只在命令行里手敲 cc —— 于是 hdrcolor.inc 改了没人回归。
# 把 GL 片元的数学搬到 CPU 出对照图：改曲线/sat/knee 后肉眼验一遍，
# 板子不在手边时唯一的"看图"手段。用法：./hcvisual out.ppm [target knee peak primaries]
hcvisual: hcvisual.c $(PLAY_HDR)
	$(CC_HOST) -O2 -Wall -Wextra -o $@ hcvisual.c -lm

hdrselftest: hdr-selftest
hdr-selftest: hdr-selftest.c $(PLAY_HDR)
	$(CC_HOST) -O2 -Wall -Wextra -o $@ hdr-selftest.c -lm

# RAP 门控状态机自检（§1.14，纯逻辑，不需要 /dev/video0）
raptest: raptest.c $(PLAY_SRC) $(PLAY_HDR)
	$(CC_HOST) -O1 -Wall -DUSE_DRM -I. -o $@ raptest.c spscolor.c render.c render_drm.c render_gl.c vout.c -lm

clean:
	rm -f v4l2hevc v4l2hevc-aarch64 v4l2hevc-drm v4l2hevc-drm-aarch64 \
	      v4l2hevc-gl-aarch64 glout glout-aarch64 *.yuv \
	      glselftest glselftest-aarch64 \
	      aout aout-aarch64 aoutctl aoutctl-aarch64 aoutprobe-aarch64 \
	      mpvctl mpvctl-aarch64 rcinputd rcinputd-aarch64 \
	      vout.o vout-aarch64.o voutprobe voutprobe-aarch64 raptest hdr-selftest hcvisual osdtest osd.ppm
