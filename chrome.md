# 浏览器直出（cog / WPE WebKit）部署与调试全流程

> 目标：把浏览器做成**第四种直出 app**，和桌面、阅读器、播放器一样——
> 谁要显示谁独占 DRM master，`systemctl stop desktop` 交棒，全屏 URL 直出 HDMI，
> 2.4G 遥控器能操作网页。
>
> 当前状态：
> ① **x98h(123)** `cog -P drm`（47 包，独占直出，静态页/中文/canvas/视频均可，**动态重绘 3–5s 崩，未修**，第 7 节）；
> ② **x98h(123)** `cage + chromium + CDP`（74 包，动态页稳定、可注入任意 JS、登录态跨重启持久，**日常用这条**，第 11–12 节）；
> ③ **x96(121)** `cog -P drm -O renderer=gles --device-scale=2`（61 包，**4K 3840x2160@60 直出已跑通**，
>    动态页无长跑压测数据，第 15 节：分辨率链路 / 崩溃处置 / 装包清单）；
> ④ **x98h(123)** `sway 1.10.1 + 微信 4.1.13.29 arm64`（**Chromium 内核的非浏览器 app**，
>    718M，独占直出 2560x1440 已跑通，第 16 节：装机 / 直出原理 / 输入现状）。
>    **合成器 2026-11-27 从 cage 换成 sway**（cage 只留作回退，见 16.3 的包清单）。
>
> **前置条件（第 10 节）**：123 能出画靠的是**内核侧的 H616/DE33 显示补丁集**（13 个 drm 补丁 + 2 处 DT），
> 不是 cog 自带的。换盒子/重刷内核前先读第 10 节，否则 `cog -P drm` 连 plane 都拿不到。

---

## 1. 技术选型：cog 还是 cage + chromium

> 本节结论**已被实测修正**：`cog` 是"少装包 + 独占直出"的首选，但**动态页面会崩**；
> `cage + chromium` 74 包换来的稳定性与 CDP 控制力，在真实使用（微博首页信息流）里是刚需。
> 两条都留，按场景选：静态展示 → cog；要交互/要脚本 → cage（第 11–12 节）。

| 方案 | 包数 | 问题 |
|---|---|---|
| `cage` + `chromium` | 约 74 包 | cage 是 Wayland 合成器，chromium 再叠一层；内存吃紧，且 chromium 自己也想抢 DRM/GBM |
| **`cog` + `libcogplatform-drm.so`** | **约 47 包** | WPE WebKit 官方 kiosk 浏览器，`-P drm` **自己直接占 DRM master**，无合成器、无 X、无 Wayland 会话 |

`cog` 的 DRM 平台插件天然满足"独占直出"模型：它启动时 open `/dev/dri/card0` 自己做
modeset + page flip，退出即释放，和播放器 `vout.c`、桌面 `kmsflip.so` 是同一层级，
不需要改任何已有架构。**但要改的驱动是另一件事**：H618 上 mixer/planes 不 bind 就没有 card，
那套 DE33 补丁集见第 10 节。

装的东西（Debian trixie arm64）：

```bash
apt install --no-install-recommends cog
# 关键依赖：libwpewebkit-2.0-1 (WebKit 2.48.x)、xdg-dbus-proxy、libwoff1、libxslt1.1、
#           libgstreamer-plugins-bad1.0-0、libxkbcommon-x11-0
```

---

## 2. 核心坑：`renderer=gles` 是唯一正确路径（这条最贵）

cog 的 DRM 平台有两个渲染器，源码 `platform/drm/cog-platform-drm.c`：

- 默认 **`renderer=modeset`**：零拷贝，把 WebProcess（panfrost 分配的）buffer
  **直接挂到 KMS plane**。
- 可选 **`renderer=gles`**：用 EGL 渲染到 gbm 分配的 buffer，再 blit 到 plane。

在 123（H618 / sun4i-drm）上默认路径直接死：

```
failed to create framebuffer: Invalid argument      (EINVAL)
```

根因在内核，不在 WebKit：

```c
/* drivers/gpu/drm/sun4i/sun4i_backend.c:158 */
if (modifier != DRM_FORMAT_MOD_LINEAR)
        return false;                    /* 只认 LINEAR，全树 sun4i 无 AFBC */
```

WebProcess 交出来的是 **AFBC** 压缩 buffer，sun4i backend 一律拒绝。而播放器能出图是因为
`hevcdec/vout.c:336-339` 自己建 fb 时**不设 modifier（= LINEAR）**、格式 `DRM_FORMAT_NV12`。

所以：

```bash
COG_PLATFORM_PARAMS=renderer=gles cog -P drm <url>
#  等价写法：cog -P drm -O renderer=gles <url>
```

`gles` 路径由 cog 自己 gbm 分配 LINEAR buffer + EGL 渲染 + blit，**真 GPU 加速**，
不需要 shim、不需要改内核、不需要 `LIBGL_ALWAYS_SOFTWARE`、不需要隐藏 renderD128。

> 走过的所有弯路（都已证明无效，别再试）：
> `PAN_MESA_DEBUG=noafbc`、各种 linear 环境变量、隐藏 `/dev/dri/renderD128`（会掉到 llvmpipe）、
> `gbm-linear-shim.so`、`gbm-probe-shim.so`、LD_PRELOAD 各类 `gst_*` 拦截 shim。

**121（Amlogic meson + panfrost）也验证了 `renderer=gles`**：能正常出 4K 画面，
主 plane 上是 `allocated by = cog`、`XR24`、`3840x2160`、`crtc-pos 3840x2160+0+0`，
无 `failed to create framebuffer`、无 page flip 报错（现场读数见 §15.1）。
所以这条参数是**两盒通用**，不是 123 专属补丁的产物
（123 在 `modeset` 下失败是 sun4i 只认 LINEAR，见上）。121 上 `modeset` 是否可用**尚未测**，
要试就单独试，失败不意外。

121 还多一个参数 **`--device-scale=2`**：4K 面板按 CSS 视口 3840 宽算时字太小，
给 2 折成 1920x1080 / DPI 192。**这是 121 与 123 唯一不能共用的一份配置**（§15.1）。

---

## 3. 独占 DRM master：必须 mask desktop

`desktop.service` 带 `Restart=always`，**光 `systemctl stop` 会被 systemd 立刻拉回来**
抢 DRM master，cog 报 `Cannot set mode (Permission denied)`，屏幕停在桌面最后一帧。

```bash
systemctl mask --runtime desktop    # --runtime：只本次开机生效，重启自动恢复
systemctl stop desktop; sleep 2
# ... 跑 cog ...
systemctl unmask --runtime desktop && systemctl start desktop
```

这一套已经封装好：

- 盒子侧 `~/kernel/tools/cog/box-cog.sh`（部署到 `/root/cog/box-cog.sh`）
  `start [URL] | stop | status | open URL | reload | previous | next | ping | quit | shot [out.raw]`
- 本机侧 `~/kernel/tools/cog/cog.lua`（LuaJIT 遥控：`start/open/reload/previous/next/ping/status/shot/stop`）

cog 需要一个 session bus（`cogctl` 用）：

```bash
dbus-daemon --session --address="unix:path=/tmp/cogrt/bus" --fork --print-pid
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/cogrt/bus"
```

---

## 4. 遥控器怎么操作网页：uinput 虚拟键盘

**不要走 `--automation` / `cogctl`**：自动化模式会把页面降级成 `about:blank`，
而且 `cogctl` 只有导航命令（open/reload/back/forward），**没有按键注入**。

正确链路（已用 strace 验证 `sendmsg` 里带 `ArrowRight`）：

```
2.4G USB 接收器 → evdev → keybd.service（keybd.lua，已 grab） → uinput 虚拟键盘
  → libcogplatform-drm.so 内的 libinput（udev backend）
  → wpe_view_backend_dispatch_keyboard_event() → 页面收到 keydown/keyup
```

要点：
- `libcogplatform-drm.so` 链接 libinput 并走 udev backend，**新插入的 uinput 设备会被自动发现**，不用重启 cog。
- keybd 的 `config.lua` 用 `exclude="Mouse,Touch,Video,HDMI"` 跳过鼠标类接口，`grab=true` 独占。
- 虚拟键盘设备名 `vkeybd-browser`（仅实验过，脚本未留档；正式应做成 `keybord/apps/browser.lua` + `keybord/keys/browser.lua`，**尚未做**）。

### 4.1 已验证可用的最小注入器（`tools/chrome3/keyinject.c`）

`/dev/uinput` 造 `lite-browser-kbd` 虚拟键盘，按名字注入，静态编译 aarch64：

```c
/* 关键部分：UI_SET_EVBIT(EV_KEY/EV_SYN) → UI_SET_KEYBIT(每个键) → UI_DEV_SETUP
 * → UI_DEV_CREATE → usleep(300000) 等 libinput 发现 → emit(EV_KEY,code,1)
 * → emit(EV_SYN,SYN_REPORT,0) → usleep(60000) → emit(EV_KEY,code,0) → UI_DEV_DESTROY */
```

```bash
aarch64-linux-gnu-gcc -O2 -static -o keyinject-aarch64 keyinject.c
scp keyinject-aarch64 x96:/root/
ssh x96 '/root/keyinject-aarch64 right down right enter'
```

**实测（121）**：注入 `right/down/right/enter` 后页面 `keydown` 收到 `ArrowRight`、`code=39`，计数自增。
这条链（uinput → libinput → `wpe_view_backend_dispatch_keyboard_event`）确认可用。

### 4.2 真遥控器现在还到不了 cog

keybd 是 `grab=true`（独占），遥控器按键被 keybd **全部吃光**，传不到 cog。
要接真遥控器必须改 keybd：加 `apps/browser.lua` + `keys/browser.lua`（键名 → 调 `keyinject` 注入），
或把该设备从 grab 白名单里排掉、让 cog 独享。**（尚未做，动配置文件前先决定）**

键码表（uinput `KEY_*`）：

```
up=103 down=108 left=105 right=106 ok=352 enter=28 esc=1
home=172 back=158 menu=139 volup=115 voldn=114
```

---

## 5. 中文字体：先确认到底缺不缺（121 实测不缺）

**别急着做硬链接。先查这一句：**

```bash
fc-list :lang=zh | wc -l
```

- **121 实测：35 条**（Noto Sans/Serif CJK 全套 + `fonts-wqy-zenhei`），`fc-match sans-serif`
  落到 DejaVu Sans 只是默认排序，中文照样有 fallback 字形能画出来。**无需任何字体配置。**
- 如果这一条是 0 或个位数，才走下面的硬链接流程。

> 血的教训：121 上第一次出图是 `cog ç›´å‡ºæµ‹è¯•` 这种乱码，看着像字体缺失，
> 实际**纯粹是测试页漏了 `<meta charset="utf-8">`**。补上 charset 后中文完全正常。
> 以后见到乱码先看 charset，再怀疑字体。

**判断口诀**：乱码是「一个汉字变 2–3 个西欧怪字母」→ charset 问题；
「一个汉字变一个空心方块」→ 真缺字体。

### 5.1 真缺字体时才做：硬链接进 fonts 目录

盒子上的仓耳今楷（TsangerJinKai02）在 `/usr/local/share/fonts` 下，**cog 的 WebKit 沙箱看不见**
（bwrap 私有挂载），且**符号链接在沙箱内是悬空的**。做法：

```bash
mkdir -p /usr/share/fonts/truetype/tsanger
ln -f  <tsanger-ttf>  /usr/share/fonts/truetype/tsanger/     # 硬链接，不是 ln -s
cat > /etc/fonts/conf.d/99-tsanger-zh.conf <<'EOF'
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias binding="strong"><family>sans-serif</family><prefer><family>TsangerJinKai02</family></prefer></alias>
  <alias binding="strong"><family>serif</family><prefer><family>TsangerJinKai02</family></prefer></alias>
</fontconfig>
EOF
fc-cache -f
```

`binding="strong"` 是关键：不加它 fontconfig 仍会挑别的字体，网页中文变方框/别的字形。

---

## 6. 视频播放：禁用硬解，回落软解

