-- box-remote.lua — 遥控器/键盘 → native-reader 翻页守护
--
-- 读 /dev/input/event*（2.4G USB 遥控 + 红外 meson-ir 都走 EV_KEY），
-- 映射成 reader 自动化 socket 的动作。
--   luajit box-remote.lua            # 正常跑
--   LEARN=1 luajit box-remote.lua    # 只打印按键（学码）
--
local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
struct rd_timeval { long tv_sec; long tv_usec; };
struct input_event { struct rd_timeval time; uint16_t type; uint16_t code; int32_t value; };
struct rd_timespec { long tv_sec; long tv_nsec; };
int open(const char *path, int flags, ...);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
int ioctl(int fd, unsigned long req, ...);
int nanosleep(const struct rd_timespec *req, struct rd_timespec *rem);
]]

local O_RDONLY, O_NONBLOCK = 0, 2048
local EV_KEY, EV_REP = 1, 20
local EVIOCGRAB = 0x40044590

local LEARN = os.getenv("LEARN") == "1"
local GRAB  = os.getenv("GRAB") ~= "0"
local REPEAT_MS = tonumber(os.getenv("REPEAT_MS") or "250")
local LOG = os.getenv("LOG") or "/tmp/reader-remote.log"

local KEY = {
  [1]="ESC",[2]="1",[3]="2",[4]="3",[5]="4",[6]="5",[7]="6",[8]="7",[9]="8",[10]="9",[11]="0",
  [14]="BACKSPACE",[15]="TAB",[16]="Q",[17]="W",[18]="E",[19]="R",[20]="T",[21]="Y",[22]="U",
  [23]="I",[24]="O",[25]="P",[28]="ENTER",[29]="LEFTCTRL",[30]="A",[31]="S",[32]="D",[33]="F",
  [34]="G",[35]="H",[36]="J",[37]="K",[38]="L",[42]="LEFTSHIFT",[44]="Z",[45]="X",[46]="C",
  [47]="V",[48]="B",[49]="N",[50]="M",[57]="SPACE",
  [59]="F1",[60]="F2",[61]="F3",[62]="F4",[63]="F5",[64]="F6",[65]="F7",[66]="F8",[67]="F9",
  [68]="F10",[87]="F11",[88]="F12",[96]="KPENTER",[98]="KPSLASH",
  [102]="HOME",[103]="UP",[104]="PAGEUP",[105]="LEFT",[106]="RIGHT",[107]="END",[108]="DOWN",
  [109]="PAGEDOWN",[110]="INSERT",[111]="DELETE",
  [113]="MUTE",[114]="VOLUMEDOWN",[115]="VOLUMEUP",[116]="POWER",[119]="PAUSE",[121]="KPCOMMA",
  [125]="LEFTMETA",[126]="RIGHTMETA",[127]="COMPOSE",
  [128]="STOP",[138]="HELP",[139]="MENU",[140]="CALC",[141]="SETUP",[142]="SLEEP",[143]="WAKEUP",
  [148]="PROG1",[149]="PROG2",[150]="PROG3",[151]="PROG4",[152]="ALL_APPS",[155]="FAVORITES",
  [156]="HOMEPAGE",[158]="BACK",[159]="FORWARD",[160]="MAIL",[161]="MEDIASELECT",
  [163]="NEXTSONG",[164]="PLAYPAUSE",[165]="PREVIOUSSONG",[166]="STOPCD",[167]="RECORD",
  [168]="REWIND",[169]="PHONE",[172]="HOMEPAGE2",[173]="REFRESH",[174]="EXIT",[175]="MOVE",
  [176]="EDIT",[177]="SCROLLUP",[178]="SCROLLDOWN",[207]="PLAY",[208]="FASTFORWARD",
  [212]="CAMERA",[240]="UNK240",
  [352]="OK",[353]="SELECT",[354]="GOTO",[355]="CLEAR",[356]="POWER2",[357]="OPTION",
  [358]="INFO",[359]="TIME",[360]="VENDOR",[362]="EPG",[364]="FAVORITES2",[365]="EPG2",
  [366]="TV",[367]="TV2",[368]="RED",[369]="GREEN",[370]="YELLOW",[371]="BLUE",
  [372]="TEXT",[373]="SUBTITLE",[377]="AUDIO",[378]="NUMERIC",[386]="EMAIL",[387]="MEDIA",
  [389]="CHANNELUP",[390]="CHANNELDOWN",[391]="LAST",[392]="RESTART",[393]="SLOW",
  [394]="SHUFFLE",[395]="BREAK",[396]="PREVIOUS",[397]="NEXT",[398]="DIGITS",[399]="TEEN",
  [400]="TWEN",[401]="VIDEOPHONE",[402]="GAMES",[403]="ZOOMIN",[404]="ZOOMOUT",
  [405]="ZOOMRESET",[407]="NEXTFAVORITE",[408]="KEYBOARD",
}

