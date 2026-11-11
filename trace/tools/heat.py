#!/usr/bin/env python3
"""折叠栈 -> 函数调用热力图（行=调用者，列=被调用者，颜色=调用边的时间/样本权重）
输入：lite trace_engine --json 的 top[]/folded[]，与 flame.py 同一套归一（复用 load/scrub）
用法：heat.py in.json out.svg|out.png "标题" [topN]
      .svg 纯标准库，悬停看数值并高亮同行同列；.png 走 PIL（没有就退回同名 .svg）
"""
import json, os, sys, math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from flame import load, CJK   # 归一化规则必须和火焰图一致

CELL = 26
RANK_W = 400
NAME_W = 300
PAD = 14
HEAD = 96
TOPEDGE = 8

def agg(j, folded):
    """folded: {(root..leaf)} -> w。产出 self/incl/edges 三张表"""
    unit_ms = j.get("unit") == "ms"
    self_w, incl_w, edges = {}, {}, {}
    for frames, w in folded.items():
        if not frames:
            continue
        self_w[frames[-1]] = self_w.get(frames[-1], 0) + w
        for f in set(frames):
            incl_w[f] = incl_w.get(f, 0) + w
        seen = set()                   # 同一栈里的递归对只算一次，避免自乘
        for a, b in zip(frames, frames[1:]):
            if (a, b) in seen:
                continue
            seen.add((a, b))
            edges[(a, b)] = edges.get((a, b), 0) + w
    return unit_ms, self_w, incl_w, edges

def fmt(v, unit_ms):
    if unit_ms:
        return ("%.1fms" % v) if v < 10 else ("%dms" % round(v))
    return "%.0f" % round(v)

def short(v):
    if v >= 1e6:  return "%.1fm" % (v / 1e6)
    if v >= 1e4:  return "%.0fk" % (v / 1e3)
    if v >= 1e3:  return "%.1fk" % (v / 1e3)
    return "%.0f" % v

STOPS = [(251, 250, 246), (254, 224, 144), (253, 174, 97), (244, 109, 67), (178, 24, 43)]

def heat(t):
    """t in [0,1] -> OrRd 顺序色"""
    t = max(0.0, min(1.0, t))
    x = t * (len(STOPS) - 1)
    i = min(int(x), len(STOPS) - 2)
    f = x - i
    a, b = STOPS[i], STOPS[i + 1]
    return "#%02x%02x%02x" % tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3))

def rgb(hexs):
    return tuple(int(hexs[k:k + 2], 16) for k in (1, 3, 5))

def clip(name, px, font_px):
    """按像素宽度截断（ASCII 约 0.6em/字，CJK 1.0em）"""
    w, out = 0.0, []
    for ch in name:
        cw = font_px * (1.0 if ord(ch) > 0x2E80 else 0.6)
        if w + cw > px:
            out.append("…")
            break
        w += cw
        out.append(ch)
    return "".join(out)

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def geom(rank, edges, topn):
    funcs = [f for f, _ in rank[:topn]]
    N = len(funcs)
    mx = max([edges.get((a, b), 0) for a in funcs for b in funcs] or [1]) or 1
    MW = N * CELL
    W = PAD + RANK_W + 26 + NAME_W + MW + 60
    H = HEAD + 40 + MW + 26 + 15 * TOPEDGE + 40
    return funcs, N, mx, MW, W, H

