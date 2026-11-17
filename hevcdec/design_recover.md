# 3. 把 V4L2 解码器改造成可恢复的状态机

承接关系：§3.1（三态 `VS_DOWN / VS_RUN / VS_LOST`、`vdec_recover(why)` 唯一入口、L0..L4 恢复阶梯）
只存在于会话文本，尚未并入本文件。本文件写 §3.2（已落地）与 §3.3（研究项，未开工），
编号与 §3.1 对齐。

---

## 3.2 将重建过程做成事务

§3.1 把"什么时候恢复"收敛到一个入口，但没有回答"恢复**到一半**怎么办"。
改造前，答案写在 `v4l2hevc.c` 那段 `if (g_reinit) { … for (tries = 1; ; tries++) … }`
里（已由本文所述事务替换，见 §3.2.8）：

```
清流状态（s_len/s_pos/s_au_*/s_eof/s_release…）
  → close(hard) → open() → 失败 ? sleep(200ms) 重来 : break
  → 再清一遍本地计数器
```

它**没有提交点**：破坏性的清零发生在 close/open 成功之前，失败时"流状态是新的、
会话是旧的（或者根本没有）"。这就不是重建，是一串没有回滚的脏写。

### 3.2.1 先承认做不到两阶段提交

事务化的教科书解法是"影子资源 + 原子切换"：另开一个 `/dev/video0`，新会话建好后
再换指针。**在 meson-vdec 上这做不到**：`cur_sess` 是驱动里的全局单例，
同一时刻只允许一个会话；第二个 open 实测直接 `"Aborting decoding session"`
（§1.10 的硬约束）。所以：

- **能事务化的只有可分配资源**：fd、OUTPUT/CAPTURE 队列、mmap、导出的 dmabuf、
  事件订阅。这些可以先建后关，失败可丢弃。
- **驱动状态不可事务化**：一旦 `REQBUFS`/`STREAMON` 碰过硬件，只能"毁掉重来"。

结论：本节的事务是**补偿式（compensating）事务**，不是 2PC。它的原子性不表现为
"回到旧状态"，而表现为——

> **对外可见的状态只有两种：`VS_RUN(sess=N)` 或 `VS_DOWN(fd<0)`。
> 中间态（fd 在、队列半套、dmabuf 半套、owner 悬空）一律不允许被事务外的人看到。**

这一条就是 §1.10/README 里"半初始化会话是自激重建的源头"的正式化。

| 想要的语义 | 实现手段 | 为什么 |
|---|---|---|
| 不闪黑 | DRM 留住最后一帧 fb，重建期间不动 plane | 屏幕语义靠 Renderer，不靠 vdec |
| 不出半套状态 | 不变式：`fd>=0` ⟺ 会话完整；abort 一律回 `VS_DOWN` | 半套 = 下一轮重建的输入垃圾 |
| 可重试 | 每个失败返回 `-errno`，按 errno 分类，不 `die()` | 启动 3 轮 / 重建 8 轮已经是这个口径 |
| 可放弃 | 预算耗尽返回 3（让上层整链重启） | 自旋比黑屏更糟 |

### 3.2.2 事务对象：把布尔量换成带内容的请求

现在只有 `g_reinit`（1 bit）和 `g_hard_reset_on_reinit`（1 bit）。两个 bit 装不下
"这次重建要做什么"：一次 `POLLERR` 叠一次 STALL，谁也说不清该按哪个档位；seek 与
`IRAPWAIT` 同时到，硬复位预算被谁消耗也说不清。改成结构：

```c
enum tx_phase { TX_IDLE, TX_PREPARE, TX_BODY, TX_COMMIT, TX_ABORT };

struct vdec_tx {
	unsigned id;            /* txid，日志对账用 */
	enum vev why;           /* NEWSTREAM/ABORT/STALL/SRCCHANGE/SELFTEST，§3.1 */
	int      level;         /* L1 REARM / L2 REBUILD / L3 HARD（L0/L4 不进事务） */
	unsigned sess_before;   /* 进入时 g_sess，commit 后才允许变 */
	int      hard;          /* = (level == L3) */
	double   t0, deadline;  /* 预算按时间，不按次数 */
	int      tries;         /* 尝试计数，与代数分开记 */
	enum tx_phase phase;
};

static struct vdec_tx g_tx;
```