WebKit 选 `v4l2slh264dec` 做视频解码时协商失败：

```
DMABuf caps negotiated without the mandatory support of VideoMeta
```

硬解本身是好的（`gst-launch ... ! v4l2slh264dec ! fakesink`：12s 片源 0.2s，720p ≈14x 实时），
问题是 WPE 的 DMABuf 路径和它谈不拢。**把硬解 rank 打到 0（= NONE）**，回落 `avdec_h264` 软解：

```bash
GST_PLUGIN_FEATURE_RANK=v4l2slh264dec:0,v4l2slh265dec:0 cog -P drm -O renderer=gles <url>
```

实测（renderer=gles + rank 0）：彩条 + 时间码 `00:00:11.960`、299 帧、`paused=false err=-`，视频可播。

另外：**媒体必须由支持 Range 的 HTTP 服务提供**。`python -m http.server` 不支持 Range →
WebKit 报 `R2: Received unexpected 200 HTTP status code for range request` → `NotSupportedError`。
用 `rangesrv.py` 之类支持 `206 Partial Content` 的服务。

---

## 7. 已知未解决问题（重要，别踩）

### 7.1 页面重绘崩溃：**123 特有，121 不复现**

现象（**只在 123 上**见过）：页面一旦定时重绘（哪怕零按键注入），cog 3–5s 内 SIGSEGV。

```
Buffer address requested when its parent pool has an external reference and a deferred resize pending.
    ← libwayland-server.so.0.23.1
```

- 触发条件（123）：页面自己定时重绘，如每 500ms 自增计数器。
- 静态页（`example.com`、静态图文 `key.html`）在 123 上**不崩**。
- 试过无效（123）：`LIBGL_ALWAYS_SOFTWARE=1`、`WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`（同样崩）。
- `renderer=modeset` 硬件 GL 路径不崩，但 fb 创建 EINVAL（第 2 节）。

**121 实测（2026-11-26）：这条崩溃没复现**。
同一个每 500ms 自更新的页面连续跑 30 秒以上存活，页内 `t` 正常自增，无 SIGSEGV；
`https://weibo.com/` 跑约 4 分钟（21:51:59 起），cog 主进程始终在。

**但 121 上出现的是另一种崩溃**：`Crash!: The renderer process crashed.`
（WebProcess 崩、cog 自动 reload，屏幕不黑），触发前日志里是
`GStreamer element appsink/autoaudiosink not found` + 两条 `GLib-GObject-CRITICAL`。
处置=装满 `gstreamer1.0-plugins-base/-good/-libav`，全过程见 **§15.2**。

**结论订正**：`Buffer address requested ...` 不是 `renderer=gles` 的通病，更像 123 的环境干扰
（desktop / `resident-heal.timer` 抢 DRM master 的残留路径）。
在 121 上排查过这条路是白费；要修就去 123 上查，或在 123 上先试
`systemctl mask --runtime desktop` + `systemctl stop resident-heal.timer` 再复测。

- **按键注入与崩溃无关**（已证明注入链可用，见 4.1）。

性能参考（123）：纯 CSS/rAF 页 GPU 16.07fps / CPU 8.68→29.7fps；
视频软解 720p 仅约 0.8fps（瓶颈在 Skia 光栅与合成，不在解码）。

`cog` 退出时的 `Segmentation fault` + `No provider of eglReleaseThread found` 是**收尾噪音**，不影响出图。

---

### 7.2 抓图：`grabscreen` 会截半张图，必须用 `grabplane`

`/root/grabscreen-aarch64` 是**写死 2560×1440** 的（一帧 14 745 600 B 的量级）。
在 121（3840×2160，一帧 **33 177 600 B**）上跑，只抓到 1302 行就停，
右下半截是撕裂/空白 —— **看图会误判成「页面花了 / 崩溃了」，其实是抓图工具的问题**。

改用 `tools/chrome3/grabplane.c` 编译的 `/root/grabplane-aarch64`：走 DRM
`GETRESOURCES → GETCRTC → GETFB → PRIME_HANDLE_TO_FD → mmap`，
按 fb 自己的 pitch/height 全量导出，**分辨率无关**：

```bash
aarch64-linux-gnu-gcc -O2 -static -o grabplane-aarch64 grabplane.c
scp grabplane-aarch64 x96:/root/
ssh x96 '/root/grabplane-aarch64 /dev/dri/card0 /tmp/cogrt/shot.raw'
# 回本机，raw 是 BGRA：-pix_fmt 必须写 bgr0
ffmpeg -y -f rawvideo -pix_fmt bgr0 -s 3840x2160 -i shot.raw shot.png
```

两个坑：
- `-pix_fmt` **必须 `bgr0`**；写 `bgra` 因 alpha=0 会得到全白图。
- `GETRESOURCES` 第二次调用时，`count_crtcs` 是**传入数组的容量**，不是请求个数
  （内核会把它改成实际可用数），写错会拿到空 crtc 列表。

---

## 8. 部署

### 8.1 统一走 deploy.sh（不要手 scp）

`~/kernel/hevcdec/deploy.sh` 第 6 段「浏览器直出脚本 → /root/cog」：

```bash
BOX=x98h ./deploy.sh          # 全套（播放器+rcd+桌面+遥控器+浏览器脚本）
BOX=x98h ./deploy.sh -D -K    # 只发浏览器脚本 + 播放器链路（-D 跳桌面，-K 跳遥控器）
BOX=x98h ./deploy.sh -C       # 跳过浏览器脚本
```

行为：
- `tar` 打包 → `/root/cog/`，`.deploy.tar.md5` 记录 tar 的 md5，**源码没改就跳过推送**（幂等）；
- 盒子上没有 `cog` 二进制 → 只提示 `apt install cog`，**不推跑不起来的脚本**；
- 不重启任何守护（cog 不是常驻服务，谁要显示谁 start）。

查盒子状态：

```bash
ssh x98h '/root/cog/box-cog.sh status'
ssh x98h '/root/cog/box-cog.sh start https://example.com'
ssh x98h '/root/cog/box-cog.sh shot /tmp/x.raw'   # 抓图 /root/grabscreen-aarch64
ssh x98h '/root/cog/box-cog.sh stop'              # 收尾还原 desktop
```

抓图转 PNG（raw 是 BGRA，**必须 `-pix_fmt bgr0`**，用 `bgra` 因 alpha=0 会得全白）：

```bash
ssh x98h 'cat /tmp/x.raw' | ffmpeg -f rawvideo -pix_fmt bgr0 -s 2560x1440 -i - /tmp/x.png
```

### 8.2 x96（121）：已验证跑通，可直接照抄

121 现状（2026-11-26 实测）：

| 项 | 状态 |
|---|---|
| `/usr/bin/cog` | **已装**，`0.18.4 (WPE WebKit 2.48.3)` |
| `/root/cog/` | `box-cog.sh`、`cog.lua`、`startcage.sh`（与仓库 `805e5b80…` 同 md5） |
| `/root/grabplane-aarch64`、`/root/keyinject-aarch64` | 在 |
| 屏幕模式 | 4K 面板，`3840x2160`（**不是 123 的 2560×1440**） |
| 中文字体 | `fc-list :lang=zh` → 35 条，**本身就有，不用装**（见第 5 节） |
| keybd | active，配置与 123 逐字节相同 |

跑起来的命令（121 实测可用）：

```bash
# 起页面（脚本内部会 mask --runtime desktop 再起 cog，用 gles 渲染）
ssh x96 '/root/cog/box-cog.sh open file:///tmp/k.html'
ssh x96 '/root/cog/box-cog.sh open https://example.com'
ssh x96 '/root/cog/box-cog.sh status'

# 抓图：⚠️ 不要用 box-cog.sh shot（见下），直接调 grabplane
ssh x96 '/root/grabplane-aarch64 /dev/dri/card0 /tmp/x.raw'
ssh x96 'cat /tmp/x.raw' | ffmpeg -f rawvideo -pix_fmt bgr0 -s 3840x2160 -i - /tmp/x.png

# 收尾（必须，否则 desktop 一直被 mask，屏幕卡在 cog 最后一帧）
ssh x96 '/root/cog/box-cog.sh stop'
```

**已知坑：`box-cog.sh shot` 在 121 上截半张图。** 脚本第 10 行写死
`GRAB=/root/grabscreen-aarch64`（内部固定 2560×1440），在 4K 上只出 1302 行。
改法：第 10 行换成 `/root/grabplane-aarch64`、第 74 行同样，并让调用方传分辨率。
**尚未改脚本，目前请直接用 `grabplane-aarch64`（见 7.2）。**

121 与 123 的差异：
- 121 是 Amlogic（meson + panfrost），123 是 allwinner sun4i。`renderer=gles` 两个都能出图。
- 123 上「页面重绘 3–5s 崩」的问题**在 121 上不复现**（第 7.1 节），所以 121 能跑动态页面。
- 视频硬解是 `meson_vdec`，与 123 的 `v4l2sl*` 不同；`GST_PLUGIN_FEATURE_RANK` 禁用名单
  要在 121 上另测，别直接套 123 的 `v4l2slh264dec:0`。
- 两个盒子的 `keybd` 配置逐字节相同（`config.lua` / `evdev.lua` / `maps/+keys` md5 一致），
  遥控器→uinput 那段**不用改**，插上接收器 keybd 自动 grab。121 的服务名是 `keybd.service`。

---

## 9. 文件清单

| 路径 | 作用 |
|---|---|
| `tools/cog/box-cog.sh` | 盒子侧：起停 cog、mask/unmask desktop、抓图、cogctl 转接 |
| `tools/cog/cog.lua` | 本机 LuaJIT 遥控：start/open/reload/previous/next/ping/status/shot/stop |
| `tools/cdp/cdp_control.lua` | 零依赖 CDP 客户端 + 百度流程演示（第 11.2 节） |
| `tools/cdp/cdp_do.lua` | 通用 CDP 执行器：`cdp_do.lua <url|-> "<js>"`（第 11.6 节） |
| `tools/cog/startcage.sh` | 一键起 cage+chromium，轮询 CDP 就绪（第 12 节）；仓库里的就是盒上跑的同一份 |
| `/root/cog/startcage.sh`（盒子） | 部署落点（deploy 第 6 段） |
| `/root/startcage.sh`（盒子） | 只是转发壳 `exec /root/cog/startcage.sh "$@"`，老敲法照旧 |
| `tools/cdp/{prof,sc2,measure}.sh`、`tools/cdp/*.html` | 抓帧/性能测量与压测页，deploy 第 7 段推到 `/root/cdp/` |
| `tools/cdp/probe/` | 一次性探针（字体族/平面/截图注入/CDP 恢复），不再靠盒子 `/tmp` |
| `hevcdec/rollback-6.18.sh` | 内核回滚脚本，随 SCRIPTS 推到 `/root/` |
| `/root/.config/chromium/`（盒子） | 持久 profile（约 16M），登录态靠它留下（第 12 节） |
| `hevcdec/deploy.sh` 第 6 段 | 把 `box-cog.sh`/`startcage.sh`/`cog.lua` 推到 `/root/cog/`，md5 幂等，并生成 `/root/startcage.sh` 转发壳 |
| `hevcdec/deploy.sh` 第 7 段 | 把 `cdp_do.lua`/`prof.sh`/`sc2.sh`/`measure.sh`/`*.html` 推到 `/root/cdp/`，md5 幂等（`-X` 跳过） |
| `/root/cog/box-cog.sh`（盒子） | 部署落点 |
| `/usr/bin/cog`（盒子） | apt 包 cog 0.18.4 |
| `/usr/share/fonts/truetype/tsanger/` | 仓耳今楷硬链接 + `99-tsanger-zh.conf`（**仅 123 需要**；121 自带 CJK，不用） |
| `/root/grabscreen-aarch64`（盒子） | 抓 DRM 帧，**写死 2560x1440**（14745600 B BGRA）→ 4K 盒子上只出半张图 |
| `tools/chrome3/grabplane.c` → `/root/grabplane-aarch64`（121/123） | 按 fb 实际 pitch/height 全量抓帧，分辨率无关（7.2 节，**首选**） |
| `tools/chrome3/keyinject.c` → `/root/keyinject-aarch64`（121） | uinput 虚拟键盘注入：`keyinject-aarch64 right down enter`（4.1 节） |

