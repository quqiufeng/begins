-- ui/theme.lua — 一套配色 + 尺寸，集中换肤
--
-- 深色底（客厅电视/盒子默认环境光偏暗），选中用暖橙强调色，
-- 图标按文件类别上色，一眼能分出书/片/图。

local M = {}

M.bg = 0x12161C
M.panel = 0x1A2029
M.panel_alt = 0x151A21
M.card = 0x1E252F
M.card_sel = 0x2C3A4C
M.border = 0x2A333F
M.border_sel = 0xF0A030
M.text = 0xE6EDF3
M.text_dim = 0x8B98A5
M.text_sel = 0xFFFFFF
M.accent = 0xF0A030
M.accent_dim = 0x7A5A20
M.ok = 0x54C08A
M.warn = 0xE0644A
M.bar = 0x0D1117

M.kind_color = {
	dir = 0xF0C060,
	ebook = 0x6FA8F5,
	video = 0xE0644A,
	audio = 0x54C08A,
	image = 0xB07FE0,
	other = 0x8B98A5,
}

-- 尺寸（逻辑像素，窗口 1280×720 为基准，缩放由 ui/grid 按实际宽算）
M.top_bar_h = 56
M.bottom_bar_h = 44
M.gap = 14
M.padding = 24

M.font_title = 26
M.font_path = 20
M.font_name = 18
M.font_small = 14
M.font_badge = 13

return M
