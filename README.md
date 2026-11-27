# begin（起初）— 嵌入式直出系统：裁剪内核 + 一组自己直出的 app

**名字**：`begin`，中文名「**起初**」。

取意：一切从起初开始 —— 不做又一个发行版，只为一台机器（RTX 3080 / 6 核 / 单 NUMA）
把 Linux 7.2.12 裁到只留需要的部分，从这条干净的起点往下走。

仓库里同时有一条**嵌入式线**：arm64 机顶盒（121 Amlogic S905X2 / 123 全志 H618）上不装桌面环境，
跑裁剪内核 + 一组自己直出 DRM 的 app（桌面 / 播放器 / 阅读器 / 浏览器 / 微信）。
下面第 2 节讲的就是这条线的模型。

| 项 | 值 |
|---|---|
| 项目名 | `begin` |
| 中文名 | 起初 |
| 内核版本串 | `7.2.12-20261111-hwreal`（**当前在跑**，真机四项验收 PASS；已二次改动补回 squashfs/vfat/fuse/ipv6，待重启验证） |
| 下一版命名 | `7.2.12-begin`（P1 起用） |
| 装机 config | `configs/config-7.2.12-20261111-hwreal`（仓库内，逐字节即装机件） |
| 旧名 | `kdb`（2026-11-10 停用） |

## 现在是什么（事实，不是愿景）

| 层 | 谁写的 | 状态 |
|---|---|---|
| 内核 | **Linux 7.2.12 裁剪版**（不是自研） | 已编完、已装、待真机重启验证 |
| 驱动 | Linux 原样 | 复用，不改 |
| 桌面 | **自研桌面**（LuaJIT + SDL2/kmsdrm，`desktop/`） | 已在盒子（121/123）上跑，独占 KMS 直出 HDMI |
| app | 桌面 / 播放器 / 阅读器 / **浏览器** / **微信** | 各自独占 DRM master 直出 HDMI，一次一个上屏（见下文表格） |

一句话：**内核是被裁过的 Linux，屏幕上的每个 app 都是自己直出的。**

## 这是什么：嵌入式直出方案，不是桌面系统

目标机是 arm64 机顶盒（晶晨 S905 系 / 全志 H618，4×A53、3.9G 内存、无风扇），
跑的是**裁剪过的 Linux + 一组自己写的直出 app**，没有安装任何桌面环境：
**没有 Xorg、没有 Wayland 会话、没有 GNOME/KDE/LXQt，也没有 Qt/GTK 外壳**（浏览器那条路除外，
`cage` 是 74 包的单窗口 Wayland 合成器，不是桌面）。

显示模型是嵌入式的「**屏幕只有一个主人**」：

```text
app 自己 open("/dev/dri/card0") → modeset 设分辨率 → drmModeSetPlane/page flip
        ↑ 独占 DRM master                              ↓
   退出 close() 释放                          HDMI 出画（无中间合成器、无 X）
```

- **零会话依赖**：不装 systemd 图形 target，不跑 display manager，app 由 `systemd` 直接拉起；
- **切换 = 交棒**：要上屏的 app 先把占屏的停掉（`desktop` 带 `Restart=always`，必须先
  `systemctl mask --runtime desktop` 再 `stop`），退出后 `unmask + start` 还给桌面；
- **代价小**：桌面、播放器、阅读器都是 LuaJIT/C 的单进程；最重的是 Chromium 内核那两个
  浏览器≈微信，微信整套（cage+主进程+wxocr+wxplayer）实测 **918M**，整机 3.9G 仍余 2.7G。

已支持直出到 HDMI 的 app（前三个遥控器就能操作；浏览器/微信用鼠标或键鼠，遥控接入见下一节）：