实验残留（123 上，可清理，均已被证明不必要）：
`/usr/local/lib/{egl-linear-only,gst-videometa-shim,gst-glconvert-shim}.so`、`/root/media/`、`/tmp/cogtest/`。

---

## 10. 内核侧：浏览器直出依赖的驱动改动（123 专属，别漏）

**一句话**：cog 自身**不需要**任何驱动改动（第 2 节的 `renderer=gles` 是纯用户态结论），
但"123 上能出画"完全建立在**这棵树已经打了 H616/DE33 显示补丁集**之上。
源码树 `~/kernel/src/linux-7.2.12`（1.8G 活树，gitignore），补丁来源
`/x96-build/armbian-build/patch/kernel/archive/sunxi-7.3/patches.drm/`，详细过程与三次误判见
`x98h.md` §9.9 ①、§9.5。

没有这套补丁时：`/dev/dri` 只有 panfrost，`sun8i-mixer ... error -EBUSY`，
`cog -P drm` 找不到能挂 fb 的 plane → 黑屏/直接退，跟字体、GST、`renderer` 参数都无关。

### 10.1 补丁改了哪些文件（现树实测清单，`*.orig` 即原版留底）

| 文件 | 改动 | 对浏览器的意义 |
|---|---|---|
| `drivers/gpu/drm/sun4i/{Makefile,sun50i_planes.c,.h}` | 新增 DE33 planes 驱动（layers 独立节点 `planes@100000`），编进 `sun8i-mixer.ko` | **关键**：cog 要的 plane 从这里来 |
| `sun8i_mixer.{c,h}` | `struct regmap *disp_regs` → `struct device *planes_dev`；blend 属性改写 `engine->regs`；删 `sun8i_blender_regmap()` | DE33 上 mixer 不再撞 `-EBUSY`，能 bind 出 card |
| `sun8i_csc.{c,h}` | 新增 DE33 CCSC（`DE33_CCSC_BASE 0x800`、`SUN50I_CSC_COEFF/ALPHA`）、`sun8i_de33_convert_table()` | 色彩空间转换；RGB 直出本身不依赖 |
| `sun8i_vi_layer.c` | 新增 `sun8i_vi_layer_de3_no_yuv_formats`（**24 个纯 RGB 格式**）：DE33 无 scaler 时只报 RGB，屏蔽 YUV | **关键**：见 10.2 第 ② 条 |
| `sun4i_drv.c` | `of_table` 加 `allwinner,sun50i-h616-display-engine` | 否则整个 display engine 不 probe |
| `sun4i_tcon.{c,h}` | 加 `SUN4I_TCON_GCTL_PAD_SEL BIT(1)`、`bool hdmi_pad`、`sun50i_h616_tv_quirks`、`sun50i-h616-tcon-tv` 匹配 | H616 必须开 HDMI pad，否则无信号 |
| `sun8i_tcon_top.c` | 加 `sun50i_h616_tcon_top_quirks`（`has_tcon_tv1`）、`sun50i-h616-tcon-top` 匹配 | 不加 → `tcon-top -61 (ENODATA)` |
| `sun8i_hdmi_phy.c` | 加 `sun50i_h616_mpll_cfg`（27M/74.25M/148.5M/297M/594M） | HDMI 像素时钟；2.5K/4K 模式靠它 |
| `drivers/clk/sunxi-ng/ccu-sun8i-de2.c` | DE33 时钟/复位布局 | mixer 起不来就直接失败 |

DT 两处（不是驱动，但不改同样不通）：

1. `tcon-top@6510000` 补 `tcon-tv1` 时钟（`CLK_TCON_TV1` = 120 = `0x78`，三项 `0x76/0x77/0x78`）；
2. `sram-section@0` compatible：`allwinner,sun50i-h616-sram-c1` → `allwinner,sun50i-h616-ve-sram`
   （这条是给 cedrus 硬解用的，浏览器不依赖）。

另：`drivers/staging/media/sunxi/cedrus/cedrus.c` 加 `sun50i-h616-video-engine` 匹配 —— 属硬解线，
浏览器里**故意不用**（第 6 节把硬解 rank 归零）。

### 10.2 驱动与浏览器的三个咬合点（"改驱动"必须写进本文的原因）

1. **`sun4i_backend.c:162` 没改，也别改**：
   ```c
   if (modifier != DRM_FORMAT_MOD_LINEAR)
           return false;      /* sun4i_backend_format_check */
   ```
   全树 sun4i 无 AFBC 支持。所以 `renderer=modeset`（零拷贝，把 WebProcess/panfrost 的 AFBC buffer
   直接挂 plane）必然 `failed to create framebuffer: Invalid argument`。
   这不是内核 bug，是**硬约束** → 第 2 节的 `renderer=gles` 是唯一解（EGL 渲到 gbm 的 LINEAR buffer 再 blit）。
2. **DE33 无 scaler → vi plane 只报 24 个 RGB 格式，没有 NV12/YUV**：
   视频帧不能直接上 plane，WebKit 必须走 GL 转换；这既再次指向 gles，
   也解释了第 7 节"视频能播但 720p 只有 0.8fps"是 Skia 光栅 + GL 合成成本，不在解码。
3. **mixer 与 planes 拆成两个 syscon 节点后**，cog 走 `drmModeGetResources` 拿到的 plane 集才完整；
   旧驱动（无补丁）在 H618 上根本 bind 不出显示 card，`cog -P drm` 直接失败。

### 10.3 当前 123 上的实物核对（2026-11-26 ssh 实测）

```text
uname -r                7.2.12-x98
/boot/Image             50366976 B  md5 754ea2ed3aabad8bc6ce12e392fe89b8
/boot/dtb/allwinner/sun50i-h618-x98h-100mb.dtb  45307 B  md5 5326fac5223edc869d0c71c3d42c45b3
/boot/System.map-7.2.12-x98  含 sun50i_planes_probe / sun50i_h616_tv_quirks / sun50i_h616_hdmi_phy
HDMI-A-1                connected
```

> 旧记录里的 `Image a9208f95…`、`dtb ddebb489…`(45165 B) 是补丁期/音频前那一版，**已被覆盖**；
> 以本节这组为准（补丁集仍在，DT 后来又加过音频/BT 节点所以字节数变了）。

### 10.4 复用与红线

- 要重编：照 `x98h.md` §9/§11 走交叉编译 → 推 `Image` + `dtb` + `modules` + `uInitrd` 四件；
  `modules_install` 必须加 `INSTALL_MOD_STRIP=1`（不加 3.1G，p2 只有 851M → ENOSPC）。
- **不要为了浏览器再编一版内核，也不要手改 bind 逻辑**：曾手改 `sun8i_mixer_bind` 试一次，
  白改一轮后逐字节回退（`x98h.md` §9.9 三次误判表）。驱动要变就整包回移上游补丁。
- 121 是 **Amlogic meson**（`meson-vdec` 线，内核改动记在 `X96max.md`），与本节无关；
  121 上 AFBC/格式行为要在机上实测，别把 123 的结论直接搬过去（见 8.2）。
---

## 11. cage + chromium + CDP（实测后成为日常路线）

第 1 节选了 cog 是因为 cage 要装 74 包且自带合成器抢 DRM；但**这条路本身是通的**，
且 CDP 比 cogctl 好用得多（能执行任意 JS、读 DOM、注入事件）。2026-11-26 在 123 上完整跑通。

### 11.1 装机

```bash
apt install --no-install-recommends -y cage chromium fonts-wqy-zenhei seatd dbus-x11 luajit curl
```

不需要 `lua-socket` / `lua-cjson` / `luarocks` / `lua-websockets`——见 11.2，全部用 FFI 手写。

### 11.2 CDP 客户端：零依赖单文件

脚本：`tools/cdp/cdp_control.lua`（入仓版本），盒上落 `/root/cdp_control.lua`。

原方案要求 `lua-websockets` + `lua-cjson`，但它们需要 luarocks 编译，且 123 上没有。
改成纯 LuaJIT：

| 件 | 做法 |
|---|---|
| TCP | FFI 直调 libc `socket/connect/send/recv`，`SO_RCVTIMEO` 做超时 |
| HTTP | 手写 `GET /json/list`，只解析 status + `Content-Length` |
| JSON | 自己写最小 encoder/decoder（够解析 `/json/list` 响应和 CDP 回包） |
| WebSocket | 手写 RFC6455：客户端掩码、`Sec-WebSocket-Key` 随机、`Sec-WebSocket-Accept` 用 `SHA1` + base64 |
| SHA1/base64 | 纯 Lua 实现，不依赖 openssl |

**三个坑（都踩过，改完才对）**：

1. **`sin_addr` 字节序**（最阴，症状是全零响应）：
   ```lua
   sa.sin_addr = 0x0100007F   -- 正确：小端写入 = 网络序 7F 00 00 01
   -- sa.sin_addr = 0x7F000001  -- 错！连的是 1.0.0.127
   ```
   `struct sockaddr_in.sin_addr` 是 `in_addr_t`（主机序存网络序），不是 `struct in_addr` 的字节数组。
   写反了 `connect()` **仍返回 0**（NAT/回环路由把它带出去了），`recv()` 返回 0，
   看起来像"服务器没响应"。用 `ss -tn` 看对端地址 `1.0.0.127:9333` 才暴露。
2. **`Sec-WebSocket-Accept` 校验不能先 `lower()`**：
   ```lua
   -- 错：local accept = head:lower():match("sec%-websocket%-accept:%s*([^\r\n]+)")
   for line in head:gmatch("[^\r\n]+") do
     local k, v = line:match("^(.-):%s*(.-)%s*$")
     if k and k:lower() == "sec-websocket-accept" then accept = v break end
   end
   ```
   base64 大小写敏感，`NrUX…` → `nrux…` 会误报握手失败。
3. **`Runtime.evaluate` 回包层级**：`{"id":N,"result":{"result":{"type":"string","value":…}}}`
   取 `res.result.result.value` 会多一层，正确是 `res.result.value`。

### 11.3 启动（必须 mask desktop，同第 3 节）

```bash
ssh x98h
systemctl mask --runtime desktop && systemctl stop desktop
dbus-run-session cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' about:blank
```

`--ozone-platform=wayland` 是必须的（cage 提供 wayland socket）；
`--remote-allow-origins=*` 缺了新版 Chromium 会拒 WS 握手。

### 11.4 实测结果（123，2560x1440）

```text
[json/list] HTTP 200，getpage 拿到 webSocketDebuggerUrl
[握手]      101 Switching Protocols，Accept 校验通过
[导航]      Page.navigate → 百度首页，readyState=complete 2.5s
[读页面]    viewport=2560x1440，title=百度一下，你就知道，中文正文正常
[注入]      #kw 填值 + form.submit → 跳 /s?wd=机顶盒浏览器直出，无验证码
[抓屏]      plane=41 fb=56 2560x1440 XR24，非零 11091/14790 均值 187.8 → 全屏搜索结果页
```

**注意**：`viewport` 在 123 上是 `2560x1440`，说明 chromium 吃到了真实 DRM 模式；
本机 x86 验证时是 `780x437`（headless 窗口），别拿本机数字推断盒子行为。

### 11.5 与 cog 路线对比

| | cog + `-P drm` | cage + chromium |
|---|---|---|
| 包数 | 47 | 74 + cage |
| 独占 DRM | 直接，无合成器 | cage 合成器接管 |
| 控制 | cogctl 只有导航 | **CDP 全能力**（任意 JS / DOM / 事件 / 截图） |
| 动态页 | 重绘 3–5s SIGSEGV（未解） | **稳定，无崩溃** |
| 视频 | 软解 720p ≈0.8fps | 未测 |
| GPU | `renderer=gles` 必须 | gpu-process + `renderD128`，正常 |

> 结论：**动态页面和需要脚本控制的场景走 cage+chromium**；只放静态图文、
> 或要求绝对少装包时走 cog。两条都已在 123 上验证出画。

### 11.6 通用执行器 `cdp_do.lua`（一次调用干一件事）

