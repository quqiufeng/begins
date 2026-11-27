-- ui/theme.lua — 配色唯一真源：直接用 lite（lua/gui/theme.lua）那套传统色
--
-- 为什么照抄 lite：桌面、阅读器、卡片、终端要看起来是一家。lite 的色系是
-- 8 槽语义色（paper/card/line/ink/text/muted/sel/shadow）+ 一个传统色 accent，
-- 这里一格不改地搬过来，再把桌面自己的名字（bg/panel/card_sel…）映射上去。
-- 默认 moon 月白（lite 的 CARD_DEFAULT）。
--
-- 切色：DESKTOP_THEME=bamboo luajit main.lua（也可以在桌面上按 T 循环）。
-- 未知名回落 moon —— 别静默变黑，宁可回到默认月白。
--
-- 注意：桌面上所有颜色必须从这里取。ui/preview.lua 之类里写死 0xE0644A 的
-- 字面量换色系就露馅（白底浅字看不见），所以 M.use() 会把整张表原地刷新，
-- grid/chrome/preview 拿的都是同一份引用。

local M = {}

-- 8 槽语义色，逐字来自 lite lua/gui/theme.lua 的 M.THEMES（改一处要同步另一处）
M.THEMES = {
	light = { paper = {245, 244, 237}, card = {250, 249, 245}, line = {228, 223, 211}, ink = {27, 54, 93},
		text = {43, 42, 38}, muted = {107, 102, 92}, sel = {241, 239, 230}, shadow = {236, 232, 222},
		stone = {154, 148, 138}, accent = {27, 54, 93} },
	sepia = { paper = {245, 236, 217}, card = {250, 244, 230}, line = {216, 203, 174}, ink = {90, 58, 30},
		text = {60, 50, 35}, muted = {140, 120, 90}, sel = {240, 231, 211}, shadow = {230, 218, 193},
		accent = {156, 83, 51} },
	amber = { paper = {239, 228, 196}, card = {246, 238, 216}, line = {214, 200, 166}, ink = {122, 82, 45},
		text = {58, 48, 34}, muted = {140, 122, 92}, sel = {233, 220, 186}, shadow = {222, 209, 178},
		accent = {161, 110, 26} },
	mist = { paper = {220, 232, 213}, card = {234, 242, 229}, line = {190, 208, 182}, ink = {47, 93, 58},
		text = {46, 58, 46}, muted = {104, 122, 102}, sel = {212, 226, 205}, shadow = {200, 216, 193},
		accent = {5, 119, 72} },
	china = { paper = {226, 240, 203}, card = {243, 248, 232}, line = {196, 214, 166}, ink = {42, 60, 92},
		text = {29, 27, 28}, muted = {91, 107, 79}, sel = {231, 240, 214}, shadow = {185, 203, 160},
		accent = {22, 133, 169} },
	moon = { paper = {242, 246, 247}, card = {251, 253, 253}, line = {216, 226, 230}, ink = {35, 64, 92},
		text = {36, 49, 59}, muted = {110, 127, 138}, sel = {232, 240, 243}, shadow = {220, 230, 234},
		accent = {46, 78, 126} },
	bamboo = { paper = {241, 245, 236}, card = {250, 252, 246}, line = {204, 217, 191}, ink = {47, 93, 58},
		text = {37, 48, 39}, muted = {110, 128, 104}, sel = {227, 236, 216}, shadow = {220, 231, 208},
		accent = {120, 146, 98} },
	lotus = { paper = {247, 240, 241}, card = {252, 247, 248}, line = {229, 210, 214}, ink = {110, 59, 78},
		text = {58, 43, 48}, muted = {138, 111, 120}, sel = {240, 226, 230}, shadow = {232, 214, 219},
		accent = {140, 67, 86} },
	ochre = { paper = {246, 239, 230}, card = {251, 246, 238}, line = {226, 208, 184}, ink = {122, 74, 43},
		text = {59, 46, 36}, muted = {142, 114, 92}, sel = {239, 227, 210}, shadow = {230, 213, 194},
		accent = {156, 83, 51} },
	indigo = { paper = {238, 242, 246}, card = {248, 250, 252}, line = {203, 214, 224}, ink = {42, 60, 92},
		text = {31, 42, 54}, muted = {100, 115, 131}, sel = {224, 232, 240}, shadow = {214, 224, 232},
		accent = {46, 78, 126} },
	cinnabar = { paper = {248, 241, 238}, card = {253, 248, 246}, line = {232, 210, 202}, ink = {140, 47, 38},
		text = {58, 42, 38}, muted = {139, 106, 96}, sel = {241, 224, 219}, shadow = {234, 216, 210},
		accent = {195, 39, 43} },
	dark = { paper = {28, 28, 30}, card = {38, 38, 40}, line = {70, 70, 74}, ink = {160, 190, 230},
		text = {220, 220, 220}, muted = {150, 150, 150}, sel = {52, 52, 56}, shadow = {20, 20, 22},
		accent = {160, 190, 230} },
}