| app | 实现 | 直出方式 | 状态 |
|---|---|---|---|
| **桌面** | `desktop/`：LuaJIT + SDL2（6641 行 + `tools/kmsflip.c`） | SDL2 `kmsdrm` 后端独占 card0，自绘文件网格 | 121/123 日常在用 |
| **播放器** | `hevcdec/`：C + V4L2（121 meson 自解 / 123 cedrus 硬解） | `vout.c` 直投 plane（NV12 / LINEAR） | 日常在用，硬解 720p≈14× 实时 |
| **阅读器** | 独立仓 `quqiufeng/reader`：LuaJIT + MuPDF（39 个 .lua / 6250 行） | 同上，kmsdrm 全屏 | 日常在用 |
| **浏览器** | `cog`（WPE WebKit，47 包）`-P drm`；备选 `cage + chromium`（74 包） | cog 自己占 DRM master 零拷贝直出；cage 那条多一次合成成线性 buffer | **已跑通**：123 2560×1440、121 4K 3840×2160@60；详见 [`chrome.md`](chrome.md) |
| **微信** | 微信 Linux 版 4.1.13.29 arm64（Chromium 内核，718M） | `sway 1.10.1` 合成后贴 plane，独占 2560×1440（壁纸 + 窗口居中 1280×720） | **已跑通**（123）；遥控器按键还没接进去，鼠标可点 |

> 微信这条要额外装合成器包：`apt-get install -y -q sway`（实装 sway + swaybg + libjson-c5，
> 共用已有的 libwlroots-0.18/seatd/dbus-run-session）。不装不报错，桌面会**静默回退到 cage**。
> 包清单、`wechat.conf`/`wx-center.py`/`wallpaper.png` 落点见 [`chrome.md`](chrome.md) §16.3.1。

### 遥控器是唯一输入 → 它就是个「智能轻显示端」

不需要键鼠、不需要桌面：一台盒子 + HDMI 线 + 一个 2.4G USB 遥控器（接收器插上即用，
`XING WEI 2.4G USB`，枚举出 4 个键盘类接口），就能把 NAS 上的影视、书、图片、
网页、微信全部调到大屏上。输入链路是自成一体的：

```text
遥控器 → evdev（keybd 用 EVIOCGRAB 独占，别的进程抢不走）
       → keys/<app>.lua 写死键位表（up=103 ok=352 back=158 …）+ 长按连发
       → apps/<app>.lua 挑前台 app（order：播放器 30 > 阅读器 20 > 桌面 10 > shell 0）
       → 各 app 的 unix socket 自动化口，一行 JSON 一个请求
```

这套东西让它具备「显示端」而不是「电脑」的几个特征：

| 特征 | 怎么来的 |
|---|---|
| **开箱只有一块屏** | 无会话、无 display manager，`desktop` 直接 kmsdrm 起；断网或 app 崩了 `resident-heal.sh` + timer 每 10s 纠正 |
| **一次只显示一件事** | 屏只有一个主人；外部 app 打开前 `screen:suspend()`，退出 `screen:resume()` |
| **遥控器就是全部 UI** | 方向 / OK / BACK / 菜单 / 音量，桌面、播放器、阅读器都靠这张表；图片就地预览，长按方向键翻列表 |
| **内容在远端** | 文件网格默认就是 NAS，`core/dav.lua` 直接 WebDAV PROPFIND，不在盒子上攒文件 |
| **可被脚本驱动** | 每个 app 都有自动化口（`state` / `click <id>` / `key <NAME>`），`core/semantic.lua` 再把状态汇成一张可读表——从外面看，它就是一个可编程的显示终端 |
| **加一个 app 就是加一个直出的进程** | 播放器、阅读器、浏览器、微信都是这样接进来的：谁要显示谁独占 DRM master |

已经能这么用的：NAS 影视 + 书库、视频播放、网页（中文与网页内视频都正常）、微信。
**还差的一步**：浏览器和微信的输入走 libinput（cage/WebKit 自己的后端），
而遥控器被 `keybd` 独占且没有 uinput 回注，所以这两者现在还得插个鼠标——
补齐方式（`uinput` 虚拟键盘回注 / 或在 keybd 里加 `apps/browser.lua`）见 [`chrome.md`](chrome.md) 第 4 节与 16.6。

### 被 AI agent 调用：一行 JSON 一个动作

对外它没有 API、没有 SDK，只有**三个 unix socket 控制口**——连上、写一行、读到 EOF 收应答。
每个 app 自己开一个口，协议都是「一行请求 → 一行应答」，客户端写完半关（`shutdown(SHUT_WR)`），
服务端读到 EOF 就立刻回包，不用猜长度：

