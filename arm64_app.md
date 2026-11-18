# arm64_app.md — arm64 盒子 App 开发方案（遥控器 + Agent 自动化）

> 目标机：X96 Max / Amlogic S905X2，aarch64，**无 X11、无 Wayland**，KMS/DRM 直出 2560×1440。
> 本文是「一份代码怎么在盒子上跑起来、怎么被遥控器操作、怎么被 agent 远程操作」的总方案，
> 具体命令细节分三份文档：构建打包见 `arm64_build.md`，业务代码写法见 `reader_dev.md`，
> 硬件与内核见 `X96max.md`。

---

## 0. 一句话方案

**一个 app = 一个 LuaJIT 进程 + 若干 `.so`，对外只有两个口：evdev（收遥控器）和
Unix socket（收 agent 指令）；屏幕只有一个主人，输入只有一个主人。**

```
 物理遥控器                    上位机 / agent (ssh)
     │                                │
  /dev/input/eventN                   │ 一行 JSON
     │                                ▼
 ┌───▼──────────┐            ┌──────────────────────────┐
 │ keybd（唯一  │  动作/键名  │ app 的自动化口            │
 │ 独占 evdev）  ├───────────►│ /tmp/<app>-automation.sock│
 └──────────────┘  JSON 一行  └─────────┬────────────────┘
     │ 判前台 FOCUS_TTL=800ms           │ 进程内 poll()
     └──────────────────────────────────┤
                                        ▼
                              ┌──────────────────┐
                              │  app 主循环       │
                              │  状态 → 画面      │
                              └────────┬─────────┘
                                       ▼
                              KMS/DRM 全屏（kmsdrm）

  开发机 x86_64 ──交叉编译──► /opt/<app> ──ssh──► 盒子
                                     └── tools/x96-check.sh 回归对拍
```

三条不变式（违反任何一条，整套东西就会互相打架）：

1. **evdev 只有一个主人**：keybd 独占。app 只当普通输入源，绝不 `EVIOCGRAB`。
2. **屏幕只有一个主人**：app 用 kmsdrm 全屏独占；起播放器/阅读器这类外部进程前必须
   `win:suspend()`，回来再 `win:resume()` 并清纹理。
3. **app 只被 JSON 驱动，不被直接摸**：agent 和遥控器走**同一个** socket 协议，
   不存在"特殊后门"。这样遥控器按得动 = agent 一定调得动。

---

## 1. 平台约束（决定了架构，不是可选风格）

| 约束 | 事实 | 架构后果 |
|---|---|---|
| 无显示服务器 | 没有 X11/Wayland，SDL 只能 `SDL_VIDEODRIVER=kmsdrm` | 全屏独占；切换 app 必须 suspend/resume |
| 无 GPU 加速保证 | S905X2 有 Mali，但 kmsdrm 下走软件渲染 | 缩略图/纹理要自己的缓存，别指望 blit 便宜 |
| 交叉编译 | 盒子上装不下 gcc 全家桶，编一次几分钟起 | 开发在 x86_64 上做（`reader_dev.md` §3），交叉只做打包 |
| 内存 2G 级 | 大 PDF/OCR 会顶到 | 后端 C 侧做 LRU 缓存，Lua 侧只拿句柄 |
| 无 cjson | 部分镜像里 Lua 侧没有 cjson | 应答里有**扁平** `brief` 命令，控制端极简解码即可 |
| 输入只有遥控器 | 无键盘无鼠标，方向键+OK+BACK+MENU | 所有功能必须能用 ≤6 个键到达，禁止依赖悬停/右键 |

---

## 2. 分层契约

```
lua/ui/*        界面、状态机、主题            ← 全部业务，改这里最多
lua/ffi/*       cdef + 薄封装                 ← 唯一允许 ffi.C 的地方
─────────────────────────────────────────  唯一的平台契约：C ABI
lib<app>_native.so / lib<app>_ctl.so         ← 文档模型、ioctl 小工具
          ↑
       SDL2（kmsdrm）
```

- **C ABI 是唯一契约**：换平台只换 `.so` 和 SDL 后端，Lua 一行不改（`reader_dev.md` §2）。
- **C 只做没有状态机的事**：指针、解析、渲染到缓冲、落盘。界面判断一律回 Lua。
- 参考比例：reader 是 C 1726 行 / Lua 6250 行，这个比例是对的。

---

## 3. 遥控器链路

### 3.1 三层，各管一件事

| 层 | 件 | 干什么 | 不干什么 |
|---|---|---|---|
| 守护 | `/opt/keybord/keybd.lua` | `EVIOCGRAB` 独占 evdev、判当前前台 app、按键分发、控制口 `/tmp/keybd.sock` | 不认识业务 |
| 键表 | `keys/<app>.lua` | 键名 → evdev 码 → 动作名，**真源，可直接手改** | 不含逻辑 |
| 动作 | `<app>.lua` → app 的 socket | 把动作名翻成 `{"cmd":"key"...}` / `{"cmd":"call"...}` | 不读 evdev |

