# reader — 123 上阅读器的代码备份

从盒子 `x98h`（192.168.1.123，Armbian trixie / aarch64）的 `/opt/reader` 拉回的**源代码**备份。
拉取日期 2026-11-27，拉取时未改动盒上任何文件。

实测规模：**60 个文件 / 444 KB / 53 个 `.lua`**；51 个可执行脚本逐个 `md5sum` 与盒上比对**全部一致**。

## 目录

| 路径 | 内容 | lua 数 |
| --- | --- | --- |
| `lua/ui/` | 界面主战场：`app.lua`(28 K)、`remote.lua`(16 K)、`reader.lua`、`input.lua`、`render.lua`、`bookshelf.lua`、`bookmarks.lua`、`epub.lua`、`page_md.lua`、`toc.lua`、`themes.lua`、`settings.lua`、`nav.lua`、`chrome.lua`、`window.lua` 等 | 32 |
| `lua/core/` | `library.lua`、`clock.lua`、`automation.lua` | 3 |
| `lua/ffi/` | `sdl2.lua`、`sdl2_ttf.lua`、`reader.lua`、`ocr.lua` | 4 |
| `automation/` | 自动化驱动：`xdo.lua`、`x11.lua`、`agent.lua`、`reader.lua`、`autoturn.lua`、`native_demo.lua`、`agent_demo.lua` | 7 |
| `tools/` | `agent_reader.lua` + `reader-agent`（sh 包装，838 B） | 1 |
| `lib/` | 仅 `sdltest.lua`（5.2 K） | 1 |
| 根目录 | `box-remote.lua`(9 K，遥控器自动化入口)、`remote-map.lua` | 2 |
| 根目录 sh | `box-launch.sh`、`box-display.sh`、`box-autoturn.sh`、`box-remote-learn.sh` | — |
| `testdata/` | `sample.txt`（187 B） | — |
| `.local/share/native-reader/` | **运行时状态**（不是代码）：`window.lua` = `{w=2560,h=1440,x=62,y=-216,max=0,full=1}`、`settings.lua` = `{theme="light",font_size=22,line_factor=1.6,margin=72}`、`state.lua`、`window.lua.bak-1119-0824` | 3 |

## 没备份的（大件/二进制，可重装）

| 盒上路径 | 大小 | 说明 |
| --- | --- | --- |
| `/opt/reader/assets/` | 37 M | `fonts/`、`icons/` 字体与图标资源 |
| `/opt/reader/build/` | 74 M | 构建中间件 |
| `/opt/reader/bin/luajit` | 591,960 B | **盒上 luajit 不在 PATH**，脚本里一律用 `/opt/reader/bin/luajit` |
| `/opt/reader/lib/luajit` | 591,960 B | 同上 |
| `/opt/reader/lib/libluajit.so` | 593,464 B | 共享库 |

## 部署回盒子

盒上改文件走 base64（盒上没装 rsync/scp 服务端配置不折腾，`ssh` 免密已通）：

```bash
B64=$(base64 -w0 lua/ui/app.lua)
ssh x98h "echo $B64 | base64 -d > /opt/reader/lua/ui/app.lua"
```

整棵回灌（谨慎，会覆盖盒上的运行时状态，先备份 `.local/`）：

```bash
tar -czf - lua automation tools lib/sdltest.lua *.lua *.sh | ssh x98h 'tar -xzf - -C /opt/reader'
```

运行：`ssh x98h '/opt/reader/bin/luajit /opt/reader/lua/ui/app.lua'`；
盒上无 `/usr/bin/time`、`v4l2-ctl`、`grim`，抓屏用 `/root/grabplane-aarch64` 或 `ffmpeg -f kmsgrab`。

## 这份备份为什么重要：它是盒上分叉，不是上游

reader 的来历是**两段**，不是「盒上直接改」：

1. 上游在**本机** `~/Desktop/reader`（独立 git 仓，HEAD `9ef3cf8` feat(remote): 新增 app.back），
   在那里交叉编译 aarch64 的 luajit + MuPDF + SDL2，`--prefix=/opt/reader` 装到盒子。
2. 装好之后，**为了适配遥控器**，直接改盒子上的 lua 脚本 —— 改动没有回流到上游。

所以盒上的 `/opt/reader` 和 `~/Desktop/reader` 是**一份分叉**，实测差异（2026-11-27）：

| 差异 | 内容 |
| --- | --- |
| `lua/ui/remote.lua` **不同** | 44 行差异，全是遥控器适配（见下） |
| 盒上**独有 7 个文件** | `box-remote.lua`(9050 B)、`remote-map.lua`(924 B)、`box-launch.sh`、`box-display.sh`、`box-autoturn.sh`、`box-remote-learn.sh`、`automation/autoturn.lua` |
| `testdata/sample.txt` 不同 | 盒上是截短版（15 行 → 2 行），纯测试数据 |
| `.local/share/native-reader/` | 只在盒上：运行时状态，非代码 |
| 其余 38 个 `lua/` 文件 | **完全一致** |