| 口 | 谁开 | 协议 | 能做什么 |
|---|---|---|---|
| `/tmp/desktop-automation.sock` | 桌面 | JSON 行 | `ping` `list`（全部动作 id）`state` `brief` `digest` `click <id>` `key <NAME>` `call <fn>` |
| `/tmp/native-reader-automation.sock` | 阅读器 | JSON 行 | 同协议，`call reader.next` / `call reader.goto {"page":36}` |
| `/tmp/play.sock` | 播放器 | **纯文本**行 | `status` / `pause` / `vol +5` / `seek 30` |

客户端是 `keybord/sock.lua`：LuaJIT **FFI 直连 AF_UNIX**，connect、超时、短写循环、半关全自己来，
盒子上不需要 `socat`/`nc`（两个都没装）：

```lua
local sock = require("sock")           -- LuaJIT，无外部依赖

local ok, r = sock.req("/tmp/desktop-automation.sock", '{"cmd":"brief"}', 1000)
-- ok=true, r='{"ok":true,"pong":true,"app":"desktop","sel":"xxx.mkv",...}'
sock.req("/tmp/desktop-automation.sock", '{"cmd":"click","id":"select.xxx.mkv"}', 2000)
sock.req("/tmp/play.sock", "status")   -- 同一个函数，纯文本口也走它
```

**给 agent 看的那份状态是专门做的**，不是把内部结构倒出来：

- `state` → 完整嵌套表（`roots`/`mounts`/`window`/`screen`/`media`/`book`…），cjson 在才解得出；
- `brief` → **扁平摘要**，一行装下「前台是谁、在哪个目录、选中什么、在播第几秒、书第几页」，
  连极简解码器（盒子上没有 cjson 时）都解得动；
- `digest` / 每次 `click` 应答里的 `state_digest` + `changed` → 一个指纹，
  agent 用它判断「这一下到底动没动」，不必整屏截图比对。

`core/semantic.lua` 干的就是把三处分散的状态（桌面自己的 fs/preview、播放器的
`/tmp/play.state`、阅读器的自动化口）汇成这一张表；查外部进程一律走 `core/peer.lua` 带超时，
**绝不为了一句 state 卡住 30fps 主循环**。

**能力白名单是硬边界**：`handlers.caps` 给了就按它裁——`caps.cmds` 限定能发哪些命令，
`caps.click` / `caps.keys` / `caps.calls` 用「字面名或正则」限定能按哪些动作和键。
协议通了不等于什么都能做：`nav.*` 随便按，`call` 只到 `reader.*` / `player.*`，关桌面要显式放开。

**本机侧（x86 主机）的 LuaJIT 脚本**，拿来驱动和验收盒子：

| 脚本 | 干什么 |
|---|---|
| `tools/cog/cog.lua` | `luajit cog.lua x98h start <url>` / `open` / `reload` / `ping` / `shot out.png` / `stop`，JSON 走 SSH 进盒子起停直出浏览器并抓 HDMI 画面 |
| `tools/cdp/cdp_control.lua` `cdp_do.lua` | 换一条路：CDP（`--remote-debugging-port`）注入 JS，导航/求值/截图 |
| `tools/x96-shot.sh` `tools/drmcap/drmcap.c` | 抓屏（`/root/grabscreen-aarch64` → raw BGRA → 本机 ffmpeg 转 PNG） |

合起来的典型用法就是：`brief` 看一眼在显示什么 → 决定按哪个 `click` / 发哪个键 →
`digest` 确认变了 → `shot` 拉一张 PNG 存证。

浏览器的前置条件在**内核侧**：123 上 `cog -P drm` 能拿到 plane，靠的是 H616/DE33 显示补丁集
（13 个 drm 补丁 + 2 处 DT），换盒子或重刷内核前先读 [`chrome.md`](chrome.md) 第 10 节。

## 桌面：自己写的（不是现成会话）

