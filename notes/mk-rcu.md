# mk-rcu：第一块（RCU）契约清单与实现方案

> 对应 `docs/design.md` §5 的模板。**填不满不许动手**——这份表在填的过程中
> 已经推翻了初稿里的一句错话（见 §2 末"填表修正"）。

## 1. 现状实测（2026-11-11，本机）

```
kernel/rcu/          16,814 行 · 19 个文件
  tree.c             PREEMPT_RCU + TREE_RCU 主体
  tiny.c             252 行，CONFIG_TINY_RCU（UP 专用）
  update.c           synchronize_rcu / 回调基座
  sync.c             rcu_sync
  srcutiny/srcutree  SRCU 两套
  rcutorture/rcuscale/refscale   测试框架（可整块删）
导出符号             141 条 EXPORT_SYMBOL*（kernel/rcu/，实测计数）
相关头文件           rcupdate.h 1186 + rcu_segcblist.h 212 + rcutiny.h 144 + rcutree.h 127 = 1,669 行
```

本机 config（`configs/config-7.2.12-20261111-hwreal`）里跟 RCU 相关的全是**最费事的组合**：

| 项 | 值 | 对自研实现的影响 |
|---|---|---|
| `CONFIG_SMP` | y（Ryzen 5 3500X，6 核） | **不能直接开 `CONFIG_TINY_RCU`**（Kconfig 要求 `!PREEMPT_RCU && !SMP`） |
| `CONFIG_PREEMPT_RCU` | y | 读侧不是 `preempt_disable()`，要维护 `task_struct` 的嵌套计数 |
| `CONFIG_PREEMPT_DYNAMIC` | y | 运行时可切抢占模式，RCU 里不能假设静态抢占模型 |
| `CONFIG_RCU_NOCB_CPU` | y | 自研实现要删掉，需在 Kconfig 里 `depends on !MK_RCU` |
| `CONFIG_RCU_LAZY` | y | 同上，删 |
| `CONFIG_NO_HZ_FULL` / `CONFIG_HZ` | y / 1000 | 静默点判定不能只靠 tick，需 IPI 兜底 |

**结论**：`tiny.c` 的 252 行是结构参考，不是可复用代码——它假设 UP。
自研版实质是"TinyRCU 的算法 + PREEMPT_RCU 的读侧记账 + SMP 的静默点收集"。

## 2. 契约清单

| 项 | 内容 |
|---|---|
| **读侧** | `rcu_read_lock()` / `rcu_read_unlock()`（PREEMPT_RCU 下展开为 out-of-line 的 `__rcu_read_lock/unlock`，声明在 `rcupdate.h:81-82`、实现在 `tree_plugin.h`）、`rcu_dereference*` 全家（纯宏 + `READ_ONCE` + 屏障，**宏不动**）、`rcu_preempt_depth()` = `READ_ONCE(current->rcu_read_lock_nesting)` |
| **写侧（核心 9 条）** | `synchronize_rcu` · `synchronize_rcu_expedited` · `call_rcu` · `call_rcu_hurry` · `rcu_barrier` · `get_state_synchronize_rcu` · `start_poll_synchronize_rcu` · `poll_state_synchronize_rcu` · `cond_synchronize_rcu` |
| **符号可见性** | 以上 9 条全部 `EXPORT_SYMBOL_GPL`；nvidia 610 条硬依赖里**不直接出现**（经 `dma_fence`/`drm_atomic` 间接触发），故 CRC 不因本块变化——但仍必须保持符号存在，否则第三方模块链接失败 |
| **结构体（冻结，布局不动）** | `task_struct` 的 4 个 PREEMPT_RCU 字段：`rcu_read_lock_nesting` / `rcu_read_unlock_special` / `rcu_node_entry` / `rcu_blocked_node`（`include/linux/sched.h:940-943`）；tasks 系列另有 5 个 `rcu_tasks_*`（947-952）。自研实现**必须自持这些字段的语义**，不能当垃圾位用 |
| **必须保持的语义** | ① `synchronize_rcu` 返回后，所有 GP 开始前的读者已离开临界区；② `rcu_read_lock` 内**不可睡眠**（否则挂死或漏 GP）；③ RCU 读侧可在 NMI/中断/关抢占上下文安全调用；④ `call_rcu` 的回调最终一定被调用一次，且在 GP 之后；⑤ `rcu_barrier` 返回后同 CPU 已提交的回调全部执行完 |
| **允许删掉的** | tree 层级（`rcu_node` 树 → 单层）、`CONFIG_RCU_NOCB_CPU` 全套、`CONFIG_RCU_LAZY`、expedited 变体（退化为 `synchronize_rcu` + 立即 IPI）、CPU 热插拔回调、stall 检测/`rcutorture`/`rcuscale`/`refscale` 整块 |
| **SRCU** | 不在本块射程（`srcutiny.c`/`srcutree.c` 继续用 Linux 原版），只保证 RCU 与 SRCU 共存时互不干扰 |
| **验收** | 见 §5 |

### 填表修正（写下来提醒自己）

初稿 `docs/design.md` §5 的 RCU 样板写着"涉及结构体：**无**（只碰 per-CPU 状态）"。
实际核对 `include/linux/sched.h` 后发现 **`task_struct` 有 4 个 PREEMPT_RCU 字段是被 RCU 直接读写的**。
改：布局仍不动（冻结线内），但**语义责任在自研实现这边**——它决定了 `rcu_preempt_depth()`
这个宏的返回值正确性，而那个宏被 `might_sleep`/lockdep 通路大量使用。
这一条如果不写清楚，M2 会出现"能启动但 lockdep 乱叫"的诡异现象。

