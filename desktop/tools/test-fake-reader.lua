-- tools/test-fake-reader.lua — 测试用假 reader：实现同一套 automation 协议
package.path = "./?.lua;" .. package.path
local automation = require("core.automation")
local a = assert(automation.start(os.getenv("FAKE_SOCK") or "/tmp/fake-reader.sock", {
	state = function()
		return { library = false, book = "三体", page = 68, pages = 534,
			chapter = 3, font_size = 26 }
	end,
	call = function(fn, args)
		return { ok = true, fn = fn, page = (tonumber(args.page) or 68) + 1 }
	end,
	click = function(id) return { ok = true, id = id } end,
	key = function(n) return { ok = true, name = n } end,
}))
local t = os.time()
while os.time() - t < (tonumber(os.getenv("FAKE_SECS") or "20")) do a:poll() end
a:close()