`g_reinit` 保留，但降级为**请求位**：事务进行中再置位不排队，只按优先级**升级**
（`REBUILD < HARD`，`STALL` 不降 `ABORT`）。排队等于先做完一次无用功再毁一次；
降级等于把已经被判定为"固件 hang"的场景降成一次软重建。

### 3.2.3 三段式：PREPARE / BODY / COMMIT

**PREPARE（只读，不碰任何 fd）**
1. 定档：`(why, g_err_rec)` → `level`（§3.1 的阶梯表）。
2. 记快照：`sess_before = g_sess`、目标分辨率（SPS 已解析）、RAP 门控参数（§1.14）。
3. 定预算：`deadline = t0 + REBUILD_MS`（默认 3000；L3 的单次硬复位实测要
   150×20ms=3s，所以 L3 用 `3 × REBUILD_MS`）。
4. 打 `TX#id BEGIN why=… level=… sess=N`。

**BODY（破坏性，全部可重试，全部返回 `-errno`）**
按固定顺序，每一步失败都进 ABORT（`TX_BODY` 里没有"打一行继续"）：

| 步 | 动作 | 失败分类 |
|---|---|---|
| 1 | 读空管道残留（`O_NONBLOCK` → `EAGAIN`） | 不可失败（`EAGAIN` 是终点） |
| 2 | `g_drop_owners=1` + `render_flush()`，再 `g_drop_owners=0` | 必须先于 `close(fd)`，否则把还在被纹理用的 dmabuf 关在脚下 |
| 3 | `vdec_close(hard)`：`STREAMOFF` → 关导出 dmabuf fd → `REQBUFS(0)` → `close(fd)` | 幂等；失败**不**当作可跳过 |
| 4 | （仅 L3）写 `hard_reset` 并等 150×20ms | 失败是硬错误，**不许**当没发生继续开流 |
| 5 | `vdec_open(w,h)`：`S_FMT`/`REQBUFS`/`QUERYBUF`/`QBUF`/订阅事件/`STREAMON` | 见 errno 表 |

errno 分类（这是"次数预算"之外最省事的一步）：

| errno | 处理 | 理由 |
|---|---|---|
| `EBUSY` / `EAGAIN` | 退避 200ms 重试，直到 deadline | 驱动 workqueue 还没收完；硬复位后尤其常见 |
| `ENOMEM` / `ENOSPC` | 重试，但**不再加硬复位** | CMA 碎片，复位只会让碎片更糟（§2.5 的教训） |
| `EINTR` | **不算失败**：重新取 `g_tx` 档位后重试，不消耗预算 | seek 的 `SIGUSR1` 可能在事务中间到 |
| `ENOENT` / `EACCES` / `EINVAL` / `ENODEV` | 立即 ABORT | 重试只是把黑屏时间拉长 |

**COMMIT（唯一的写屏障）**
只有 `vdec_open()==0` 才允许执行下面这一串，且**顺序固定**：

1. `g_sess++`（提交计数，不是尝试计数）；
2. `rap_enter(WAIT)` + 计时器/计数器归零（§1.14）；
3. 清 `drained / stream_done / poll_timeouts / idle_ticks / eos_seen / g_refeed / tq / au_idx`；
4. `g_mark_first = 1`，放行往新 fd 上的 `QBUF`；
5. `t_last_rx = now`；
6. `TX#id COMMIT sess=N+M <ms>`。

反过来说，**commit 之前这些字段一律不动**——事务外的人读到的永远是"旧的整套"
或"新的整套"。现在的实现把第 2、3 步放在 open 成功之后、但第 1 步（`g_sess++`）
放在 `vdec_open` 一进门（`v4l2hevc.c:1486`，注释还写着"后面的失败也要按这个号收尾"），
结果是失败的尝试也占代数：日志里"重建了 4 次"，实际成功 1 次，代数和次数对不上账。

