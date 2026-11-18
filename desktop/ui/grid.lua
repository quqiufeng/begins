-- ui/grid.lua — 文件网格视图（遥控方向键的主战场）
--
-- 布局：顶栏固定，底栏固定，中间是可滚动的网格。
--   列数按窗口宽度自适应（3..8 列），格子高度跟着格子宽度走，
--   行数由剩余高度决定，选中项永远保证在可视区内（按行滚动，不是按项）。
--
-- 遥控语义只在这里：左右 = 相邻项，上下 = 换行（同列），
--   上下翻页键 = 整屏翻，OK 由 main 交给 launcher。

local M = {}
M.__index = M

local floor, min, max = math.floor, math.min, math.max
-- 缩略图纹理上限（张）。256x256 RGBA ≈ 256KB/张，默认 48 张 ≈ 12MB 上界。
local THUMB_MAX = tonumber(os.getenv("DESKTOP_THUMB_CACHE") or "") or 48

function M.new(cfg, theme, ttf, txt, img, icons, sdl)
	return setmetatable({
		cfg = cfg, theme = theme, ttf = ttf, txt = txt,
		img = img, icons = icons, sdl = sdl,
		-- config.font_path 是函数（多个候选路径挑第一个存在的），这里解析一次
		font_path = (type(cfg.font_path) == "function") and cfg.font_path() or cfg.font_path,
		cols = 4, rows = 3, cell_w = 240, cell_h = 190,
		ax = 0, ay = 0, aw = 0, ah = 0, row0 = 0,
		thumb_cache = {},
		thumb_lru = {},
		thumb_max = THUMB_MAX,
	}, M)
end

-- 计算布局；W/H 变了要重算（main 在 resize 时调用）
function M:layout(W, H)
	local t = self.theme

	self.W, self.H = W, H
	self.ax = t.padding
	self.ay = t.top_bar_h + 10
	self.aw = max(200, W - t.padding * 2)
	self.ah = max(120, H - t.top_bar_h - t.bottom_bar_h - 16)

	local min_w = 190
	local cols = floor((self.aw + t.gap) / (min_w + t.gap))

	cols = max(3, min(8, cols))
	self.cols = cols
	self.cell_w = floor((self.aw - t.gap * (cols - 1)) / cols)
	self.cell_h = floor(max(132, min(240, self.cell_w * 0.80)))
	self.rows = max(1, floor((self.ah + t.gap) / (self.cell_h + t.gap)))
	-- 内容不满一屏时也保持顶部对齐，不做居中（居中选择器会"跳"）
	self.row0 = 0
	return self
end

function M:page_size() return self.cols * self.rows end

function M:cell_xy(col, row)
	local t = self.theme

	return self.ax + col * (self.cell_w + t.gap),
		self.ay + (row - self.row0) * (self.cell_h + t.gap)
end

-- 让 fs.sel 落在可视区
function M:ensure(fs)
	local sel = fs.sel or 1
	local row = floor((sel - 1) / self.cols)

	if row < self.row0 then self.row0 = row end
	if row > self.row0 + self.rows - 1 then self.row0 = row - self.rows + 1 end
	local total_rows = math.ceil(max(1, fs:count()) / self.cols)

	self.row0 = max(0, min(max(0, total_rows - self.rows), self.row0))
end

function M:move(fs, dx, dy)
	local n = fs:count()

	if n == 0 then return false end
	local sel = fs.sel or 1

	if dy ~= 0 then
		local target = sel + dy * self.cols

		-- 同列换行；越过末行就往最后一个 / 第一个靠（不跨列乱跳）
		if target > n then
			local col = (sel - 1) % self.cols + 1
			local last_row = floor((n - 1) / self.cols)

			target = last_row * self.cols + col
			if target > n then target = n end
		end
		if target < 1 then target = 1 end
		sel = target
	elseif dx ~= 0 then
		sel = max(1, min(n, sel + dx))
	end
	if sel == fs.sel then return false end
	fs.sel = sel
	self:ensure(fs)
	return true
end

function M:page(fs, dir)
	local n = fs:count()

	if n == 0 then return false end
	local step = self:page_size()
	local sel = max(1, min(n, (fs.sel or 1) + dir * step))

	if sel == fs.sel then return false end
	fs.sel = sel
	self:ensure(fs)
	return true
end

function M:home(fs)
	if fs:count() == 0 then return false end
	fs.sel = 1
	self:ensure(fs)
	return true
end

function M:endk(fs)
	local n = fs:count()

	if n == 0 then return false end
	fs.sel = n
	self:ensure(fs)
	return true
end

