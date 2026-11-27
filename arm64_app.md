# arm64_app.md — 盒子 app 的两种直出模式（遥控器 + Agent 自动化）

> 主用机：**123 `x98h`**，全志 H618，aarch64，内核 `7.2.12-x98`，HDMI 2560×1440。
> 121 `x96`（Amlogic S905X2）现在**不可达**（`ssh` 报 No route to host），但那台机器上验证过的
> 分辨率/崩溃差异仍记在 `chrome.md` §15，别把两条机型的结论混着引用。
> 具体命令细节分三份文档：构建打包 `arm64_build.md`，业务代码写法 `reader_dev.md`，
> 浏览器/微信/内核侧 `chrome.md`，硬件与内核 `x98h.md`。

---

## 0. 一句话方案

**app 有两种模式，共用一套输入和一套控制面：**

| 模式 | 谁 | 上屏方式 | 输入怎么进来 |
|---|---|---|---|
| **A. 原生直出** | 桌面 / 播放器 / 阅读器 | 自己 `open(/dev/dri/card0)` → modeset → page flip（SDL2 `kmsdrm` / 直接 plane） | keybd 独占 evdev，按键翻译成动作打 app 的 socket |
| **B. cage 直出** | 浏览器 / 微信（Chromium 内核） | `cage` 独占 DRM master，合成后贴 plane；app 只是 cage 里的一个 Wayland 客户端 | keybd 独占 evdev，**原样重放进 uinput 虚拟键盘**，cage/libinput 收得到 |

```
 物理遥控器（+2.4G 键鼠 dongle）
      │ evdev（keybd EVIOCGRAB 独占）
      ▼
  ┌─────────────┐  动作/键名   ┌────────────────────────┐
  │ keybd       ├─────────────►│ A: /tmp/<app>-automation.sock │
  │ FOCUS_TTL   │              └────────────────────────┘
  │ =800ms      │  原始按键     ┌────────────────────────┐
  │             ├─────────────►│ uinput keybd-passthru  │──► cage → chromium 页面
  └─────────────┘              └────────────────────────┘
      │ 判前台靠 ping 各 app socket
      ▼
  app 主循环（A） / 页面（B）→ KMS/DRM → HDMI

  agent/ssh ── 一行 JSON ──► A: socket  ┐
            ── CDP/9222 ──► B: chromium ┘ 两个控制面，别互相冒充
```

三条不变式（违反任何一条，整套东西互相打架）：

1. **屏幕只有一个主人**：起任何直出 app 前先 `systemctl mask --runtime desktop && systemctl stop desktop`，
   退出后 `unmask + start`。desktop 是 `Restart=always` + `KillMode=process`，不 mask 就会被拉回来抢屏。
2. **evdev 只有一个主人**：keybd `grab=true` 独占；app 自己绝不再 `EVIOCGRAB`（B 模式的经 uinput 回注，不是抢设备）。
3. **遥控器按得动 = agent 一定调得动**：A 模式走同一个 socket 协议；B 模式走 CDP + uinput 注入，
   不存在"只有鼠标能点"的暗门（微信侧还没补齐，见 §6）。

---

## 1. 平台约束（决定架构，不是风格选择）

| 约束 | 事实（123 实测） | 架构后果 |
|---|---|---|
| 没有桌面会话 | 没有 Xorg/GNOME/KDE；`cage` 是 74 包的单窗口 Wayland 合成器，不是桌面 | 一次只上一个 app；切换=停旧的起新的 |
| cage 的启动前提 | 缺 `XDG_RUNTIME_DIR` 会立刻 exit 1；要 `LIBSEAT_BACKEND=seatd` | `desktop.service` 里已带这两个环境变量，别在 shell 里裸起 cage |
| 无 GPU 加速保证 | 4×A53 + Mali，渲染实际走 gles，合成多一次线性 buffer | 缩略图/纹理自己缓存；页面别堆动画 |
| 内存 3.9G | 浏览器≈微信整套实测 **918M**（cage+主进程+…），余 2.7G | 大 PDF/OCR 仍要 LRU；同时只留一个 Chromium |
| 无 cjson | 盒上 Lua 侧没有 cjson | 应答里有**扁平** `brief`；CDP 用零依赖 `/root/cdplib.lua` |
| 两条输入源 | 遥控器 + `XING WEI 2.4G` 键鼠 dongle（枚举 4 个键盘类接口，`0957:0007`） | 键表必须收全别名；鼠标只在 B 模式有用 |
| 抓屏不等于 fb0 | cage 上屏后 `/dev/fb0` 里没有桌面像素 | 桌面走 socket `app.capture`，cage/cog 走 `grabplane`（§5） |

