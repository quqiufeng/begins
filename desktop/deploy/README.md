# 常驻兜底（盒端 systemd 现场文件）

盒子上有两个「底座」服务，都必须常驻：

- **desktop** —— 屏幕底座，唯一占 KMS 的进程；
- **keybd** —— 遥控/键盘派发底座，`GRAB=1` 独占 `event*`。它躺了的表现不是黑屏，
  而是**屏幕好好的但遥控一点反应都没有**（按键日志里全是 `focus=reader[...]` 之类的
  错派发，或者干脆没有 press）。

`Restart=always` 只管进程崩，管不到下面三种：

1. 有人 `systemctl stop` 过 —— systemd 认为这是显式意图，不会自己起来；
2. `StartLimit` 打满后服务变 `failed`，之后再也不重启；
3. 迁移脚本 stop 了桌面，自己却被 Ctrl-C / 报错打断。

所以加一层 timer 每 10s 纠正一次，外加两份 drop-in 把启动限制/超时放宽。

## 文件与落点

| 仓库文件 | 盒子落点 |
| --- | --- |
| `desktop-resident.conf` | `/etc/systemd/system/desktop.service.d/resident.conf` |
| `keybd-resident.conf` | `/etc/systemd/system/keybd.service.d/resident.conf` |
| `resident-heal.sh` | `/usr/local/sbin/resident-heal.sh`（`chmod +x`） |
| `resident-heal.units` | 拆成 `/etc/systemd/system/resident-heal.{service,timer}` |

装完 `systemctl daemon-reload && systemctl enable --now resident-heal.timer`。
（旧名 `desktop-heal.{sh,service,timer}` 已废弃，装新的时先 `disable --now` 再删。）

## drop-in 为什么这么写

桌面（`desktop-resident.conf`）：

- `Restart=always` + `RestartSec=2`：崩了 2s 内回来。
- `StartLimitIntervalSec=0`：HDMI 重新锁信号、NAS 暂时不在这类情形会连续失败几次，
  不能让 5 次/10s 的上限把服务永久打成 `failed`。
- `TimeoutStartSec=150`：原来继承默认 10s，而 `ExecStartPre=/usr/local/bin/wait-nas 40`
  要等 40s —— NAS 不在时第 10 秒就被 systemd 砍掉，永远走不到 `wait-nas` 自己放行。

遥控（`keybd-resident.conf`）：

- `StartLimitIntervalSec=0`：遥控器反复重连/学码失败不能把它永久打成 `failed`。
- `TimeoutStopSec=20`：它握着一批 `event*` 的独占 fd，停的时候要来得及
  `EVIOCGRAB(0)` 放掉，否则下一任（含重启后的自己）收不到键。

## resident-heal.sh 的让路约定

用法 `resident-heal.sh [服务名...]`，缺省 `desktop keybd`。

- `touch /run/desktop-hold`：**屏幕相关部分完全不插手**。做迁移、手工接管、
  跑全屏测试时，stop 之前 touch，用完 rm。成对使用，忘了 rm 就再也拉不起来。
  keybd 不受它影响 —— 它不占屏，停了遥控就废了。
- `touch /run/keybd-hold`：手工学码/改键位时用，heal 不碰 keybd。
- KMS（`/dev/dri/card*`、`render*`）被别的程序占着时先不动 —— 那通常说明有人正在用屏。
  只有 PPID=1 且持续超过 `ORPH_GRACE`（默认 90s）才当孤儿 `kill -9`，
  避免把正常播放/测试打断。`kmshold` 的常驻 `sleep` fd 在扫描里已白名单跳过。
- 状态自己也在保护自己：`active|activating|reloading|deactivating` 一律不插手。

日志：`/var/log/resident-heal.log`（每次插手一行，含原因和孤儿杀灭记录）。

## 验证过（2026-11-19）

keybd：

- `systemctl stop keybd` → 7s 被 heal 拉起（Restart=always 管不到 stop，说明 heal 生效）；
- `kill -9` 主进程 → 3s 新 PID；
- 重启后 `GRAB` 恢复（5 个 `event*` fd），`ctl state` 认得 `focus=desktop`；
- `touch /run/keybd-hold` + stop → 13s 仍 `inactive`；`rm` 后 11s 恢复；
- `StartLimitIntervalUSec=0`、`TimeoutStartUSec=20s`、`TimeoutStopUSec=20s`。

桌面（沿用上一轮）：

- `kill -9` 主进程 → 2s 自动重启；
- 手动 `systemctl stop desktop` → 第 8s 被 heal 拉起；
- `touch /run/desktop-hold` 后 stop → 14s 仍 `inactive`；`rm` 后 8s 恢复。

## 还没管的

`keybd` 的「活着但派发错」：app 崩了留孤儿（PPID=1）但 socket 还在 `ping` 得通，
`detect()` 会把它当成前台，遥控全被吞掉。目前靠人 `kill -9` 孤儿解决。
根治要给 `apps/*.lua` 的 `detect()` 加一条：PPID=1 或 `state` 超时就降级/跳过。

## 桌面本体 + 浏览器（2026-11-27 补齐的落点表）