`cdp_control.lua` 是**演示脚本**（固定走百度搜索那一套流程）；日常遥控用它的执行器版本
`tools/cdp/cdp_do.lua`，库部分同源，只把流程参数化：

```bash
# 导航 + 读值
luajit cdp_do.lua https://cn.bing.com "document.title"
# 不导航，直接操作当前页（"-" 是关键）
luajit cdp_do.lua - "JSON.stringify({t:document.title,n:document.querySelectorAll('h3').length})"
# 注入交互：填框 + 提交，返回表达式结果
luajit cdp_do.lua https://www.baidu.com "(function(){var i=document.querySelector('#kw');i.value='内核 直出 HDMI';(document.querySelector('#su')||{}).click?document.querySelector('#su').click():i.form.submit();return 'typed'})()"
```

不给 js 就只导航并打印 `title/href/readyState/视口`。执行结果打印 `[js] <值>`，
`awaitPromise=false` 时 Promise 会原样返回，要等异步结果就在表达式里用 IIFE + `Promise`
（脚本里 `awaitPromise` 已开）。

**两个新坑**（写 `cdp_control.lua` 时没暴露，拆成通用执行器才炸）：

1. **`webSocketDebuggerUrl` 带 `ws://host:port` 前缀**，`GET` 请求行只要路径。
   直接把整串丢进 `ws_open` 会得到 `握手失败 HTTP nil`。必须
   `url:match("^ws://[^/]+(/.*)$")` 剥掉协议+host。
2. **CDP 回包是两层 `result`**：`{id=…, result={result={type,value}}}`。
   外层 `result` 是 CDP 信封，内层 `result` 才是 `RemoteObject`。
   少读一层——`r.result.value` 恒为 `nil`——症状是**每条求值都返回 `nil`、
   但日志里 `readyState=complete` 又是对的**（因为 `readyState` 的比较用
   `nil ~= "complete"` 走完了循环，看着像成功）。正确取值：

```lua
local res   = r.result                    -- 信封
local inner = res and res.result          -- RemoteObject
local v     = inner and (inner.value ~= nil and inner.value or inner.description)
```

实测（123，cage+chromium 在跑）：

```text
[page] https://cn.bing.com/
[load] readyState=complete  0.0s  (当前页)
[js]   {"t":"内核 直出 HDMI_百度搜索","n":9,"first":"【教程】7代核显直通HDMI成功输出画面…"}
[抓屏] 2560x1440 全屏搜索结果页，中文无方块
```

注意 `document.readyState` 在**跨文档导航后**立即读可能拿到旧文档的值，
脚本用 250ms×120 轮询到 `complete` 再往下走。

---

## 12. 上电即用：持久 profile + 一键启动 + 微博实测

前 11 节解决的是"能不能出画、能不能控制"；本节解决"重启后还是不是那个登录好的浏览器"。

### 12.1 登录态靠 profile 目录，不靠任何额外参数

chromium 默认把 profile 写在 `$HOME/.config/chromium`（root 下即 `/root/.config/chromium`），
**cage 路线不需要 `--user-data-dir` 也是持久的**，别被文档里的"每次都是新浏览器"误导。实测：

```text
/root/.config/chromium                16M
/root/.config/chromium/Default/Cookies          53248 B   ← 微博 cookie 库
/root/.config/chromium/Local State               6146 B
```

`Cookies` 是 SQLite，盒上没有 `sqlite3`，直接 `strings` 就能确认登录票在：

```bash
ssh x98h "strings /root/.config/chromium/Default/Cookies | grep -E '^\.weibo' | sort -u"
# .weibo.com / .weibo.cn 下 SUB、SUBP、SCF、ALF 各一份（v10 后缀是同库的加密列名）
```

**结论**：只要不删这个目录、不换 `--user-data-dir`、不在 kiosk 里开隐身，
微博这类登录站点重启后仍是登录态（实测时间跨度 >20 分钟，cookie 过期时间在 2026 年之后）。

### 12.2 一键启动 `/root/startcage.sh`

**已入仓**：现行版就是仓库里的 `tools/cog/startcage.sh`（含第 13 节调优参数与第 14 节字号修正），
`BOX=x98h ./deploy.sh` 会推到 `/root/cog/startcage.sh`，并在 `/root/startcage.sh` 留一个转发壳
（`exec /root/cog/startcage.sh "$@"`）—— 实体只有一份，别再像 rcup 那次在盒上手改出两个版本。

下面是**初版骨架**，只用来解释每一步为什么这么写；实际起浏览器请调 `/root/cog/startcage.sh`。

```bash
#!/bin/bash
systemctl mask --runtime desktop >/dev/null 2>&1   # Restart=always，必须先 mask 再 stop
systemctl stop desktop 2>/dev/null
sleep 1.5
pkill -x cage 2>/dev/null; pkill -x chromium 2>/dev/null; sleep 0.5
# ← 此处插入第 14 节的 Preferences 字号修正（必须在 chromium 停掉之后）
cd /root
setsid dbus-run-session cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' about:blank > /tmp/cage.log 2>&1 &
for i in $(seq 1 40); do
  curl -s --max-time 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1 \
    && { echo "CDP ready after ${i}x0.5s"; curl -s http://127.0.0.1:9222/json/version; exit 0; }
  sleep 0.5
done
echo "TIMEOUT"; tail -20 /tmp/cage.log; exit 1
```

要点：

- `setsid` + `&`：脚本退出后 cage/chromium 留在自己的会话里，SSH 断开不掉。
- 轮询 `127.0.0.1:9222/json/version` 而不是 `sleep 5`：实测**约 2 秒**就绪，
  判定条件就是能拿到 `Browser: Chrome/156.0.8078.108` 那张 JSON。
- `pkill -x cage` / `pkill -x chromium`：**用 `-x` 精确匹配进程名**，
  不要用 `pkill -f chromium`（会连 SSH 自己的命令行一起匹配）。见第 3 节。
- 收工回桌面：`systemctl unmask --runtime desktop && systemctl start desktop`。

### 12.3 微博实测（123，2560x1440，登录态跨重启）

```text
[json/version] Browser Chrome/156.0.8078.108  Protocol-Version 1.3
[json/list]    type=page  title=微博 – 随时随地发现新鲜事  url=https://weibo.com/
[首屏]          顶栏头像+账号、左侧分组、中间信息流、右侧热搜榜（中文与图片均正常）
[登录态]        重启 cage/chromium 后 SUB/SUBP/SCF 仍在 → 仍登录
```

`faviconUrl` 也变成了 `https://weibo.com/favicon.ico`——这是 CDP 侧判断
"真的到了微博"而不是"停在中转页"的一个免费信号。

### 12.4 一处已纠正的误判：所谓"骨架屏"

之前把灰白骨架、以及登录页只有空白二维码，判成"微博 SPA 渲染不出"。
**实际是标签页卡在 `https://passport.weibo.com/sso/signin?...` 那次跳转上**
（`/json/list` 里能看到该 URL），页面根本没走完登录回跳。
重启后首屏直接是正常信息流——所以遇到骨架屏，**先看 `/json/list` 里的 url/title**，
再考虑渲染问题，别一上来就怀疑 GPU/字体/字体缓存。

### 12.5 收尾清单（跑完实验腾空间）

- `/tmp` 是 tmpfs（121/123 各约 2G，重启即清）；抓下来的 raw 一帧 2560x1440 就是 **14745600 B**，
  连抓十几帧就能写满，写满后是**静默失败**（`sed: couldn't flush stdout` 之类）。
- 123 上可清的实验残留：`/usr/local/lib/{egl-linear-only,gst-videometa-shim,gst-glconvert-shim}.so`
  （均已证明不必要，见第 2、6 节）、`/root/media/`、`/tmp/cogtest/`。

## 13. 多核调优：哪些负载能吃满 4 核，哪些吃不动（2026-11-26 实测）

背景：页面滚动/动画偶尔发涩，怀疑 chromium 只用了一个核。实测确认了——
**默认配置下渲染进程 17 个线程里只有主线程(72%)和 Compositor(4%)在干活，其余 15 个闲转**。

### 13.1 渲染后端先要确认（别瞎猜）

`chrome://gpu` 在 CDP 下 `innerText` 是空的（WebUI 未渲染），拿不到信息。
用 WebGL 取真实后端，一条就够：

```js
const g=document.createElement('canvas').getContext('webgl2');
const d=g.getExtension('WEBGL_debug_renderer_info');
g.getParameter(d.UNMASKED_RENDERER_WEBGL)
// → "ANGLE (Mesa, Mali-G31 (Panfrost), OpenGL ES 3.1)"
```

结论：**合成走真 GPU（Mali-G31 / Panfrost），不是 llvmpipe**。
Debian 的 chromium 启动器还默认强制了 `--enable-gpu-rasterization`。

### 13.2 三种负载，三种瓶颈（2560x1440，4x A53）

| 负载 | 默认 | 多核调优后 | 瓶颈 |
|---|---|---|---|
| canvas 2D 重绘页（6 块 640x360 每帧全画） | **1.5 fps** | **3.6 fps**（+140%） | CPU 软光栅 → 吃满 4 核 |
| 真实网页（backdrop-filter/blur/大阴影/mix-blend） | 11.7 fps | 11.8 fps | **GPU 合成**，加线程无效 |
| 720p 视频（软解 avdec/h264） | 29.6 fps | 29.7 fps | 已经满帧，本来就多核 |

CPU 归集（`/proc/<pid>/stat` 前后差分，单核%=100）：

```text
canvas 页 默认：      gpu-process 18.2%   renderer  6.0%          → 1.5 fps，两边都没吃饱
canvas 页 软件光栅：  gpu-process 44.2%   renderer 126.1%  cage 12.5% → 3.6 fps，4 核 39/45/52/52%
视频：                gpu-process 59.3%   renderer 134.4%         → 29.7 fps 满帧
```

**关键判断法**：`gpu-process` 与 `renderer` 都不高、但帧率还上不去 → 卡在 GPU 执行，
加线程纯属浪费；`renderer` 单线程接近 100% 而其它核空着 → 才是线程数问题。

### 13.3 落地的参数（已写进 `/root/startcage.sh`）

```bash
cage -- chromium --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' \
  --num-raster-threads=3 --disable-accelerated-2d-canvas \
  about:blank
```

- `--num-raster-threads=3`：4 核里留一核给 GPU 进程/合成器。
  实测 2/3/4 线程**都是 3.6 fps**（已饱和），选 3 只是不想和 cage/GPU 抢核。
- `--disable-accelerated-2d-canvas`：**这是真正有效的那一条**。
  Panfrost 驱动弱，canvas 2D 走 GPU 反而慢；转 CPU 软光栅后由多线程并行，帧率翻倍。
  对 blur/阴影类真实网页**无副作用**（11.6 vs 11.7，噪声内），对视频**无影响**（29.7 满帧）。
- `--enable-oop-rasterization` **无效**（1.6 fps），光栅挪到 GPU 进程只是换个地方单线程。
- `--disable-gpu-rasterization` **无效**（fps 掉且只压一核），别混用。

改前备份：`/root/startcage.sh.bak-pre-multicore`。

### 13.4 测量脚本（源码在 `tools/cdp/`，跑到 123 上，可重跑）

- `tools/cdp/prof.sh <标签> [秒]`：按进程归集 CPU + renderer/GPU 热点线程 + 页面 fps + PSS 内存。
- `tools/cdp/sc2.sh`：`EXTRA="--flags" PAGE=bench.html` 起指定参数的 cage，便于 A/B。
- `tools/cdp/bench.html`（canvas 重绘压测）、`bench2.html`（blur/阴影压测）、
  `vid.html`（`requestVideoFrameCallback` 数真实解码帧）。
- 页面 fps 用 `window.__t0`/`__stats.f` 自算；**注意 rAF 计数是 BeginFrame 节流后的结果**，
  负载高时它才反映真实吞吐（低负载页面 rAF 会恒为 ~60，不能当成"上屏 60 帧"）。

