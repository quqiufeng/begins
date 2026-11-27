# keybord — 盒子遥控器（两步走）

遥控器按键 → app 自动化，全程 LuaJIT，无外部依赖。

## 第一步：动态探索（不改文件）

用 `luajit -e` 现场调 app 的自动化口，摸清「能干什么 / 现在什么状态 / 哪几个键」：

```sh
# 探活 + 动作清单 + 状态 + 键表覆盖对照
luajit -e 'dofile("/opt/keybord/explore.lua")' reader

# 当场执行一个动作（看屏幕确认效果）
luajit -e 'dofile("/opt/keybord/explore.lua")' reader --try app.toc

# 连做几步
luajit -e 'dofile("/opt/keybord/explore.lua")' reader --seq "app.library,app.toc,font+"

# 学码：让 keybd 只记键 10 秒，配遥控器按一遍，读回真实键名/码
luajit -e 'dofile("/opt/keybord/explore.lua")' reader --keys 10
```

`--` 后置参数：`luajit -e '…'` 后面的 `--xxx` 会被 luajit 本身当选项，
要看表/状态就写 `luajit /opt/keybord/keys/reader.lua --list`，或加 `--`：
`luajit -e 'dofile("/opt/keybord/keys/reader.lua")' -- --list`

## 第二步：落地成固定脚本

试稳了就冻结成**写死键码表**，之后每键只跑这一条：

```sh
# 把当前 app.map（含 maps 覆盖）生成 keys/<app>.lua
luajit -e 'dofile("/opt/keybord/explore.lua")' reader --freeze

# 之后：键名 / 裸键码 / 动作名三选一
luajit -e 'dofile("/opt/keybord/keys/reader.lua")' C-1
luajit -e 'dofile("/opt/keybord/keys/reader.lua")' 2
luajit -e 'dofile("/opt/keybord/keys/reader.lua")' app.toc
```

`keys/<app>.lua` 就是真源（键名, evdev 码, 修饰键, 动作），可以直接手改；
keybd 启动时读它当 map，`DISPATCH=exec` 时每键 fork 一条
`luajit -e 'dofile(keys/<app>.lua)' <键名>`，由它去调 `apps/<app>.lua` → app 的 socket 自动化口。

## 目录

| 文件 | 作用 |
| --- | --- |
| `keybd.lua` | 常驻守护：独占 evdev、判前台、按键分发（控制口 `/tmp/keybd.sock`） |
| `explore.lua` | **第一步**：动态探索 / 学码 / `--freeze` 冻结 |
| `keys/base.lua` | 固定脚本执行器（查表、环境、失败日志） |
| `keys/<app>.lua` | **第二步**：写死的键码表（唯一真源） |
| `apps/<app>.lua` | 自动化适配层：detect / run / state，连 app 自己的 socket |
| `maps/<app>.lua` | 探索期的手工键位覆盖（`--freeze` 的输入之一） |
| `tools/rk.sh` | 按遥控器键 + 回传截图（`./tools/rk.sh down x3 ok`），不摸遥控器也能测 |
| `tools/vkey.lua` | 用 /dev/uinput 造虚拟键盘往盒子里打按键（LuaJIT FFI，无 python） |
| `tools/gen-keynames.lua` | 从 `input-event-codes.h` 全量生成 `keynames.lua`；`--check` 校验漏码 |

## 长按（app.hold）

一个物理键想干两件事时，用 `apps/<app>.lua` 里的 `M.hold` 声明长按动作：

```lua
M.map  = { ["C-3"] = "nav.menu" }    -- 短按（抬起前松手）
M.hold = { ["C-3"] = "nav.theme" }   -- 按住 ≥ CFG.hold_ms（默认 700ms）
```

- 按下只记账不派发；抬起（短按）派发 `M.map` 里那一层的动作，按住超过
  `hold_ms` 派发 `M.hold` 的动作，派发过长按后抬起不再补发短按。
- 设备连发（`value=2`）不参与长按，只等 `hold_ms` 到点，一次按键只出一个动作。
- **控制口/命令行（`act.lua`、测试脚本、`{"cmd":"key"}`）不受影响**：它们只发按下
  没有抬起，走长按逻辑会把动作挂住，所以 `devname` 是 `ctl`/`cli` 时直接派发 `M.map`。
- 日志分得清：`short C-3 ... -> nav.menu ok` / `hold C-3 ... -> nav.theme ok`。
- 实测用 `tools/vkey.lua`：`VKEY_NAME=vremote-test /opt/reader/bin/luajit tools/vkey.lua ctrl+3`
  （短按）、`VKEY_NAME=vremote-test VKEY_HOLD=0.9 ... vkey.lua hold:ctrl+3`（0.9s 长按，
  该过 0.7s 阈值）。`VKEY_NAME` 必须换个名字 —— 默认 `vkeybd-test` 含 `keybd-`，
  keybd 会当成自己的 uinput 键盘排除掉。

### 判定精度：两个曾经让 0.9s 长按变短按的坑

长按要的是"按下到抬起"的真实时长，中间任何一处取错时刻都会让阈值差一口气：

1. **主循环 `select` 超时 `CFG.poll_ms`（默认 100ms）**：`hold_tick()` 只在每轮
   `select` 返回后跑，超时给 500ms 时，按 0.9s 要等满 1.0s 才判定，手一快就变短按。
2. **记按下时刻用事件自带的时间戳（`evdev.ev_ms()`），不用读到的时刻**：上一个动作
   （例如经 socket 让桌面刷一次列表）会把主循环占住两三百毫秒，事件晚读，若拿
   `evdev.now_ms()` 当按下时刻，0.9s 会被算成 0.6s。`struct input_event.time` 是
   `CLOCK_REALTIME`，`ev_ms()` 一次性算好与 `CLOCK_MONOTONIC` 的偏移再换算。
3. 顺带记一笔测试工具的坑：`vkey.lua` 早先是"数 sleep 次数"控制长按时长，
   每轮 `nanosleep` 被信号打断就少睡一点，累积下来 `VKEY_HOLD=0.9` 只按住 0.66s；
   现在按绝对时钟到点为止（`hold_for()`）。

桌面（`apps/desktop.lua`）现在是：☰ 短按 = 刷新列表，☰ 长按 0.7s = 换主题。

## 安装

```sh
./install.sh              # 拷到 192.168.1.121:/opt/keybord 并起 keybd.service
./install.sh --no-service # 只拷文件
```