### 3.2 判前台：为什么不把 evdev 给 app

app 全屏后如果自己收键，一旦某个 app 崩了/独占不放，遥控器就彻底失灵，且 ssh 上去也救不回来
（没有别的输入口）。所以 evdev 归 keybd，它每 **800ms** 问一次各 app 的 socket
`{"cmd":"ping"}`，谁活谁收键。app 崩了只是没人应答，键自动落到下一个/兜底 shell。

调参（环境变量，`keybd.lua` 顶部）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `FOCUS_TTL` | 800 | 前台探测周期 ms，别调太快，每轮都是 socket 往返 |
| `DEDUP_MS` | 40 | 同码去抖，遥控器连发很快 |
| `REPEAT_MS` | 220 | 长按重复间隔；只对 `repeatable(action)` 的动作生效 |
| `DISPATCH` | `inproc` | `exec` = 每键 fork `timeout 6 luajit …`（隔离好、慢）；`inproc` 快但一崩全崩 |

### 3.3 键名表（app 侧 `on_key` 认这些）

`LEFT RIGHT UP DOWN`、`OK ENTER RETURN SPACE`、`BACK ESC ESCAPE`、
`HOME END PAGEUP PAGEDOWN CHANNELUP CHANNELDOWN`、`MENU REFRESH F5`、`QUIT EXIT`。

- 别名必须都收（`CHANNELUP`≡`PAGEUP`），不同遥控器码不一样。
- **阻塞键**（`OK/ENTER/RETURN/SPACE`）在 app 侧要特殊处理：它们会进阅读器/播放器这种
  外部进程，应答必须先发出去、动作排队到下一帧，否则控制端 3s 超时误判失败，
  再触发 fallback 抢屏（真踩过，`desktop/main.lua` `defer()` 就是为此）。

### 3.4 新 app 接遥控器：四步

```sh
# ① 动态探索：app 活着吗？有哪些动作？现在什么状态？
luajit -e 'dofile("/opt/keybord/explore.lua")' <app>

# ② 学码：让 keybd 只记 10s，拿遥控器按一遍，读回真实键名/码
luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --keys 10

# ③ 当场试一个动作，看屏幕确认
luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --try app.toc

# ④ 冻结成写死键码表 —— 之后每键只跑这一条，不再动态查
luajit -e 'dofile("/opt/keybord/explore.lua")' <app> --freeze
```

冻结后的 `keys/<app>.lua` 手改即可，不用重跑探索。

---

## 4. Agent 自动化链路

### 4.1 协议：一行 JSON 进，一行 JSON 出

`/tmp/<app>-automation.sock`，`AF_UNIX`+`SOCK_STREAM`，**0700 root**，客户端写完半关读 EOF。
app 主循环每帧 `poll()` 一次，accept/recv 全非阻塞 —— 单个慢客户端不会卡画面。

| cmd | 参数 | 语义 |
|---|---|---|
| `ping` | — | `{"ok":true,"pong":true}`，keybd 判前台就靠它 |
| `list` | — | 动作清单 |
| `state` | — | 嵌套完整状态（需 cjson） |
| `brief` | — | **扁平**摘要：`sel/count/name/dir/selected/reader/player/cols/rows`，无 cjson 也解得出 |
| `click` | `id` | 点一个具名控件（`nav.right`） |
| `key` | `name` | **等价按了一下遥控**，走同一条 `on_key` |
| `call` | `fn`,`args` | 通用入口，见下 |

`call` 的 `fn`：`app.capture`（落 PNG）、`app.key`、`app.goto`（跳目录/归位）、
`app.rescan`、`app.size`、`app.quit`。

### 4.2 三条实现纪律

1. **`key` 必须和遥控走同一个函数**，不许各写一份。否则"遥控能按、agent 按不动"这类
   幽灵 bug 会一直查不出来。
2. **阻塞动作 `defer`**：`app.key`/`call` 里凡是会起外部进程、挂起主循环的，
   先回 `{"ok":true,"deferred":true}`，动作排到下一帧。
3. **`FD_CLOEXEC`**：socket 上必须设。播放器/阅读器是 `io.popen` 起的，会继承所有裸 fd，
   不关的话客户端永远等不到 EOF（表现为"点开视频后应答到了但连接不收尾"）。

### 4.3 上位机/agent 侧最小客户端

```sh
ssh x96 'python3 -c "…connect socket, 发一行 JSON, 读一行…"'
```

不需要任何库。要点：`settimeout`、发完 `shutdown(SHUT_WR)`、读到 `\n` 为止。
`tools/x96-check.sh` 就是把这层封成了 `key:` / `click:` / `call:` 步骤命令。

### 4.4 抓屏

```bash
tools/x96-shot.sh            # 桌面：走 socket 的 app.capture（失败自动回落 -d）
tools/x96-shot.sh -d         # DRM 直读，app 卡死也能抓
tools/x96-shot.sh -c         # tty2 壁纸终端（dd /dev/fb0）
```

