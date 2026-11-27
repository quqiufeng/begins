# chrome3 —— 六站（YouTube / 微博 / 知乎 / Gmail / 抖音 / Jable）直出脚本的合订本

原来各站各有一套 `*cage.sh` + `inject_*.lua`，内容 90% 相同，只差 profile 目录、代理开关、验登录 JS。
这里合成三份参数化脚本，站点差异集中在一个表里。**盒上实跑记录见 `chrome.md` §11–§17。**

## 1. 站点参数表（唯一真相）

| 站点 | key | profile 目录 | 代理 | 登录态判据 | warm | 截图 |
|---|---|---|---|---|---|---|
| YouTube | `yt` | `/root/.config/chromium` | `127.0.0.1:7890` | `#avatar-btn` 存在 = 已登录；`signin_btn` 存在 = 未登录 | 3s | 否 |
| 微博 | `wb` | `/root/.config/chromium-wb` | 直连（国内） | `window.$CONFIG.uid/nick` 非空 | 6s | 否 |
| 知乎 | `zh` | `/root/.config/chromium-zh` | 直连（国内） | `document.cookie` 里有 `z_c0` + `.AppHeader-profile` 存在 = 已登录；出现 `.yidun_*` = 点选验证码 | 5s | 否 |
| Gmail | `gm` | `/root/.config/chromium-gm` | `127.0.0.1:7890` | `[gh="cm"]` 写邮件按钮 + 收件箱行数 | 12s | 是 |
| 抖音 | `dy` | `/root/.config/chromium-dy` | 直连（国内） | 头像 `avatar` 出现 = 已登录（`im_entry` 偶发不稳，别单看它） | 长（ARM 冷刷新约 77s 才渲染头像） | 是 |
| Jable | `jb` | `/root/.config/chromium-jb` | `127.0.0.1:7890` | `document.cookie` 有 `kt_member` + 视频条目 `vids` > 0 = 会员已登录；出现 captcha 即失败 | 6s | 是 |

注意 `yt` 用的是**默认 profile**（历史原因，登录态在那），没有单独的 `chromium-yt`。

## 2. 文件清单（本机 2 个 + 盒上 5 个）

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `export_cookies.lua` + `cookiecrypt.c`（+ 自建 `libcookiecrypt.so`） | **本机** | 解本机 Chrome/Chromium 的 cookie（keyring + AES-128-CBC）→ Lua 表。LuaJIT FFI 直读 SQLite，C 补件做 keyring + 解密 |
| `cage.sh` | 盒上 | 独占 DRM 起 cage+chromium，前台 exec，日志 `/tmp/cage.log` |
| `startcage.sh` | 盒上（实体在仓库 `tools/cog/startcage.sh`，`deploy.sh` 推到 `/root/cog/`，`/root/startcage.sh` 是转发壳） | 同上但后台 + 等 CDP ready + 修默认字号 + 光栅调优 |
| `inject.lua` | 盒上 | 注入 cookie → 导航 → 等渲染 → 打印验登录 JSON（gm/dy/jb 顺带截图） |
| `browser-nav.js` + `navinject.lua` | 盒上 | 遥控方向键选链接（见 §3.5） |
| `browser.lua` | 盒上 `/opt/keybord/apps/`，仓库同一份 `keybord/apps/browser.lua`（只在 `keybord/` 留一份，别在 `tools/` 再放副本） | keybd 的 browser app：返回语义（见 §3.5） |

依赖盒上已有的 `/root/cdplib.lua`（WebSocket/CDP 零依赖库，源自 `tools/cdp/cdp_do.lua`）。

## 3. 典型一轮（以微博为例）

