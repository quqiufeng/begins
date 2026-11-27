-- /opt/reader/remote-map.lua — 覆盖 box-remote.lua 的默认按键表
-- 遥控器（XING WEI 2.4G，实测）：event0=键盘接口，event2=Consumer Control
--   ←→=LEFT/RIGHT  ↑↓=UP/DOWN  OK=ENTER  ↩返回=ESC  上排是 Ctrl+数字：
--   首页=Ctrl+1  静音=Ctrl+2  菜单=Ctrl+3  音量+=Ctrl+4  音量−=Ctrl+5
-- 方向键/ESC/OK 阅读器自己就吃（SDL evdev），这里不重复映射，否则翻两页。
-- 动作名必须是 reader 自动化 socket 的真 fn id（app.* / reader.*）。
return {
  ["C-1"] = "app.library",   -- 首页  → 书架
  ["C-2"] = "app.dual",      -- 静音（阅读器无音频）→ 借作单/双栏切换
  ["C-3"] = "app.toc",       -- 菜单  → 目录
  ["C-4"] = "font+",         -- 音量+ → 放大字号
  ["C-5"] = "font-",         -- 音量− → 缩小字号
  MENU      = "app.toc",
  HOMEPAGE  = "app.library",
  HOMEPAGE2 = "app.library",
}