`/dev/fb0` 里**没有**桌面像素（桌面走 DRM planes），别拿 fb 抓桌面。

---

## 5. 回归验收：三层判定

遥控器/agent 这类"输入 → 画面"的改动，只看日志会把回归放过。`tools/x96-check.sh`
把**注入 → 状态断言 → 画面对拍**串成一条命令，有失败就 `exit 1`：

```bash
tools/x96-check.sh --golden home          # 录基线
tools/x96-check.sh --diff home            # 0=过 1=画面不符 2=状态断言失败 3=抓图失败
tools/x96-check.sh --run-dir tools/cases  # 跑整目录
tools/x96-check.sh --run-dir tools/cases --record   # 改版式后批量重录
```

- 判据是差异像素占比。这块屏静止时**逐像素可重现**（连抓两张 0.0000%），
  默认 `--fuzz 1 --max-diff 0.1` 就够严：右移一格 3.4%、整屏下移 1px 7.9%、0.5% 色偏 7.3%。
- 必须**同时**断言状态（`assert-sel/assert-count`）：光比图会把"按了没反应但长得像"判成通过。
- 用例第一段固定 `call:app.goto:{"dir":…};key:HOME` 归位，保证幂等、与顺序无关；
  `restore` 行无论成败都执行，别把机器留在半开状态（比如停在阅读器里）。

---

## 6. 新建一个 app 的落地顺序

```sh
# 1) 宿主侧先跑通（x86_64，改一行看一帧最快）
cd ~/Desktop/<app> && ./run.sh            # SDL 走 x11/dummy

# 2) 交叉编译 + 审计（见 arm64_build.md）
#    - 产物必须是 AArch64；ldd 里不许出现宿主路径
#    - 只带运行时真要的东西（字体、.so、lua/、assets）

# 3) 部署
scp -r out/<app> x96:/opt/<app>

# 4) 上屏
ssh x96 'cd /opt/<app> && DESKTOP_HOME=/root SDL_VIDEODRIVER=kmsdrm ./run.sh'

# 5) 接遥控器（§3.4 四步，最后 --freeze）

# 6) 接自动化（§4）：socket 起来、ping 通、brief 有内容、capture 能落 PNG

# 7) 回归用例
cp tools/cases/list-home.case tools/cases/<app>-home.case   # 改 dir/断言
tools/x96-check.sh --case tools/cases/<app>-home.case --record
tools/x96-check.sh --run-dir tools/cases
```

交付清单（换平台照这张表填，`arm64_build.md` §13 有完整版）：
可执行 + `.so` + `lua/` + 字体/资源 + `run.sh`（含必要环境变量）+ `keys/<app>.lua` +
socket 路径与权限 + 一条能 `ping` 通的最小验证命令 + 至少一条回归用例。

---

## 7. 坑位速查

| 现象 | 真因 | 处理 |
|---|---|---|
| 点开视频/阅读器后连接不收尾 | 子进程继承了 socket fd | `FD_CLOEXEC` |
| 遥控器按什么都没反应 | 前台探测超时掉到兜底 shell | 外部 app 期间 `pump()` 里只答 ping/brief，别全 busy |
| 播放器和阅读器抢屏 | 阻塞动作在 poll 里跑，应答发不出→判失败→fallback | 阻塞动作一律 `defer` |
| 退出外部 app 后花屏 | KMS 被抢走，纹理全废 | `resume()` 后清 ico/thumb_cache/pv 缓存再重画 |
| 某些遥控器 PAGEDOWN 无效 | 码映射成 `CHANNELDOWN` | 别名在 `on_key` 里都要收 |
| 抓屏一片白/黑条 | 拿了 fb0 抓桌面；fb 有 2160 行但只 1440 上屏 | 桌面走 `app.capture` 或 `-d`；fb 路径只 dd 可见行 |
| Lua 侧解不出应答 | 盒子上没 cjson | 用 `brief`（扁平） |
| 改了版式全量用例红 | 基线过期 | `--record` 重录，先肉眼确认新画面是对的 |

---

## 8. 文件索引

| 位置 | 内容 |
|---|---|
| `desktop/` | 盒子桌面 app（LuaJIT，`main.lua` + `core/{automation,dav,fs,launcher}.lua`） |
| `desktop/run.sh` | 上屏入口：`DESKTOP_HOME` / `DESKTOP_FONT_DIR` / `SDL_VIDEODRIVER=kmsdrm` |
| `reader_dev.md` | 一份代码的开发视角（C ABI、目录、开发循环、平台矩阵） |
| `arm64_build.md` | 交叉编译、sysroot、产物审计、部署、交付清单 |
| `X96max.md` §22 | console-wall / fbterm / 截图 / 回归对拍细节 |
| `tools/x96-check.sh` + `tools/cases/` | 回归对拍工具与用例 |
| `tools/x96-shot.sh` | 三条抓屏路径 |
| 盒子 `/opt/keybord/` | keybd 守护、键表、`explore.lua` 探索/冻结 |
| 盒子 `/opt/desktop/`、`/opt/reader/` | 两个已落地的 app |