### 3.2.4 ABORT 与回滚清单

补偿式事务没有 undo log，只有"撤到干净的空态"。ABORT 必须保证：

```
fd < 0  &&  cap_count == 0  &&  out_count == 0  &&  g_drop_owners == 0
         &&  Renderer 帧队列空（render_flush 已过） &&  导出 dmabuf fd 全关
```

这条不变式要能在注入失败后**断言**，不能只靠人眼（见 §3.2.6）。顺序上：
`vdec_close(0)` 幂等（`fd<0` 直接返回），所以 ABORT 无条件再调一次即可，不需要
"我记得走到第几步"。这是把"部分成功"消掉的最便宜做法：不追踪进度，只重复做补偿。

ABORT 之后：

- `g_err_rec++`；`level` 若已是 L3 且 `g_err_rec > ERRREC` → `L4 GIVEUP`，返回 3；
- 门控状态**不**回 `PLAY`，保持 `WAIT`（§1.14 的错误边）；
- 打 `TX#id ABORT step=<步> errno=<E> tries=<k> <ms>`。

### 3.2.5 与三态、门控、Renderer 的三处接口

| 接口 | 规则 | 坑 |
|---|---|---|
| 三态（§3.1） | `VS_RUN --BEGIN--> VS_LOST --COMMIT--> VS_RUN`，`--ABORT--> VS_DOWN` | 事务只存在于 `VS_LOST`；其它态出现 `g_tx.phase != TX_IDLE` 就是 bug，直接断言 |
| RAP 门控（§1.14） | 只有 COMMIT 才 `rap_enter(WAIT)`；ABORT 不动门控 | 提前 `rap_enter` 会让门控超时把 `IRAPWAIT` 算成"流没 RAP"，实际是重建没成功 |
| Renderer / `vout` | BODY 第 2 步作废 owner；commit 前不许 push 新帧 | 事务期间屏上停最后一帧 = 用户可见的"不闪黑"，所以 deadline 也是**静止时长预算** |

顺带一条：暂停（`pkill -STOP`）若把进程冻在 BODY 中间，`CLOCK_MONOTONIC` 照走，
`deadline` 会瞬间过期 → resume 后第一轮就判"重试超预算"去 L4。修法与 §1.10 的
STALL 同源：`t_loop` 间隔 > 4s 时把 `g_tx.t0/deadline` 整体平移（不是重置，保持
已花的预算），否则一次暂停就等于一次"重建失败"。

### 3.2.6 怎么验证（没有注入就没有事务）

`FORCEREINIT=N` 已经能在第 N 帧主动走一遍；再补一个失败注入，覆盖四条分支：

```
REBUILD_FAIL=STREAMON:EBUSY      # 重试到 deadline → ABORT
REBUILD_FAIL=REQBUFS:ENOMEM      # 重试但不加硬复位
REBUILD_FAIL=S_FMT:EINVAL        # 立即 ABORT（硬错误）
REBUILD_FAIL=hard_reset:EPERM    # L3 硬失败 → GIVEUP
```

验收四条：① 每种注入都打出 `TX#id ABORT step=… errno=…`；② ABORT 后 §3.2.4 的
不变式断言通过；③ `g_sess` 与 `tx_attempt` 的比值等于成功率（日志能自证）；
④ 事务期间 SIGUSR1 到达不导致 abort，只升级档位。

### 3.2.7 明确不做的事

- **影子会话 / 双 open**：驱动单例，写了就是死代码（§3.2.1）。
- **重建期间继续喂流**：新会话里 ref list 是空的，喂到 GOP 中间必然
  `"Couldn't find ref. frame 0"`（§1.10，实测 8 帧挂死）。事务期间只等 RAP。
- **把事务做成可持久化（跨进程重启恢复）**：进程被杀时唯一留在驱动里的是
  `cur_sess`，恢复手段只有"OPEN 失败就 close(0) 重试"，不需要额外的日志/状态文件。

### 3.2.8 实现状态（已落地）

