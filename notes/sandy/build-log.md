## 2026-11-12 sandy-dbg2-20261111（远端 192.168.1.68 已启动，verify PASS=21/FAIL=0）

- 树：build/sandy-20261111/tree，defconfig 起步 + configs/sandy-dbg-20261111.fragment
- **坑**：defconfig 下 `CONFIG_BPF_SYSCALL=n`，而 `DEBUG_INFO_BTF depends on BPF_SYSCALL`，
  于是 olddefconfig 会把 DEBUG_INFO_BTF **静默丢掉**（不报错、bzImage 照出）。
  已在 configs/trace-capture.fragment 追加第 5 节（BPF_SYSCALL/BPF_JIT/CGROUP_BPF/BTF）补齐。
- 首次部署 7.2.12-sandy-dbg-20261111 时只有 BTF 缺失 + ftrace 整块 n（tracers 只有 blk nop）。
- 本次：DEBUG_INFO=y + DWARF5 + BTF(6.9MB) + FUNCTION_TRACER/FUNCTION_GRAPH/DYNAMIC_FTRACE/FTRACE_SYSCALLS
  实测 available_filter_functions 63363 条、uprobe 符号 203 个、bpftrace kprobe 命中、perf 可用。
- 体积代价：bzImage 18M（9→18M），initrd 53M，/lib/modules 110M（.ko 带调试信息；
  想瘦身用 `make INSTALL_MOD_STRIP=1 modules_install`）。
- verify-remote.sh 已修：tracefs 根目录 0700，探针改走 `sudo -n`，否则恒假失败。
- 远端 perf 注意：/usr/bin/perf 是 Ubuntu 包装脚本，认不出自定义内核版本，
  真身是 /usr/lib/linux-tools/6.8.0-147-generic/perf。
- /boot 现有 4 个内核，dbg(第一版) 可删。

## 第 7 轮：dbg2 转正为远端默认内核（2026-11-12 00:0x）

目标：192.168.1.68 不只「跑过」dbg2，而是 **GRUB 持久默认** = dbg2，且不依赖 grub-reboot 一次性条目。

做法：
- 新增 `tools/kernel/set-default-kernel.sh <ver> [user@host]`：改 /etc/default/grub 的 GRUB_DEFAULT
  → update-grub → `grub-script-check` 复核 → 清 next_entry 残留 → 校验菜单条目真实存在；失败自动回滚备份。
- `remote-stage.sh` 加 `--persist`（直接转正）/ `--no-grub-reboot`（只落盘），默认仍是一次性首启防砖。
- `verify-remote.sh` 末尾新增「转正」步骤：PASS 且跑在目标内核上 → 自动调 set-default-kernel.sh（幂等）。
- `remote-install.sh` 把 set-default-kernel.sh 一起 scp，第 4 参数透传模式。

坑（重要）：`grep -oE "with Linux <ver>[^']*" /boot/grub/grub.cfg` 会先命中文件顶部的
`set default="Advanced options for Ubuntu>Ubuntu, with Linux <ver>"`，那行尾部自带引号，
于是写进 /etc/default/grub 变成 `GRUB_DEFAULT="…""`（双引号）→ 下次 update-grub 直接
`Syntax error: EOF in backquote substitution`。改为只从 `menuentry 'Ubuntu, with Linux <ver>' …` 行
用 sed 取标题，并在 update-grub 后加 `grub-script-check` + 失败回滚。已修复远端文件并重新生成 grub.cfg。

实测：
- GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.2.12-sandy-dbg2-20261111"
- `grub-editenv list` → next_entry 空；连续两次 reboot 都稳定进 dbg2（证明是持久默认而非一次性）
- verify-remote.sh PASS=21 FAIL=0

遗留（可选）：模块未 strip，/lib/modules 110M / initrd 53M；旧内核 sandy-dbg-20261111 可删。

## 第 8 轮：远端 7.2.12-sandy-dbg2 声音 + 抓包/追踪能力实测（2026-11-12 00:10）

