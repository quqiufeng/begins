# chrome3 —— 三个网站（YouTube / 微博 / Gmail）直出脚本的合订本

原来三个站各有一套 `*cage.sh` + `inject_*.lua`，内容 90% 相同，只差 profile 目录、代理开关、验登录 JS。
这里合成三份参数化脚本，站点差异集中在一个表里。**盒上实跑记录见 `chrome.md` §11–§17。**

## 1. 站点参数表（唯一真相）

| 站点 | key | profile 目录 | 代理 | 登录态判据 | warm | 截图 |
|---|---|---|---|---|---|---|
| YouTube | `yt` | `/root/.config/chromium` | `127.0.0.1:7890` | `#avatar-btn` 存在 = 已登录；`signin_btn` 存在 = 未登录 | 3s | 否 |
| 微博 | `wb` | `/root/.config/chromium-wb` | 直连（国内） | `window.$CONFIG.uid/nick` 非空 | 6s | 否 |
| Gmail | `gm` | `/root/.config/chromium-gm` | `127.0.0.1:7890` | `[gh="cm"]` 写邮件按钮 + 收件箱行数 | 12s | 是 |

注意 `yt` 用的是**默认 profile**（历史原因，登录态在那），没有单独的 `chromium-yt`。

## 2. 文件清单（本机 2 个 + 盒上 3 个）

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `export_cookies.lua` + `cookiecrypt.c`（+ 自建 `libcookiecrypt.so`） | **本机** | 解本机 Chrome/Chromium 的 cookie（keyring + AES-128-CBC）→ Lua 表。LuaJIT FFI 直读 SQLite，C 补件做 keyring + 解密 |
| `cage.sh` | 盒上 | 独占 DRM 起 cage+chromium，前台 exec，日志 `/tmp/cage.log` |
| `startcage.sh` | 盒上 | 同上但后台 + 等 CDP ready + 修默认字号 + 光栅调优 |
| `inject.lua` | 盒上 | 注入 cookie → 导航 → 等渲染 → 打印验登录 JSON（gm 顺带截图） |

依赖盒上已有的 `/root/cdplib.lua`（WebSocket/CDP 零依赖库，源自 `tools/cdp/cdp_do.lua`）。

## 3. 典型一轮（以微博为例）

```bash
# 本机：导出该站 cookie 成 Lua 表（hosts 是子串过滤，逗号分隔）
#   .so 缺失或比 .c 旧时会自动编译，需要 libsecret-1.so.0 / libsqlite3 / libcrypto
LJ=~/.local/share/lite/third_party/luajit/src/luajit   # 本机没有 luajit 在 PATH
$LJ tools/chrome3/export_cookies.lua ~/.config/google-chrome/Default /tmp/wb.lua weibo.com,sina.com.cn
scp /tmp/wb.lua x98h:/root/wbcookies.lua        # 或走 base64 推送
scp tools/chrome3/{cage.sh,startcage.sh,inject.lua} x98h:/root/

# 盒上：起浏览器（后者等 CDP ready 再返回）
ssh x98h 'bash /root/startcage.sh wb'
#   一个终端常驻跑前台版也可以： ssh x98h 'bash /root/cage.sh wb'

# 盒上：注入 + 验登录          inject.lua <站> [cookies.lua] [url] [port]
ssh x98h 'luajit /root/inject.lua wb'
#   默认值都来自站点表；要临时改： luajit inject.lua wb /root/other.lua https://m.weibo.cn/
```

YouTube 换看视频：`luajit /root/inject.lua yt` 之后跑 `ytplay.lua`（§17.4，走真实 DOM 点击，不伪造 player API）。

## 4. 收尾必做：还原桌面

cage 抢 DRM master，`desktop` 被 `mask --runtime` 停掉，不还原屏幕就卡在最后一帧：

```bash
pkill -x chromium; pkill -x cage
systemctl unmask --runtime desktop && systemctl start desktop
systemctl is-active desktop          # 必须 active
```

## 5. 红线

- `export_cookies.lua` 会把 `Cookies` 快照到 `/tmp/host-cookies.db`（内含加密 cookie），跑完顺手删。
- **cookie 明文 Lua 表用完就删**（含 `SID`/`HSID`/`SAPISID`，等价密码），不进仓库、不留 `/tmp`。
- 代理只在本机 `127.0.0.1:7890`（mihomo）；盒上别改成外部 IP。
- 起之前必须 `mask --runtime desktop`，否则 DRM master 抢不到，cage 起不来。
- 别用 `renderer=modeset`（cog 路线）——sun4i 只认 LINEAR，`fb create EINVAL`；chromium 走 wayland 没这问题。

## 6. 三站之外的一条备用路线：直接写 Cookies 库

`tmp/ckfill.py`（历史脚本，未纳入本目录）：把本机明文 cookie **加密回写**盒上 chromium 的
`Cookies` SQLite（`peanuts`/`saltysalt` 派生 key，`v10` AES-128-CBC），不用 CDP 注入。
好处是不依赖 9222、可离线预置登录态；坏处要停机改库（chromium 运行时会覆写）。
日常用 CDP 注入（`inject.lua`）就够了，这条留作浏览器起不来时的后手。