| 设计条目 | 代码位置 | 状态 |
|---|---|---|
| 事务对象 `struct vdec_tx` / `enum tx_phase` | `v4l2hevc.c` 事务对象段（`g_tx`） | 已实现 |
| `g_reinit` 降级为请求位，**只升级不降级** | `tx_request(lvl, why)` + `g_req_lvl/g_req_why`；`on_usr1` 里内联 L2 请求 | 已实现 |
| PREPARE：定档 + 快照 + 时间预算 | `tx_begin()`，`REBUILDMS`（默认 3000，L3×3） | 已实现 |
| BODY 1 读空管道 | `tx_flush_pipe()`（`flush=0` 时跳过，保住启动预读的 SPS） | 已实现 |
| BODY 2 owner 作废 | `vdec_close()` → `retire_capture_frames()`（`g_drop_owners` 包住 `render_flush`） | 已实现 |
| BODY 3 关会话（幂等） | `vdec_close(hard)`；output 映射改由 `out_release()` 就地撤 | 已实现 |
| BODY 4 硬复位 | `vdec_close(1)` → `vdec_hard_reset()`；失败仍只报不吞，注入路径直接 ABORT | 已实现 |
| BODY 5 开会话 + errno 分类 | `tx_classify()`：EBUSY/EAGAIN 重试、ENOMEM/ENOSPC 重试且不加硬复位、EINTR 不吃预算、ENOENT/EACCES/EINVAL/ENODEV/ENXIO 立即 ABORT | 已实现 |
| COMMIT 唯一写屏障 | `tx_commit()`：`g_sess++`（唯一递增点，`vdec_open` 里已删除）、`rap_enter(WAIT)`、门控降级/超支计数归位 | 已实现 |
| ABORT 补偿 + 断言 | ABORT 段：`vdec_close(0)` 无条件再调一次 → `tx_assert_clean()` → `g_err_rec++` → `ERRREC` 超限 L4 返回 -2 | 已实现 |
| 暂停平移预算 | `tx_shift_pause()`（BODY 内按实际睡眠间隔平移，>4s 判定被冻） | 已实现 |
| 失败注入 | `tx_inject()`：`REBUILD_FAIL=STEP:ERRNO`，STEP∈{S_FMT,REQBUFS,STREAMON,hard_reset}，`REBUILD_FAILN` 限制次数 | 已实现 |
| 启动也走事务 | `main()` 的 3 次重试循环删除，改 `tx_run(0)` | 已实现 |

日志格式（对账用，脚本可 grep）：

```
TX#<id> BEGIN why=<cause> level=L<n> sess=<N> budget=<ms>
TX#<id>: try <k> 失败（step=<s> errno=<E>），200ms 后重试（剩 <ms>）
TX#<id> COMMIT why=… sess=<N>→<N+1> <ms> tries=<k>
TX#<id> ABORT step=<s> errno=<E>(<n>) tries=<k> <ms>
TX-ASSERT: OK（不变式 fd<0 cap=0 out=0 owners=0）| FAILED …
```

`g_sess` / `g_tx_attempt` 是成功率的两条腿：`g_sess` 只在 COMMIT 递增，
`g_tx_attempt` 每次 open 尝试都递增（含注入失败），二者之比就是成功率——
"日志说重建了 4 次、实际成功 1 次"这种账再也对不上了。

已验证（x86 主机，无 `/dev/video0`，只跑得到注入分支）：

| 注入 | 期望 | 实测 |
|---|---|---|
| 无 | 立即 ABORT（ENOENT 属硬错误）+ 断言 OK | ✅ `TX#1 ABORT step=open errno=…(2)` |
| `S_FMT:EBUSY` | 200ms 退避重试到 deadline → ABORT | ✅ try1..3 后 `预算耗尽` → ABORT |
| `REQBUFS:ENOMEM` | 同上，且不加硬复位 | ✅ |
| `STREAMON:EINVAL` | 立即 ABORT | ✅ 0ms |

**尚未验证**：真机（meson-vdec）上的 L3 分支与 `hard_reset:EPERM` 注入——板子当前
不可达（`192.168.1.100` no route to host），需要在盒子上补跑一遍
`REBUILD_FAIL=hard_reset:EPERM` 与 `FORCEREINIT=300`，确认
① `TX#n ABORT step=hard_reset` 后直接 L4；② 正常 `FORCEREINIT` 打出
`COMMIT sess=1→2` 且随后 `REINIT: first frame`。