上盒跑之前，先把 `tools/cdp/` 里的 `cdp_do.lua` + `bench*.html` + `vid.html` 放到盒上 `/tmp/`：
`scp tools/cdp/*.{lua,html} x98h:/tmp/`。脚本里 `$L /tmp/cdp_do.lua`、`file:///tmp/bench.html` 是**硬编码的 /tmp**，
所以文件名不能改、目录不能挪（盒上 `/tmp` 是 tmpfs，重启即空，需重推）。

## 14. 默认字号：只能改 Preferences，且必须停机改（2026-11-26 实测）

### 14.1 没有命令行开关

chromium 的默认字号（未指定 `font-size` 的文档用哪个 px）**没有对应的 `--font-size` 类开关**，
只存在于 `webkit.webprefs.default_font_size`。查法：`chromium --help` 里搜 font 只能搜到
`--force-device-scale-factor`、`--default-tile-*` 这类无关项。所以唯一切口是配置文件：

```text
/root/.config/chromium/Default/Preferences
  .webkit.webprefs.default_font_size   # 整数，默认 16
```

### 14.2 坑：运行中改会被覆写

chromium 持有 Preferences，**退出时整份回写内存里的副本**。运行期间用 python 改文件，
进程一退就被覆盖回去，白改。顺序必须是：**先停 chromium → 改文件 → 再起**。
所以这个动作固化进 `/root/startcage.sh`，在 `pkill` 之后、启 cage 之前跑（幂等：值相同就不写）。

### 14.3 落地写法（已进 `/root/startcage.sh`）

```bash
FONTSIZE="${LITE_FONT_SIZE:-14}"
python3 - "$FONTSIZE" <<'PY' 2>/dev/null
import json, os, sys
p = "/root/.config/chromium/Default/Preferences"
size = int(sys.argv[1])
try:
    d = json.load(open(p))
except Exception:
    d = {}
w = d.setdefault("webkit", {}).setdefault("webprefs", {})
if w.get("default_font_size") != size:
    w["default_font_size"] = size
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(d, open(p, "w"))
    print("font-size -> %dpx" % size)
PY
```

想临时换字号：`LITE_FONT_SIZE=18 bash /root/startcage.sh`。

### 14.4 A/B 实测（123，2560x1440）

用 CDP 新开临时 target 量 `getComputedStyle`，不动正在显示的页面：

| 状态 | 未指定字号的文档 | Preferences |
|---|---|---|
| 改前 | `html=16px  p=16px` | 无 `webkit.webprefs` |
| 改后（14） | `html=14px  p=14px` | `{'default_font_size': 14}` |

### 14.5 重要边界：只对"没写字号"的页面有效

同一台盒子上访问 `https://weibo.com/`，改后仍是 `html=16px`——**站点自己的 CSS 显式给了字号**，
浏览器默认值被覆盖。这是正常行为，不是没生效：
**默认字号 = 兜底值，只决定那些没写 font-size 的文档**（本地 html、纯文本、简易页）。
要强行放大已有站点的字号，得走 CDP 注入 CSS（`Emulation.setPageScaleFactor` 或插 `*{font-size:...}`），
那是页面级的临时手段，不要塞进启动脚本。

验证截图：`tmp/after14.png`（整幅 2560x1440）与缩放版 `tmp/after14-s.png`。

---

## 15. 121（x96）实战：4K 分辨率怎么来的、崩溃怎么处置、装了哪些包

> 全部来自 2026-11-26 22:0x 在 x96 上的实测（`/tmp/cogrt/cog.log`、`/var/log/display-adapt.log`、
> `/var/log/dpkg.log`、`/var/log/apt/history.log`、`i2c`/DRM sysfs 现场读数）。
> 结论先行：**分辨率链路是干净的（crtc 3840x2160@60，cog 主 plane fb 也是 4K）；
> 但"持续重绘不崩"没有长跑数据，别把"能开 weibo"当成"动态页稳"。**

### 15.1 3840×2160 是谁定下来的：三层各管一段

| 层 | 组件 | 它负责的那一段 | 121 当前状态 |
|---|---|---|---|
| ① 内核 | cmdline `drm.edid_firmware=edid/active.bin`（**无 `video=`**） | 开机用固件 EDID 建模式表，拿到 34 个模式、首选 3840x2160 | 在 `/proc/cmdline` 里 |
| ② 自愈 | `/usr/local/bin/display-adapt` + `display-adapt.timer`（2 分钟一查） | 拔插 HDMI 后 fbcon 会落到 1024x768（DRM 安全模式），它负责把模式扳回首选 | timer `active`，脚本 11-25 版本 |
| ③ 应用 | `cog -P drm -O renderer=gles --device-scale=2` | 自己 gbm 分配 LINEAR buffer 并挂主 plane，scanout 尺寸 = CRTC 模式 | 实测 plane fb=3840x2160 |

**② 的自愈逻辑**（这就是"拔掉 HDMI 再插分辨率就坏"的修法）：

```
读 connector=connected，模式表 nmodes=34，当前 CUR
CUR == PREF ? 收工
stop desktop            # 必须停，否则它持着 DRM master，modeset 抢不到
/usr/local/bin/drm-setmode 3840x2160
start desktop
回读校验 == PREF ? rm /run/display-adapt.tried : 保留 TRIED 防死循环（避免每 2 分钟重启桌面）
```

11-25 的真实现场（`/var/log/display-adapt.log`）：

```
[12:20:39] 模式表 34 项，当前 1920x1080 → 目标 3840x2160 → 停桌面 / drm-setmode / 起桌面
OK set 3840x2160@60 on HDMI-A (crtc 46 fb 49)
[12:20:47] 修正后 3840x2160，desktop=active   OK
[12:26:52] 当前 1024x768 → 同上 → [12:27:00] 修正后 3840x2160   OK
```

> 老版本只 `systemctl restart desktop`，桌面顺着当前（错的）模式重建 → 死循环，
> 已在 `display-adapt.bak-pre-modeset` 留底。

**③ 的两个参数，缺一不可：**

```bash
cog -P drm -O renderer=gles --device-scale=2 https://weibo.com
```

- `renderer=gles`：默认 `modeset` 会把 WebProcess 的 AFBC buffer 直接挂 plane，
  meson/sun4i 老 backend 只认 LINEAR → `failed to create framebuffer: Invalid argument`（第 2 节）。
  121 上这条**实测无报错**。
- `--device-scale=2`：4K 面板上若按 CSS 视口 3840 宽算，1 CSS px = 1 物理像素，正文小到看不清。
  给 2 → CSS 视口折成 1920x1080、DPI=192，网页按"高分屏"排版，字恢复正常大小。
  这是 121（4K）与 123（2560x1440，通常给 1 或 1.5）在**同一份脚本里也必须分开**的唯一参数。

**现场证据（22:0x 实测）：**

```
crtc=46 fb=47 3840x2160@60          # /root/grabplane-aarch64 /dev/dri/card0 out.raw
fb 3840x2160 pitch=15360 bpp=32
已存 out.raw (33177600 B)            # = 3840*2160*4，与 fb 尺寸吻合
主 plane：allocated by = cog，XR24，crtc-pos 3840x2160+0+0
dmesg：无 failed to create framebuffer、无 page flip 报错
```

**两个假象，别当成故障：**

1. `meson-drm ... Requesting EDID firmware "0" failed (err=-2)`：开机探测期刷一阵（本次 113 次）就停，
   是 `edid_firmware` 参数被读成 `"0"` 的噪音，**模式不受影响**。
2. `grabscreen-aarch64` 写死 2560x1440，在 121 上只抓 1302 行 → 右下半截空白，
   看图会误判"画面只出一半 / 崩了"。必须用 `grabplane-aarch64`（见 7.2）。

### 15.2 崩溃处置：两种崩溃，别混为一谈

| 类型 | 现象 | 121 现状 |
|---|---|---|
| **cog 主进程 SIGSEGV** | 屏幕定格，进程没了；日志 `Buffer address requested when its parent pool has an external reference and a deferred resize pending.`（`libwayland-server`，shm 传帧路径） | **未复现**（只在 123 见过，见 7.1） |
| **WebProcess 渲染进程崩溃** | 页面白一下，cog 自己 reload，屏幕不黑、进程还在 | **出现过 1 次**，自愈成功 |

121 的实测日志（`/tmp/cogrt/cog.log`，访问 `https://weibo.com/`）：

```
21:51:59  Load started.
21:52:25  The GStreamer FDK AAC plugin is missing, AAC playback is unlikely to work.
21:52:25  GStreamer element appsink not found. Please install it.
21:52:25  GStreamer element autoaudiosink not found. Please install it.
21:52:29  GLib-GObject-CRITICAL: invalid (NULL) pointer instance
21:52:29  g_signal_connect_data: assertion 'G_TYPE_CHECK_INSTANCE (instance)' failed
21:52:29  Crash!: The renderer process crashed. Reloading the page may fix intermittent failures.
21:52:30  Load started. → 21:52:30 Loaded successfully.
21:52:31  No provider of eglReleaseThread found.  ← 崩掉的那个旧 WebProcess 的收尾噪音，
          不是 cog 退出；主进程还在（4 分钟后仍在），日志此后无新错误
```

**处置（按顺序，每条都对应日志里的一行）：**

1. 缺 GStreamer element → 装 `gstreamer1.0-plugins-base`（`appsink`）、
   `gstreamer1.0-plugins-good`（`autoaudiosink`/`autovideosink`）、`gstreamer1.0-libav`（软解 `avdec_h264`）。
   缺 element 时 WebKit 的媒体栈会走到空指针分支（上面两条 `CRITICAL`），接着就是 renderer 崩。
2. **不加任何 GL 环境变量**。`LIBGL_ALWAYS_SOFTWARE=1`、`PAN_MESA_DEBUG=noafbc`、
   `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`、`JSC_useJIT=0` 都会把 WebKit 推回 shm 传帧，
   正是 123 那条 `Buffer address requested ...` 崩溃的诱因。121 也别加，
   当前 cog 进程环境里确实一个都没有（`/proc/<pid>/environ` 只有 `DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/cogrt/bus`）。
3. **desktop 必须 `mask --runtime` 再 `stop`**。它是 `Restart=always`，只 stop 会被拉回来抢 DRM master，
   cog 报 `Cannot set mode (Permission denied)`，屏幕停在桌面最后一帧（曾误判为"cog 画错"）。
   收尾必须 `unmask --runtime && start`，否则屏幕永远卡在 cog 的最后画面。
4. 页面重绘本身目前**不需要规避**（121 上 500ms 自更新页跑过 30s+、weibo 首页跑过约 4 分钟），
   但**没有 30 分钟以上的长跑数据**；要上"网页当播放器/游戏"这种持续重绘负载，先补压测再宣布稳。

### 15.3 121 装了哪些包（2026-11-26，两批共 61 个，全部 `--no-install-recommends`）

**批 1 — 21:32:32，45 个**

```bash
apt-get install -y --no-install-recommends cog
```

版本锚点：`cog 0.18.4-1+b1`、`libwpewebkit-2.0-1 2.48.3-1`、`libwpe-1.0-1 1.16.2-1`、
`libwpebackend-fdo-1.0-1 1.16.0-1`。

- 命脉 6 个（少一个都起不来）：`cog`、`libwpewebkit-2.0-1`、`libwpe-1.0-1`、
  `libwpebackend-fdo-1.0-1`、`bubblewrap`、`xdg-dbus-proxy`（WebKit 沙箱用的 DBus 代理）
- 输入（libinput udev backend，遥控器/键盘能进网页就靠这条链）：
  `libinput10`、`libinput-bin`、`libevdev2`、`libmtdev1t64`、`libgudev-1.0-0`、
  `libwacom9`、`libwacom-common`、`libmanette-0.2-0`、`libhidapi-hidraw0`、`libxkbcommon-x11-0`、`libxcb-xkb1`
- 网络 / 渲染 / 文本：`libsoup-3.0-0(+common)`、`glib-networking(+services,+common)`、
  `dconf-gsettings-backend`、`dconf-service`、`libdconf1`、`gsettings-desktop-schemas`、`libproxy1v5`、
  `libavif16`、`libgav1-1`、`libyuv0`、`libwoff1`、`libxslt1.1`、`iso-codes`、`libduktape207`、`libatk1.0-0t64`、`at-spi2-common`