`remote.lua` 上新增的遥控器逻辑（上游没有）：

- `shelf.up` / `shelf.down` / `shelf.pageup` / `shelf.pagedown` / `shelf.select` / `shelf.open`
  —— 书库（阅读历史）里用上下键选择，`pagedown` 走 `±10`，`select/open` 可按序号跳转并激活；
- `app.ok` 与 `app.toc` 同义 —— 书库开着时 OK 键是「打开这本书」，否则才是切目录；
- `reader.next` / `reader.prev` —— 书库开着时改派 `lib:move(±1)`，不再翻页；
- `state()` 多吐 `selected` / `name` 字段，让遥控端知道当前选中哪本。

**这个分叉是有意为之，不要合并回去**：

- `~/Desktop/reader`（本机）用键盘鼠标，**不需要遥控器**，`shelf.*` 那套在桌面上是死代码，
  合并进去只会让上游变脏。上游保持干净。
- 盒上那份是为遥控器改的，遥控键位只有盒子需要。

**唯一要小心的是重装**：重新交叉编译 + `make install`（第 1 步）会把第 2 步的遥控器改动
**整个冲掉**，因为上游里没有这些 `shelf.*`。
重装前先备份盒上的 `/opt/reader/lua`，装完把 `remote.lua` 和那 7 个 `box-*` 文件补回去。
本目录就是那个备份。

## 桌面版更新后，怎么重新适配（固定流程）

上游 `~/Desktop/reader` 一有更新，就拿**本目录当基线**做 diff，把遥控适配重新打一遍。
不要手工回忆改了哪儿 —— 差异全在 diff 里。

```sh
# 0) 先把盒上现状拉回来覆盖本目录（本目录 = 盒上快照，永远保持最新）
rsync -a --delete x98h:/opt/reader/lua/ ~/kernel/reader/lua/

# 1) 上游更新
cd ~/Desktop/reader && git pull        # 或切到目标 tag

# 2) diff：正常情况下只该有 remote.lua 一行差异
diff -rq ~/Desktop/reader/lua ~/kernel/reader/lua

# 3) 生成补丁，看清改了什么（93 行）
diff -u ~/Desktop/reader/lua/ui/remote.lua \
        ~/kernel/reader/lua/ui/remote.lua > /tmp/remote-adapt.patch

# 4) 把补丁打到新版上游上（冲突就按 shelf.* 的语义手工并）
#    只落工作区、不提交：上游要一直干净，桌面版不需要遥控代码
cd ~/Desktop/reader && git apply -3 /tmp/remote-adapt.patch
#    编译装机之后可选还原：git checkout -- lua/ui/remote.lua

# 5) 交叉编译 + 装盒子（会覆盖 /opt/reader，所以第 0 步已备份）
#    ... 略，见本文件上面的构建步骤 ...

# 6) 装完再拉一次快照，确认盒上 = 适配后的代码
rsync -a --delete x98h:/opt/reader/lua/ ~/kernel/reader/lua/
diff -rq ~/Desktop/reader/lua ~/kernel/reader/lua   # 期望：仍然只有 remote.lua
```

判断标准（第 2/6 步的输出）：

| 输出 | 含义 |
| --- | --- |
| `只报 remote.lua 不同` | 正常，这就是遥控适配 |
| 报 `ffi/sdl2.lua`、`ui/app.lua` 等**其他文件**不同 | 盒上有手动改过、上游没有的东西 —— **先搞清是不是别人的改动**，别随手覆盖 |
| 报 `Only in ...` | 多半是被 `--delete` 干掉了或新加了文件，核对一下再继续 |

要注意的两点：

- `box-remote.lua`、`remote-map.lua`、`box-*.sh` 在**根目录不在 `lua/` 下**，
  上面的 `rsync lua/` 不会带走它们。盒子重装若清了 `/opt/reader`，这几个要单独再传一次。
- 重启阅读器前先确认控制台能起：`ssh x98h '/opt/reader/bin/luajit /opt/reader/lua/ui/app.lua'`。

## 说明

- 本目录是**只读备份**：`window.lua` 等运行时状态由盒上程序自己写，回灌时别拿这份覆盖正在用的状态。
- 相关文档见仓库 `x98h.md`、`arm64_app.md`；桌面（非阅读器）代码在 `desktop/`。
  **注意别搞混**：`desktop/` 是另一个程序（sway 桌面启动器），和 reader 无关。