-- 键 → 动作（/opt/reader/remote-map.lua 可覆盖）
local MAP = {
  RIGHT="next", PAGEDOWN="next", DOWN="next", NEXTSONG="next", NEXT="next",
  FASTFORWARD="next", SCROLLDOWN="next", CHANNELDOWN="next",
  LEFT="prev", PAGEUP="prev", UP="prev", PREVIOUSSONG="prev", PREVIOUS="prev",
  REWIND="prev", SCROLLUP="prev", CHANNELUP="prev",
  ENTER="toc", KPENTER="toc", MENU="toc", OK="toc", EPG="toc", TEXT="toc", SUBTITLE="toc",
  INFO="bookmarks", BLUE="bookmarks",
  HOME="library", HOMEPAGE="library", HOMEPAGE2="library", MEDIA="library",
  BACK="toc.close", EXIT="quit", STOPCD="quit",
  SETUP="settings", OPTION="settings", AUDIO="settings",
  C="dual", YELLOW="dual", M="eye", PLAYPAUSE="eye", PAUSE="eye", RED="eye",
  ZOOMIN="font+", ZOOMOUT="font-", ZOOMRESET="font0",
  VOLUMEUP="font+", VOLUMEDOWN="font-",
  F11="fullscreen", TAB="maximize",
  GREEN="bookmark.add",
  ["1"]="goto0", ["2"]="chapter2", ["3"]="chapter3",
}

local logf
local function log(fmt, ...)
  local line = string.format("[%s] "..fmt.."\n", os.date("%Y-%m-%d %H:%M:%S"), ...)
  logf = logf or io.open(LOG, "a")
  if logf then logf:write(line); logf:flush() end
end