- GStreamer 骨架（只有骨架，没有元素）：`libgstreamer1.0-0`、`libgstreamer-plugins-base1.0-0`、
  `libgstreamer-gl1.0-0`、`libgstreamer-plugins-bad1.0-0`、`liborc-0.4-0t64`、
  `libgssdp-1.6-0`、`libgupnp-1.6-0`、`libgupnp-igd-1.6-0`、`libnice10`

**批 2 — 21:59:56，16 个（补 WebRTC/媒体元素，直接对应 15.2 的 renderer 崩溃）**

```bash
apt-get install -y --no-install-recommends gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav
```

连带自动包：`libtheora0`、`libdv4t64`、`libwavpack1`、`libtag2`、`libshout3`、`libvisual-0.4-0`、
`libopencore-amrnb0`、`libopencore-amrwb0`、`libaa1`、`libncurses6`、`libcdparanoia0`、`libxdamage1`、`libxtst6`。

**刻意没装**：`cage`、`chromium`、`Xorg`、任何桌面/合成器、Node.js、Python 运行时。
整条链路 61 个包，且不需要 Wayland 合成器 —— 这是 cog 路线相对 cage+chromium（74 包 + 合成器 + 抢 DRM master）的实际差距。

**核对方法（换盒子重装后照这个查）**：

```bash
dpkg -l | grep -iE 'cog|wpewebkit|wpebackend|libwpe'          # 版本锚点
awk '$3=="install"{print $1, $4}' /var/log/dpkg.log | grep 2026-11-26
awk '/^Start-Date: 2026-11-26/{p=1} p' /var/log/apt/history.log | grep -E 'Commandline|Install:'
```

## 16. 微信 Linux 版（arm64）当直出 app（2026-11-26，123 实测）

### 16.1 为什么微信能直出：它也是 Chromium

微信 4.x 的 Linux 客户端不是 Qt 也不是 Electron 壳，而是**腾讯自研外壳 + Chromium 内核**，
从 `/opt/wechat/` 的库名就能认出来：

| 库 | 作用 |
|---|---|
| `libmmmojo.so` | Mojo IPC（Chromium 的多进程消息总线），主进程 ↔ 渲染进程 |
| `libmmcronet.so` | Cronet（Chromium 的 network stack），所有 HTTP/HTTPS 走它 |
| `libandromeda.so` / `libilink2.so` / `libilink_stream.so` | 腾讯自研传输层（长连接/信令） |
| `libowl.so` | 腾讯 OWL 组件框架 |
| `libvlc.so` / `libvlccore.so.9` | 语音/视频消息播放，对应子进程 `wxplayer` |
| `crashpad_handler` | Chromium 的 crashpad，崩溃转储 |

**结论：渲染链和 chromium 完全同源**，所以第 11 节 cage + chromium 那条路能跑，微信这条路就能跑，
而且不需要 CDP、不需要 `--kiosk`——微信自己就是全屏最大化。

### 16.2 直出链路（和 cog 的关键差别在这里）

> 下面这份 fd/socket 证据是 **cage 时代**（2026-11-26）抓的；换成 sway 后协议层不变、链路同构，
> 只是拿 master 的进程变成 `sway`（微信照样只开 `renderD128`）。原理段不必重写，把进程名读成"合成器"即可。

实测抓到的实物证据（`/proc/<pid>/fd`、`/proc/net/unix`、`grabplane`）：

```text
cage(60944)   → /dev/dri/card0 ×7、/dev/dri/renderD128 ×7   ← DRM master + 自家 EGL/GLES
wechat(60947) → /dev/dri/renderD128 ×2                       ← 只有渲染节点，没有 card0
crtc=49  fb=56  2560x1440@60  pitch=10240 bpp=32             ← 全屏单 plane（XR24）
```

也就是说屏幕上的像素走这条链：

```text
1. cage 用 libseat(seatd) 拿 DRM master，打开 card0，取当前 CRTC 49 / plane 41，模式 2560x1440@60
2. wechat 以 Chromium 的 ozone/wayland 后端建一个 wl_surface，EGL + GLESv2（panfrost/panvk 自家驱动）
   渲到 gbm 分配的 dmabuf，commit 给 cage 的 wayland-0（socket 在 /run/user/0/wayland-0）
3. cage 做合成：把 client buffer 合成到自己的一张**线性** XR24 buffer（fb 2560x1440 pitch=10240）
4. drmModeSetPlane 把这张 fb 直接贴到 plane 41 → sun4i/DE33 → HDMI
```

**和 cog 的差别，一句话**：cog 是**零拷贝**——把 WebKit(panfrost) 的 buffer 直接挂 plane，
所以 sun4i 只认 `DRM_FORMAT_MOD_LINEAR` 这一条（第 2 节）会把 AFBC buffer 打成
`failed to create framebuffer: Invalid argument`；cage 是**多一次 copy**——合成成自家的线性 buffer
再上屏，代价是一次全屏 blit（2560x1440×4B = 14MB/帧），换来**不挑 modifier、不动内核**。

这就是为什么微信这条一次就跑通，而 cog 要折腾 `renderer=gles`（第 2 节）。

**没有 X11**：`pgrep Xwayland` 为空，`DISPLAY=:0` 只是继承来的死变量；wechat 是
`--ozone-platform=wayland` 纯 Wayland 客户端。所以任何依赖 X11 的输入法/托盘都不会有。

四种直出并排：

| | 拿 master | 渲染栈 | 上屏方式 | 改内核 | 动态页面 |
|---|---|---|---|---|---|
| desktop | 自己 | 自研 GLES | 自建 fb → plane | 是（DE33 补丁） | — |
| 阅读器 / 播放器 | 自己 | mupdf / 自研 vdec+GLES | 自建 fb → plane | 是 | — |
| cog -P drm | 自己 | WPE WebKit + panfrost | 零拷贝挂 plane（必须 gles） | 是 | 123 会崩（第 7 节） |
| cage + chromium | cage | Chromium + panfrost | 合成后单 plane | **否** | 稳定 |
| 微信（sway） | sway | Chromium + panfrost | 合成后单 plane | **否** | 稳定 |

### 16.3 装机

包来自腾讯官网的 arm64 deb（本机下载后 scp 到盒子，`/root/deb/`）。

页面：<https://linux.weixin.qq.com/>（x86_64 / arm64 / LoongArch，deb|rpm|AppImage）

直链（2026-11-27 复验，`HTTP 200`，`Content-Length: 211831284` = 202M，
`Last-Modified: Fri, 20 Nov 2026 06:53:38 GMT`）：

```text
https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_arm64.deb
```

同目录另外两个格式（换后缀即可，x86_64/LoongArch 同理）：
`WeChatLinux_arm64.rpm`、`WeChatLinux_arm64.AppImage`。

```bash
curl -LO https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_arm64.deb
scp WeChatLinux_arm64.deb x98h:/root/deb/          # 盒子直连也行：curl -LO <上面的直链>

ls -lh /root/deb/WeChatLinux_arm64.deb
# -rw-r--r-- 1 root root 203M  /root/deb/WeChatLinux_arm64.deb

apt-get install -y /root/deb/WeChatLinux_arm64.deb
```

实测装配结果：

```text
Package: wechat   Version: 4.1.13.29   Architecture: arm64
Installed-Size: 734894 KB                     ← 解包后 /opt/wechat = 718M
Depends: fonts-noto-cjk | google-noto-cjk-fonts
Description: wechat from Tencent
```

- **只多装 1 个包**：`fonts-noto-cjk 1:20240730+repack1-1`（91MB，arm64）。
  它是**硬 Depends**，`--no-install-recommends` 也挡不住；中文靠它显示（盒子上没有桌面字体）。
  123 原本没装它，装微信时被一起拽上来（`/var/log/apt/history.log` 里能看到
  `fonts-noto-cjk:arm64 (…, automatic)`）。
- **不需要**：X11、桌面、`chromium`、Node.js、Python 运行时、任何额外 .so。
- 入口：`/usr/bin/wechat` → `/opt/wechat/wechat`，ELF 64-bit LSB pie / ARM aarch64。
- 用户数据不在 `/opt`：`/root/.xwechat/`（配置 + mmkv 库）、`/root/xwechat_files/`（聊天文件）。

空间提醒：`/opt/wechat` 718M + deb 203M，`/root` 要留出 1G 以上；`/tmp` 是 tmpfs（2G），别往那儿解包。

#### 16.3.1 合成器 sway：要装的包（2026-11-27 换掉 cage，**这条最容易漏**）

微信不是直出 app，它得有个 Wayland 合成器替它拿 DRM master。原来用 `cage`，现在用 `sway`
（cage 0.2 的 view 只能贴左上角：`lx/ly` 写死 0，没配置项也没 IPC，居中 + 壁纸在 cage 上做不到）。
**换合成器 = 盒子上要多装一个 apt 包**，不装的话 `desktop/config.lua` 会静默回退到 cage 老路径
（判断条件是 `exists("/usr/bin/sway")`，没有就 `cage -- …`）。

123 实测就这么一条命令（其余全是已装依赖，`/var/log/apt/history.log` 2026-11-27 21:41）：

```bash
apt-get install -y -q sway
# Install: swaybg:arm64 (1.2.1-1+b1, automatic), libjson-c5:arm64 (0.18+ds-1, automatic),
#          sway:arm64 (1.10.1-2)
```

| 包 | 版本（123 实装） | 大小 | 谁要的 |
|---|---|---|---|
| `sway` | 1.10.1-2 | 1148 KB | 合成器本体；含 `sway` / `swaymsg` / `swaynag` |
| `swaybg` | 1.2.1-1+b1 | 82 KB | sway 的硬 Depends，`bg … fill` 那条壁纸指令靠它 |
| `libjson-c5` | 0.18+ds-1 | — | sway 的硬 Depends（自动） |

不需要额外装的（cage 那轮已经在机器上，被 sway 复用 —— 重刷系统时才要补）：

| 已有依赖 | 版本 | 谁提供 |
|---|---|---|
| `libwlroots-0.18` | 0.18.2-3 | sway 的合成后端库（cage 时代一起装的） |
| `seatd` + `libseat1` | 0.9.1-1 | sway 靠 libseat 拿 DRM master；`systemctl is-active seatd` 必须 active |
| `dbus-daemon` | 1.16.2-2 | 提供 `/usr/bin/dbus-run-session`（启动命令前缀） |
| `python3` | 3.x（基系统） | `/opt/desktop/bin/wx-center.py` 只用标准库（glob/json/subprocess），无 pip 依赖 |
| `xwayland` | 2:24.1.6-1 | **用不上**：配置里 `xwayland disable`；它是装 cage 时被拽上来的 |

`fonts-noto-cjk` 仍照旧（中文显示），与合成器无关。

配套的落盘文件（仓库 `desktop/` 同步到盒上，见 `desktop/deploy/README.md` 落点表）：

| 文件 | 盒上落点 | 作用 |
|---|---|---|
| `wechat.conf` | `/opt/desktop/wechat.conf` | `output HDMI-A-1 mode 2560x1440 position 0 0 bg /opt/desktop/assets/wallpaper.png fill`、`default_border none`、`for_window [app_id=".*"] floating enable`、`exec wx-center.py`、`exec … wechat …; swaymsg exit` |
| `bin/wx-center.py` | `/opt/desktop/bin/wx-center.py` | 等 `/run/user/0/sway-ipc.*.sock` 出现，`swaymsg -t get_tree` 找到 `app_id=wechat`，`resize set 1280 720` + `move absolute position` 居中（Electron 会覆盖 map 时刻的尺寸，只能在 map 后补一刀） |
| `assets/wallpaper.png` | `/opt/desktop/assets/wallpaper.png` | swaybg 只吃图片文件；由 `tools/bgra2png.py` 从 `wallpaper.bgra` 转 |
| `tools/bgra2png.py` | 不用上盒 | **在主机上跑**（要 `python3-PIL`；盒上没有 PIL，别在盒上执行） |

