-- 播放列表 OSD：坐标/字号按「视频帧」坐标系给（640x360 会被屏幕放大 4 倍）
local VW, VH = 640, 360
-- 仓耳今楷 02（W04 正文）——桌面同款；mpv 走 fontconfig，装了就认中文名
local FONT = os.getenv("MUSIC_OSD_FONT") or "TsangerJinKai02"
local function esc(s) return (s:gsub("\\","\\\\"):gsub("{","\\{"):gsub("}","\\}")) end

local function name_of(t)
  t = t:gsub("^.-/mp3/", "")
  local ok, dec = pcall(function()
    return t:gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end)
  end)
  if ok then t = dec end
  t = (t:gsub("^.-/", ""))
  t = t:gsub("%.[Aa][Pp][Ee]$",""):gsub("%.[Ff][Ll][Aa][Cc]$","")
       :gsub("%.[Ww][Mm][Aa]$",""):gsub("%.[Mm][Pp]3$","")
       :gsub("%.[Mm]4[Aa]$",""):gsub("%.[Dd][Ff][Ff]$","")
  if #t > 34 then t = t:sub(1, 33) .. "…" end
  return t
end

local function draw()
  local pos   = mp.get_property_number("playlist-pos-1") or 0
  local cnt   = mp.get_property_number("playlist-count") or 0
  local title = name_of(mp.get_property("media-title") or "")
  local tp    = mp.get_property_number("time-pos")
  local dur   = mp.get_property_number("duration")
  local vol   = math.floor(mp.get_property_number("volume") or 0)
  local st    = mp.get_property("pause") == true and "暂停" or "播放"
  local clk   = os.date("%m-%d %H:%M:%S")
  local tstr  = ""
  if tp and dur then
    tstr = string.format("  %d:%02d/%d:%02d", math.floor(tp/60), math.floor(tp%60),
                          math.floor(dur/60), math.floor(dur%60))
  end
  mp.set_osd_ass(VW, VH, string.format(
    "{\\fn%s\\an7\\pos(10,7)\\fs13\\b1\\c&H00FFFFFF&\\bord1.2\\3c&H00000000&}%d/%d  %s{\\r}\n" ..
    "{\\fn%s\\an7\\pos(10,24)\\fs10\\c&H00D8FFFF&\\bord1.2\\3c&H00000000&}%s%s   音量 %d%%{\\r}\n" ..
    "{\\fn%s\\an9\\pos(630,7)\\fs10\\c&H00C8FFC8&\\bord1.2\\3c&H00000000&}%s{\\r}",
    FONT, pos, cnt, esc(title), FONT, st, tstr, vol, FONT, clk))
end

mp.register_event("file-loaded", draw)
mp.register_event("playback-restart", draw)
mp.add_periodic_timer(0.5, draw)