---

## 2. 分层契约

```
lua/ui/*            界面、状态机、主题            ← 业务，改这里最多
lua/ffi/*           cdef + 薄封装                 ← 唯一允许 ffi.C 的地方
──────────────────────────────────────────────  唯一平台契约：C ABI / 页面 JS
lib<app>_native.so                                  文档模型、ioctl、渲染到缓冲
        ↑
  SDL2（kmsdrm）        ── 模式 A
  cage + Chromium      ── 模式 B（页面里那层 JS 就是它的"业务层"）
```

- A 模式：C 只做没状态机的事（指针、解析、渲染、落盘），界面判断全在 Lua；reader 的 C 1726 行 / Lua 6250 行这个比例是对的。
- B 模式：业务就是网页 + 注入的 JS（`browser-nav.js` 负责选点/进入），别在盒子上写第二个 UI 框架。
- 两种模式都**不碰内核**：内核只提供 DRM/cedrus/音频，app 侧改动不要求重编内核。

---

## 3. 遥控器链路（两种模式共用）

### 3.1 三层，各管一件事

| 层 | 件 | 干什么 | 不干什么 |
|---|---|---|---|
| 守护 | `/opt/keybord/keybd.lua` | `EVIOCGRAB` 独占 evdev、判前台、分发动作、建 uinput 直通、控制口 `/tmp/keybd.sock` | 不认识业务 |
| 键表 | `keys/<app>.lua` | 键名 → 码 → 动作名，冻结后可直接手改 | 不含逻辑；没有这个文件就退回 `act.lua <app> <action>` |
| app 条目 | `apps/<app>.lua` | `order`、键→动作映射、跨进程动作（起/停外部 app） | 不读 evdev |

盒上 `apps/` 现有：`desktop.lua`(10) `player.lua`(30) `reader.lua`(20) `browser.lua`(25) `shell.lua`(0)。
**微信没有 app 条目** —— 起了微信时前台判定会落到 desktop/shell，这是 §6 的缺口。

### 3.2 判前台与直通：为什么要两条路

keybd 每 **800ms** 对每个 app 的 socket 发 `{"cmd":"ping"}`，谁应答谁收键；app 崩了只是没人答，
键自动落给下一个。顺序固定：**player 30 > browser 25 > reader 20 > desktop 10 > shell 0**。

B 模式的 app 不是我们的 socket 服务，ping 不到它，所以两件事同时做：

1. keybd 起来时 `evdev.uinput_create("keybd-passthru")` 建一个虚拟键盘，把真设备的按键
   **原样重放**（uinput 上 key-down/up 成对，key-up 不派发动作）；
2. `apps/browser.lua` 里方向键/OK 一律映射成 `noop`——只放行、不去翻背后的桌面
   （桌面还活着、socket 也在，不挡就会被它的 `nav.*` 吃掉）。

坑：自建的 uinput 设备必须从扫描列表里排除，否则 grab 到自己转发的事件 → 自激环路；
keybd 重启时要给 uinput 全码补一次 `value=0`，不然按键会卡在按下状态。

调参（`/opt/keybord/config.lua`，改完 `systemctl restart keybd` 或控制口 `reload`）：

| 变量 | 现值 | 含义 |
|---|---|---|
| `grab` | `true` | 独占 evdev；关掉则各吃各的，容易一按两翻 |
| `focus_ttl` | 800 | 前台判定缓存 ms |
| `dedup_ms` | 40 | 同码去抖（两个接口报同一个键） |
| `repeat_ms` | 220 | 长按连发间隔，只对 `repeatable(action)` |
| `dispatch` | `exec` | 每键 fork `timeout 6 luajit …`（隔离好）；`inproc` 快但一崩全崩 |
| `exclude` | `Mouse,Touch,Video,HDMI` | 这些设备不吃 |

### 3.3 键名表（app 侧 `on_key` 认这些）

`LEFT RIGHT UP DOWN`、`OK ENTER RETURN SPACE`、`BACK ESC ESCAPE`、
`HOME END PAGEUP PAGEDOWN CHANNELUP CHANNELDOWN`、`MENU REFRESH F5`、`QUIT EXIT`。