壁纸两处一致性：桌面走 DRM 直接贴 `wallpaper.bgra`（14.7MB，`tools/fbwall`），微信走 swaybg 读
`wallpaper.png`（6.0MB）。改壁纸必须两边都重生成，否则退出微信回桌面会看到背景跳一下。

运行前提仍是 `XDG_RUNTIME_DIR=/run/user/0` + `LIBSEAT_BACKEND=seatd`（`desktop.service` 里已带，
`desktop/config.lua` 起的 sway 继承这两个变量），sway 的 socket 落在 `/run/user/0/sway-ipc.<pid>.sock`。

回退：`apt-get remove --purge sway swaybg` 后 `config.lua` 自动走 cage（`cage` 0.2.0-2 仍在机器上），
不用改代码。

### 16.4 启动命令（sway 现行 / cage 回退）

日常入口不手打：桌面卡片「微信」由 `desktop/config.lua` 起来（`systemctl` 在位，走 desktop 的环境变量）：

```text
exec dbus-run-session -- sway -c /opt/desktop/wechat.conf
```

配置文件里后两行就是"起微信 + 微信退出即退出合成器"：

```text
exec /opt/desktop/bin/wx-center.py
exec sh -c '/opt/wechat/wechat --no-sandbox --ozone-platform=wayland \
            --disable-dev-shm-usage --window-size=1280,720; swaymsg exit'
```

命令行手测（先 mask 桌面，别再裸起）就写在同一份 `/root/wx-run.sh`（cage 老版本留作回退）：

```bash
#!/bin/bash
systemctl mask --runtime desktop 2>/dev/null
systemctl stop desktop 2>/dev/null
export XDG_RUNTIME_DIR=/run/user/0
export LIBSEAT_BACKEND=seatd
cd /root
exec dbus-run-session -- sway -c /opt/desktop/wechat.conf     # 回退：cage -- /opt/wechat/wechat …
```

逐条理由：

- `mask --runtime desktop` + `stop`：desktop 是 `Restart=always`，只 stop 会被拉回来抢 DRM master（同第 3 节）。
  **`wx-run.sh` 只 mask 不还原**，收尾必须手动 `systemctl unmask --runtime desktop && systemctl start desktop`。
- `XDG_RUNTIME_DIR=/run/user/0`：合成器的 socket 落在这里（cage 是 `wayland-0`；sway 另有
  `sway-ipc.<pid>.sock`，`wx-center.py` 靠它发 `swaymsg`）；root 直接跑不设这个，合成器会拒绝建 socket。
- `LIBSEAT_BACKEND=seatd` + `dbus-run-session`：cage 0.2.0 / sway 1.10 都靠 libseat 拿 master，seatd 已在跑；
  dbus session 是 Chromium 系进程的最低要求（不然有一堆 dbus 报错，虽不致命）。
- `--ozone-platform=wayland`：**必须**，否则会去找 X11 然后 `DISPLAY=:0` 连不上直接退出
  （sway 这边 `xwayland disable`，没有 X 可连）。
- `--no-sandbox` / `--disable-dev-shm-usage`：root 跑 Chromium 内核的老两样；后者是因为 `/dev/shm` 小。
- `--window-size=1280,720`：给个初始值。**sway 下窗口不再自动全屏**，由 `wx-center.py` 在 map 后
  resize 到 1280x720 并居中（`--start-maximized` 在 sway 下没意义，可去掉）。
- **不要加 `--disable-gpu`**：panfrost 能渲，加了反而把光栅压到 CPU（微信的圆角/阴影/图片滚动会明显掉帧）。

日志：`/root/wx.log`（当前 3.4K，33 行）。

### 16.5 实测（123，2560x1440@60，2026-11-26 23:18）

进程与内存（登录二维码界面，闲置）：

| 进程 | RSS | 说明 |
|---|---|---|
| `cage`（回退路径；sway 同量级） | 138M | 合成器 + DRM master |
| `wechat` | 546M | 主进程（Chromium 外壳 + 主窗口） |
| `wxocr` | 169M | 扫码/图片识别子进程 |
| `wxplayer` ×2 | 28M + 17M | libvlc，语音视频消息 |
| **合计** | **≈ 918M** | 整机 `free`: used 1170M / 3910M，available 2739M |

出图判定：

```bash
cd /root && ./grabplane-aarch64          # → crtc=49 fb=56 2560x1440@60，落 /tmp/plane.raw 14745600B
# 回本机：raw 是 BGRA，-pix_fmt 必须写 bgr0（写 bgra 因 alpha=0 得全白图）
ffmpeg -f rawvideo -pix_fmt bgr0 -s 2560x1440 -i plane.raw -frames:v 1 wx.png
```

`libinput` 在本机 USB 鼠标上报 `event processing lagging behind by 28ms/69ms`
（`event7 Lenovo ThinkPad USB Laser Mouse`）：4×A53 上 Chromium 系进程吃满单核时的正常抱怨，不影响点击。

### 16.6 输入现状（遥控器**还进不去**，这是当前唯一断点）

- sway 走 libinput + seatd（第 4 节那条链的合成器版），**鼠标可用**：微信里点联系人/滚动都行。
- 2.4G 遥控器（`XING WEI 2.4G USB`）的 4 个键盘类接口 `event1/2/4/5/6` 被
  **`keybd.service`（/opt/reader/bin/luajit /opt/keybord/keybd.lua，config `grab=true`）独占**，
  而 keybd 没有建 uinput 虚拟键盘（`/proc/bus/input/devices` 里没有虚拟设备，`/dev/uinput` 空闲），
  所以遥控器按键到不了 sway/微信。
- 要用遥控器，二选一（都**未做**）：
  1. `systemctl stop keybd` 让 sway 的 libinput 直接吃遥控器（最简单，验证用）；
  2. 给 keybd 加 app 映射（`browser`/`wechat`），把按键经 uinput 注入合成器 —— 同第 4.1 节注入器思路，
     app 表目前只有 `player(30)/reader(20)/desktop(10)/shell(0)`。
- 中文输入：装了 noto-cjk 只是**能显示**；盒子上没有 IBus/Fcitx，键盘直输英文/数字可以，
  中文得靠手机端或后续接输入法（未做）。

### 16.7 坑（都踩过）

1. **`EGL_BAD_PARAMETER eglQueryDeviceStringEXT`**（wx.log 开头两行）：Chromium 在探测 EGL 设备扩展，
   panfrost 不实现该扩展，报错**无害**，别去改驱动。
2. **`FlueGlobalStorage, fail to get keys from db, delete db_dir = /root/.xwechat/radium/mmkv/xweb_global_storage`**
   （首次启动连刷多条）：首次建库的自我修复，登录一次后消失，**不是装坏了**。
3. **不要指望 wechat 自己 `-P drm`**：它只开 `renderD128`（只有渲染节点），拿 master 的是合成器。
   想省掉合成器就得像 cog 那样自己写 DRM 后端——没必要，cage/sway 这条路已验证稳定。
4. **`WeChatLinux_arm64.deb` 203M 别留在 `/tmp`**：tmpfs 重启即清且会静默写失败；放 `/root/deb/`。
5. **收尾不还原 desktop，屏幕就卡在微信最后一帧**（第 3 节同款坑）：
   ```bash
   pkill -x wechat; pkill -x sway     # 回退路径时是 cage
   systemctl unmask --runtime desktop && systemctl start desktop
   systemctl is-active desktop    # 必须是 active
   ```
6. 磁盘/内存水位：718M 程序 + 546M 常驻，`/` 与 `/root` 余量低于 500M 时先清 `/root/media`、`/tmp/cogtest`。

## 17. YouTube 登录态直出 + 视频播放实测（2026-11-27，123）

这一节回答两件事：**怎么让盒子上的浏览器带着本机 Chrome 的登录态打开 YouTube**，
以及**视频能不能真的在 DRM 上放出来**。结论：能，音视频分离，画面通过，声音没有。

### 17.1 链路总览

```
本机 Chrome profile ──解密──> ytcookies.lua ──CDP Network.setCookie──> 盒上 chromium
                                                                        │ cage (DRM master)
本机 127.0.0.1:6880 (digilink) <──链式── 盒上 mihomo 127.0.0.1:7890 <──┘ --proxy-server
```

- **不要拷 `Cookies` 加密库文件**：Chrome 的 key 在 keyring 里，换机器/换用户解密必失败。
  正确做法是本机解密成明文表，再到盒子上用 CDP 一条条 `setCookie`。
- 代理不是可选项：123 直连 YouTube 不通，盒子靠自己的 mihomo 出口，链路见附录。

### 17.2 本机侧：把 Chrome cookie 解成 Lua 表

脚本 `tools/chrome3/export_cookies.lua`（LuaJIT FFI + C 补件，见 §17.7-A）：

```bash
luajit tools/chrome3/export_cookies.lua ~/.config/google-chrome/Default /tmp/ytcookies.lua
# 总 N 行，选中 228 条（youtube/.google），解失败 0 -> /tmp/ytcookies.lua
```

关键点（Linux 版 Chrome）：

| 环节 | 写法 | 坑 |
|---|---|---|
| 取密钥 | `Secret.Service` 找 label `Chrome Safe Storage` | 没有 python3-gi / keyring 没解锁则拿不到 |
| 派生 | `pbkdf2_hmac('sha1', pw, b'saltysalt', **1**, 16)` | Linux 迭代 **1**；抄 macOS 的 1003 会直接解不开 |
| 解密 | AES-128-CBC，IV = 16 个空格 | `EVP_aes_128_cbc.restype` 必须声明成 `c_void_p`，否则指针被截断 → 段错误 |
| 明文头 | 新版前 32 字节 = `sha256(host)`，**要跳过** | 不跳会解出乱码 cookie |
| Chrome 在跑 | 先 `shutil.copy` 一份 `Cookies` 到 /tmp | 运行中 SQLite 被锁，直接 open 会 `database is locked` |

### 17.3 盒上侧：注入 + 验证登录

`/root/ytcage.sh`（cage 起 chromium，kiosk + 9222）：

```bash
export XDG_RUNTIME_DIR=/run/user/0 LIBSEAT_BACKEND=seatd
exec dbus-run-session -- cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 --remote-allow-origins='*' \
  --proxy-server=http://127.0.0.1:7890 \
  --user-data-dir=/root/.config/chromium about:blank
```

注入用 `inject_yt.lua`（依赖 `cdplib.lua`，= `tools/cdp/cdp_do.lua` 的库部分）：

```bash
scp tools/chrome3/inject.lua tools/cdp/cdp_do.lua /tmp/ytcookies.lua x98h:/root/
ssh x98h '/opt/reader/bin/luajit /root/inject.lua /root/ytcookies.lua 9222 https://www.youtube.com/'
# [page] about:blank
# [cookie] 注入成功 228 / 失败 0
# [check] {"avatar":true,"signin_btn":false,"vids":..,"thumbs":..,"name":"..."}
```

- **带前导点的域必须用 `domain`**，不带点的用 `url`（`https://host/path`），否则 `setCookie` 失败。
- 注入完必须 `Page.navigate` 重载一次才生效；`#avatar-btn` 存在 = 已登录，比看 cookie 数量可靠。

### 17.4 播放实测

`ytplay.lua` 走**真实 DOM 点击**（`a#thumbnail[href*="/watch"].click()`），不伪造 player API：

```
[click] https://www.youtube.com/watch?v=...
[ 2s] {"t":1.8,"ready":4,"paused":false,"w":1280,"h":720,"dur":...,"q":60,"drop":1}
...
[60s] {... "q":1613,"drop":128,"t":...}
```

| 项 | 实测值 | 说明 |
|---|---|---|
| 分辨率 | 1280x720 | 自适应，不是 2560x1440（网络带宽 + VP9 软解） |
| 帧数 / 丢帧 | 1613 / 8% | 4x A53 软解 720p 的合理水平，不是卡死 |
| 画面是否上屏 | 是 | 播放中连抓两帧，`raw` 差 222 万字节；HDMI 肉眼正常 |
| 抓帧命令 | `/root/grabscreen-aarch64 /dev/dri/card0 /tmp/yt.raw` | raw 是 **BGRA**，转 PNG 必须 `-pix_fmt bgr0` |

