-- 打开新书：非阻塞系统文件对话框 + 结果轮询。
local M = {}
M.__index = M

function M.new(ctx)
    return setmetatable({ ctx = ctx, pending = nil }, M)
end

function M:choose()
    local ctx = self.ctx
    local v = ctx.v
    if v.dialog then return end

    local cmd
    if os.execute("command -v zenity >/dev/null 2>&1") == 0 then
        cmd = string.format('zenity --file-selection --title=%q --filename=%q',
            "选择电子书", (v.last_browse_dir or ctx.home) .. "/")
    elseif os.execute("command -v kdialog >/dev/null 2>&1") == 0 then
        cmd = string.format('kdialog --getopenfilename %q', v.last_browse_dir or ctx.home)
    else
        ctx.open_browser()
        return
    end

    local out = os.tmpname()
    local done = out .. ".done"
    os.remove(out)
    os.remove(done)
    os.execute(string.format(
        "( timeout 300 %s > %q 2>/dev/null; : > %q ) &", cmd, out, done))
    v.dialog = { out = out, done = done, started = ctx.now() }
    ctx.show_toast("请选择电子书…", 2)
end

-- 返回 true 表示需要重绘。
function M:poll(now)
    local ctx = self.ctx
    local v = ctx.v
    if not v.dialog then return false end

    local df = io.open(v.dialog.done, "rb")
    if df then
        df:close()
        local pf = io.open(v.dialog.out, "rb")
        local chosen = pf and pf:read("*l") or nil
        if pf then pf:close() end
        os.remove(v.dialog.out)
        os.remove(v.dialog.done)
        v.dialog = nil
        if chosen and chosen ~= "" then
            local ok, err = ctx.open_book(chosen, nil)
            if not ok then
                print("open failed: " .. tostring(err))
                ctx.show_toast("打开失败：" .. tostring(err), 3)
            end
        end
        return true
    end

    if now >= (v.dialog.started or now) + 310 then
        os.remove(v.dialog.out)
        os.remove(v.dialog.done)
        v.dialog = nil
        return true
    end
    return false
end

return M