local function scan_devices()
  local list, name = {}, "?"
  local f = io.open("/proc/bus/input/devices")
  if not f then return list end
  for line in f:lines() do
    if line:match("^N: Name=") then name = line:match('Name="(.-)"') or "?"
    elseif line:match("^H: Handlers=") then
      for ev in line:gmatch("(event%d+)") do
        list[#list+1] = { dev = "/dev/input/"..ev, name = name }
      end
    end
  end
  f:close()
  return list
end

local function wanted(e)
  local want = os.getenv("DEVICES")
  if want and want ~= "" then
    for pat in want:gmatch("[^,]+") do
      if e.name:lower():find(pat:lower(), 1, true) then return true end
    end
    return false
  end
  return not e.name:find("Mouse")
end

local agent, agent_err
local function open_agent()
  local ok, a = pcall(function() return require("agent").new() end)
  if ok and a then return a end
  agent_err = tostring(a)
  return nil
end

local function state_of(a)
  local s = a:state(); return (s and (s.state or s)) or {}
end

local function do_action(act)
  if not act then return end
  if not agent then
    agent = open_agent()
    if not agent then log("no agent (%s)", tostring(agent_err)); return end
  end

  if act == "font+" or act == "font-" or act == "font0" then
    local s = state_of(agent)
    local fs = tonumber(s.font_size) or 22
    if act == "font+" then fs = fs + 2 elseif act == "font-" then fs = fs - 2 else fs = 22 end
    fs = math.max(10, math.min(64, fs))
    agent:setSettings({ font_size = fs })
    log("action font_size=%d", fs); return
  elseif act == "goto0" then
    agent:goto(1); log("action goto page 1"); return
  elseif act:match("^chapter(%d+)$") then
    local ch = tonumber(act:match("^chapter(%d+)$"))
    local r = agent:gotoChapter(ch)
    log("action chapter %d ok=%s", ch, tostring(r and r.ok))
    return
  end

  local ok, r = pcall(function() return agent:call(act) end)
  if not ok then log("action %s error %s", act, tostring(r)); return end
  if r and r.ok == false then
    log("action %s FAILED: %s", act, tostring(r.error))
  else
    local s = state_of(agent)
    log("action %s ok page=%s/%s", act, tostring(s.page), tostring(s.pages))
  end
end

local function main()
  if not LEARN then
    local ok, map = pcall(dofile, "/opt/reader/remote-map.lua")
    if ok and type(map) == "table" then
      for k, v in pairs(map) do MAP[k] = v end
      log("loaded remote-map.lua")
    end
  end
  agent = open_agent()
  if not agent then log("WARN: 没连上阅读器 socket，只记录按键") end

  local devs = {}
  for _, e in ipairs(scan_devices()) do
    if wanted(e) then
      local fd = C.open(e.dev, O_RDONLY + O_NONBLOCK)
      if fd >= 0 then
        local g = false
        if GRAB and not LEARN then g = C.ioctl(fd, EVIOCGRAB, ffi.cast("int",1)) == 0 end
        devs[#devs+1] = { fd=fd, name=e.name, path=e.dev, grabbed=g }
        log("open %s (%s) grab=%s", e.dev, e.name, tostring(g))
      end
    end
  end
  if #devs == 0 then log("ERROR: 没有可用输入设备"); os.exit(1) end
  log("ready learn=%s grab=%s", tostring(LEARN), tostring(GRAB))

  local ev = ffi.new("struct input_event")
  local buf = ffi.cast("char*", ev)
  local sz = ffi.sizeof("struct input_event")
  local ts = ffi.new("struct rd_timespec"); ts.tv_sec = 0; ts.tv_nsec = 20*1000*1000
  local last = {}
  local mods = {}   -- 修饰键状态 29/97=CTRL 42/54=SHIFT 56/100=ALT

  local function combo(raw)
    local p = {}
    if mods[29] or mods[97] then p[#p+1] = "C-" end
    if mods[42] or mods[54] then p[#p+1] = "S-" end
    if mods[56] or mods[100] then p[#p+1] = "A-" end
    return table.concat(p) .. raw
  end

  while true do
    for _, d in ipairs(devs) do
      local n = C.read(d.fd, buf, sz)
      if n == sz and ev.type == EV_KEY then
        local code, val = ev.code, ev.value
        local raw = KEY[code] or ("KEY_"..code)
        local name = raw
        if code == 29 or code == 97 or code == 42 or code == 54
           or code == 56 or code == 100 then
          mods[code] = (val ~= 0) or nil
        elseif val ~= 0 then
          name = combo(raw)
        end
        local t = os.clock()
        if val == 1 then
          last[code] = t
          if LEARN then
            log("LEARN %s code=%d dev=%s", name, code, d.name)
          else
            local act = MAP[name]
            if act then log("press %s code=%d -> %s", name, code, act) end
            do_action(act)
          end
        elseif val == 2 and not LEARN and last[code] and (t-last[code])*1000 >= REPEAT_MS then
          last[code] = t
          do_action(MAP[name])
        end
      end
    end
    C.nanosleep(ts, nil)
  end
end

main()
