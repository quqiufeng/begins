# 裁剪路线（2026-11-10 定：裁剪式，非重写）

**做法**：以 Linux 7.2.12 源码为基，删掉不针对本机的代码，重新梳理，让内核正常工作。
比"对照语义重写"风险低一个数量级 —— 不用猜驱动的隐含假设，因为代码就是原来那份。

## 基线已实测 PASS（不用编译）

`Module.symvers` 里就是全表 CRC，直接对表即可：

| 项 | 数 |
|---|---|
| `~/kernel-meta-7.2.12/Module.symvers` | 24327 符号 |
| 契约 610 | 内核侧 521 + 模块间 89 |
| 内核侧 521 匹配 | **521 / 521，CRC 不符 0** |
| 模块间 89 | 全部由 nvidia 四模块自己导出 ✅ |

**判定 PASS。** 这 521 个符号 = 裁剪时绝对不能碰的边界。

## 陷阱：config 分两类，一类不能砍

CRC 是类型签名指纹，**config 会改类型布局**。实测：

| config | 改了什么 | 后果 |
|---|---|---|
| `CONFIG_NR_CPUS=8192` | `cpumask_t = DECLARE_BITMAP(bits, NR_CPUS)` → **1024 字节** | 改 8 就变 8 字节，所有含 cpumask 的 struct 变形 → CRC 全变 |
| `CONFIG_PREEMPT_RT` | `spinlock_t` / `mutex` 整块换实现 | 类型完全不同 |
| `CONFIG_DEBUG_SPINLOCK` | `spinlock_t` 加 owner/魔数字段 | 变形 |
| `CONFIG_SMP` | `spinlock_t`、atomic、smp 辅助 | 变形 |
| `CONFIG_LOCKDEP` | 加 `dep_map` | 变形 |
| `CONFIG_MEMCG` | `struct page`/`folio`/`lruvec` | 变形 |

→ **这些开关一律不动**，即使"本机只有 6 核、单 NUMA 节点"看着浪费。
`NR_CPUS=8192` 留着的代价只是几个静态位图，改了要赔上 610 个符号的兼容性。

## 可以安全砍的（纯增量，不进类型定义）

| 类别 | 现状 | 砍法 |
|---|---|---|
| 架构 | 多 arch + ia32 兼容 | `arch/` 只留 x86，删 ia32 emulation |
| 驱动 | 上千个 `drivers/*` | 只留 nvidia 需要的（PCI/DMA/DRM/ACPI/fb） |
| 文件系统 | 几十个 | ext4 / proc / sysfs / devtmpfs / tmpfs |
| 网络协议 | 完整栈 | 留 IPv4/v6 + AF_UNIX；砍 netfilter/sched/无线 |
| cgroup/namespace | 全套 | 单用户单机，砍 |
| KVM / BPF / perf / ftrace | 有 | 不观测不当宿主，砍 |
| suspend / 热插拔 | 有 | 台式机，砍 |

参考量：当前 `.config` **6914 个 CONFIG、2821 个 =y**，目标是砍到 **~500 =y**。

## 执行顺序（每步都要回归）

```
① 基线可复现编译      cp .config → make olddefconfig → make -j6（出一份 vmlinux）
② 量出账本            每个子系统编了多少文件/行，按行数排序砍
③ 分轮砍 config       一轮只砍一类，砍完 make
④ 真删目录             归零的目录直接 rm，这是"简化代码"的实际来源
⑤ 重构                只在少数热点动实现（调度单队列、RCU）；
                      锁语义一律保留 —— SMP 是真的
```

每轮结束跑：

```bash
~/kernel/tools/abi/check_symvers.py ~/kernel-meta-7.2.12/Module.symvers \
                                     ~/kernel/kpi/abi/nvidia.contract
```

→ 必须始终 **521/521 PASS**。一旦有 CRC 不符，说明这轮砍到了类型定义，回退。

## 与"重写"路线的取舍

| | 裁剪式 | 重写式 |
|---|---|---|
| 保留 | 语义天然正确 | 需逐条复现隐含假设 |
| 风险 | 删错东西 → 编不过/启动失败（**立刻可见**） | 语义偏差 → 偶发崩（**难查**） |
| 工作量 | 删 + 梳理 | 2~4 万行新写 |
| 行数结果 | 15~20 万（同量级） | 15~20 万 |

两者最终规模一样，但裁剪式的每处错误当场暴露。**选裁剪式。**