### 声音：全部正常
- 3 张声卡全识别：card0 HDA Intel PCH(alc662, 板载 analog + HDMI)、card1 COMICA Joy Uni(USB 麦)、card2 DUNU DTC 480(USB DAC)。
- 模块：snd_hda_codec_alc662/intelhdmi/hdmi、snd_usb_audio 均加载；dmesg 音频无 err/warn（generic codec 走 autoconfig，无 xrun）。
- 实测（paplay 440Hz/2s + parec 录 monitor 算 RMS，峰值 8000 = 生成幅度 24.4%FS，说明链路无损）：
  DUNU DAC RMS 3464 / HDMI RMS 3265 / COMICA RMS 4000 —— 三条 sink 都确实出声。
- ALSA 直通 `aplay -D hw:0,0` 正常（绕开 PipeWire 也通，说明内核 ALSA 层没问题）。
- 输入：COMICA USB 麦 RMS 33 峰值 356（有声但很轻，需在 wireplumber 里加增益）；板载 analog 输入 RMS 1001 正常。
- 默认 sink = DUNU DTC 480，70% 未静音；HDMI sink 31% 且静音（不影响）。

### 网络抓包：内核侧齐备，用户态缺件
- AF_PACKET 原始抓包 OK（6 帧）、tcpdump **原先未装 → 已 apt 装上**，实抓 5 包 + BPF 过滤 `tcp or udp or icmp` 正常，0 dropped。
- 注意网卡名是 **enp2s0**（不是 eth0）。
- config：PACKET=y、NETFILTER=y、NETFILTER_XTABLES=y、NETFILTER_NETLINK=y、INET_DIAG、IP_ADVANCED_ROUTER=y、TLS=m、XFRM_USER=y 全有。
- 缺：tshark/dumpcap、nftables、iptables、conntrack、trace-cmd、nmap（工具层，内核支持都在）。

### 动态追踪：内核能力完整，userspace perf 有个坑
- BTF /sys/kernel/btf/vmlinux 6.9MB 在；tracefs+debugfs 已挂；available_filter_functions 63363 个；sysrq 可写。
- config：BPF_SYSCALL/JIT、KPROBES/KPROBE_EVENTS、UPROBES/UPROBE_EVENTS、FTRACE/FUNCTION_TRACER/DYNAMIC_FTRACE/FTRACE_SYSCALLS、DEBUG_INFO_BTF、PERF_EVENTS/TRACEPOINTS 全 y。
- 实测通过：bpftrace tracepoint 计数、kprobe_events 建/删 p:kprobes/myprobe 成功、function_graph 抓 vfs_read 调用树、perf trace 出 56 行 syscall。
- **坑1**：Ubuntu 的 /usr/bin/perf 是壳，按 uname 找 linux-tools-<ver>，我们是自编 localversion 所以报 "perf not found for kernel 7.2.12-sandy"。真二进制在 /usr/lib/linux-tools/6.8.0-147-generic/perf，直调可用。建议做软链或包装。
- **坑2**：`perf record -F 99`（cycles 频率模式）采样数 0；`-e cycles -c 100000`、`-e cpu-clock`、`-e task-clock` 都有样本。Sandy Bridge 老 PMU 的频率模式在这版 perf/kernel 组合下不可靠，采样请用定周期 -c。perf stat 硬件事件正常（cycles/instructions/branches/cache-misses 都能读）；nmi_watchdog 无 sysctl 项（已编译掉）。
- pmu 设备齐：cpu/cstate_core/cstate_pkg/uncore_cbox_0-3/uncore_imc/msr/kprobe/uprobe/i915。

## 第 8 轮：dbg2 补回 netfilter，重新落盘并重启验收（2026-11-12 00:25）

**起因**：dbg2 第一版裁剪时把 `CONFIG_NETFILTER` 整块关掉了，机器上 `nftables`/`iptables`
直接不可用（模块不存在），属于「跑起来能用但功能缺一块」的隐性缺陷。

