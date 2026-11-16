# meson-vdec 8bit HEVC 硬解修复记录（2026-11-16 固化）

目标机：X96（S905X2 / SM1，内核 7.2.12-x96-trim），板子 192.168.1.121（ssh 别名 `x96`）。
源码：`/x96-build/7.2.12-trim/drivers/staging/media/meson/vdec`
构建：`cd /x96-build/kbuild-trim && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=/x96-build/7.2.12-trim/drivers/staging/media/meson/vdec modules -j8`
产物：`meson-vdec.ko` 落在**源码树**该目录下（不是 kbuild-trim 里）。

## 修了什么（三处）

1. **`vdec.c: vdec_start_streaming()` —— 去掉 `changed_format` 门槛**
   原先 CAPTURE 队列的 start_streaming 只在 `changed_format` 为真时才真正起流，
   于是「分辨率没变（SPS 与初始 S_FMT 相同）」的流永远起不了硬件解码：esparser
   灌满预留窗口后就 EAGAIN 空转。改为无条件走起流路径。

2. **`vdec_helpers.c: amvdec_src_change()` —— 驱动自己 resume**
   src-change（V4L2_EVENT_SRC_CH_RESOLUTION）后原实现依赖用户态重新 queue 才恢复解码。
   现在若 `streamon_cap && streamon_out` 且 codec 提供 `resume`，事件发出后由驱动直接
   `resume(sess)`；分辨率未变时同样处理（旧代码只在分辨率变化时恢复）。

3. **`esparser.c: esparser_queue()` —— drain 时释放 3 个 CAPTURE 预留**
   正常播放保留 3 个 CAPTURE 缓冲避免解码器断粮；但 `esparser_queued_bufs` 只在整帧完成时
   递减，EOS 前解码器又必须收到剩余 AU 才能吐出重排序帧 —— 预留使条件恒真，尾部帧被丢弃。
   现在 `should_stop` 时不再扣 3。

## 保留的唯一日志

`vdec.c` STOP 路径的单行 `STOP flush: iters=.. src_ready=.. dst_ready=.. pending=.. queued=..`
（每次 stop 只打一行，用于确认 drain 是否真的排空）。其余 DRBG 探针已全部移除。

## 验证（干净版，无探针）

```
CAPBUF=32 FRAMES=60 ./v4l2hevc-aarch64 1080p8b.265
结果: RESULT decoded=60 / 60 AUs, resets=0, 1920x1080
      PERF wall=1.554s fps=38.62 bitstream=0.97 MB/s
      /proc/interrupts vdec 计数 63，dmesg 无错误
```

**CAPBUF 必须 >= ~11**：`esparser_queue()` 里 `num_dst_bufs = dst_ready - 3`，
CAPBUF=8 时只能同时在飞 5 个 AU，首帧出不来就永远 EAGAIN
（实测 CAPBUF=8 → 3 次中断后卡死 rc=124）。这**不是**回归：用带 DRBG 探针的同源码
A/B 构建跑同一份流，卡点与中断数完全一致。

## 已排除的假线索

- `/root/1080p8b.265`、`1080p10b.265`、`800p8b.265`（11-16 15:14 那批）**已被复位清零**
  （实测非零半字节数 = 0）。现用流是主机 ffmpeg/x265 重新生成：
  `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -frames:v 60 -pix_fmt yuv420p -c:v libx265 -x265-params keyint=30:min-keyint=30:bframes=0 -f hevc 1080p8b.265`
- 板子硬复位会丢磁盘写入，部署的 .ko 与日志都可能回滚（见 memory
  `x96-tvbox-rootfs-rollback-on-reset`）。**任何结论都要 A/B 比对**，不能只跑一次。

## 未完成

4K / 1080p **10bit** HEVC 仍会 oops（`FSC=0x04 level 0 translation fault` on
`0x0043800b5bb5db6c`，P5 sao 之后），寄存器序列本身已跑通，怀疑 10bit 分支字段未初始化。
