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

## 安装

```sh
./install.sh              # 拷到 192.168.1.121:/opt/keybord 并起 keybd.service
./install.sh --no-service # 只拷文件
```