**改了什么**（都在 `configs/sandy-dbg2-20261111.fragment`，基线 x86_64_defconfig）：
- `CONFIG_NETFILTER=y`、`CONFIG_NF_TABLES=m`（+ INET/NETDEV/ARP=y）
- `CONFIG_IP_NF_IPTABLES=y`、`CONFIG_NF_NAT` **内置 =y**（不是模块，`find *.ko` 找不到属正常）
- `CONFIG_NETFILTER_XTABLES_LEGACY=y` + `XT_MATCH_STATE/CONNTRACK` 等 → iptables 兼容层可用

**验证方式变了**（重点）：不再只看「模块在不在」，而是真写规则 + 真看 counter。
`verify-remote.sh` 新增第 3 节 6 项：
```
✅ nf_tables/nft_ct/iptable_filter 模块可加载
✅ nft list ruleset 可用（nfnetlink 通路通）
✅ nft 可写入规则（table/chain/rule 落盘成功）
✅ 规则真生效：打到 :9 的包被计数 1 个（数据面通）
✅ iptables filter 表可用（兼容层）
✅ iptables nat 表可用（兼容层）
```
PASS 由 20 → **PASS=27 FAIL=0**（转正步骤自动跳过，已是默认）。

**顺手修的两个静默 bug**（`tools/kernel/apply-fragment.sh`）：
1. `# CONFIG_X is not set` 行以前被 case 忽略 → 反向导出的 fragment 回灌时「关不掉」符号；
2. `LOG_BUF_SHIFT=18` / `NLS_DEFAULT="utf8"` 这类数值/字符串行以前被整行丢弃 → 配置会漂移。
   现已补 `# ... is not set` → `-d`、`CONFIG_*=*` 兜底 → `--set-val/--set-str`。

**configs 不再手写**：`configs/sandy-dbg2-20261111.fragment` 由 `make savedefconfig` 从真实
`.config` 反向导出（317 行含注释 / 310 条配置）。回灌验证：cp .config → /tmp，
用同款循环灌 fragment，再与真实 `.config` 做归一化 diff → **0 行差异（4015 vs 4015）**。

**部署与退路**：远端现役 dbg2 先备份为 `*.prev`（/boot 4 个文件 + /lib/modules 110M），
再同名覆盖安装 → reboot。回线后 `uname -r` = 7.2.12-sandy-dbg2-20261111，
GRUB 持久默认仍是它；`dbg`(第一版) 和 `*.prev` 都留在菜单里可手工选回。

## 第 9 轮：清理旧内核，只保留现役 dbg2（2026-11-12 00:27）

**要求**：只留 `7.2.12-sandy-dbg2-20261111`，其余全清。

**清掉的东西**：
| 对象 | 处理方式 |
|---|---|
| 原厂 6.8.0-147 栈（image/modules/modules-extra/headers/generic 元包） | `apt purge`，共 8 个包 |
| `7.2.12-sandy-20261102` | rm（/boot 4 文件 + modules 442M） |
| `7.2.12-sandy-dbg-20261111` | rm（/boot 4 文件 + modules 11M） |
| `7.2.12-sandy-dbg2-20261111.prev` | rm（/boot 4 文件 + modules 110M） |
| `/boot/vmlinuz`、`initrd.img` 及其 `.old` 符号链接 | 原本指向 6.8，已重建指向现役内核 |

**踩到的坑（差点漏删）**：第一版清理脚本用子串判断保留（`case "$b" in *"$KEEP"*)`），
而 `.prev` 文件名里**同样含**新内核版本号 → `vmlinuz-...dbg2-20261111.prev` 被误判为保留，
4 个 `.prev` 文件和 110M 模块目录会整批漏掉。dry run 时发现，改为精确等值匹配才对。

**结果**：/boot 426M → **87M（5%）**，/lib/modules 只剩 144M 一个目录，全盘 19G 未变。
grub.cfg 只剩 1 个启动项 + recovery + UEFI 固件设置，`grub-script-check` 通过。