- 别名必须都收（`CHANNELUP`≡`PAGEUP`），不同遥控器码不一样。
- **阻塞键**（`OK/ENTER/RETURN/SPACE`）在 A 模式会进阅读器/播放器这种外部进程：应答必须先发出去、
  动作排队到下一帧，否则控制端 3s 超时误判失败，再触发 fallback 抢屏（`desktop/main.lua` 的 `defer()`）。
- B 模式反过来：按键要**立刻**重放进 uinput，别在 keybd 里等。

### 3.4 浏览器里的返回与选点（B 模式特有）

chromium kiosk 没有浏览器 UI，外部网站也不处理 ESC，所以：

| 需求 | 做法 |
|---|---|
| 返回 | keybd 合成 **Alt+Left**（chromium 加速键，任何站点都生效） |
| 退到首页再退就退出 | 用 CDP 读 `http://127.0.0.1:9222/json/list` 第一个 page 的 url，撞到 `browser-home.html` 才杀浏览器；拿不到 url 时只后退不退出 |
| 方向键选链接 | 页面内注入 `/root/browser-nav.js`：选 URL 元素、大块内容优先、跳过页头导航，OK 进入 |
| 注入怎么常驻 | `navinject.lua` 常驻，每 2s 扫一次 target，`Page.addScriptToEvaluateOnNewDocument` + `Runtime.evaluate`，target 变了就重连重注 |

`navinject` 单实例靠 `/run/navinject.pid`，**不要**在启动命令里 `pkill -f navinject.lua`
——那条命令行自身含该串，会把拉起它的 `sh -c` 一起杀掉（实测浏览器刚起就被杀，退出码 0）。

### 3.5 新 app 接遥控器：四步

```sh
# ① app 活着吗？有哪些动作？什么状态？
/opt/reader/bin/luajit -e 'dofile("/opt/keybord/explore.lua")' <app>
# ② 学码：10s 内按一遍遥控器，读回真实键名/码
/opt/reader/bin/luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --keys 10
# ③ 当场试一个动作，看屏幕确认
/opt/reader/bin/luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --try app.toc
# ④ 冻结成写死键码表（之后每键只跑这一条）
/opt/reader/bin/luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --freeze
```

注意盒上 `luajit` 不在 PATH，用 `/opt/reader/bin/luajit`。

---

## 4. Agent 自动化链路

### 4.1 A 模式：一行 JSON 进，一行 JSON 出

`/tmp/<app>-automation.sock`，`AF_UNIX`+`SOCK_STREAM`，**0700 root**（123 上现为
`/tmp/desktop-automation.sock`、`/tmp/keybd.sock` 0755）。客户端写完半关读 EOF；
app 主循环每帧 `poll()` 一次，accept/recv 全非阻塞。

| cmd | 参数 | 语义 |
|---|---|---|
| `ping` | — | `{"ok":true,"pong":true}`，keybd 判前台靠它 |
| `list` | — | 动作清单 |
| `state` | — | 嵌套完整状态（需 cjson） |
| `brief` | — | **扁平**摘要：`sel/count/name/dir/selected/reader/player/cols/rows` |
| `click` | `id` | 点一个具名控件（`nav.right`） |
| `key` | `name` | 等价按了一下遥控，走同一条 `on_key` |
| `call` | `fn`,`args` | 通用入口：`app.capture`（落 PNG）、`app.key`、`app.goto`、`app.rescan`、`app.size`、`app.quit` |

三条纪律：`key` 必须和遥控走同一个函数；会起外部进程的动作 `defer` 并先回
`{"ok":true,"deferred":true}`；socket 上必须 `FD_CLOEXEC`（播放器/阅读器是 `io.popen` 起的，
继承裸 fd 会让客户端永远等不到 EOF）。

### 4.2 B 模式：CDP（同一台盒子上第二套控制面）

chromium 带 `--remote-debugging-port=9222`（只监听 127.0.0.1），于是：

| 件 | 盒上位置 | 干什么 |
|---|---|---|
| `cdplib.lua` | `/root/cdplib.lua` | 零依赖 WebSocket/CDP 单文件库（源自 `tools/cdp/cdp_do.lua`） |
| `cdp_do.lua` | `/root/` | 一次调用干一件事：导航 + 读值 + 注入提交 |
| `naveval.lua` | `/root/` | 对当前页求值（调试口） |
| `inject.lua` | `/root/` | 注入 cookie → 导航 → 等渲染 → 打印验登录 JSON（gm/dy/jb 顺带截图） |
| `browser-nav.js` | `/root/` | 页面内选点/进入，见 §3.4 |