```bash
ssh x98h '/root/grabscreen-aarch64 /dev/dri/card0 /tmp/yt.raw >/dev/null'
scp x98h:/tmp/yt.raw /tmp/yt.raw
ffmpeg -f rawvideo -pix_fmt bgr0 -s 2560x1440 -i /tmp/yt.raw -vf scale=900:-1 yt.png
```

**视频走的是软解 VP9/AV1 → 合成上屏**，没走 V4L2 硬解（`v4l2slvp9dec` 不可用），
所以 720p 已经是这颗 SoC 的天花板，1080p 会掉帧更狠。

### 17.5 唯一没解决的：声音

- 页面内音频**确实在解码**：`webkitAudioDecodedByteCount` ≈ 1.85 MB。
- 但 `/dev/snd/pcmC0D0p` **没有进程打开**，盒上也没有 pulseaudio/pactl 守护进程。
- 即 Chromium 在容器里找不到可用的 ALSA/Pulse 输出设备，静默丢音。
- 和播放器那条链不是一个问题（那边是自己 `aout_open` 直接写 ALSA），
  浏览器要出声得给它一个 **PulseAudio 或裸 ALSA 输出**，且注意 123 上 `card1`（H616 Codec）没有 pcm 节点，
  只有 `card0`(HDMI) 有 —— 即浏览器出声只能走 HDMI 内嵌音频。

### 17.6 坑（本节新增）

1. **`--password-store=basic` 是给"拷 profile 到新机器"用的，和 cookie 注入二选一**；两者混用会出现
   登录态在、但部分站点反复掉。
2. **`about:blank` 起、注入后再 navigate**：先开会话再注入，比直接开 YouTube 再注入稳
   （直接开时首个请求已带空 cookie，YouTube 会给未登录分支，之后注入也不换渲染树）。
3. **cookie 明文文件（`ytcookies.lua`）用完就删**：里面有 `SID`/`HSID` 等等价于密码，别留在 `/tmp` 或仓库。
4. **收尾必还原桌面**（同 16.7.5）：`pkill -x chromium; pkill -x cage;
   systemctl unmask --runtime desktop && systemctl start desktop`，再 `systemctl is-active desktop` 确认。

### 17.7 附录：脚本说明（源码在 `tools/chrome3/`，正文留档关键实现与踩坑）

**A. `export_cookies.lua` + `cookiecrypt.c`（本机跑，只读本机 profile，输出 Lua 表）**

原 python 版已删（要 `python3-gi` + ctypes + sqlite3 三套绑定）。现在是 lua+c 两件套，源码在仓库
`tools/chrome3/`，这里只留关键实现与踩坑：

分工：**SQLite 读表 / host 过滤 / Lua 表输出** 在 `export_cookies.lua`（LuaJIT FFI 直调 `libsqlite3`）；
**keyring 取密码 + PBKDF2 + AES-128-CBC** 在 `cookiecrypt.c`（本机只有 `libsecret-1.so.0`、没有开发头文件，
且遍历 SecretService→collections→items 要 GObject 变参 + GList，FFI 写不划算，手写原型比装 -dev 省事）。

```bash
# .so 缺失或比 .c 旧时脚本自建；链接要写 /lib/x86_64-linux-gnu/libsecret-1.so.0（没有 dev symlink）
cc -O2 -shared -fPIC -o libcookiecrypt.so cookiecrypt.c \
   /lib/x86_64-linux-gnu/libsecret-1.so.0 -lgobject-2.0 -lglib-2.0 -lcrypto
luajit export_cookies.lua ~/.config/google-chrome/Default /tmp/ytcookies.lua youtube,.google
```

四个必踩点：

1. **keyring 里可能有多把 `Chrome Safe Storage`**（换过 profile / 留了旧条目），遍历顺序不保证是你
   要的那把 —— 原 py 版按 label 取第一个，这次实测取到了旧 key（97 条全解失败）。现版本把匹配到的
   密码**全取出逐把试**，`cc_password_nth(labels, idx)`。
2. `PBKDF2-SHA1(pw, "saltysalt", 1, 16)`：Linux 迭代 **1**（macOS 才是 1003），IV 固定 16 个空格。
3. 新版 Chrome 明文 = `sha256(host_key) || 真值`，前 32 字节要剥，判据是**按 host 算出来的 hash 比对**，
   不是按长度硬砍。
4. `Cookies` 库运行时被锁 → 先 `cp` 快照到 `/tmp/host-cookies.db`；快照里是密文，但仍是登录态材料，跑完删。
   明文表同样用完即删（红线见 `tools/chrome3/README.md` §5）。

实测对齐：本机 3331 行，`youtube` 命中 97 条、`youtube,.google` 命中 227 条，**逐字段与旧 py 版输出完全一致**。

**B. `inject_yt.lua`（盒上跑，`/opt/reader/bin/luajit`；WS/CDP 库用 `cdplib.lua`）**

库文件 `cdplib.lua` = `tools/cdp/cdp_do.lua` 前 413 行的库部分 + 导出表，别重复造：
`lib.http_get_json_list()`、`lib.ws_open(path)`、`lib.jenc/jdec`。

```lua
-- inject_yt.lua —— 把 cookies 表逐条 Network.setCookie 注入当前 chromium，然后打开 youtube 验登录
--   用法: luajit inject_yt.lua /root/ytcookies.lua [9222] [url]
--   依赖同目录 cdplib.lua（= tools/cdp/cdp_do.lua 前 413 行的库部分 + 导出表）
arg = { [3] = select(2, ...) or "9222" }
local lib = dofile("/root/cdplib.lua")
local cookies = dofile(select(1, ...) or "/root/ytcookies.lua")
local url = select(3, ...) or "https://www.youtube.com/"

local status, body = lib.http_get_json_list()
if status ~= "200" then print("ERROR /json/list HTTP " .. tostring(status)); os.exit(1) end
local list = lib.jdec(body)
local target
for _, t in ipairs(list) do
  if t.type == "page" and t.webSocketDebuggerUrl then target = t break end
end
if not target then print("ERROR 没有 page 目标"); os.exit(1) end
print("[page] " .. tostring(target.url))
local wpath = target.webSocketDebuggerUrl:match("^ws://[^/]+(/.*)$")
local ws, werr = lib.ws_open(wpath)
if not ws then print("ERROR WS 握手失败 " .. tostring(werr)); os.exit(1) end

local id = 0
local function rpc(method, params)
  id = id + 1
  local myid = id
  ws.send_frame(lib.jenc({ id = myid, method = method, params = params or {} }))
  for _ = 1, 4000 do
    local f = ws.recv_frame()
    if not f then return nil end
    if f.op == 1 and #f.payload > 0 then
      local msg = lib.jdec(f.payload)
      if type(msg) == "table" and msg.id == myid then return msg end
    elseif f.op == 8 then return nil end
  end
end

rpc("Network.enable")
rpc("Page.enable")
local ok, fail, errs = 0, 0, {}
for i, c in ipairs(cookies) do
  local host = c.domain
  local params = {
    name = c.name, value = c.value, path = c.path or "/",
    secure = c.secure, httpOnly = c.httpOnly, sameSite = c.sameSite,
    expires = c.expires,
  }
  -- 带前导点的域必须用 domain；不带点的用 url 更稳
  if host:sub(1, 1) == "." then
    params.domain = host
  else
    params.url = "https://" .. host .. (c.path or "/")
  end
  local r = rpc("Network.setCookie", params)
  if r and r.result and r.result.success then ok = ok + 1
  else
    fail = fail + 1
    if #errs < 3 then errs[#errs + 1] = host .. ":" .. c.name .. " => " .. lib.jenc(r and (r.error or r.result) or {}) end
  end
end
print(string.format("[cookie] 注入成功 %d / 失败 %d", ok, fail))
```

**C. 播放验证的核心表达式**（`ytplay.lua` 里真正有用的就这两条）：

```lua
-- 真实 DOM 点击第一个视频（不要用 player API，YouTube 会判非用户操作）
(function(){var a=document.querySelector('a#thumbnail[href*="/watch"]')||
  document.querySelector('ytd-rich-item-renderer a[href*="/watch"]');
  if(!a)return 'no-link';var h=a.href;a.click();return h})()

-- 每秒轮询播放状态
(function(){var v=document.querySelector('video');if(!v)return 'no-video';
  return JSON.stringify({t:+v.currentTime.toFixed(2),ready:v.readyState,paused:v.paused,
    w:v.videoWidth,h:v.videoHeight,dur:Math.round(v.duration),
    q:v.getVideoPlaybackQuality().totalVideoFrames,
    drop:v.getVideoPlaybackQuality().droppedVideoFrames})})()
```

**D. 登录态判定表达式**（`inject_yt.lua` 60 行之后的部分，注入完 `Page.navigate` 再跑）：

```js
(function(){var b=document.querySelector('#avatar-btn');
  return JSON.stringify({title:document.title, href:location.href, avatar:!!b,
    signin_btn:!!document.querySelector('a[href*="ServiceLogin"]'),
    vids:document.querySelectorAll('ytd-rich-item-renderer, ytd-video-renderer').length,
    thumbs:document.querySelectorAll('img[src^="https://i.ytimg"]').length})})()
```
`avatar:true` + `signin_btn:false` 才是真登录；只看 cookie 注入数量会被"注入成功但已过期"骗。

## 18. 三站脚本合订本（YouTube / 微博 / Gmail）——`tools/chrome3/`

§12–§17 是逐站踩出来的，脚本散在盒上 `/root/`。三套 `*cage.sh` + `inject_*.lua` 有 90% 是重复，
差异只在 **profile 目录 / 代理开关 / 验登录 JS / 等待时长**。已合成三份参数化脚本，站点差异集中在
`inject.lua` 顶部一个 `SITES` 表里；文件与用法见 `tools/chrome3/README.md`。

| 站点 | key | profile | 代理 | 登录态判据 | warm |
|---|---|---|---|---|---|
| YouTube | `yt` | `/root/.config/chromium`（默认 profile） | `127.0.0.1:7890` | `#avatar-btn` 存在；`signin_btn` 不存在 | 3s |
| 微博 | `wb` | `/root/.config/chromium-wb` | 直连 | `window.$CONFIG.uid/nick` 非空 | 6s |
| Gmail | `gm` | `/root/.config/chromium-gm` | `127.0.0.1:7890` | `[gh="cm"]` 写邮件按钮 + 收件箱行数 | 12s |

四个文件：`export_cookies.lua`+`cookiecrypt.c`（本机，解 keyring cookie → Lua 表）、`cage.sh`（盒上，前台 exec）、
`startcage.sh`（盒上，后台 + 等 CDP ready + 修字号 + 光栅调优）、`inject.lua`（盒上，注入+导航+验登录，gm 顺带截图）。

```bash
~/.local/share/lite/third_party/luajit/src/luajit tools/chrome3/export_cookies.lua \
  ~/.config/google-chrome/Default /tmp/wb.lua weibo.com,weibo.cn
ssh x98h 'bash /root/startcage.sh wb && /opt/reader/bin/luajit /root/inject.lua wb'
```

**2026-11-27 合订后实测（123，2560x1440）**：

```
CDP ready after 2x0.5s
[page] about:blank
[微博][cookie] 注入成功 17 / 失败 0
[check] {"title":"微博 – 随时随地发现新鲜事","href":"https://weibo.com/","uid":2018236971,
         "nick":null,"login_nav":false,"name":"","signin_btn":false,"feeds":6}
```

`uid` 非空 + `feeds:6` → 登录态有效；`nick=null`/`login_nav:false` 是微博新版 DOM 改名导致的选择器过期
（只影响那个字段，不影响判据）。

两个必须记住的细节：
1. **盒上没有 `luajit` 在 PATH**，要写全 `/opt/reader/bin/luajit`（§17 的老坑）。
2. **CDP 端口由 `cdplib.lua` 加载时的全局 `arg[3]` 决定**，所以 `inject.lua` 在 `dofile("/root/cdplib.lua")`
   **之前**先 `arg = { [3] = port }`，否则第 4 个参数（端口）静默失效。