## 3. 实现方案（目标 ~500 行）

```
读侧（PREEMPT_RCU 语义）
  __rcu_read_lock:    current->rcu_read_lock_nesting++     （8 行）
  __rcu_read_unlock:  nesting--；归零且有待处理特殊状态→ rcu_read_unlock_special()
  —— 关键：nesting > 0 的 task 是"阻塞 GP 的读者"，GP 必须等它归零

静默点收集（per-CPU 位图）
  静默点 = 上下文切换 / 进 idle / 用户态返回 / 显式 rcu_qs()
  每个静默点置位 cpu_qs_mask；GP 结束条件 = 所有 online CPU 都已置位
  若某 CPU 超过 1 个 tick 未置位 → 发 IPI 强制（把 NMI/关抢占的死角兜住）

GP 推进（单个 GP kthread，串行化，不做层级）
  synchronize_rcu: 记快照号 → 等 gp_seq 前进 → 返回
  call_rcu:        挂到 per-CPU cblist（沿用 rcu_segcblist 结构，不重写）→ 返回
  GP 完成后：把该 CPU 的 cblist 搬到"可执行"段，在 softirq 里批量跑

删掉的复杂度
  无 rcu_node 树、无 boost、无 NOCB、无 lazy、无 expedited 独立路径、无 stall 检测
```

为什么沿用 `rcu_segcblist`：它是 `rcu_segcblist.c`（独立 300 行左右）+ 头文件 212 行，
里面是纯数据结构（三段链表 + 段计数），与 GP 算法解耦，重写无收益、出错有代价。

## 4. 落地文件

```
src/linux-7.2.12/mk/Kconfig.mk        加 MK_RCU（depends on SMP && PREEMPT_RCU，并 !NOCB !LAZY）
src/linux-7.2.12/mk/rcu/rcu.c         read 侧 + GP + callback 调度（~500 行）
src/linux-7.2.12/mk/rcu/Makefile      obj-$(CONFIG_MK_RCU) += rcu.o
src/linux-7.2.12/kernel/rcu/Makefile  一行改动：CONFIG_MK_RCU=y 时不编 tree.o/update.o/tiny.o
                                      ← 唯一的"改上游文件"，且只是 Makefile 条件，不碰 C 代码
```

必须一并关掉的（否则双实现撞符号）：
`CONFIG_RCU_NOCB_CPU`、`CONFIG_RCU_LAZY`、`CONFIG_RCU_EXPERT` 相关子项。
用 Kconfig 的 `depends on !MK_RCU` 表达，而不是让用户手动改 config。

## 5. 验收（照 design.md §6 四层，逐条可执行）

| 步 | 命令 | 判据 |
|---|---|---|
| 1 编译 | `tools/trim/clean-build.sh` | 出 bzImage，无 duplicate symbol |
| 2 CRC | `tools/abi/check_symvers.py` | 610 条实测不变（RCU 本不在其中，作为回归护栏） |
| 3 QEMU | `tools/trim/verify-boot.sh` | 到 shell + ext4 挂载成功 + 无 oops |
| 4 真机 | 装机，`CONFIG_MK_RCU=y` | `dmesg` 无 WARN/hung task；nvidia 模块加载成功；桌面起来 |
| 5 压测 | 编译内核 + 跑 `git status` 级负载 24h | 不挂；`rcu_barrier` 不超时 |
| 6 lockdep | 启动参数 `prove_locking=1` + 压测 | 无 RCU 相关 splat（验 §2 的字段语义） |
| 7 **回退** | 关 `MK_RCU` 重编、重装 | 回到全 Linux 实现，正常启动 ← **回不去 = 没做完** |

## 6. 风险

| 风险 | 触发症状 | 兜底 |
|---|---|---|
| 漏静默点 → GP 卡死 | `synchronize_rcu` 挂住，系统假死 | IPI 强制 + 1s 超时打印 CPU 位图 |
| `rcu_read_lock` 内睡眠 | 随机挂死，难复现 | 保留 `rcu_read_lock_nesting` 检查 + `might_sleep` 告警 |
| 回调饥饿 | 内存涨（`call_rcu` 堆积） | cblist 长度告警 + 强制 GP |
| `PREEMPT_DYNAMIC` 运行时切换 | 静态假设失效 | 不在读侧假设抢占模型，只读 nesting |
| IPI 风暴 | 高负载下性能崩 | 先位图、后 IPI，IPI 只作兜底 |

性能红线（design.md §6 等价性）：允许退化，**不允许 > 2~3 倍**。
基准取 `synchronize_rcu` 调用频率高的场景（大量文件 close 时 `dput`/`iput` 路径）。

## 7. 工期（对照 design.md §3 的"1 周"）

| 阶段 | 内容 | 估 |
|---|---|---|
| 读侧 + 嵌套计数 + 静默点 | 可编译、可启动 | 2 天 |
| GP 推进 + call_rcu | 能跑，`rcu_barrier` 通过 | 2 天 |
| 删 NOCB/LAZY、修 Kconfig 冲突 | 全量编译干净 | 1 天 |
| 真机 + 24h + 回退验证 | M2 判据 | 2 天 |

**1 周是对的，前提是 §7 的"全量编译干净"不被 Kconfig 冲突拖住**——
`RCU_NOCB_CPU=y` 在本机 config 里已经开着，这是第一个会撞的坑。