function M:hit(fs, mx, my)
	local t = self.theme
	local n = fs:count()

	for i = 1, n do
		local idx = i - 1
		local col, row = idx % self.cols, floor(idx / self.cols)
		local x, y = self:cell_xy(col, row)

		if mx >= x and mx < x + self.cell_w and my >= y and my < y + self.cell_h
			and row >= self.row0 and row < self.row0 + self.rows then
			return i
		end
	end
	return nil
end

-- ---------- 绘制 ----------

local function blend_color(rgb, a)
	-- 只用于"半透明填充"的近似：向背景色靠，省得开 alpha 通道计算
	local r = floor(rgb / 65536) % 256
	local g = floor(rgb / 256) % 256
	local b = rgb % 256

	return r, g, b
end

-- 图标徽章：色块圆角矩形 + 类别缩写（ASCII，字体一定有字形）
function M:draw_badge(ren, x, y, w, h, kind, label, sel)
	local t, sdl = self.theme, self.sdl
	local c = t.kind_color[kind] or t.text_dim
	local fh = max(11, min(20, floor(h * 0.42)))

	local f = self.badge_font or (t.font_badge)
	local pad = floor(h * 0.12)

	-- 卡底（暗）+ 顶部色条（亮）：比描边省，也比纯色块柔和
	sdl.fill(ren, x, y, w, h, c, sel and 64 or 40)
	sdl.frame(ren, x, y, w - 1, h - 1, c, sel and 200 or 120)
	sdl.fill(ren, x, y, w, max(2, floor(h * 0.10)), c, sel and 230 or 150)
	-- 折角：右上角切出一个小三角的感觉
	sdl.fill(ren, x + w - floor(w * 0.22), y, floor(w * 0.22), floor(h * 0.18), t.bg, 255)

	self.ttf.draw(ren, self.font_path, label, f,
		x + floor(w / 2), y + floor(h * 0.55), c, "center")
end

-- 缩略图：懒加载 + 按 path/mtime 缓存，真 LRU（超限只淘汰最久没用的那张）
--
-- 旧写法「一超上限就全清」在快速翻目录时会连续触发全量销毁重建：既抖屏，
-- 又把刚建好的纹理立刻扔掉。这里改成标准 LRU，纹理数有硬上界、行为可预测。

