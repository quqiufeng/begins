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

.PHONY: all clean

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f v4l2hevc v4l2hevc-aarch64 *.yuv
