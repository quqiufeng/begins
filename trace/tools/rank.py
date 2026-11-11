#!/usr/bin/env python3
"""折叠栈 -> 卡点排行榜：按自身/包含/命中排序，顶部一句话说清卡在哪
输入：lite trace_engine --json 的 top[]/folded[]（与 flame.py / heat.py 同一套归一）
用法：rank.py in.json out.svg|out.png "标题" [topN] [sortkey]
      sortkey = self(默认,自身权重) | incl(含下游) | count(命中高者优先)
      .svg 纯标准库，悬停行出明细；.png 走 PIL（没有就退回同名 .svg）
坑：top[] 受 --limit 控制，默认只留 40 条，结论会如实标出覆盖率
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from flame import load, CJK          # 归一化规则必须和火焰图一致
from heat import agg, fmt, clip, esc

PAD = 16
ROW = 27
TOPH = 168
NAME_W = 250
BAR_W = 300
W = 940
X_TAG, X_NAME = PAD + 30, PAD + 100
X_BAR = X_NAME + NAME_W
X_SELF = X_BAR + BAR_W + 46
X_INCL = X_BAR + BAR_W + 104
X_HIT  = X_BAR + BAR_W + 158
X_CUM  = X_BAR + BAR_W + 212

SELF_C = (47, 111, 178)
INCL_C = (219, 228, 238)


def fit(t, px, fs):
    """按估算宽度裁字：ASCII 约 0.55em，CJK 1em"""
    w, out = 0.0, []
    for ch in t:
        cw = fs if ord(ch) > 0x2E80 else fs * 0.55
        if w + cw > px:
            return "".join(out) + "…"
        w += cw
        out.append(ch)
    return t


def num(v, unit_ms):
    """ms 值超过 1s 就换秒，否则「4430ms」会把命中列挤爆"""
    if unit_ms and v >= 1000:
        return "%.1fs" % (v / 1000.0)
    return fmt(v, unit_ms)


def stacks_of(folded):
    """每个函数出现在多少种不同调用栈里"""
    c = {}
    for frames in folded:
        for f in set(frames):
            c[f] = c.get(f, 0) + 1
    return c


def stats(j, folded):
    unit_ms, self_w, incl_w, edges = agg(j, folded)
    tot = sum(self_w.values()) or 1
    return unit_ms, self_w, incl_w, edges, tot, stacks_of(folded)


def coverage(j, tot):
    """已采总量 vs 列出的折叠栈总量：--limit 会截断，结论必须说清覆盖多少"""
    got = j.get("blocked") if j.get("unit") == "ms" else j.get("events")
    got = got or tot
    return got, (100.0 * tot / got if got else 100.0)


def trail(folded):
    """最重的那条栈 = 权重真正堆住的完整路径"""
    if not folded:
        return [], 0
    frames, w = max(folded.items(), key=lambda kv: kv[1])
    return list(frames), w


def verdict(j, unit_ms, self_w, incl_w, tot, folded):
    top_self, vself = (max(self_w.items(), key=lambda kv: kv[1]) if self_w else ("-", 1))
    top_incl, vincl = (max(incl_w.items(), key=lambda kv: kv[1]) if incl_w else ("-", 1))
    got, cov = coverage(j, tot)
    u = "" if unit_ms else " 样本"
    head = "最热卡点 %s：自身 %s%s，占已列栈 %.1f%%" % (
        fit(top_self, 330, 13.5), num(vself, unit_ms), u, 100.0 * vself / tot)
    if top_incl != top_self and (vincl - self_w.get(top_incl, 0)) > 0.12 * tot:
        if vincl > 0.85 * tot and self_w.get(top_incl, 0) < 0.10 * tot:
            head += "；%s 吃掉 %.0f%% 的包含权重但自身极少——它是全栈共同入口，不是热点" % (
                fit(top_incl, 190, 13.5), 100.0 * vincl / tot)
        else:
            head += "；%s 含下游 %s，重心在它下面" % (
                fit(top_incl, 210, 13.5), num(vincl, unit_ms))
    return head, 100.0 * vself / tot, trail(folded), top_self, got, cov


def tag_of(f, self_w, incl_w):
    s, i = self_w.get(f, 0), incl_w.get(f, 0) or 1
    r = s / i
    if r >= 0.5:
        return "自热", (178, 24, 43)
    if r <= 0.02:
        return "纯转发", (150, 150, 150)
    return "混合", (63, 124, 181)


def rows_of(self_w, incl_w, stk, sortkey, topn):
    if sortkey == "count":
        pool = sorted(stk.items(), key=lambda kv: (-self_w.get(kv[0], 0), -kv[1]))
        keys = [f for f, _ in pool if self_w.get(f, 0) > 0]
        if len(keys) < topn:
            rest = sorted(self_w, key=lambda x: -self_w[x])
            keys += [f for f in rest if f not in set(keys)]
        return keys[:topn]
    key = (lambda f: -incl_w.get(f, 0)) if sortkey == "incl" else (lambda f: -self_w.get(f, 0))
    return sorted(self_w.keys(), key=key)[:topn]


def geom(n):
    return TOPH + 26 + max(1, n) * ROW + 54


def subtitle(sortkey, n, tot, unit_ms):
    return "排序 = %s · %d 个函数 · 已列权重 %s · 深色条=自身，浅色条=含下游" % (
        {"self": "自身权重", "incl": "含下游", "count": "命中次数"}[sortkey],
        n, num(tot, unit_ms))


def notes(j, folded, cov, got, unit_ms):
    """底部提示：数据被截断 / 大量未符号化，这两个不说清结论就是错的"""
    out = []
    if cov < 99.5:
        out.append("top[] 只收 %s / 共 %s（--limit 截断，覆盖 %.0f%%），调大 --limit 再排更准"
                   % (num(got * cov / 100.0, unit_ms), num(got, unit_ms), cov))
    n = sum(len(f) for f in folded) or 1
    raw = sum(1 for f in folded for x in f if "+0x" in x or x.startswith("0x"))
    if raw * 2 > n:
        out.append("超半数帧是裸偏移（无符号），加 --sym 或给 pid 对应 ELF 才能看出函数名")
    return out


def svg(j, folded, topn, sortkey, title, out):
    unit_ms, self_w, incl_w, edges, tot, stk = stats(j, folded)
    rows = rows_of(self_w, incl_w, stk, sortkey, topn)
    H = geom(len(rows))
    head, share, (path, _), topf, got, cov = verdict(j, unit_ms, self_w, incl_w, tot, folded)
    mx = max([incl_w.get(r, 0) for r in rows] or [1]) or 1
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="Noto Sans CJK SC, DejaVu Sans Mono, monospace">' % (W, H, W, H),
         '<style>text{dominant-baseline:middle}.row:hover{opacity:.82}</style>',
         '<rect width="%d" height="%d" fill="#fff"/>' % (W, H),
         '<text x="%d" y="30" font-size="21" fill="#161616">%s</text>' % (PAD, esc(title)),
         '<text x="%d" y="58" font-size="12.5" fill="#5c5c5c">%s</text>'
         % (PAD, esc(subtitle(sortkey, len(incl_w), tot, unit_ms)))]

    s.append('<rect x="%d" y="76" width="%d" height="62" rx="4" fill="#f4f7fb" stroke="#dbe4ee"/>'
             % (PAD, W - 2 * PAD))
    s.append('<rect x="%d" y="76" width="5" height="62" fill="#b2182b"/>' % PAD)
    s.append('<text x="%d" y="99" font-size="13.5" fill="#1f3d5c">%s</text>' % (PAD + 16, esc(head)))
    chain = "  ->  ".join(path[-6:]) if path else "-"
    s.append('<text x="%d" y="121" font-size="12" fill="#4a4a4a">卡点链：%s</text>'
             % (PAD + 16, esc(fit(chain, W - 2 * PAD - 90, 12))))

    hy = TOPH + 14
    for x, t, anch in ((X_TAG, "结论", "start"), (X_NAME, "函数", "start"),
                       (X_BAR, "相对权重", "start"), (X_SELF, "自身%", "end"),
                       (X_INCL, "包含%", "end"), (X_HIT, "命中", "end"), (X_CUM, "累计%", "end")):
        s.append('<text x="%d" y="%d" font-size="11.5" fill="#6b7280" text-anchor="%s">%s</text>'
                 % (x, hy, anch, t))
    s.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#e2e6ec"/>'
             % (PAD, hy + 10, W - PAD, hy + 10))

    y0, cum = TOPH + 26, 0.0
    for i, f in enumerate(rows):
        yy = y0 + i * ROW
        sw, iw = self_w.get(f, 0), incl_w.get(f, 0)
        pct_s, pct_i = 100.0 * sw / tot, 100.0 * iw / tot
        cum += pct_s
        tw, swd = max(2.0, BAR_W * iw / mx), max(2.0, BAR_W * sw / mx)
        tg, tc = tag_of(f, self_w, incl_w)
        s.append('<g class="row"><title>%s&#10;自身 %s（%.1f%%）  包含 %s（%.1f%%）'
                 '&#10;累计 %.1f%%  出现在 %d 种栈里</title>'
                 % (esc(f), num(sw, unit_ms), pct_s, num(iw, unit_ms), pct_i,
                    cum, stk.get(f, 0)))
        s.append('<rect x="%d" y="%.1f" width="%d" height="%d" fill="transparent"/>'
                 % (PAD, yy - 4, W - 2 * PAD, ROW - 4))
        s.append('<text x="%d" y="%.1f" font-size="11" fill="#9aa3ae">%d</text>' % (PAD, yy + 8, i + 1))
        s.append('<text x="%d" y="%.1f" font-size="10.5" fill="#%02x%02x%02x">%s</text>'
                 % (X_TAG, yy + 8, tc[0], tc[1], tc[2], tg))
        s.append('<text x="%d" y="%.1f" font-size="11.5" fill="#22262b">%s</text>'
                 % (X_NAME, yy + 8, esc(fit(f, NAME_W - 10, 11.5))))
        s.append('<rect x="%d" y="%.1f" width="%.1f" height="13" rx="2" fill="rgb(219,228,238)"/>'
                 % (X_BAR, yy + 1, tw))
        s.append('<rect x="%d" y="%.1f" width="%.1f" height="13" rx="2" fill="rgb(47,111,178)"/>'
                 % (X_BAR, yy + 1, swd))
        s.append('<text x="%d" y="%.1f" font-size="11.5" fill="#1f2937" text-anchor="end" '
                 'font-weight="600">%.1f%%</text>' % (X_SELF, yy + 8, pct_s))
        it = "·" if abs(pct_i - pct_s) < 0.05 else "%.1f%%" % pct_i
        s.append('<text x="%d" y="%.1f" font-size="11" fill="%s" text-anchor="end">%s</text>'
                 % (X_INCL, yy + 8, "#c8ced6" if it == "·" else "#6b7280", it))
        s.append('<text x="%d" y="%.1f" font-size="11" fill="#4b5563" text-anchor="end">%s</text>'
                 % (X_HIT, yy + 8, num(sw, unit_ms)))
        s.append('<text x="%d" y="%.1f" font-size="11" fill="#9aa3ae" text-anchor="end">%.1f%%</text>'
                 % (X_CUM, yy + 8, cum))
        s.append('</g>')

    for k, t in enumerate(notes(j, folded, cov, got, unit_ms)):
        s.append('<text x="%d" y="%d" font-size="10.5" fill="#b2182b">%s</text>'
                 % (PAD, H - 40 + k * 15 - (0 if len(notes(j, folded, cov, got, unit_ms)) > 1 else 14),
                    esc(fit(t, W - 2 * PAD, 10.5))))
    s.append('<text x="%d" y="%d" font-size="11" fill="#8a8f98">trace_engine · 自身=采样点落在此函数，'
             '包含=含下游 · 采样模式命中=样本数或毫秒，folded 模式=真实调用次数</text>' % (PAD, H - 16))
    s.append('</svg>')
    open(out, "w", encoding="utf-8").write("\n".join(s))
    return out


def png(j, folded, topn, sortkey, title, out):
    from PIL import Image, ImageDraw, ImageFont
    unit_ms, self_w, incl_w, edges, tot, stk = stats(j, folded)
    rows = rows_of(self_w, incl_w, stk, sortkey, topn)
    H = geom(len(rows))
    head, share, (path, _), topf, got, cov = verdict(j, unit_ms, self_w, incl_w, tot, folded)
    mx = max([incl_w.get(r, 0) for r in rows] or [1]) or 1
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    try:
        f_t = ImageFont.truetype(CJK, 21, index=1)
        f_s = ImageFont.truetype(CJK, 12.5, index=1)
        f_n = ImageFont.truetype(CJK, 11.5, index=1)
        f_b = ImageFont.truetype(CJK, 12.5, index=1)
    except Exception:
        f_t = f_s = f_n = f_b = ImageFont.load_default()

    def rt(x, y, t, font, fill, anchor_right=False):
        d.text((x - d.textlength(t, font=font) if anchor_right else x, y), t, font=font, fill=fill)

    rt(PAD, 18, title, f_t, (22, 22, 22))
    rt(PAD, 50, subtitle(sortkey, len(incl_w), tot, unit_ms), f_s, (92, 92, 92))

    d.rounded_rectangle([PAD, 76, W - PAD, 138], 4, fill=(244, 247, 251), outline=(219, 228, 238))
    d.rectangle([PAD, 76, PAD + 5, 138], fill=(178, 24, 43))
    rt(PAD + 16, 92, head, f_b, (31, 61, 92))
    chain = "  ->  ".join(path[-6:]) if path else "-"
    rt(PAD + 16, 113, fit("卡点链：" + chain, W - 2 * PAD - 40, 12.5), f_s, (74, 74, 74))

    hy = TOPH + 8
    for x, t, right in ((X_TAG, "结论", False), (X_NAME, "函数", False), (X_BAR, "相对权重", False),
                        (X_SELF, "自身%", True), (X_INCL, "包含%", True),
                        (X_HIT, "命中", True), (X_CUM, "累计%", True)):
        rt(x, hy, t, f_n, (107, 114, 128), right)
    d.line([PAD, hy + 20, W - PAD, hy + 20], fill=(226, 230, 236))

    y0, cum = TOPH + 26, 0.0
    for i, f in enumerate(rows):
        yy = y0 + i * ROW
        sw, iw = self_w.get(f, 0), incl_w.get(f, 0)
        pct_s, pct_i = 100.0 * sw / tot, 100.0 * iw / tot
        cum += pct_s
        tw, swd = max(2.0, BAR_W * iw / mx), max(2.0, BAR_W * sw / mx)
        tg, tc = tag_of(f, self_w, incl_w)
        if i % 2 == 1:
            d.rectangle([PAD - 4, yy - 4, W - PAD + 4, yy + ROW - 8], fill=(250, 251, 252))
        rt(PAD, yy, str(i + 1), f_n, (154, 163, 174))
        rt(X_TAG, yy, tg, f_n, tc)
        rt(X_NAME, yy, fit(f, NAME_W - 10, 11.5), f_n, (34, 38, 43))
        d.rectangle([X_BAR, yy + 1, X_BAR + tw, yy + 14], fill=INCL_C)
        d.rectangle([X_BAR, yy + 1, X_BAR + swd, yy + 14], fill=SELF_C)
        rt(X_SELF, yy, "%.1f%%" % pct_s, f_b, (31, 41, 55), True)
        same = abs(pct_i - pct_s) < 0.05
        rt(X_INCL, yy, "·" if same else "%.1f%%" % pct_i, f_n,
           (200, 206, 214) if same else (107, 114, 128), True)
        rt(X_HIT, yy, num(sw, unit_ms), f_n, (75, 85, 99), True)
        rt(X_CUM, yy, "%.1f%%" % cum, f_n, (154, 163, 174), True)

    ns = notes(j, folded, cov, got, unit_ms)
    for k, t in enumerate(ns):
        rt(PAD, H - 40 - (len(ns) - 1 - k) * 15, fit(t, W - 2 * PAD, 11.5), f_n, (178, 24, 43))
    rt(PAD, H - 18, "trace_engine · 自身=采样点落在此函数，包含=含下游 · 采样模式命中=样本数或毫秒，"
       "folded 模式=真实调用次数 · 包含列的 · 表示该函数全是叶子帧", f_n, (138, 143, 152))
    img.save(out)
    return out


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__)
        return 2
    src, out = a[0], a[1]
    title = a[2] if len(a) > 2 else "卡点排行"
    topn = int(a[3]) if len(a) > 3 else 18
    sortkey = a[4] if len(a) > 4 else "self"
    if sortkey not in ("self", "incl", "count"):
        sortkey = "self"
    j, folded = load(src)
    if not folded:
        print("没有栈数据")
        return 1
    if out.lower().endswith(".svg"):
        svg(j, folded, topn, sortkey, title, out)
    else:
        try:
            png(j, folded, topn, sortkey, title, out)
        except ImportError:
            out = out.rsplit(".", 1)[0] + ".svg"
            svg(j, folded, topn, sortkey, title, out)
            print("[rank] 没有 PIL，改出 SVG")
    print("[rank] %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