def svg(unit_ms, self_w, incl_w, edges, topn, title, out):
    rank = sorted(incl_w.items(), key=lambda kv: -kv[1])
    funcs, N, mx, MW, W, H = geom(rank, edges, topn)
    idx = set(funcs)
    tot = sum(incl_w.values()) or 1
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="Noto Sans CJK SC, DejaVu Sans Mono, monospace">' % (W, H, W, H),
         '<style>rect.c:hover{stroke:#111;stroke-width:1.6}'
         'text{dominant-baseline:middle}</style>',
         '<rect width="%d" height="%d" fill="#fff"/>' % (W, H),
         '<text x="%d" y="26" font-size="20" fill="#1a1a1a">%s</text>' % (PAD, esc(title)),
         '<text x="%d" y="52" font-size="12.5" fill="#5a5a5a">%s</text>' % (PAD,
          esc("行 = 调用者，列 = 被调用者，格色 = 该调用边占总权重的比例（log 色阶） · "
             "%d 个函数 · 总权重 %s" % (N, fmt(tot, unit_ms))))]

    # ---- 左：热门函数（浅色=包含权重，深色=自身） ----
    y = HEAD + 6
    s.append('<text x="%d" y="%d" font-size="13" fill="#333">热门函数（按包含权重排名，深色为自身）</text>'
             % (PAD, y - 12))
    bw = RANK_W - 130
    topi = rank[0][1] if rank else 1
    for i, f in enumerate(funcs):
        yy = y + i * (CELL - 4)
        sw, iw = self_w.get(f, 0), incl_w.get(f, 0)
        ww = max(1.0, bw * iw / topi)
        s.append('<rect x="%d" y="%.1f" width="%.1f" height="%d" rx="2" fill="#dfe6ee"/>'
                 % (PAD + 130, yy, ww, CELL - 7))
        if sw > 0:
            s.append('<rect x="%d" y="%.1f" width="%.1f" height="%d" rx="2" fill="#3f7cb5"/>'
                     % (PAD + 130, yy, max(1.0, bw * sw / topi), CELL - 7))
        s.append('<text x="%d" y="%.1f" font-size="11" fill="#2a2a2a" text-anchor="end">%s</text>'
                 % (PAD + 124, yy + (CELL - 7) / 2.0, esc(clip(f, 122, 11))))
        s.append('<text x="%.1f" y="%.1f" font-size="10" fill="#666">%s / %s</text>'
                 % (PAD + 136 + ww, yy + (CELL - 7) / 2.0, short(sw), short(iw)))

    # ---- 右：调用边矩阵 ----
    x0 = PAD + RANK_W + 26 + NAME_W
    y0 = HEAD + 40
    s.append('<text x="%d" y="%d" font-size="13" fill="#333">调用边热力矩阵</text>' % (x0 - NAME_W, y0 - 18))
    for jx, f in enumerate(funcs):     # 列标签旋转
        cx = x0 + jx * CELL + CELL / 2.0 + 2
        s.append('<text x="%.1f" y="%d" font-size="10.5" fill="#333" transform="rotate(-62 %.1f %d)" '
                 'text-anchor="start">%s</text>' % (cx, y0 - 6, cx, y0 - 6, esc(clip(f, 112, 10.5))))
    for iy, f in enumerate(funcs):     # 行标签
        s.append('<text x="%d" y="%.1f" font-size="10.5" fill="#2a2a2a" text-anchor="end">%s</text>'
                 % (x0 - 6, y0 + iy * CELL + CELL / 2.0, esc(clip(f, NAME_W - 10, 10.5))))
    for iy, a in enumerate(funcs):
        for jx, b in enumerate(funcs):
            v = edges.get((a, b), 0)
            diag = (a == b)
            fill = ("#eef1f4" if diag else "#f7f8fa") if v <= 0 else heat(math.log1p(v) / math.log1p(mx))
            s.append('<rect class="c" data-r="%d" data-c="%d" x="%d" y="%d" width="%d" height="%d" '
                     'fill="%s" stroke="#fff" stroke-width="0.8"><title>%s → %s&#10;%s · 占全部 %.2f%%</title></rect>'
                     % (jx, iy, x0 + jx * CELL, y0 + iy * CELL, CELL - 1, CELL - 1, fill,
                        esc(a), esc(b), fmt(v, unit_ms), 100.0 * v / tot))
            if v > 0 and math.log1p(v) / math.log1p(mx) > 0.62:
                s.append('<text x="%.1f" y="%.1f" font-size="8.5" fill="#fff" text-anchor="middle" '
                         'pointer-events="none">%s</text>'
                         % (x0 + jx * CELL + CELL / 2.0, y0 + iy * CELL + CELL / 2.0, short(v)))
    s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#c8ced8"/>'
             % (x0, y0, MW - (N - 1 if N else 0), MW - (N - 1 if N else 0)))

    # ---- 最热调用边 ----
    ly = y0 + MW + 34
    s.append('<text x="%d" y="%d" font-size="13" fill="#333">最热调用边</text>' % (PAD, ly - 12))
    hot = sorted(((a, b, v) for (a, b), v in edges.items() if a in idx and b in idx),
                 key=lambda t: -t[2])[:TOPEDGE]
    for i, (a, b, v) in enumerate(hot):
        yy = ly + i * 15
        s.append('<rect x="%d" y="%d" width="6" height="10" rx="1" fill="%s"/>'
                 % (PAD, yy - 5, heat(math.log1p(v) / math.log1p(mx))))
        s.append('<text x="%d" y="%d" font-size="11" fill="#333">%s  →  %s</text>'
                 % (PAD + 12, yy, esc(clip(a, 150, 11)), esc(clip(b, 150, 11))))
        s.append('<text x="%d" y="%d" font-size="10.5" fill="#666">%s · %.2f%%</text>'
                 % (PAD + 340, yy, fmt(v, unit_ms), 100.0 * v / tot))

    # ---- 图例 ----
    gx, gy, gw = W - 300, H - 46, 200
    for k in range(100):
        s.append('<rect x="%.1f" y="%d" width="%.1f" height="12" fill="%s"/>'
                 % (gx + gw * k / 100.0, gy, gw / 100.0 + 0.4, heat(k / 99.0)))
    s.append('<text x="%d" y="%d" font-size="10" fill="#666">低</text>' % (gx, gy + 26))
    s.append('<text x="%d" y="%d" font-size="10" fill="#666" text-anchor="end">高 %s</text>'
             % (gx + gw, gy + 26, fmt(mx, unit_ms)))
    s.append('<text x="%d" y="%d" font-size="11" fill="#888">trace_engine · 色阶按 log(1+w) 归一</text>'
             % (PAD, H - 22))

    # 悬停：同行同列高亮，其余压暗
    s.append('<script><![CDATA['
             'var cs=[].slice.call(document.querySelectorAll("rect.c"));'
             'document.addEventListener("mouseover",function(e){var t=e.target;'
             'if(!t.getAttribute)return;var r=t.getAttribute("data-r");'
             'if(r===null||r===undefined)return;var c=t.getAttribute("data-c");'
             'cs.forEach(function(x){x.setAttribute("opacity",'
             '(x.getAttribute("data-r")===r||x.getAttribute("data-c")===c)?"1":"0.25")})});'
             'document.addEventListener("mouseout",function(){'
             'cs.forEach(function(x){x.setAttribute("opacity","1")})});'
             ']]></script>')
    s.append('</svg>')
    open(out, "w", encoding="utf-8").write("\n".join(s))
    return out