**⚠ 现状是零退路**：机器上再无第二个内核。`apt purge` 同时移除了 `linux-generic` 元包，
以后 `apt upgrade` 不会自动装回 Ubuntu 内核（符合只跑自编内核的意图）。
若新内核下次启动失败，远程无法自救，只能现场用 U 盘/PE 修复。

## 第 10 轮：清理后冷启动验证（2026-11-12 00:28）

清理旧内核后重启，这是**唯一一次验证机会**（机器上已无退路内核）。

- reboot 发出 00:27:39，SSH 回线 00:28:10（**15 秒**），boot_id 变更
  `f933a187…` → `cfac46c7…`，确认非假重启。
- `uname -r` = `7.2.12-sandy-dbg2-20261111`，本次确实由重建后的 `/boot/vmlinuz` 引导。
- `verify-remote.sh` 全量复验：**PASS=27 FAIL=0**。
  驱动 8/8 绑定、tracer/kprobe/BTF/uprobe 全可用、nftables 数据面真通、systemd 0 failed。
- 转正复核：GRUB_DEFAULT 仍指向该内核，下次重启不变。

**勘误**：本轮中途我用 `grep -c "^ *[0-9]" /proc/asound/cards` 临时判声卡，得 0 并误报"声卡 0"。
实际验收脚本确认 `snd_hda_intel` 已绑定、声卡 `HDA Intel PCH at 0xf7e00000 irq 27` 存在，音频正常。
临时指标不可靠，以 verify-remote.sh 为准。

**已修**（00:30）：`verify-remote.sh` 的 `panic=10` 提示原写死"会自动重启回老内核"，
现改为按实际可引导内核数动态输出——只有一份时明确报"无退路，panic 后重启回同一份"，
多份时报可回落，并额外提示远程切换风险。验证：`bash -n` 通过，实跑输出符合预期。

## 第 11 轮：补 TUN/TAP（`CONFIG_TUN=m`，2026-11-12 22:02）

**要求**：这台小机箱要能跑 wireguard/tailscale 一类的东西，需要 `/dev/net/tun`。

**坑的经过（值得记住）**：`scripts/config -e TUN` 之后我图省事，**用
`make drivers/net/tun.ko` 单独编一个模块、scp 到远端 `/lib/modules/` 替换**，
连挂两次不同的错：

| 尝试 | 报错 |
|---|---|
| 单独编、带 BTF | `BPF: [155041] ENUM (anon) ... Invalid name` / `failed to validate module [tun] BTF: -22` |
| 单独编、关 `DEBUG_INFO_BTF_MODULES` | `module: x86/modules: Invalid relocation target, existing value is nonzero for sec 28, idx 1` |

**根因不是 tun**：`CONFIG_DEBUG_INFO_BTF_MODULES=y` 下模块 BTF 是**相对 vmlinux BTF 的
split BTF**（类型 id 从基准表尾部续号，例中 155041）。模块集必须和**正在跑的那个 vmlinux**
同源；只换模块不换 vmlinux，或脱离完整构建单编一个 `.ko`（section 号、modpost 产物都对不上），
两种都必然报上面两类错。判据：`modprobe -r nf_tables && modprobe nf_tables` 也报同样 `-22`。

**按文档的正确做法**：

```bash
# 1) config 只走 fragment/snapshot，一个版本一份（§2）
scripts/config --file .config -e TUN && make olddefconfig
cp .config ~/kernel/configs/config-7.2.12-sandy-dbg2-20261111     # 与 .config md5 一致

# 2) 完整构建，让 vmlinuz 与整套模块同源
cd ~/kernel/build/sandy-20261111/tree && make -j6

# 3) 用现成通道落盘，不手搬单 .ko
~/kernel/tools/kernel/remote-install.sh 7.2.12-sandy-dbg2-20261111 \
    /home/quqiufeng/kernel/build/sandy-20261111/tree 192.168.1.68 --no-grub-reboot
```

**换内核的安全套路**（机器只有一份内核，`无法远程回退`）：

