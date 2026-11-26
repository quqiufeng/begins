# 浏览器直出（cog / WPE WebKit）部署与调试全流程

> 目标：把浏览器做成**第四种直出 app**，和桌面、阅读器、播放器一样——
> 谁要显示谁独占 DRM master，`systemctl stop desktop` 交棒，全屏 URL 直出 HDMI，
> 2.4G 遥控器能操作网页。
>
> 当前状态：**x98h(123) 两条路线都已跑通**——
> ① `cog -P drm`（47 包，独占直出，静态页/中文/canvas/视频均可，**动态重绘 3–5s 崩，未修**，第 7 节）；
> ② `cage + chromium + CDP`（74 包，动态页稳定、可注入任意 JS、登录态跨重启持久，**日常用这条**，第 11–12 节）。
> **x96(121) 未部署**（只确认了 apt 有包，见第 8 节）。
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
- 虚拟键盘设备名 `vkeybd-browser`（`/tmp/vkeyd.lua` 实验用；正式应做成 `apps/browser.lua` + `keys/browser.lua`，**尚未做**）。

键码表（uinput `KEY_*`）：

```
up=103 down=108 left=105 right=106 ok=352 enter=28 esc=1
home=172 back=158 menu=139 volup=115 voldn=114
```

---

## 5. 中文字体：必须硬链接进 fonts 目录

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

**页面一旦重绘，cog 3–5s 内 SIGSEGV。**

```
Buffer address requested when its parent pool has an external reference and a deferred resize pending.
    ← libwayland-server.so.0.23.1
```

- 触发条件：页面自己定时重绘（哪怕零按键注入），如每 500ms 自更新一次。
- 静态页（`example.com`、静态图文 `key.html`）**不崩**。
- 试过无效：`LIBGL_ALWAYS_SOFTWARE=1`、`WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`（同样崩）。
- `renderer=modeset` 硬件 GL 路径不崩，但 fb 创建 EINVAL（第 2 节）。
- **按键注入与崩溃无关**（已证明注入链可用）。

**修的方向**：合成 buffer / deferred resize 路径（cog 的 drm 平台在 pool resize 期间
不应对 parent pool 持有外部引用；要么在 resize 前释放，要么改用不 hold reference 的 wl_buffer 创建方式）。
这是下一步要做的事。

性能参考（123）：纯 CSS/rAF 页 GPU 16.07fps / CPU 8.68→29.7fps；
视频软解 720p 仅约 0.8fps（瓶颈在 Skia 光栅与合成，不在解码）。

`cog` 退出时的 `Segmentation fault` + `No provider of eglReleaseThread found` 是**收尾噪音**，不影响出图。

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

### 8.2 x96（121）：部署步骤

121 目前状态（已核实）：`/usr/bin/cog` **未安装**；apt 有 `cog 0.18.4-1+b1`（阿里云 trixie/main）；
`/dev/dri/{card0,card1,renderD128}` 齐；`/root/grabscreen-aarch64` 在；`keybd` active；
**`/usr/share/fonts/truetype/tsanger/` 不存在**（字体没按 123 的方式装）。
121 是 Amlogic（meson + panfrost），不是 123 的 sun4i，AFBC 行为可能不同。

按顺序做：

```bash
# 1) 装包
ssh x96 'apt-get install -y --no-install-recommends cog'

# 2) 字体：照第 5 节做硬链接 + 99-tsanger-zh.conf（121 现在没有，必须先补，否则中文方块）
ssh x96 'ls /usr/local/share/fonts/'          # 先找到 TsangerJinKai02 的实际路径
#    然后 mkdir + ln -f + conf + fc-cache -f

# 3) 发脚本（deploy.sh 会自动跳过——它检测到没有 cog 就不推；装完 cog 再发就有）
BOX=x96 ./deploy.sh -D -K
ssh x96 'ls -l /root/cog/'

# 4) 先试 gles（安全选择，和 123 一致）
ssh x96 '/root/cog/box-cog.sh start https://example.com'
ssh x96 '/root/cog/box-cog.sh shot /tmp/x.raw'
#    抓回来转 png 看图（8.1 的 ffmpeg 命令，注意分辨率可能不是 2560x1440，先确认 TV 模式）

# 5) 若 121 上 modeset（默认）也能出图，则可以省掉一次 blit，值得单独试一次：
#    ssh x96 'COG_PLATFORM_PARAMS= cog -P drm <url>'   （即不加 renderer=gles）
#    若报 failed to create framebuffer: Invalid argument → 回到 gles。

# 6) 视频：加 GST_PLUGIN_FEATURE_RANK=v4l2slh264dec:0,v4l2slh265dec:0
#    121 是 meson_vdec，硬解协商失败的表现需在机上确认，先按 123 的结论保守处理。

# 7) 收尾
ssh x96 '/root/cog/box-cog.sh stop'   # 必须执行，否则 desktop 一直被 mask，屏幕一直停在 cog 最后一帧
```

121 特有的注意点：
- `box-cog.sh` 里 `GRAB=/root/grabscreen-aarch64`、`card0` —— 121 上都在，无需改。
- 两个盒子的 `keybd` 配置逐字节相同（`config.lua` / `evdev.lua` / `maps/+keys` md5 一致），
  所以遥控器→uinput 那段在 121 上**不用改**，插上接收器 keybd 自动 grab。
  121 的服务名是 `keybd.service`（123 是 `keybd`，无所谓，`systemctl is-active` 都认）。

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
| `/usr/share/fonts/truetype/tsanger/` | 仓耳今楷硬链接 + `99-tsanger-zh.conf` |
| `/root/grabscreen-aarch64`（盒子） | 抓 DRM 帧（2560x1440 → 14745600 B BGRA） |

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

### 13.4 测量脚本（都在 123 的 `/tmp/`，可重跑）

- `/tmp/prof.sh <标签> [秒]`：按进程归集 CPU + renderer/GPU 热点线程 + 页面 fps + PSS 内存。
- `/tmp/sc2.sh`：`EXTRA="--flags" PAGE=bench.html` 起指定参数的 cage，便于 A/B。
- `/tmp/bench.html`（canvas 重绘压测）、`/tmp/bench2.html`（blur/阴影压测）、
  `/tmp/vid.html`（`requestVideoFrameCallback` 数真实解码帧）。
- 页面 fps 用 `window.__t0`/`__stats.f` 自算；**注意 rAF 计数是 BeginFrame 节流后的结果**，
  负载高时它才反映真实吞吐（低负载页面 rAF 会恒为 ~60，不能当成"上屏 60 帧"）。

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