```sh
ssh x98h '/opt/reader/bin/luajit /root/inject.lua zh'          # 注入 + 验登录
ssh x98h '/opt/reader/bin/luajit /root/cdp_do.lua - "document.title"'   # 不导航，只取当前页
```

站点参数（profile 目录、代理、登录判据、warm 秒数）唯一真源是 `tools/chrome3/README.md` 的表。

### 4.3 最小客户端

```sh
ssh x98h 'python3 -c "…connect socket, 发一行 JSON, 读一行…"'
```

不需要库：`settimeout`、发完 `shutdown(SHUT_WR)`、读到 `\n` 为止。

---

## 5. 抓屏：三条路，别看错

| 上屏的是谁 | 抓法 | 命令 |
|---|---|---|
| 桌面（A） | socket `app.capture` 落 PNG | `tools/x96-shot.sh`（默认路径） |
| cage / cog / 微信（B） | **`grabplane`** 全量导出 DRM framebuffer | `/root/grabplane-aarch64 /dev/dri/card0 /tmp/shot.raw` |
| 兜底（app 卡死） | `drmcap` 直读 card0 | `tools/x96-shot.sh -d` |

三条硬事实：

- `/dev/fb0` 里**没有**桌面像素（A 走 DRM planes），fb 路径只配 dd tty 壁纸终端。
- `/root/grabscreen-aarch64` 写死 2560×1440，在 4K 上只抓 1302 行、右下半截撕裂 —— 看图会误判成"页面崩了"。
  `grabplane` 走 `GETRESOURCES → GETCRTC → GETFB → PRIME_HANDLE_TO_FD → mmap`，按 fb 自己的 pitch/height 导出，分辨率无关。
- raw 是 BGRA：`ffmpeg -f rawvideo -pix_fmt bgr0 -s 2560x1440 -i shot.raw shot.png`。
  写成 `bgra` 因 alpha=0 得到**全白图**。

`tools/x96-shot.sh` 的主机来自 `X96_HOST`（默认 `x96`）。121 现在不可达，抓 123 要
`X96_HOST=x98h tools/x96-shot.sh`。

---

## 6. 现状与缺口（2026-11-27 实机核对）

| 项 | 状态 |
|---|---|
| 桌面 / 播放器 / 阅读器（A） | 123 上日常在用；`desktop.service` active（LuaJIT 常驻 ≈102M），播放器入口 `/root/play.sh`，阅读器 `/opt/reader`，微信 `/opt/wechat` |
| 浏览器（B） | cage+chromium kiosk 已跑通并进桌面卡片；遥控方向键经 uinput + `browser-nav.js` 能选点进入；BACK 走 Alt+Left / CDP 判首页 |
| 微信（B） | cage + wayland 已上屏、鼠标可点；**没有 `apps/wechat.lua` 条目**，遥控器按键还没进得去 |
| 抓屏 | `grabplane` 可用；`grabscreen-aarch64` 只对 2560×1440 有效 |
| 回归对拍 | `tools/x96-check.sh` 绑 `X96_HOST`（默认 x96），121 不可达；要在 123 上跑就得改 `X96_HOST=x98h`，且基线要重录 |

---

## 7. 新建 app 的落地顺序

**A 模式（自写直出进程）**

```sh
# 1) 宿主侧先跑通（x86_64，改一行看一帧最快）
cd ~/Desktop/<app> && ./run.sh                    # SDL 走 x11/dummy
# 2) 交叉编译 + 审计（arm64_build.md）：产物必须 AArch64，ldd 无宿主路径
# 3) 部署（别手 scp，走 deploy.sh，chrome.md §8.1）
scp -r out/<app> x98h:/opt/<app>
# 4) 上屏：先 mask desktop
ssh x98h 'systemctl mask --runtime desktop && systemctl stop desktop'
ssh x98h 'cd /opt/<app> && DESKTOP_HOME=/root SDL_VIDEODRIVER=kmsdrm ./run.sh'
# 5) 接遥控器（§3.5，最后 --freeze）
# 6) 接自动化（§4.1）：ping 通、brief 有内容、capture 能落 PNG
# 7) 收尾：unmask + start 还给桌面
```

**B 模式（cage 里的网页）**