```bash
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux $V"   # 一次性：新内核
# 持久默认若设为 "$V.prev" 即可在 panic 后回落；本次默认仍是同名新内核（版本串没变）
reboot
```

**结果**：22:01:40 冷启动，`boot_id c737a02f… → f57056ae…`；`modprobe tun` rc=0，
`ip tuntap add/del dev tun-test0 mode tun` 进出都成功；`verify-remote.sh` **PASS=27 FAIL=0**。
/boot 171M（含 4 个 `.prev` 备份），`/lib/modules/$V` 146M / 106 个模块。

> **`.prev` 已清（22:06）**：按 §4.5 流程 `rm -f /boot/{vmlinuz,initrd.img,config,System.map}-$V.prev`
> + `rm -rf /lib/modules/$V.prev`（本次无此目录，`.old` 那套没跑过 modules_install）→ `update-grub`。
> 菜单只剩 `Ubuntu` / `7.2.12-sandy-dbg2-20261111` / recovery / UEFI 四项，`grep -c '\.prev' grub.cfg` = 0，
> `saved_entry` 仍指向在跑的内核；`/boot` 从 165M 降到 **87M（5%）**。
> **代价要记住**：清静之后机器上就只剩这一份内核，`vmlinuz.old` 也指向同一个文件，再覆盖安装前必须先备份。

## 第 12 轮：dbg3 定稿快照 + fragment 重导出（2026-11-14 17:50）

**背景**：dbg3 已转正为远端默认内核（第 11 轮），但 `configs/` 里躺的还是 dbg2 的快照和 dbg2 的
savedefconfig fragment——两条都会把人带回 dbg2 的错误路径。

**做了什么**：

| 动作 | 对象 |
|---|---|
| 新增快照 | `configs/config-7.2.12-sandy-dbg3-20261114`（130 K，4987 行），与 `build/sandy-20261111/tree/.config` **字节一致**，md5 `1d507b74ff60dd1fbb493c46b3fcfd6e` |
| 删除快照 | `configs/config-7.2.12-sandy-dbg2-20261111`（git 03c3419 可取回） |
| 新增 fragment | `configs/sandy-dbg3-20261114.fragment`，`make savedefconfig` 反向导出 312 行（310 条配置） |
| 删除 fragment | `configs/sandy-dbg2-20261111.fragment` |
| 改文档 | `docs/build.md` §2 分工表（当前装机版换成 dbg3 + 新增「fragment 也只留一份」规则）；`src-archive/README.md` 叠加链标注 dbg2 fragment 已删 |

**回灌验证**（同 §8 的方法，不是嘴上说）：

```bash
cp .config /tmp/real-dbg3.config
make x86_64_defconfig
tools/kernel/apply-fragment.sh . configs/sandy-dbg3-20261114.fragment
diff <(grep -E '^(CONFIG_|# CONFIG_)' .config | sort) \
     <(grep -E '^(CONFIG_|# CONFIG_)' /tmp/real-dbg3.config | sort)
# → 0 行差异，4015 项 vs 4015 项
cp /tmp/real-dbg3.config .config && make olddefconfig   # "No change to .config"，md5 仍是 1d507b74…
```

> **做完回灌一定要把 `.config` 恢复回去再跑一次 `olddefconfig`**，否则 `.config` 对了但
> `include/config/auto.conf` 还是回灌态，下一次增量编译会按错的 autoconf 走。

**dbg2 → dbg3 的真实差异只有 3 项**：`LOCALVERSION`、`USER_NS`（n→y）、`TUN`（n→m）。
其余 4012 项一字未动，所以这两个快照的 diff 本身就是一份准确的变更记录。

**留着的 fragment（手写意图链，不要删）**：`sandy-from-zero`（defconfig 起步）、`netfilter`
（nft/iptables 整块）、`sandy-dbg`（第一版追踪开关）、`trace-capture`（BPF 抓栈流程，`trace/README.md` 还在用）、
`trim-conservative` / `trim-fast`（裁剪模板）。判据：快照里读不出「为什么偏离 defconfig」，这就是它们的价值。