---

## 3.3 把软重置研究单独列为驱动项目

§3.2 的事务是**在"只能整会话来拆"这个前提下**做出来的最优解。它同时也承认了这个前提的
代价：一次 L2 重建 = `stop_stream` + 回收到 `fd=-1` + 80ms 落定期 + 重开 + dmabuf 重导出
+ 纹理重新导入，seek 的延迟下限和 §3.2 一半的复杂度都是这一条买来的。所以：

> **软重置（不拆会话、不清 fd、只清硬件与解码状态）不在用户态解决，单列为驱动侧研究项。**
> 本文档只管把它写清楚，等驱动给了语义，用户态再回收这笔账。

三条理由，都不是"顺手不顺手"：

1. **用户态做不出来。** `meson-vdec` 唯一的复位入口是 `hard_reset` 模块参数
   （`vdec_hr_run()`，写只、`0200`、且 `cur_sess != NULL` 直接 `-EBUSY`），它是**整块掉电再上电**，
   不是软重置；`amvdec_abort()` 只往两个 vb2 队列打 `vb2_queue_error`，一根寄存器都不碰。
   在驱动之外再没有第二条路能清固件。
2. **半秒级的定位成本该由驱动承担。** 现在 seek 踩到"驱动没清干净"的现场，只能在用户态
   靠 `REBUILD_FAIL` 注入、靠 200ms 退避、靠整块复位去撞（§3.2.6）。同样的实验在驱动里是一个
   `dev_dbg` 加一次 `esparser_power_up()`，在用户态是一轮黑屏。
3. **它有自己的回归面。** 软重置是否真的清了 DPB/canvas/vififo，要在驱动里断言，
   用户态只能看到"出帧了没有"——把不可判定留在用户态，等于永远不知道 500 次 seek 之后
   坏掉的是哪一层。

### 3.3.1 现状盘点：已经有三块半成品，缺的是语义

| 位置 | 现在是什么 | 离软重置缺什么 |
|---|---|---|
| `esparser_power_up()` | `reset_control_reset(core->esparser_reset)` + 重写 `PFIFO_RD/WR_PTR`、`PARSER_CONFIG` → **parser 这一侧的软重置其实已经写了** | 只覆盖 parser，不含固件与 DPB；也没人把它当"重置"调用 |
| `vdec_stop_streaming()` | `vdec_poweroff()` + `vdec_free_canvas()` + 释放 vififo + `kfree(sess->priv)` + `cur_sess = NULL` + `STATUS_STOPPED`，**而 fd 与两套队列都留着** | 这就是现成的"最接近软重置"的路径：只差一个"不出队列、不丢缓冲、不需要上层重配格式"的变体 |
| `codec_ops->resume()` | `amvdec_src_change()` 里"capture 队列已经配得下"就不重启，直接 resume | 正向证据：**不重启硬件而继续解码是被驱动认可的**，但只用于分辨率变化，不接 seek |
| `vdec_hr_run()` | 掉电 → 上电 的 6 步二分，`cur_sess == NULL` 才允许 | 硬重置，L3 专用；和软重置是两档，不许混用 |

结论：**不需要发明新机制，需要给一条已存在的路径定语义。** 这也是为什么它是"研究项"
而不是"实现项"——先要证明 `STREAMOFF(OUTPUT) → STREAMON(OUTPUT)` 在不关 fd 的情况下
等价于一次软重置（见 §3.3.4）。

### 3.3.2 目标语义（草案，未实现）

给用户态一个 in-session 重置动词，语义按"下一个 buffer 必须是 RAP"收口：

