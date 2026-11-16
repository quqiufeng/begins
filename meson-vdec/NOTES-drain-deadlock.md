# DEC_CMD_STOP 尾部 flush 的死锁与 NULL deref（已修）

## 症状

- 播放小码流（test360.265 必现，720/1080 偶发）时内核卡死：
  - 用户进程 D 态、wchan 先是 `flush_work`，进程杀不掉；
  - rmmod 报 "module in use"，只能 sysrq-b 重启；
  - 另一条路径是 Oops：`codec_hevc_flush_output+0x20` 访问
    `sess->priv` 为 NULL（偏移 0x480 附近），即 priv 已 kfree。

## 根因（两层）

1. **死锁**：`vdec.c` 里
   ```c
   src_vq->lock = &sess->lock;
   dst_vq->lock = &sess->lock;
   ```
   即 vb2 队列锁就是 `sess->lock`。vb2 在调用 `vdec_stop_streaming()`
   时**已经持有** `sess->lock`；而原来的代码在这个回调里
   `cancel_delayed_work_sync(&sess->esparser_drain_work)`，
   work 一进 `esparser_flush_src()`/`esparser_queue_all_src()` 就要
   拿同一把 `sess->lock` → 互等，永远卡在 flush_work。
   同理，凡是在 stop_streaming 里 `mutex_lock(&sess->lock)` 都是
   self-deadlock（非递归 mutex），会表现为 wchan=vdec_stop_streaming。

2. **NULL deref**：`draining` 的置位（`vdec_decoder_cmd`）不在锁内，
   而清零点在 stop_streaming 里。窗口期内 stop_streaming 可以
   取消（无 work 可取消）→ `vdec_poweroff()` → `kfree(sess->priv)` →
   ioctl 才把 work 挂上 → work 在已释放的 priv 上跑
   `codec_ops->drain()`。

## 修法

- `vdec_stop_streaming()`：只在锁内调用 `vdec_drain_abort_locked()`
  （清 draining/drain_retries，置 drain_disabled），**不做任何
  cancel_delayed_work_sync，也不再锁 sess->lock**（锁已被 vb2 持有）。
- `esparser_drain_work()`：claim + `codec_ops->drain()` **全程持
  sess->lock**。这样 priv 的生命周期被封死：拆解要么排在 work 前面
  （draining/priv 检查失败直接退出），要么排在后面（等锁）。
  持锁 sleep 安全，因为再没有任何路径"等这个 work 结束后拿锁"。
- `vdec_decoder_cmd(DEC_CMD_STOP)`：置位放进 `sess->lock`，并拒绝
  `drain_disabled`（会话已拆）。
- `vdec_close()`：锁内作废后，出锁再 `cancel_delayed_work_sync()`
  （此处不持 sess->lock，不会互等）。

## 验证（x96max，7.2.12-x96-trim）

test360/test720/test1080 各 300/300 AU，1080p8b、720p10b、
4k2160_10b(3840x2160)、real4k10(3840x1600) 全绿，连跑多轮无 D 态、
dmesg 无 Oops。`800p8b.265` 失败与驱动无关（测试文件解析出 0 个 AU）。

ko md5（最终版）：7bed76ec2c2fe490a83be94d3382282d
