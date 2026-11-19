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