盒子（arm64 机顶盒）上没有 X11/Wayland 桌面环境，`desktop/` 是唯一的屏幕底座：
LuaJIT + SDL2 `kmsdrm` 后端独占 `/dev/dri/card0`，一帧 = poll 事件 → 处理 → 绘制 → present。

| 项 | 事实 |
|---|---|
| 代码 | `desktop/` 28 个 `.lua` / 6641 行 + `tools/kmsflip.c` 574 行，无 C++ 框架、无 Qt/GTK |
| 显示 | SDL2 `kmsdrm` 全屏直出（开发机用 `SDL_VIDEODRIVER=dummy` 跑自动化） |
| 来源 | 文件网格默认就是 NAS，`core/dav.lua` 直接走 WebDAV PROPFIND（curl），不做本地同步 |
| 交互 | 2.4G 遥控器：左右相邻、上下换行、OK/ENTER 打开、BACK/ESC 返回；图片就地预览 |
| 外部 app | 书 → reader、影音 → player、目录/命令 → shell。打开前 `screen:suspend()`，退出后 `screen:resume()`，屏始终只有一个主人 |
| 自动化 | `core/automation.lua` 暴露 unix socket，一行 JSON 一个请求（`state` / `click <id>` / `key <NAME>` / `call ...`）；`core/semantic.lua` 再把 reader/player 的状态汇总成一份可读表 |
| 兜底 | `deploy/resident-heal.sh` + timer，每 10s 纠正被停掉/打成 failed 的 `desktop`、`keybd` |

配套的遥控底座在 `keybord/`：evdev 独占（`EVIOCGRAB`）取键 → `apps/<app>.lua` 转成动作 →
调对应 app 的自动化口；换盒子只换 `config.lua` 里的设备与键位映射。
app 表当前是桌面、播放器、阅读器、shell。**浏览器与微信已经能独占直出**（见上文表格），
但它们的输入走 libinput（cage），而遥控器被 `keybd` 的 `EVIOCGRAB` 独占、又没有 uinput 回注，
所以遥控按键暂时到不了这两者——这是当前唯一的断点，解法写在 [`chrome.md`](chrome.md) 16.6 节。

```bash
cd desktop
luajit main.lua                          # 真机：kmsdrm 全屏（占 /dev/dri/card0）
SDL_VIDEODRIVER=dummy luajit main.lua    # 开发机：无屏跑，走自动化口
```

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

方案 A 的替代路径是 **分块重写**（[`docs/design.md`](docs/design.md)）：驱动层原样复用，
内核**实现层**按块替换（RCU → locking → timer/wq → mm 分配器 → sched → blk），
每块一个 `CONFIG_MK_*` 开关、默认关、随时回退。首个块的契约清单见 [`notes/mk-rcu.md`](notes/mk-rcu.md)。

```
L3  桌面（自研）              ← desktop/：LuaJIT + SDL2/kmsdrm 直出
L2  Linux 驱动（原样编入）     ← 复用，不改
```

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
src-archive/        源码快照 tar.zst（两份：hwreal 68.9 MB / sandy-dbg2 77.2 MB，入库，解包即用）
build/              构建产物与日志
desktop/            **自研桌面**（LuaJIT + SDL2/kmsdrm）：文件网格、NAS、预览、开 app、自动化口、常驻兜底
keybord/            遥控底座：evdev 独占取键 → apps/<app>.lua → 各 app 的自动化口
hevcdec/            自研 V4L2 播放器（C）与 play.sh（两盒平面模式/硬解差异见 docs/box-matrix.md）
tools/trim/         lint_includes.py（找彻底缺失的头文件）
                    clean-build.sh（真·全新构建+计时，绕开不删 .o 的 make clean）
                    verify-boot.sh（QEMU 真启动 + ext4 挂载断言）
tools/abi/          check_symvers.py（零编译 CRC 对表）
docs/               设计文档
  build.md          **裁剪→编译→安装 完整流程**（照着敲就能复现装机内核）
  trim.md           裁剪方法与五轮账本（主文档）
  design.md         **分块重写方案**：驱动复用 + 实现层按块替换，M1~M7 路线
  box-matrix.md     121/123 两盒播放适配矩阵（V4L2 平面模式、ffmpeg 硬解、二进制选择）
  tracing-capture.md **动态追踪/网络抓包/TLS 明文依赖清单**（bpftrace、tcpdump、ecapture 真机实测）
  playback.md       **高清播放**：4K/HDR 片源主机转码 → 盒子 mpv 直显（命令 + mpv.conf/stats.lua 全文 + 坑）
