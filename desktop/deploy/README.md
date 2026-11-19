# desktop 常驻兜底（盒端 systemd 现场文件）

盒子上桌面是「底座」：谁都可能临时用屏（迁移脚本、阅读器、播放器、测试程序），
用完就该还回来。`Restart=always` 只管进程崩，管不到下面三种黑屏：

1. 有人 `systemctl stop desktop` 过 —— systemd 认为这是显式意图，不会自己起来；
2. `StartLimit` 打满后服务变 `failed`，之后再也不重启；
3. 迁移脚本 stop 了桌面，自己却被 Ctrl-C / 报错打断。

所以加一层 timer 每 10s 纠正一次，外加一份 drop-in 把启动超时放宽。

## 文件与落点

| 仓库文件 | 盒子落点 |
| --- | --- |
| `desktop-resident.conf` | `/etc/systemd/system/desktop.service.d/resident.conf` |
| `desktop-heal.sh` | `/usr/local/sbin/desktop-heal.sh`（`chmod +x`） |
| `desktop-heal.units` | 拆成 `/etc/systemd/system/desktop-heal.{service,timer}` |

装完 `systemctl daemon-reload && systemctl enable --now desktop-heal.timer`。

## resident.conf 为什么这么写

- `Restart=always` + `RestartSec=2`：崩了 2s 内回来。
- `StartLimitIntervalSec=0`：HDMI 重新锁信号、NAS 暂时不在这类情形会连续失败几次，
  不能让 5 次/10s 的上限把服务永久打成 `failed`。
- `TimeoutStartSec=150`：原来继承默认 10s，而 `ExecStartPre=/usr/local/bin/wait-nas 40`
  要等 40s —— NAS 不在时第 10 秒就被 systemd 砍掉，永远走不到 `wait-nas` 自己放行。

## desktop-heal.sh 的让路约定

- `touch /run/desktop-hold`：**heal 完全不插手**。做迁移、手工接管、跑全屏测试时，
  stop 之前 touch，用完 rm。成对使用，忘了 rm 就再也拉不起来。
- KMS（`/dev/dri/card*`、`render*`）被别的程序占着时先不动 —— 那通常说明有人正在用屏。
  只有 PPID=1 且持续超过 `ORPH_GRACE`（默认 90s）才当孤儿 `kill -9`，
  避免把正常播放/测试打断。`kmshold` 的常驻 `sleep` fd 在扫描里已白名单跳过。
- 状态自己也在保护自己：`active|activating|reloading|deactivating` 一律不插手。

日志：`/var/log/desktop-heal.log`（每次插手一行，含原因和孤儿杀灭记录）。

## 验证过

- `kill -9` 主进程 → 2s 自动重启（restart counter 递增）；
- 手动 `systemctl stop desktop` → 第 8s 被 heal 拉起；
- `touch /run/desktop-hold` 后 stop → 14s 仍 `inactive`；`rm` 掉 hold → 8s 恢复；
- `systemctl show desktop -p TimeoutStartUSec` → `2min 30s`。