仓库里 `desktop/` 与 `keybord/` 是**盒上现场文件的完整副本**，不是节选。改动前先在这里
`scp x98h:/opt/desktop/<f> .` 拉一遍，避免用旧版盖掉盒上的修复（`main.lua` 的
`local toast` 前向声明和 `ev.key.sym`、`core/hotplug.lua` 的 `opendir/readdir` 取法，
盖错会分别导致「首页图标刷不出来」和「U 盘永远扫不到」）。

| 仓库文件 | 盒子落点 |
| --- | --- |
| `desktop/*.lua`、`desktop/core/`、`desktop/ui/`、`desktop/ffi/`、`desktop/tools/` | `/opt/desktop/` 同名 |
| `desktop/assets/icons/*.png` | `/opt/desktop/assets/icons/`（`browser` 256、`wechat` 512、`usb`/`host`/`nas` 256） |
| `desktop/assets/browser-home.html` | `/root/browser-home.html`（浏览器首页卡片，配置里是绝对路径 `file:///root/browser-home.html`） |
| `desktop/tools/cdp.py` | `/root/cdp.py`（调 9222 的 CDP 小工具；页面线程卡死时 `Runtime.evaluate` 会超时，判活先看 `curl 127.0.0.1:9222/json/list`） |
| `desktop/deploy/desktop.service` | `/etc/systemd/system/desktop.service`（含 `XDG_RUNTIME_DIR=/run/user/0`、`LIBSEAT_BACKEND=seatd`，cage/sway 缺前者立即 exit 1） |
| `desktop/wechat.conf` | `/opt/desktop/wechat.conf`（微信专用 **sway** 配置：**不写死 `mode`**，用 output 的 preferred（123=2560x1440 / 121=3840x2160）+ 壁纸 `bg … fill` + 全窗口 floating + `exec wx-center.py` + 微信退出即 `swaymsg exit`） |
| `desktop/bin/wx-center.py` | `/opt/desktop/bin/wx-center.py`（`chmod +x`；等 `sway-ipc` socket，`swaymsg` 把微信 resize 1280×720 并居中。只用 python3 标准库） |
| `desktop/assets/wallpaper.png` | `/opt/desktop/assets/wallpaper.png`（swaybg 的背景图，6.0MB。**主机**上用 `desktop/tools/bgra2png.py` 从同目录 `wallpaper.bgra` 转，盒上没 PIL） |
| `keybord/*.lua`、`keybord/apps/`、`keybord/keys/`、`keybord/maps/` | `/opt/keybord/` 同名 |

`keybord/apps/browser.lua`（order=25）是浏览器前台时的按键表：方向/ENTER 走 uinput 直通，
`BACK/ESC` 不在首页时合成 `KEY_BACK(158)` 让 chromium 后退、已在首页时收浏览器并
`systemctl restart desktop`，`MENU/C-3/STOP/EXIT` 直接退出。

部署后校验（都别靠肉眼看屏幕）：

```sh
systemctl restart desktop && sleep 3
ls -l /proc/$(systemctl show -p MainPID --value desktop)/fd | grep dri   # 有 /dev/dri/card0
curl -s --max-time 4 127.0.0.1:9222/json/list | grep title               # 浏览器活着才通
```

## 微信的合成器依赖（sway，2026-11-27 起）

微信不属于模式 A（自己拿 master），它要在合成器里跑，所以**盒上必须装合成器包**：

```bash
apt-get install -y -q sway
# 实装：sway 1.10.1-2、swaybg 1.2.1-1+b1 (automatic)、libjson-c5 (automatic) —— 只多 3 个包
# 复用已有：libwlroots-0.18 0.18.2-3、seatd 0.9.1-1（须 active）、dbus-daemon→dbus-run-session、python3
# 用不上：xwayland（配置里 xwayland disable，它是装 cage 时被拽上来的）
```

`desktop/config.lua` 的判断是 `exists("/opt/wechat/wechat") and exists("/usr/bin/sway")`：
**有 sway 走 sway，没有就静默回退 `cage` 老路径**（不报错、不提示，只是窗口又贴回左上角、没有壁纸）。
所以「微信窗口居中 + 壁纸」这套失效时，第一件事是查 `which sway` 与 `dpkg -l sway`。

装完必须确认三件事，缺一个 sway 起不来（微信黑屏/直接掉回桌面）：

```bash
apt-get install -y -q sway
systemctl is-active seatd || systemctl start seatd     # enabled ≠ active！装完且 enabled 也可能没跑
systemctl is-enabled seatd                              # 要 enabled，否则重启后又没了
systemctl show -p Environment desktop | tr ' ' '\n' | grep -E 'XDG_RUNTIME_DIR|LIBSEAT_BACKEND'
```

- `seatd` 没跑 → sway 拿不到 DRM master，日志里 `wl_display` 直接失败；
- 缺 `XDG_RUNTIME_DIR=/run/user/0` → sway/libseat 立刻退（`desktop.service` 里已带，改完记得 `daemon-reload`）；
- 121（电视 3840x2160）上位的就是这条：seatd 装了但没 active，只报 `sway: cannot open display` 之类，`desktop.log` 里微信那条 `stopped:user`。修完 `wx-center.py` 按 4K 算中心 `1280,720`，和 123 的 `640,360` 是同一套数学。

回退：`apt-get remove --purge sway swaybg`，`cage 0.2.0-2` 仍在机器上，配置不用动。
完整包清单/落点/坑见 `../../chrome.md` §16.3.1。