```bash
# 本机：导出该站 cookie 成 Lua 表（hosts 是子串过滤，逗号分隔）
#   .so 缺失或比 .c 旧时会自动编译，需要 libsecret-1.so.0 / libsqlite3 / libcrypto
LJ=~/.local/share/lite/third_party/luajit/src/luajit   # 本机没有 luajit 在 PATH
$LJ tools/chrome3/export_cookies.lua ~/.config/google-chrome/Default /tmp/wb.lua weibo.com,sina.com.cn
#   知乎：hosts 用 zhihu.com,zhimg.com
scp /tmp/wb.lua x98h:/root/wbcookies.lua        # 或走 base64 推送
scp tools/chrome3/{cage.sh,inject.lua} x98h:/root/
scp tools/cog/startcage.sh x98h:/root/cog/   # 启动脚本实体在 cog/，或直接跑 hevcdec/deploy.sh

# 盒上：起浏览器（后者等 CDP ready 再返回）
ssh x98h 'bash /root/startcage.sh wb'
#   一个终端常驻跑前台版也可以： ssh x98h 'bash /root/cage.sh wb'

# 盒上：注入 + 验登录          inject.lua <站> [cookies.lua] [url] [port]
ssh x98h 'luajit /root/inject.lua wb'
#   默认值都来自站点表；要临时改： luajit inject.lua wb /root/other.lua https://m.weibo.cn/
```

YouTube 换看视频：`luajit /root/inject.lua yt` 之后跑 `ytplay.lua`（§17.4，走真实 DOM 点击，不伪造 player API）。

## 3.5 遥控导航（盒上闲时那条路：桌面「浏览器」卡片）

电视上没人用鼠标，所以有三个部件配合：

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `browser-nav.js` | 页面内（CDP 注入） | 方向键按几何距离选「最近的链接/按钮」并加黄框；OK 真点它（`A.click()` 不生效时兜底 `location.href`）；其他键不拦。首页 `browser-home.html` 与 `chrome://` 内建页直接 return，不抢键。页头/导航条（`header`/`nav`/`[role=banner]`/`.site-header`/贴顶 fixed-sticky 横条）整排不参与选点，面积 ≥0.8% 视口的大块内容优先（小元素得分 ×1.8 让路但不禁用），首次落点优先视口内最靠左上的大块 |
| `navinject.lua` | 盒上常驻 | 每 2s 扫 CDP `/json/list`，对新 page 目标下 `Page.addScriptToEvaluateOnNewDocument` + 立刻 `Runtime.evaluate` 一次，SPA 跳转后仍生效；单实例靠 `/run/navinject.pid`，日志 `/tmp/navinject.log` |
| `naveval.lua` | 盒上调 `luajit naveval.lua <js文件> [9222]` | 调试口：CDP `Runtime.evaluate` 在当前 page 里跑一段 JS 并打印返回值（查 `__navState()`/`__liteNav` 用，不用截图） |
| `browser.lua` | `/opt/keybord/apps/browser.lua` | keybd 的 browser app：`BACK` 不在首页时合成 `KEY_BACK(158)` 交给 chromium 走历史；**在首页则收掉 chromium/cage 并 `systemctl restart desktop`** |

配套的关键修复在 `keybord/keybd.lua`：浏览器前台时 `BACK`/`ESC` **不直通**（否则页面先自己退一步，
`browser.lua` 随后读到的 url 已是首页 → 误判在首页 → 一次 BACK 直接退进程），且 key-up（`val==0`）
不派发动作（否则一次按键的动作跑两遍：BACK 退两格、OK 开两次）。

实测一轮（jable.tv）：主页方向键 1→2→3→6 选卡 → OK 进站 → 站内 RIGHT/DOWN/RIGHT 选中
`家政婦`/`便利店`/`監獄` → OK 进 `/tags/prison/` → BACK 回 jable 首页 → BACK 回 `browser-home.html`
→ BACK 收进程回桌面（chromium/cage 归零，`desktop` 仍 active）。

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

## 6. 站点之外的一条备用路线：直接写 Cookies 库

`tmp/ckfill.py`（历史脚本，未纳入本目录）：把本机明文 cookie **加密回写**盒上 chromium 的
`Cookies` SQLite（`peanuts`/`saltysalt` 派生 key，`v10` AES-128-CBC），不用 CDP 注入。
好处是不依赖 9222、可离线预置登录态；坏处要停机改库（chromium 运行时会覆写）。
日常用 CDP 注入（`inject.lua`）就够了，这条留作浏览器起不来时的后手。