M.ORDER = { "moon", "light", "bamboo", "china", "sepia", "amber",
	"mist", "ochre", "lotus", "indigo", "cinnabar", "dark" }
M.NAMES = { light = "浅色", moon = "月白", bamboo = "竹青", china = "霜地", sepia = "护眼",
	amber = "羊皮纸", mist = "雾松绿", ochre = "赭石", lotus = "藕荷",
	indigo = "黛蓝", cinnabar = "朱砂", dark = "深色" }
M.DEFAULT = "moon"

-- ---------- 小工具 ----------

local function rgb(c) return c[1] * 65536 + c[2] * 256 + c[3] end

-- a、b 两色按 t（0=a 1=b）线性混
local function mix(a, b, t)
	return rgb({
		math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
		math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
		math.floor(a[3] + (b[3] - a[3]) * t + 0.5),
	})
end

local function lum(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end

-- 类别色：lite 的 SERIES（朱砂/赭石/缃色/竹青/石青/藏青/绛紫/石）。
-- 亮底和暗底各一套：同一族色在暗底上要提亮，否则卡片上的图标糊成一团。
local KIND_LIGHT = {
	dir = {200, 150, 45},   -- 缃色·深
	ebook = {46, 78, 126},  -- 藏青
	video = {195, 39, 43},  -- 朱砂
	audio = {5, 119, 72},   -- 松花绿
	image = {140, 67, 86},  -- 绛紫
	browser = {29, 116, 145}, -- 靛青
	nas = {37, 99, 130},     -- 石青（网络存储）
	host = {110, 88, 60},    -- 赭石（本机）
	wechat = {52, 145, 82},   -- 微信绿
	other = {154, 148, 138}, -- 石
}

local KIND_DARK = {
	dir = {240, 192, 96},
	ebook = {111, 168, 245},
	video = {224, 100, 74},
	audio = {84, 192, 138},
	image = {176, 127, 224},
	browser = {116, 194, 228},
	nas = {120, 190, 226},
	host = {214, 176, 126},
	wechat = {110, 205, 145},
	other = {139, 152, 165},
}

-- 状态色（reader/lite 的亮暗两套）
local STATUS_LIGHT = { ok = {45, 110, 75}, warn = {168, 62, 55}, err = {168, 62, 55} }
local STATUS_DARK = { ok = {126, 200, 140}, warn = {230, 118, 118}, err = {230, 118, 118} }

-- ---------- 尺寸 / 字号（换肤不动版式） ----------

M.top_bar_h = 64
M.bottom_bar_h = 50
M.gap = 14
M.padding = 26

-- 字号整体放宽一档（盒子离沙发远，原来的 18/14 太细）；改这里会连带顶栏、
-- 底栏、网格卡片的排布，grid:layout 里 cell_h 的下限和它配套，改要一起看。
M.font_title = 30
M.font_path = 24
M.font_name = 22
M.font_small = 16
M.font_badge = 15

-- 上面是 720p 基准；大屏按高度再放大一档（1920x1080 的电视上 22px 名字太小）。
-- 幂等：每次都以 BASE 为底乘 k，重复调用不会越放越大。
local BASE = {
	font_title = M.font_title, font_path = M.font_path, font_name = M.font_name,
	font_small = M.font_small, font_badge = M.font_badge,
	top_bar_h = M.top_bar_h, bottom_bar_h = M.bottom_bar_h,
}

-- 屏幕高 → 默认字号档（用户没自己定过就吃这套）
local function auto_scale(h)
	if h >= 2000 then return 1.7
	elseif h >= 1400 then return 1.45
	elseif h >= 1000 then return 1.25
	elseif h >= 800 then return 1.08 end
	return 1
end

-- 以 BASE 为底乘 k（幂等：重复调用不会越放越大）
function M.apply_scale(k)
	for key, v in pairs(BASE) do M[key] = math.floor(v * k + 0.5) end
	M.font_scale = k
	return k
end

function M.fit(h)
	h = tonumber(h) or M.view_h or 720
	M.view_h = h
	M.auto_scale = auto_scale(h)
	-- 用户自己定过（遥控器 C-4/C-5 或 DESKTOP_FONT_SCALE）就听用户的，
	-- 否则按窗口高推。拉窗口跨过档位时也走这里，所以已定的值不会被冲掉。
	return M.apply_scale(M.user_scale or M.auto_scale)
end

-- 手动定字号：C-4/C-5 每按一次 ±10%，落盘记住
local SCALE_MIN, SCALE_MAX = 0.8, 2.2

function M.set_scale(k, nosave)
	k = math.floor((tonumber(k) or 1) * 100 + 0.5) / 100
	if k < SCALE_MIN then k = SCALE_MIN end
	if k > SCALE_MAX then k = SCALE_MAX end
	M.user_scale = k
	M.apply_scale(k)
	if not nosave then M.save() end
	return k
end

function M.step_scale(d)
	return M.set_scale((M.font_scale or 1) + (d or 0.1))
end

-- 回到按屏幕高自动算的档（调试/写错值时的出口）
function M.reset_scale()
	M.user_scale = nil
	M.apply_scale(M.auto_scale or auto_scale(M.view_h or 720))
	M.save()
	return M.font_scale
end

-- ---------- 选色系（原地刷新整张表） ----------

-- 把 name 的 8 槽色翻译成桌面自己的键。全部写进 M 本身（不是副本），
-- 这样已经持有 M 引用的 grid/chrome/preview 立刻跟着变。
function M.use(name)
	local p = M.THEMES[name or ""]

	if not p then p, name = M.THEMES[M.DEFAULT], M.DEFAULT end

	local dark = lum(p.paper) < 128
	local status = dark and STATUS_DARK or STATUS_LIGHT
	local kind = dark and KIND_DARK or KIND_LIGHT

	M.name = name
	M.label = M.NAMES[name] or name
	M.dark = dark
	M.paper, M.card, M.line = rgb(p.paper), rgb(p.card), rgb(p.line)
	M.ink, M.text, M.muted = rgb(p.ink), rgb(p.text), rgb(p.muted)
	M.sel, M.shadow = rgb(p.sel), rgb(p.shadow)
	M.accent = rgb(p.accent)

	-- 桌面语义
	M.bg = M.paper
	M.panel = M.card
	M.panel_alt = M.sel
	M.card_bg = M.card
	M.card_sel = M.sel
	M.border = M.line
	M.border_sel = M.accent
	M.text_dim = M.muted
	M.text_sel = M.ink
	M.accent_dim = mix(p.accent, p.paper, 0.55)
	M.bar = dark and M.shadow or M.sel
	M.ok = rgb(status.ok)
	M.warn = rgb(status.warn)
	-- 图片预览的幕布：亮底用 paper 压到接近不透明（像展厅白墙），
	-- 暗底压成近黑。alpha 由 preview 决定。
	M.scrim = M.paper

	M.kind_color = {}

	for k, c in pairs(kind) do M.kind_color[k] = rgb(c) end
	return M
end

-- 循环下一个色系（遥控/键盘 T）
function M.cycle(step)
	local cur = 1

	for i, n in ipairs(M.ORDER) do
		if n == M.name then cur = i; break end
	end
	step = step or 1
	local n = M.ORDER[(cur - 1 + step) % #M.ORDER + 1]

	M.use(n)
	M.save(n)		-- 记下来：下次启动还是这套
	return n
end

-- 随机换一套色系，但绝不给当前这套（MENU 刷新时用；连按两次保证看着有变化）
function M.random()
	local n = #M.ORDER

	if n <= 1 then
		M.use(M.ORDER[1] or M.DEFAULT)
		M.save()
		return M.name
	end

	local cur = 0

	for i, name in ipairs(M.ORDER) do
		if name == M.name then cur = i; break end
	end
	-- 在 n-1 个候选中抽，跳过 cur，映射回真实下标
	local i = math.random(n - 1)

	if cur > 0 and i >= cur then i = i + 1 end
	M.use(M.ORDER[i] or M.DEFAULT)
	M.save()
	return M.name
end

M.mix = mix

-- ---------- 记住用户选的色系 + 字号（一份 theme.json） ----------
-- 以前只落盘一行色系名（<state>/theme），字号是 fit(窗口高) 现推的，用户按了
-- 也留不住。现在一份 json 全记下来：
--   {"theme":"moon","font_scale":1.45,"font":{"font_name":32,…},"auto_scale":1.45,"updated":"…"}
-- 读取优先级：env（DESKTOP_THEME / DESKTOP_FONT_SCALE）> json 落盘值 > 默认 moon / 按屏高推。
-- 兼容旧的纯文本 theme 文件（整份就是一行色系名），读到就当色系名用，下次保存自动迁成 json。
local json = require("util.json")

local function state_dir()
	local d = os.getenv("DESKTOP_STATE_DIR")
		or ((os.getenv("HOME") or "/root") .. "/.config/desktop")

	return d
end

function M.file()
	return os.getenv("DESKTOP_THEME_FILE") or (state_dir() .. "/theme.json")
end

-- 读落盘状态：返回 {theme=…, font_scale=…, …}，没有/坏了都返回 nil（别让坏文件拦住启动）
function M.load()
	local f = io.open(M.file(), "rb")

	if not f then
		-- 迁移旧格式：老版本只写 <state>/theme（一行色系名）。theme.json 还没
		-- 生成时读它一次，用户之前选的色系不至于丢（下次 save 就写成 json 了）。
		local old = state_dir() .. "/theme"

		if old ~= M.file() then f = io.open(old, "rb") end
	end
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	if not s or s == "" then return nil end

	local ok, t = pcall(json.decode, s)

	if ok and type(t) == "table" then return t end
	-- 旧格式：整份文件就是一行色系名（"moon\n"），json 解不出来就走这条
	local name = s:gsub("%s+$", "")

	if M.THEMES[name] then return { theme = name } end
	return nil
end

-- 写落盘状态。色系取当前 M.name，字号取 M.font_scale；font 明细一起写，
-- 是为了 cat 一眼能看出「这套设置实际是多少 px」，读的时候只用 font_scale 重算。
function M.save(name)
	local p = M.file()
	local f = io.open(p, "w")

	if not f then
		-- 目录可能还不存在：建一次再写（失败就算了，下次启动只是回默认）。
		-- 建的是 p 自己的目录，不是 state_dir()：DESKTOP_THEME_FILE 可能指到别处，
		-- 早先按 state_dir() 建目录，指到别处时永远写不进去。
		local dir = p:match("^(.*)/[^/]+$")

		if dir then os.execute(("mkdir -p '%s' 2>/dev/null"):format(dir)) end
		f = io.open(p, "w")
		if not f then return false end
	end

	local font = {}

	for k, v in pairs(BASE) do font[k] = M[k] or v end

	local st = {
		theme = name or M.name or M.DEFAULT,
		font_scale = M.font_scale or 1,
		auto_scale = M.auto_scale or M.font_scale or 1,
		font = font,
	}

	if M.user_scale then st.user_scale = M.user_scale end
	st.updated = os.date("%Y-%m-%dT%H:%M:%S")

	f:write(json.encode(st), "\n")
	f:close()
	return true
end

-- 载入时定色系 / 字号：env > json > 默认
M.stored = M.load() or {}

local function pick_theme()
	local env = os.getenv("DESKTOP_THEME")

	if env and M.THEMES[env] then return env end
	local st = M.stored.theme

	if st and M.THEMES[st] then return st end
	return M.DEFAULT
end

M.use(pick_theme())

-- 字号只记 k，具体 px 等 window 起来后 fit(win.H) 以 BASE 重算（幂等）
do
	local env = tonumber(os.getenv("DESKTOP_FONT_SCALE") or "")
	local st = tonumber(M.stored.user_scale) or tonumber(M.stored.font_scale)

	if env then M.user_scale = math.floor(env * 100 + 0.5) / 100
	elseif st then M.user_scale = math.floor(st * 100 + 0.5) / 100 end
end

return M