notes/              踩坑记录
kpi/                API 面清单（愿景期产物，暂不推进）
```

## 怎么玩这份源码（clone → 编译 → 跑起来）

不用先跑裁剪流程。`src-archive/` 里是清空构建产物的完整源码树（`.config` 已就位），解包即可编译。
两份：`hwreal`（本机装机内核）与 `sandy-dbg2`（小机箱追踪/调试内核，ftrace/BTF/netfilter 全开）。

### 1. 取下来

```bash
git clone https://github.com/quqiufeng/begins.git
cd begins/src-archive
sha256sum -c SHA256SUMS          # 应输出「成功」
```

### 2. 解包

```bash
tar --zstd -xf linux-7.2.12-begin-src-20261110.tar.zst
cd linux-7.2.12
```

需要 `zstd`（`apt install zstd` / `pacman -S zstd`）。没有的话用 `zstd -dc x.tar.zst | tar -xf -`。

解开后 **550 MB / 60202 个文件**，`.config` 已带好，不用再 `make menuconfig`。

### 3. 编译

```bash
cp /boot/config-$(uname -r) /tmp/orig.bak   # 可选：留个对照
make -j6                                     # 本机 6 核，按自己核数改
```

产物 `arch/x86/boot/bzImage`。全量编译后目录会涨到 **约 11.4 GB**（实测：编译产物 9.04 GB / 31155 个文件，链接产物 3.11 GB / 46 个，其中 `vmlinux.unstripped` 一段就 1.16 GB），**留 12 GB 空闲空间**。

编完想还原本仓库里那种干净状态：

```bash
make clean      # 12 GB → 701 MB，2 秒
```

### 4. 装到机器上

```bash
sudo make modules_install
sudo make install
sudo update-initramfs -c -k 7.2.12-begin    # Debian/Ubuntu
# sudo dracut -f                              # Fedora/Arch 系
sudo update-grub
```

重启，GRUB 里选 `7.2.12-begin`。

### 这份树和上游的差别

| 项 | 上游 `linux-7.2.12.tar.xz` | 这份快照 |
|---|---|---|
| 文件数 | 94775 | **60202** |
| 解包体积 | 1.51 GB | **550 MB** |
| 配置 | 无 | **`.config` 现成**（4226 个 =y/=m，裁剪前 6717） |
| 源码改动 | — | **无，一字没改** |

只动了 `.config` 和删掉整个不需要的驱动目录实体，**C 代码原样未改**。所以任何上游文档、补丁、`git bisect` 经验都照常适用。

砍掉的清单在 `tools/trim/disable.list`（2265 个符号），规则在 `tools/trim/rules.txt`。想自己重走一遍裁剪见 `docs/trim.md`。

**已实测跑通五轮：全新构建 20m05s → 7m53s，编译单元 9000 → 4584。** 方法与账本在 `docs/trim.md` 第 82 行起（含真清场、记账口径、QEMU 验证的三个坑）。复现两条命令：

```bash
tools/trim/clean-build.sh configs/config-baseline-2026-11-11 6      # 基线 20m05s
tools/trim/clean-build.sh configs/config-7.2.12-20261111-hwreal 6   # 装机版（在跑的）
tools/trim/verify-boot.sh
```

**要从零装出一模一样的内核，看 [`docs/build.md`](docs/build.md)**：9 步全流程 + 每一步的断言命令 + 回退路径，
配套的装机 config 就是 `configs/config-7.2.12-20261111-hwreal`（入仓库，直接 `cp` 即可编译）。

二次改动（§4.5）补回了轮5 误裁的 `SQUASHFS`/`VFAT_FS`/`FAT_FS`/`FUSE_FS`/`IPV6`——
缺了它们 snap 全坏、`/boot/efi` 挂不上。增量编译 274 s，覆盖安装前先留 `.prev` 备份，
装机 config 已同步更新（`=y 2175 / =m 645`，659 个 `.ko`）。

### 注意

- **显卡驱动**：用发行版自带的就行，本仓库不含 NVIDIA 闭源 blob（再分发违反 EULA）。`kpi/abi/nvidia.contract` 只是 CRC 清单文本（610 个符号 = 内核侧 521 + 模块间 89），用来校验裁剪有没有破坏 ABI。
- **不是自研内核**：这就是被裁过的 Linux 7.2.12，驱动、文件系统、网络协议栈全是原样的。
- **驱动只服务一台机器**：这份树的驱动是按本机（Ryzen / RTX 3080 / NVMe / AMD SATA / RTL8168 / USB xHCI）裁的，**换别的 x86 机器，驱动需要专门处理**，不能照搬。

### 换机器：驱动要补回来

砍驱动是**连目录一起删**，不是只关 `.config` 开关。所以 `make menuconfig` 补不回来——符号背后已经没代码了，得先把目录从上游解包回去。

常见缺的：

| 目录 | 上游文件数 | 谁会用 |
|---|---|---|
| `drivers/net/wireless/` | 2422 | 笔记本、无线网卡（现树 0 文件） |
| `drivers/net/ethernet/intel/` | 428 | Intel 有线网卡 e1000e/igb/i40e |
| `drivers/gpu/drm/amd` `i915` `nouveau` | — | AMD/Intel 核显、开源 NVIDIA |
| `drivers/{mmc,ufs,watchdog,iio,reset,pmdomain,pcmcia,staging}` | — | 传感器、看门狗、老笔记本 |

**别手抄清单——在目标机器上问它自己。** `tools/trim/adapt.py` 读 `/sys` 拿到本机真正在用的
驱动名，反查 `obj-$(CONFIG_X) += y.o` 得到符号和目录，缺哪个就从上游 tar 里只解哪个：

```bash
python3 tools/trim/adapt.py probe            # 上机探测 → notes/hw.json
python3 tools/trim/adapt.py plan             # 谁缺目录、谁缺 CONFIG，一目了然
python3 tools/trim/adapt.py fetch --apply    # 缺的目录从 tar.xz 拷回树里
python3 tools/trim/adapt.py refs  --apply    # 把目录重新挂回父 Makefile/Kconfig（否则代码是哑的）
python3 tools/trim/adapt.py config --apply   # 生成 config 片段并 merge，回报没生效的符号
make -j6
```

本机实测：100 个在用驱动/模块 → 88 个已就绪、0 个缺目录（这棵树本来就是为本机裁的）；
伪造一台 Intel 网卡+无线+读卡器的机器 → 正确报出 3 个缺目录并从上游拷回 921 个文件。
细节见 [`docs/adapt.md`](docs/adapt.md)。

手工兜底（知道确切目录时）：

```bash
tar -xf linux-7.2.12.tar.xz \
    linux-7.2.12/drivers/net/ethernet/intel \
    linux-7.2.12/drivers/net/wireless
cp -r linux-7.2.12/drivers/net/{ethernet/intel,wireless} ./drivers/net/
make menuconfig      # 这时符号才有代码可开
make -j6
```

x86 核心链路（ACPI / PCI / AHCI / NVMe / USB xHCI / input / DRM core）是完整的，所以换机器**能进桌面**，典型问题是能开机但没网。

## P0 验收清单（2026-11-10 23:33 实测 PASS）

实测结果：`uname -r` = `7.2.12-rtx3080-20261025-test`；RTX 3080 / 595.99.02 正常；LXQt(X11) 会话正常；
网络通（HTTP 200）；6 核识别；sda+nvme 挂载读写 283MB/s；USB 输入正常；dmesg 无致命错误。
遗留（非裁剪导致）：`amd_pstate: _CPC object is not present in SBIOS` → 无 cpufreq，BIOS 未提供 _CPC，旧内核同样如此。

注：P0 当时借发行版 LXQt 会话验证的是**内核**；桌面层后来换成自研 `desktop/`（跑在盒子上，见上文）。

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