local function lru_touch(self, key)
	local l = self.thumb_lru

	for i = 1, #l do
		if l[i] == key then
			table.remove(l, i)
			break
		end
	end
	l[#l + 1] = key
end

-- 腾出位置：只淘汰已解码的真纹理，解码失败的 false 标记留着（免得反复重试坏文件）
function M:thumb_evict(limit)
	local l, c, sdl = self.thumb_lru, self.thumb_cache, self.sdl
	local ntex, i = 0, 1

	for _, k in ipairs(l) do
		if c[k] then ntex = ntex + 1 end
	end
	while ntex >= limit and i <= #l do
		local k = l[i]

		if c[k] then
			if sdl and sdl.destroy_texture then sdl.destroy_texture(c[k]) end
			c[k] = nil
			table.remove(l, i)
			ntex = ntex - 1
		else
			i = i + 1
		end
	end
end

function M:thumb(ren, item)
	local img = self.img

	if not img or not img.available then return nil end
	local key = item.path .. "@" .. tostring(item.mtime or 0)
	local hit = self.thumb_cache[key]

	if hit ~= nil then
		if hit then lru_touch(self, key) end
		return hit or nil
	end
	local tex = img.texture(ren, item.path)

	if tex == nil then
		self.thumb_cache[key] = false
		self.thumb_lru[#self.thumb_lru + 1] = key
		return nil
	end
	self:thumb_evict(self.thumb_max or THUMB_MAX)
	self.thumb_cache[key] = tex
	self.thumb_lru[#self.thumb_lru + 1] = key
	return tex
end

-- 外部 app 抢过 KMS 之后纹理全废：destroy=false 时只丢引用不销毁（上下文已丢，
-- 交给 SDL 内部回收更安全）；正常退出/换目录用 destroy=true 真正释放。
function M:clear_thumbs(destroy)
	local c = self.thumb_cache

	if destroy and self.sdl and self.sdl.destroy_texture then
		for _, v in pairs(c) do
			if v then self.sdl.destroy_texture(v) end
		end
	end
	self.thumb_cache = {}
	self.thumb_lru = {}
end

function M:draw(ren, fs, W, H)
	local t, sdl = self.theme, self.sdl

	self:layout(W, H)
	-- 图标模块没显式传进来就自己建（有 SDL + 解码器时）
	if not self.icons and self.img and self.sdl and self.img.available then
		self.icons = require("ui.icons").new(self.cfg, self.sdl, self.img)
	end
	self:ensure(fs)
	sdl.clip(ren, self.ax - 8, self.ay - 6, self.aw + 16, self.ah + 12)

	local n = fs:count()
	local first = self.row0 * self.cols + 1
	local last = min(n, (self.row0 + self.rows) * self.cols)

	if n == 0 then
		local msg = fs.err and ("无法读取目录：" .. tostring(fs.err)) or "这里没有可显示的文件"
		local col = fs.err and t.warn or t.text_dim

		sdl.clip(ren)
		self.ttf.draw(ren, self.font_path, msg, t.font_name,
			W / 2, self.ay + self.ah / 2 - 10, col, "center")
		return
	end

	for i = first, last do
		local item = fs:at(i)

		if item then
			local idx = i - 1
			local col, row = idx % self.cols, floor(idx / self.cols)
			local x, y = self:cell_xy(col, row)
			local sel = (i == fs.sel)
			local pad = 12
			local ix, iy = x + pad, y + pad
			local iw, ih = self.cell_w - pad * 2, floor(self.cell_h * 0.52)

			-- 卡底
			sdl.fill(ren, x, y, self.cell_w, self.cell_h, sel and t.card_sel or t.card, 255)
			if sel then
				sdl.frame(ren, x, y, self.cell_w - 1, self.cell_h - 1, t.border_sel, 255)
				sdl.frame(ren, x + 1, y + 1, self.cell_w - 3, self.cell_h - 3, t.border_sel, 90)
				sdl.fill(ren, x, y, 4, self.cell_h, t.accent, 255)
			else
				sdl.frame(ren, x, y, self.cell_w - 1, self.cell_h - 1, t.border, 255)
			end

			-- 图标区：图片给真缩略图，其余给主题类别图标，都没有再退回文字徽章
			local tex = (item.kind == "image") and self:thumb(ren, item) or nil

			if tex then
				local tw, th = sdl.tex_size(tex)

				if tw and th and tw > 0 and th > 0 then
					-- 裁切填充：竖长图（截图/长图）contain 会缩成一根线，改 cover 居中裁
					local scale = max(iw / tw, ih / th)
					local dw, dh = max(1, floor(tw * scale)), max(1, floor(th * scale))
					local dst = { x = ix + floor((iw - dw) / 2), y = iy + floor((ih - dh) / 2),
						w = dw, h = dh }

					sdl.clip(ren, ix, iy, iw, ih)
					sdl.copy(ren, tex, dst)
					sdl.clip(ren)
				end
				sdl.frame(ren, ix, iy, iw, ih, t.border, 120)
			elseif self.icons and self.icons:draw(ren, item.kind, ix, iy, iw, ih) then
				-- 类别图标已画（等比居中）
			else
				local label

				if item.kind == "dir" then label = "DIR"
				elseif item.ext and item.ext ~= "" then label = item.ext:upper():sub(1, 4)
				else label = "FILE" end
				self:draw_badge(ren, ix + floor(iw * 0.18), iy, floor(iw * 0.64), ih,
					item.kind, label, sel)
			end

			-- 文件名（最多两行）
			local name_w = self.cell_w - pad * 2
			local lines = self.txt.wrap(self.ttf, self.font_path, item.name,
				t.font_name, name_w, 2)
			local ly = iy + ih + 10

			for li, line in ipairs(lines) do
				self.ttf.draw(ren, self.font_path, line, t.font_name,
					x + floor(self.cell_w / 2), ly + (li - 1) * (t.font_name + 4),
					sel and t.text_sel or t.text, "center")
			end

			-- 右下角小字：文件夹给项数做不了（要再扫），这里给类别/大小
			local meta

			if item.dir then
				meta = "文件夹"
			elseif item.kind == "other" then
				meta = fs.human_size(item.size)
			else
				meta = fs.human_size(item.size)
			end
			self.ttf.draw(ren, self.font_path, meta, t.font_small,
				x + self.cell_w - pad, y + self.cell_h - pad - t.font_small,
				sel and t.accent or t.text_dim, "right")
		end
	end
	sdl.clip(ren)

	-- 滚动条：只有真超出时才画
	local total_rows = math.ceil(n / self.cols)

	if total_rows > self.rows then
		local track_x = W - t.padding + 6
		local track_h = self.ah

		sdl.fill(ren, track_x, self.ay, 4, track_h, t.border, 160)
		local h = max(24, floor(track_h * self.rows / total_rows))
		local y = self.ay + floor((track_h - h) * self.row0 /
			max(1, total_rows - self.rows))

		sdl.fill(ren, track_x, y, 4, h, t.accent, 220)
	end
end

return M