def png(unit_ms, self_w, incl_w, edges, topn, title, out):
    from PIL import Image, ImageDraw, ImageFont
    rank = sorted(incl_w.items(), key=lambda kv: -kv[1])
    funcs, N, mx, MW, W, H = geom(rank, edges, topn)
    tot = sum(incl_w.values()) or 1
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    try:
        f_t = ImageFont.truetype(CJK, 20, index=1)
        f_s = ImageFont.truetype(CJK, 12, index=1)
        f_n = ImageFont.truetype(CJK, 11, index=1)
    except Exception:
        f_t = f_s = f_n = ImageFont.load_default()
    d.text((PAD, 14), title, font=f_t, fill=(26, 26, 26))
    d.text((PAD, 44), "行=调用者 列=被调用者 颜色=调用边权重 · %d 函数 · 总权重 %s"
           % (N, fmt(tot, unit_ms)), font=f_s, fill=(90, 90, 90))
    y, bw = HEAD + 6, RANK_W - 130
    topi = rank[0][1] if rank else 1
    for i, f in enumerate(funcs):
        yy = y + i * (CELL - 4)
        sw, iw = self_w.get(f, 0), incl_w.get(f, 0)
        wx, ww = PAD + 130, max(1.0, bw * iw / topi)
        d.rectangle([wx, yy, wx + ww, yy + CELL - 7], fill=(223, 230, 238))
        if sw > 0:
            d.rectangle([wx, yy, wx + max(1.0, bw * sw / topi), yy + CELL - 7], fill=(63, 124, 181))
        t = clip(f, 122, 11)
        d.text((PAD + 124 - d.textlength(t, font=f_n), yy), t, font=f_n, fill=(42, 42, 42))
        d.text((wx + ww + 5, yy), "%s / %s" % (short(sw), short(iw)), font=f_n, fill=(102, 102, 102))
    x0, y0 = PAD + RANK_W + 26 + NAME_W, HEAD + 40
    for iy, a in enumerate(funcs):
        t = clip(a, NAME_W - 10, 10.5)
        d.text((x0 - 6 - d.textlength(t, font=f_n), y0 + iy * CELL + 7), t, font=f_n, fill=(42, 42, 42))
    for iy, a in enumerate(funcs):
        for jx, b in enumerate(funcs):
            v = edges.get((a, b), 0)
            fill = (247, 248, 250) if v <= 0 else rgb(heat(math.log1p(v) / math.log1p(mx)))
            d.rectangle([x0 + jx * CELL, y0 + iy * CELL,
                         x0 + jx * CELL + CELL - 1, y0 + iy * CELL + CELL - 1], fill=fill)
            if v > 0 and math.log1p(v) / math.log1p(mx) > 0.62:
                t = short(v)
                d.text((x0 + jx * CELL + CELL / 2.0 - d.textlength(t, font=f_n) / 2.0, y0 + iy * CELL + 7),
                       t, font=f_n, fill=(255, 255, 255))
    ly = y0 + MW + 34
    idx = set(funcs)
    hot = sorted(((a, b, v) for (a, b), v in edges.items() if a in idx and b in idx),
                 key=lambda t: -t[2])[:TOPEDGE]
    for i, (a, b, v) in enumerate(hot):
        yy = ly + i * 15
        d.rectangle([PAD, yy - 5, PAD + 6, yy + 5], fill=rgb(heat(math.log1p(v) / math.log1p(mx))))
        d.text((PAD + 12, yy - 7), "%s → %s   %s · %.2f%%"
               % (clip(a, 150, 11), clip(b, 150, 11), fmt(v, unit_ms), 100.0 * v / tot),
               font=f_n, fill=(51, 51, 51))
    # 图例
    gx, gy, gw = W - 300, H - 46, 200
    for k in range(100):
        d.rectangle([gx + gw * k / 100.0, gy, gx + gw * (k + 1) / 100.0, gy + 12],
                    fill=rgb(heat(k / 99.0)))
    d.text((gx, gy + 18), "低", font=f_n, fill=(102, 102, 102))
    t = "高 %s" % fmt(mx, unit_ms)
    d.text((gx + gw - d.textlength(t, font=f_n), gy + 18), t, font=f_n, fill=(102, 102, 102))
    d.text((PAD, H - 24), "trace_engine · 色阶按 log(1+w) 归一 · 悬停请看 SVG 版", font=f_n, fill=(136, 136, 136))
    img.save(out)
    return out

def main():
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__)
        return 2
    src, out = a[0], a[1]
    title = a[2] if len(a) > 2 else "函数调用热力图"
    topn = int(a[3]) if len(a) > 3 else 24
    j, folded = load(src)
    unit_ms, self_w, incl_w, edges = agg(j, folded)
    if not incl_w:
        print("没有栈数据")
        return 1
    if out.lower().endswith(".svg"):
        svg(unit_ms, self_w, incl_w, edges, topn, title, out)
    else:
        try:
            png(unit_ms, self_w, incl_w, edges, topn, title, out)
        except ImportError:
            out = out.rsplit(".", 1)[0] + ".svg"
            svg(unit_ms, self_w, incl_w, edges, topn, title, out)
            print("[heat] 没有 PIL，改出 SVG")
    print("[heat] %s" % out)
    return 0

if __name__ == "__main__":
    sys.exit(main())
