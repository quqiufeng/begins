# begin（起初）— 裁剪内核 + 现成桌面

**名字**：`begin`，中文名「**起初**」。

取意：一切从起初开始 —— 不做又一个发行版，只为一台机器（RTX 3080 / 6 核 / 单 NUMA）
把 Linux 7.2.12 裁到只留需要的部分，从这条干净的起点往下走。

| 项 | 值 |
|---|---|
| 项目名 | `begin` |
| 中文名 | 起初 |
| 内核版本串 | `7.2.12-begin`（下次构建生效；当前待测产物是 `-rtx3080-20261025-test`） |
| 旧名 | `kdb`（2026-11-10 停用） |

## 现在是什么（事实，不是愿景）

| 层 | 谁写的 | 状态 |
|---|---|---|
| 内核 | **Linux 7.2.12 裁剪版**（不是自研） | 已编完、已装、待真机重启验证 |
| 驱动 | Linux 原样 | 复用，不改 |
| 桌面 | **现成桌面**（不是自研） | 沿用系统已有会话 |

一句话：**现在是一个被裁过的 Linux，不是自研内核。** 桌面也是现成的。

## 当前阶段

| 阶段 | 目标 | 状态 |
|---|---|---|
| **P0 能启动** | 裁剪内核在真机开机、进桌面、日常能用 | **PASS（2026-11-10 23:33 真机启动，8/8 项通过）** |
| **P1 基于此版本开发** | 在这份树上改 config / 打补丁 / 删代码，每次重编可回退 | **可开始**（P0 已 PASS） |
| P2 之后 | 见「长期愿景」 | — |

P0 的验收标准就是能日常用：进桌面、nvidia 驱动起来、网络、声音、USB 都正常。
不达标就回退旧条目继续裁，不往下走。

## 长期愿景（暂停，不是当前任务）

早期定过"自研 L0 内核 + linuxkpi 兼容层"的方案 A（`docs/scope.md`）：
内核自己写、驱动复用 Linux。这条路需要年，且和 P1 抢同一份精力。

```
L3  桌面（现成）              ← 现在用的
L2  Linux 驱动（原样编入）     ← 复用，不改
## 环境事实（与索引/构建精确对应）

| 项 | 路径 |
|---|---|
| 内核源码 | `/opt/linux/src/linux-7.2.12`（裁剪工作在此树内进行） |
| 配置 | `~/kernel-meta-7.2.12/.config` → 生效副本 `src/linux-7.2.12/.config` |
| 导出符号表 | `~/kernel-meta-7.2.12/Module.symvers`（24327 个） |
| 代码索引 | `/opt/code_caches/linux_7212_cache`（355188 块 + call_graph 60MB + dataflow 705MB） |
| 构建产物 | `build/artifacts/`（bzImage + config 快照），`build/initrd/`（验证用 initramfs） |

⚠️ `Module.symvers` 是**可链接 API 的唯一真相**；源码 grep 只能补结构体/宏。

## 目录

```
src/linux-7.2.12/   裁剪中的内核树（真正的工作面，本地，不入库）
src-archive/        裁剪后源码快照 tar.zst（88.1 MB，入库，解包即用）
build/              构建产物与日志
tools/trim/         lint_includes.py（找彻底缺失的头文件）
tools/abi/          check_symvers.py（零编译 CRC 对表）
docs/               设计文档（trim.md 是当前主文档）
notes/              踩坑记录
kpi/                API 面清单（愿景期产物，暂不推进）
```

## P0 验收清单（2026-11-10 23:33 实测 PASS）

实测结果：`uname -r` = `7.2.12-rtx3080-20261025-test`；RTX 3080 / 595.99.02 正常；LXQt(X11) 会话正常；
网络通（HTTP 200）；6 核识别；sda+nvme 挂载读写 283MB/s；USB 输入正常；dmesg 无致命错误。
遗留（非裁剪导致）：`amd_pstate: _CPC object is not present in SBIOS` → 无 cpufreq，BIOS 未提供 _CPC，旧内核同样如此。

逐项命令：

| # | 检查 | 命令 |
|---|---|---|
| 1 | 起来了、版本对 | `uname -r` → `7.2.12-rtx3080-20261025-test` |
| 2 | 无报错 | `dmesg -l err,warn \| head -30` |
| 3 | 桌面进得去 | 图形会话正常，无黑屏/掉驱动 |
| 4 | 显卡 | `nvidia-smi` 有型号、无 Xid 错误 |
| 5 | 网卡 | `ip a` 有地址，能上网 |
| 6 | 声音 | `aplay -l` 有设备，能出声 |
| 7 | USB/输入 | 键盘鼠标摄像头正常 |
| 8 | 磁盘 | `lsblk`、能挂载、能读写 |

**默认启动项（重要）**：`/etc/default/grub` 里
`GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-rtx3080-20261025"`，
默认进的是**旧内核**，不是裁剪版。当前正在跑的也是旧版（`uname -r` = `7.2.12-rtx3080-20261025`）。
所以重启不会自动进裁剪版，必须：

- 重启时进 `Advanced options for Ubuntu`，手选 `7.2.12-rtx3080-20261025-test`；或
- 先验证通过，再改默认：
  `sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-rtx3080-20261025-test"|' /etc/default/grub && sudo update-grub`

**回退**：改回上述 GRUB_DEFAULT，或重启时手选 `7.2.12-rtx3080-20261025`（旧条目），一切照旧。

## P1 基于此版本开发（P0 通过后）

在这份树上按"改一点 → 编 → 启 → 回退"的小步循环推进，每轮守两条底线：

1. **能启动**：`make -j6 bzImage modules` 通过，且重启后 P0 清单不复测失败。
2. **ABI 不破**：`tools/abi/check_symvers.py` 对 521 个内核侧符号始终 PASS（nvidia blob 靠它）。
3. **保留上一版**：新产物先进 `build/artifacts/<日期>`，装到 `/boot` 时旧条目不动，随时回退。

## 愿景附录（暂停，不投入）

早期方案 A 的产物，保留记录但当前不做：

- `kpi/virtio_blk.txt` —— virtio-blk 需内核提供 63 个符号（blk-mq 28 是真门槛）
- `docs/scope.md` / `docs/abi.md` —— 自研 L0 + linuxkpi 的分层与 ABI 契约
- 目标曾是 M1 hello → M2 virtio-blk → M3 framebuffer+自研桌面 → M4 真机 nvidia

现在这些全部让位于：**先把裁过的 Linux 跑稳，再在这上面开发。**