```
RESET(in-session)
  前置：fd 有效，会话完整；OUTPUT/CAPTURE 队列可以不 STREAMOFF
  动作：esparser 软复位 + PFIFO 指针归零 + 固件 stop（不掉电）
        + canvas/DPB/mv 缓冲全部标失效 + 参考帧表清空 + 时间戳基准重置
  保证：① 不碰 AO 掉电寄存器（那是 L3 的地盘）
        ② cur_sess 不变——单例约束（§3.2.1）不被绕过
        ③ 返回后 CAPTURE 侧所有在飞 buffer 以 ERROR 回收，不留悬空 owner
        ④ 接受的下一个 AU 必须是 IRAP，否则闭嘴不出帧（照旧走 rap 门控）
```

对用户态而言，这把 §3.2 的 L2 从"补偿式事务"降级成"一句 ioctl"，收益是可数的：

| 指标 | 现在（整会话重建） | 软重置可用后 |
|---|---|---|
| seek 到出首帧 | 80ms 落定期 + open/REQBUFS/QBUF/STREAMON + 重导 dmabuf | 取决于 `vdec_poweroff`/`power_up` 的几毫秒量级 |
| Renderer 影响 | 必须 `render_flush`（旧 dmabuf 全换） | 旧帧仍在，纹理无需重建 |
| 失败面 | 5 个可失败步骤 + 硬复位预算 | 1 个动词，失败即 L3/L4 |
| §3.2 事务 | 每次 seek 都走 | 只留给 POLLERR / STALL / 硬复位 |

### 3.3.3 明确的边界：软重置不是万能的

- **不省 RAP 等待。** 参考帧表清空后只能从 IRAP 起解，seek 精度不变（这本来就靠 §3.2 的
  `rap_enter(WAIT)` 管，与重置方式无关）。
- **不动 `cur_sess` 单例。** 想靠"软重置"绕过单例开第二个会话是错的方向，仍然做不到（§3.2.1）。
- **不许碰 `MC` / `ASSIST` 寄存器。** `vdec.c` 头部注释记着：无活动会话时读这些会让 AXI 锁死、
  整机挂起无 oops。软重置若在某条路径上先停固件再读它们，就复现那个死法。
- **与 `drain_disabled` 互斥。** `DEC_CMD_STOP` 的尾部 flush 与重置抢 `sess->lock` 的历史
  （`NOTES-drain-deadlock.md`）说明：任何"在 stop 路径里同步等 work"的写法都会死锁。
  软重置必须先在锁内置 `drain_disabled`，再单方面作废 drain。
- **不替代 §3.2。** 硬件真坏了（POLLERR / STALL × N）仍然要整会话重建 + 硬复位，
  事务代码一条都不删，它从"每次 seek 都走"退成"兜底"。

### 3.3.4 落地前的四个探针实验（零改动的验证）

按顺序做，任一失败就回到"软重置不可行、维持现状"，不许边试边改用户态：

| # | 实验 | 预期（软重置成立） | 反例意味着 |
|---|---|---|---|
| 1 | 同一 fd：`STREAMOFF(OUTPUT+CAPTURE)` → `STREAMON(OUTPUT+CAPTURE)` → 从 IRAP 喂 | 出帧；`cur_sess` 经历 NULL→新会话但不涉及 `close()`；无 `Aborting decoding session` | 队列重配必须换 fd ⇒ 事务结论仍成立 |
| 2 | 只 `STREAMOFF(OUTPUT)`、CAPTURE 保持 STREAMON（不加任何新 ioctl） | 要么解码继续，要么 CAPTURE 侧干净地 ERROR 回收、再 STREAMON 出帧 | 出现悬空 owner / vb2 报错死锁 |
| 3 | 连做 200 次实验 1 后看 `CMA` 与 `dma_buf` 计数、`vdec_free_canvas` 是否每次都配对 | 计数回到基线；`meson-vdec` 无 "Failed to alloc" | 有泄漏 ⇒ 先修泄漏，软重置免谈 |
| 4 | 实验 1 期间刻意在 GOP 中间喂（不从 IRAP 起） | 明确报 "Couldn't find ref. frame 0" 或静默丢帧，**不许**出花屏 | 花了就是 DPB 没清干净，重置语义不完整 |

实验 1/2 用现成二进制即可做（`v4l2hevc` 加一个 `STREAMOFF/ON` 开关，不改重建逻辑），
不需要先动驱动——这也是把它单列的原因：**验证不依赖实现**。

