# V4L2 M2M HEVC 解码验证工具 (meson-vdec / X96Max)
#
#   make            本机编译（静态链接）
#   make CROSS=1    aarch64 交叉编译，产物 v4l2hevc-aarch64
#   make clean
#
# 部署：scp v4l2hevc-aarch64 root@<box>:/tmp/  然后板子上执行 /tmp/v4l2hevc xxx.265

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

CFLAGS ?= -O2 -Wall -Wformat -static
SRC    := v4l2hevc.c
LDLIBS ?= -lm	# tone mapping 的 pow/exp

.PHONY: all clean

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# 带 DRM 导入（零拷贝验证）的版本，裸 ioctl，不依 libdrm.so
DRM_BIN := v4l2hevc-drm$(if $(filter 1,$(CROSS)),-aarch64,)

drm: $(DRM_BIN)

$(DRM_BIN): $(SRC)
	$(CC) $(CFLAGS) -DUSE_DRM -o $@ $< $(LDLIBS)

# glout: EGL/GLES3 输出，aarch64 交叉编译（不在盒子上编译）
# crosslib/ 里是盒子上 scp 下来的 aarch64 .so（EGL/GLESv2/gbm/drm/GLdispatch/expat）
CROSSLIB := crosslib
GL_LIBS  := $(CROSSLIB)/libEGL.so.1 $(CROSSLIB)/libGLESv2.so.2 $(CROSSLIB)/libgbm.so.1 \
            $(CROSSLIB)/libdrm.so.2 $(CROSSLIB)/libGLdispatch.so.0 $(CROSSLIB)/libexpat.so.1

GL_CFLAGS := -O2 -Wall -Wformat

glout-aarch64: glout.c $(GL_LIBS)
	aarch64-linux-gnu-gcc $(GL_CFLAGS) -o $@ $< \
	  -idirafter /usr/include -idirafter /usr/include/libdrm -lm $(GL_LIBS)

# v4l2hevc 解 + glout GLES3 上屏（一个二进制，GLPLAY=1 切过去）
GL_BIN := v4l2hevc-gl-aarch64

$(GL_BIN): v4l2hevc.c glout.c $(GL_LIBS)
	aarch64-linux-gnu-gcc $(GL_CFLAGS) -DUSE_DRM -DUSE_GLOUT -DGLOUT_NO_MAIN -o $@ \
	  v4l2hevc.c glout.c -idirafter /usr/include -idirafter /usr/include/libdrm \
	  -lm $(GL_LIBS)

gl: $(GL_BIN)

clean:
	rm -f v4l2hevc v4l2hevc-aarch64 v4l2hevc-drm v4l2hevc-drm-aarch64 \
	      glout glout-aarch64 v4l2hevc-gl-aarch64 *.yuv

.PHONY: drm glout-aarch64 gl