```sh
# 1) 站点参数进 tools/chrome3/README.md 那张表（profile/代理/登录判据/warm）
# 2) 起浏览器（脚本内部会 mask desktop、等 CDP ready）
ssh x98h 'bash /root/startcage.sh <key>'
# 3) 注入 + 验登录
ssh x98h '/opt/reader/bin/luajit /root/inject.lua <key>'
# 4) 抓一张确认（§5 grabplane），再决定要不要写截图判据
# 5) 收尾：unmask + start
```

交付清单（换平台照这张表填）：

- A：可执行 + `.so` + `lua/` + 字体/资源 + `run.sh`（含必要环境变量）+ `apps/<name>.lua`（可无 keys，退回 `act.lua`）+ socket 路径与权限 + 一条能 `ping` 通的最小验证命令。
- B：profile 目录 + cookie 导出脚本 + 站点表一行 + `apps/browser.lua` 里需要的键映射（多数是 `noop`）+ 一条 CDP 取 url/title 的验证命令。

---

## 8. 坑位速查

| 现象 | 真因 | 处理 |
|---|---|---|
| 点开视频/阅读器后连接不收尾 | 子进程继承了 socket fd | `FD_CLOEXEC` |
| 遥控器在浏览器里完全没反应 | cage 走 libinput，keybd 已独占 | 确认 `keybd-passthru` uinput 建起来了（`/tmp/keybd.log` 有 WARN 就是没建成） |
| 按键一按两翻（页面动一次、桌面也动一次） | browser app 的键映射没设 `noop` | `apps/browser.lua` 里方向键/OK 全 `noop` |
| 按键卡在按下（连发不停） | 只重放了 key-down，或 keybd 重启没清状态 | key-up 也重放；重启时 uinput 全码 `value=0` |
| 浏览器刚起来就退出、退出码 0 | 启动命令里 `pkill -f navinject.lua` 杀到自己 | 用 `/run/navinject.pid` 判单实例 |
| 起 cage 立刻 exit 1 | 缺 `XDG_RUNTIME_DIR`/`LIBSEAT_BACKEND` | 抄 `desktop.service` 的环境变量 |
| 桌面抢回屏幕 | `Restart=always` 把 desktop 拉回来了 | 先 `systemctl mask --runtime desktop` 再 stop |
| 抓图右下半截撕裂/空白 | `grabscreen` 写死 2560×1440 | 换 `grabplane` |
| 抓出来整张全白 | `-pix_fmt bgra`（alpha=0） | 用 `bgr0` |
| 退出 cage app 后桌面花屏 | KMS 被抢走，纹理全废 | `resume()` 后清 ico/thumb_cache/pv 缓存再重画 |
| Lua 侧解不出应答 | 盒上没 cjson | 用 `brief`（扁平） |

---

## 9. 文件索引

| 位置 | 内容 |
|---|---|
| `desktop/` | 桌面 app（LuaJIT + SDL2/kmsdrm，`main.lua` + `core/{automation,dav,fs,launcher,hotplug}.lua`） |
| `desktop/config.lua` → 盒上 `/opt/desktop/config.lua` | app 卡片表：`browser` / `wechat` 的 `cage` 启动命令都在这里（**真源在盒上**，仓库同步） |
| `desktop/run.sh` + `desktop.service` | `DESKTOP_HOME`/`DESKTOP_FONT_DIR`/`SDL_VIDEODRIVER=kmsdrm`，cage 用的 `XDG_RUNTIME_DIR=/run/user/0`、`LIBSEAT_BACKEND=seatd` |
| `keybord/` | keybd 守护、`config.lua`、`apps/`、`keys/`、`explore.lua`、`evdev.lua`（uinput） |
| `tools/chrome3/` | 六站脚本合订本：`cage.sh`/`inject.lua`/`navinject.lua`/`browser-nav.js`/`grabplane.c`/`keyinject.c` |
| `tools/cdp/` | `cdp_do.lua`（CDP 通用执行器）、测量脚本 |
| `tools/cog/` | `startcage.sh` 实体、`cog.lua`、`box-cog.sh` |
| `tools/x96-shot.sh` / `x96-check.sh` | 抓屏 / 回归对拍（主机由 `X96_HOST` 决定） |
| `chrome.md` | 浏览器/微信/cog 选型与全部实测记录（§11 cage+CDP、§16 微信、§17 YouTube） |
| `reader_dev.md` / `arm64_build.md` | 一份代码的开发视角 / 交叉编译与交付 |
| `x98h.md` | 123 的内核、驱动、音频、启动链 |