### 3.3.5 状态

| 项 | 状态 |
|---|---|
| 本文档 §3.3 语义与边界 | 已写下（本节） |
| 四个探针实验 | **未做**（板子当前不可达，`192.168.1.100` no route to host） |
| 驱动侧 RESET 动词 | **未开工**；等实验 1/2 的结论决定是"复用 STREAMOFF/ON"还是"新增 DEC_CMD" |
| 用户态接入 | **不动**。§3.2 仍是唯一重建路径，代码里不许预留"将来有软重置"的分支 |

最后一条是纪律：软重置研究期间，`v4l2hevc.c` 的重建路径保持现状——不做投机性的抽象层，
等驱动给出可测的语义再改。§3.2 已经把"只能拆"这个前提做成了可回滚的事务，
它等得起。

### 3.3.6 不阻塞：软重置排队，重构照走

这一节是纪律条款，不是技术结论。软重置研究**不带任何阻塞边**：下面三件事今天就能做完，
一件都不等 §3.3.4 的实验，也不等驱动。

**1. seek 黑屏跟软重置无关，但也不是"发个信号就没了"（两个坑连在一起）**

`design_player.md` §6 第 2 条"seek 黑 0.8 s"的成因是**整链重开**，不是会话重建：
`tvplay-node.sh` 的 `restart_at()` 走的是 `sh "$0" play ...`，`pkill -9 -f v4l2hevc-aarch64`
把持 DRM master 的进程打死，屏幕才掉回内核控制台文本（`X96Max-Player.md` §5.4）。

**但"把 `restart_at` 改成 `kill -USR1`"是错的**，这一步今天必须记下来，否则会被当成
"低风险脚本改动"排进迭代：

- seek 需要的是**新的字节位置**，而位置只存在于 `ffmpeg -ss $START` 的参数里；
  `v4l2hevc` 的 `SIGUSR1` 只干一件事——在**已有 fd** 上重建 meson-vdec 会话
  （`v4l2hevc.c:1908-1913`、`X96Max-Player.md` §5.2"收到 SIGUSR1：换新码流"）。
  信号里没有位置，也不会有：它是 `sig_atomic_t` 置位，不是控制消息。
- 现在 `ffmpeg … | v4l2hevc -` 是**兄弟进程**（同一个 `sh -c` 的管道两侧）。
  杀掉上游 → 下游 `read()` 拿到 EOF（`v4l2hevc.c:936` 只有 `r==0` 分支退流），
  杀掉下游 → DRM 掉。**壳没法只换上游**，这正是 `X96Max-Player.md` §5.2 说的"能力闲置"。
- 所以要消黑屏，最小改动不是改脚本，而是**把 ffmpeg 变成 `v4l2hevc` 的子进程**，
  seek 时由 C 侧 kill 子进程 → 带新 `-ss` 重开 → 收 `SIGUSR1` 重建会话 → DRM 全程不放。
  这动的是 `v4l2hevc.c` 的进程模型，属于 §3.2/§3.3.5 的重构范围，不是一行 `kill`。

结论不变、指向变了：黑屏与软重置**正交**（收益全在"不释放 DRM"），但它也不是白捡的，
它和"重建会话"一样需要代码。两者可以分别验收，见 §3.3.7。

**2. §3.2 事务不下线**

软重置若成立，`stop_stream` + 重开 + dmabuf 重导的那套事务从"常态路径"退成"兜底"；
若不成立，它就是终态。两种结果下**代码都留着**，所以现在不需要为"将来可能简化"预留任何分支。
§3.3.5 最后一条（不做投机抽象）在这里变成正向规则：重构可以放心按"每次 seek 都会重建会话"
写，不需要留 `#ifdef SOFT_RESET` 之类的口子。

**3. 排期与判据**

