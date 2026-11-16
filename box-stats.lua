-- tvcast 状态探针: 每 2s 落盘 /tmp/mpvstat.txt, 供 tvcast.sh -t 读取
local function t(k) return mp.get_property(k) or "?" end
mp.add_periodic_timer(2, function()
  local f = io.open("/tmp/mpvstat.txt", "w")
  if not f then return end
  f:write(string.format(
    "t=%.2f fps=%s drop=%s mistimed=%s vo_drop=%s vcache=%s disp_fps=%s sync=%s hw=%s\n",
    mp.get_property_number("time-pos") or 0, t("estimated-vf-fps"),
    t("frame-drop-count"), t("mistimed-frame-count"), t("vo-drop-frame-count"),
    t("demuxer-cache-duration"), t("display-fps"), t("video-sync"), t("hwdec-current")))
  f:close()
end)