| 项 | 阻塞谁 | 状态 |
|---|---|---|
| 消黑屏（ffmpeg 收进 `v4l2hevc` 子进程，DRM 不放） | 无 | 可开工，但**要改 `v4l2hevc.c` 进程模型**，不是改脚本 |
| §3.2 事务打磨 / 失败注入 | 无 | 可开工 |
| §3.3.4 四个探针实验 | 无（但需板子可达） | 排队；板子 `192.168.1.100` 当前 no route to host |
| 驱动侧 RESET 动词 | 实验 1/2 的结论 | 未开工，不进任何 milestone |

判据只有一条：**别把"等软重置"写成任何一个任务的前置条件。** 如果哪天某个改动必须等它，
说明那个改动本身设计错了——现有事务已经把"只能整会话重建"这个前提做成了可回滚路径，
没有哪个功能需要"更快的重建"才能成立，只有"更少的黑屏/更快的首帧"这类体验指标会受益，
而这类指标目前都可以从用户态拿走（第 1 条、§3.2 的落定期参数、`-ss` 精度）。

### 3.3.7 分别验证：两条互不依赖的验收轨

上一节把"消黑屏"和"软重置"解耦了，那么验收也必须分开看，否则一次失败会拖累另一条。
两条轨的共同点是：**都不需要对方通过**。

**轨 A：位置由谁提供（本地可做，不要板子）**

要证的只有一句话：`SIGUSR1` 不携带位置，所以它不能单独完成 seek。

| 检查 | 手段 | 判据 |
|---|---|---|
| 管道两侧是兄弟进程 | 读 `tvplay-node.sh:104-110` 的 `sh -c 'ffmpeg … \| … "$HW" -'` | 找不到"杀掉 ffmpeg 后 `v4l2hevc` 还在跑"的路径 |
| 上游死 → 下游 EOF | `v4l2hevc.c:930-940`：`r==0` → `s_eof=1` → 退流 | 只有 `EINTR && g_reinit` 才有"不退出"的出口，EOF 没有 |
| 信号无载荷 | `on_usr1` 只置 `g_reinit`，`sig_atomic_t` | 无 target/offset 字段可传 |
| 位置只在 ffmpeg 参数里 | `grep -n '\-ss' tvplay-node.sh` | `-ss` 出现处全在 ffmpeg 命令行，C 侧无 seek ioctl |

四条都能用 static 检查在本地做完，判据是"反例不存在"而不是"实验成功"。
这就是为什么轨 A 现在就能结题，而板子在不在都不影响。

**轨 B：DRM 是否真的全程不放（必须板子）**

轨 B 只关心一个可观测量：**seek 期间屏幕有没有掉回控制台文本**。分三步，每步独立可停：

| 步 | 改法 | 期望 | 失败说明什么 |
|---|---|---|---|
| B1 | 只 `kill` ffmpeg，不动 `v4l2hevc` | 该进程立刻 EOF 退出，画面照样掉 | 轨 A 的结论在板上复现；`v4l2hevc` 无法独立于上游存活 |
| B2 | ffmpeg 收成 `v4l2hevc` 子进程，seek 时重开子进程 | 画面保持最后一帧（或继续 flip），无控制台 | 黑屏另有来源（VT 模式/plane 释放），要去查 `glout.c` |
| B3 | B2 + `SIGUSR1` 重建会话 | 首帧 ≈ 会话重建耗时（~600 ms），**全程无黑屏** | 会话重建本身掉了 DRM —— 那就是真问题，回到 §3.2 事务 |

B1 是"证伪自己"的一步，必须排在前面：如果 B1 的预期不成立（ffmpeg 死了画面还在），
说明板上有别的进程持 DRM，那么 B2/B3 全部的前提要重写。

**两条轨的独立性**

- 轨 A 通过、轨 B 未做 → 文档结论成立，代码不动，正确状态。
- 轨 A 不通过（比如发现板上有 IPC 能给 `v4l2hevc` 传位置）→ 消黑屏退化成一行的活儿，
  但要先改 §3.3.6 第 1 条，别让错结论留在文档里。
- 轨 B 的 B2/B3 失败 → 与软重置**无关**，是 DRM 所有权问题，回去查 §3.2 事务的释放点。

谁先做都行，唯一要求是**别把 B 的结论写进 A 的判据**。
