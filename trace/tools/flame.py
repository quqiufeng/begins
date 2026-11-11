#!/usr/bin/env python3
"""折叠栈 -> 火焰图（PNG=纯 PIL / SVG=零依赖可交互）
输入：lite trace_engine --json 的 top[] 或 folded[]，方向由 JSON 的 frame_dir 决定
      （oncpu/offcpu 是 root-first，folded 是 leaf-first，这里会归一）
用法：flame.py in.json out.png|out.svg "标题"
      .svg 走标准库内置 JS：悬停看占比、点框放大、点空白回退，无 PIL 也能跑
"""
import json, sys, hashlib, re

CJK = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
ROW = 17
W = 1800
MARGIN = 12
HEAD = 86

def collapse(frames):
    """折叠连续重复帧：内核 unwind 在不可靠的栈帧上会扫出几十层同一地址，
    真实递归不会连续出现同一个返回地址上百次。保留一帧并记下倍数。"""
    out, note, run = [], set(), 1
    for i, f in enumerate(frames):
        if i and f == frames[i - 1]:
            run += 1
            continue
        out.append(f)
        if run > 1:
            note.add(len(out) - 1)
        run = 1
    return out, note

import os
MAXD = int(os.environ.get("MAXD", "32"))
BAD_OFF = 1 << 40          # 用户态地址不可能到这个量级

def off_of(f):
    import re
    m = re.search(r"\+0x([0-9a-fA-F]+)\]?$", f) or re.match(r"^0x([0-9a-fA-F]+)$", f)
    return int(m.group(1), 16) if m else None

def scrub(frames):
    """裸用户态地址归并成占位帧（ASLR 下几乎每条都不同，展开会炸成上万节点）；
    符号化出错产生的超大偏移才丢弃；超深部分合并成一个节点。
    返回 (frames, 丢帧数, 截断层数, 归并的裸地址帧数)"""
    kept, dropped, unsym = [], 0, 0
    for f in frames:
        o = off_of(f)
        bare = re.match(r"^0x([0-9a-fA-F]+)$", f) is not None
        if o is not None and o >= BAD_OFF:
            if bare:
                kept.append("[user-addr]")   # 纯 ASCII：mono 字体没有 CJK 字形
                unsym += 1
            else:
                dropped += 1
            continue
        kept.append(f)
    tail = 0
    if len(kept) > MAXD:
        tail = len(kept) - MAXD
        kept = kept[:MAXD] + ["[…%d 层过深栈已合并]" % tail]
    return kept, dropped, tail, unsym

def load(path):
    j = json.load(open(path))
    folded = {}
    stat = {"collapsed": 0, "dropped": 0, "trunc": 0, "unsym": 0}
    # oncpu 出 top[]，folded 模式出 folded[]，两者字段名都是 stack/count
    rows = j.get("top") or j.get("folded") or []
    dirn = j.get("frame_dir", "leaf-first")
    for e in rows:
        frames = [f for f in e["stack"].split(";") if f]
        if dirn == "leaf-first":
            frames.reverse()                  # 叶子在前 -> 反转，根在底部
        # oncpu/folded 权重是样本数(count)；offcpu 权重是阻塞时长(total_ms)。
        # 注意 offcpu 的条目同样带 count（=配对数），只能靠 unit 区分。
        if j.get("unit") == "ms":
            w = e.get("total_ms") or 0
        else:
            w = e.get("count") or 0
        n0 = len(frames)
        frames, _ = collapse(frames)
        if len(frames) < n0:
            stat["collapsed"] += 1
        frames, dropped, trunc, unsym = scrub(frames)
        frames = collapse(frames)[0]   # 归并裸地址后可能相邻，再折一次
        stat["dropped"] += dropped * w
        stat["unsym"] += unsym * w
        stat["trunc"] += 1 if trunc else 0
        folded[tuple(frames)] = folded.get(tuple(frames), 0) + w
    j["_stat"] = stat
    return j, folded

def build(folded):
    root = {"children": {}, "count": 0}
    for frames, cnt in folded.items():
        n = root; root["count"] += cnt
        for f in frames:
            c = n["children"].setdefault(f, {"children": {}, "count": 0})
            c["count"] += cnt
            n = c
    return root

def is_user(name):
    return ("." in name and not name.startswith("[")) or name.startswith("0x")

def color(name, user):
    h = int(hashlib.md5(name.encode()).hexdigest()[:8], 16)
    if user:
        return (30 + h % 40, 120 + (h >> 8) % 60, 170 + (h >> 16) % 60)
    return (230 + (h >> 4) % 25, 150 + (h >> 12) % 60, 60 + (h >> 20) % 50)

def layout(node, x0, depth, maxd):
    node["x"], node["y"] = x0, depth
    maxd[0] = max(maxd[0], depth)
    kids = sorted(node["children"].items(), key=lambda kv: -kv[1]["count"])
    for _, c in kids:
        layout(c, x0, depth + 1, maxd)
        x0 += c["count"]

def walk(node, out):
    for name, c in node["children"].items():
        out.append((name, c)); walk(c, out)

def draw(j, root, out_png, title):
    from PIL import Image, ImageDraw, ImageFont

    nodes = []; walk(root, nodes)
    if not nodes:
        # 空结果也要出图：只画标题 + 一句提示，别抛 traceback
        H = 140
        img = Image.new("RGB", (W, H), (250, 250, 248))
        d = ImageDraw.Draw(img)
        d.text((MARGIN, 14), title, font=ImageFont.truetype(CJK, 20), fill=(20, 20, 20))
        d.text((MARGIN, 56), "无样本：该 pid / 时长内没有采到任何栈",
               font=ImageFont.truetype(CJK, 14), fill=(150, 40, 40))
        d.text((MARGIN, 80), "（检查 --pid 是否为运行中的进程，或改用全机模式去掉 --pid）",
               font=ImageFont.truetype(CJK, 13), fill=(110, 110, 110))
        img.save(out_png)
        return out_png
    depth = max(n["y"] for _, n in nodes) + 1
    bottom = HEAD + depth * ROW
    H = HEAD + depth * ROW + 46
    img = Image.new("RGB", (W, H), (250, 250, 248))
    d = ImageDraw.Draw(img)
    f_title = ImageFont.truetype(CJK, 20)
    f_sub = ImageFont.truetype(CJK, 13)
    try:
        f_cell = ImageFont.truetype(MONO, 11)
    except Exception:
        f_cell = ImageFont.load_default()

    total = root["count"]
    scale = (W - 2 * MARGIN) / total
    d.text((MARGIN, 14), title, font=f_title, fill=(20, 20, 20))
    if j.get("unit") == "ms":
        tot = total / 1000.0 if total > 100000 else total
        sub = ("阻塞 %.1fms · 栈种类 %d · 最深 %d 层 · 权重=阻塞时长 · 内核=暖色 / 用户态=冷色"
               % (tot, len(nodes), depth))
    else:
        fr = j.get("freq")
        rate = ("%dHz" % fr) if fr else "-"
        sub = ("样本 %d · 栈种类 %d · 最深 %d 层 · %s · 内核=暖色 / 用户态=冷色"
               % (total, len(nodes), depth, rate))
    st = j.get("_stat")
    if st:
        bits = []
        if st["collapsed"]:
            bits.append("%d 条栈的连续重复帧已折叠" % st["collapsed"])
        if st["dropped"]:
            bits.append("丢弃非法符号偏移 %d 个样本" % st["dropped"])
        if st.get("unsym"):
            bits.append("%d 个用户态裸地址已归并" % st["unsym"])
        if st["trunc"]:
            bits.append("%d 条过深栈截断至 %d 层" % (st["trunc"], MAXD))
        if bits:
            sub += " · " + "，".join(bits)
    d.text((MARGIN, 44), sub, font=f_sub, fill=(90, 90, 90))
    d.line([(MARGIN, HEAD - 10), (W - MARGIN, HEAD - 10)], fill=(200, 200, 200))

    skipped = 0
    for name, n in nodes:
        x = MARGIN + n["x"] * scale
        w = n["count"] * scale
        y0 = bottom - (n["y"] + 1) * ROW + 1
        if w < 0.7:
            skipped += 1
            continue
        u = is_user(name)
        d.rectangle([x, y0, x + w - 0.6, y0 + ROW - 1.2], fill=color(name, u),
                    outline=(255, 255, 255))
        if w > 26:
            label = name
            while label and d.textlength(label, font=f_cell) > w - 6:
                label = label[:-1]
            if label:
                d.text((x + 3, y0 + 2), label, font=f_cell, fill=(25, 25, 25))
    foot = "lite trace_engine · 过窄(<0.7px)省略 %d 个框" % skipped
    d.text((MARGIN, H - 30), foot, font=f_sub, fill=(120, 120, 120))
    img.save(out_png)
    return out_png, total, len(nodes), depth


# ---------------------------------------------------------------------------
# SVG：可交互火焰图（悬停看占比、点击缩放、空白处退回全图）
# 静态 rect 也照写一份，丢了 JS 的查看器（rsvg / Inkscape）仍有图看。
# ---------------------------------------------------------------------------
SW, SROW, SHEAD, SFOOT, SM = 1400, 17, 96, 44, 12


def xesc(t):
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def hexcol(name, user):
    return "#%02x%02x%02x" % color(name, user)


def flatten(root):
    """预序展开，顺带算好 x（子节点按权重降序，与 PNG 侧 layout 一致）"""
    nodes = []

    def rec(n, name, parent, depth, x0):
        i = len(nodes)
        u = is_user(name) if name else False
        nodes.append({"i": i, "n": name, "c": n["count"], "p": parent,
                      "d": depth, "x": x0, "u": u, "col": hexcol(name or "all", u)})
        cx = x0
        for cn, c in sorted(n["children"].items(), key=lambda kv: -kv[1]["count"]):
            rec(c, cn, i, depth + 1, cx)
            cx += c["count"]
        return i

    rec(root, "all", -1, 0, 0)
    return nodes


JS = r"""
var N=__DATA__,W=__W__,H=__H__,HEAD=__HEAD__,ROW=__ROW__,FOOT=__FOOT__,M=__M__,WU=__WU__;
function fmt(v){return Math.abs(v)>=100?String(Math.round(v)):String(Math.round(v*10)/10)}
var NS='http://www.w3.org/2000/svg',kids=[],root=0;
for(var i=0;i<N.length;i++)kids.push([]);
for(var i=1;i<N.length;i++)kids[N[i][2]].push(i);
for(var i=0;i<kids.length;i++)kids[i].sort(function(a,b){return N[b][1]-N[a][1]});
var dyn=document.getElementById('dyn'),stat=document.getElementById('stat');
var TOTAL=N[0][1];
function pct(v){return (v*100/TOTAL).toFixed(2)+'%'}
function render(){
  while(dyn.firstChild)dyn.removeChild(dyn.firstChild);
  var st0=document.getElementById('static');
  if(st0&&st0.parentNode)st0.parentNode.removeChild(st0);
  var k=(W-2*M)/N[root][1],stack=[[root,0,0]];
  while(stack.length){
    var it=stack.pop(),i=it[0],x=it[1],d=it[2],w=N[i][1]*k,y=H-FOOT-(d+1)*ROW;
    if(w>=0.7){
      var r=document.createElementNS(NS,'rect');
      r.setAttribute('x',(M+x*k).toFixed(2));
      r.setAttribute('y',y);
      r.setAttribute('width',Math.max(w-0.6,0.4).toFixed(2));
      r.setAttribute('height',ROW-1);
      r.setAttribute('fill',N[i][4]);
      r.setAttribute('class','f');
      r.setAttribute('data-i',i);
      var ti=document.createElementNS(NS,'title');
      ti.textContent=N[i][0]+'  '+fmt(N[i][1])+WU+'  '+pct(N[i][1]);
      r.appendChild(ti);
      dyn.appendChild(r);
      if(w>26){
        var ch=Math.max(1,Math.floor((w-6)/6.3)),nm=N[i][0];
        var t=document.createElementNS(NS,'text');
        t.setAttribute('x',(M+x*k+3).toFixed(2));
        t.setAttribute('y',y+12);
        t.textContent=nm.length>ch?nm.slice(0,ch-1)+'\u2026':nm;
        dyn.appendChild(t);
      }
    }
    var kk=kids[i],pos=[],cx=x;
    for(var j=0;j<kk.length;j++){pos.push([kk[j],cx]);cx+=N[kk[j]][1];}
    for(var j=pos.length-1;j>=0;j--)stack.push([pos[j][0],pos[j][1],d+1]);
  }
  document.getElementById('zoom').textContent=
    (root?N[root][0]:'全部')+' · '+fmt(N[root][1])+WU+' · '+pct(N[root][1]);
}
dyn.addEventListener('mousemove',function(e){
  var i=e.target.getAttribute&&e.target.getAttribute('data-i');
  if(i===null||i===undefined){return}
  i=+i;
  stat.textContent=N[i][0]+'   '+fmt(N[i][1])+WU+'   '+pct(N[i][1])+
    (root?'   （占当前根 '+(N[i][1]*100/N[root][1]).toFixed(1)+'%）':'');
});
dyn.addEventListener('click',function(e){
  var i=e.target.getAttribute&&e.target.getAttribute('data-i');
  if(i===null||i===undefined)return;
  i=+i;
  if(i===root)root=0; else root=i;
  render();
});
document.getElementById('bg').addEventListener('click',function(){root=0;render();});
render();
"""


def draw_svg(j, root, out_svg, title):
    nodes = flatten(root)
    depth = max((n["d"] for n in nodes), default=0) + 1
    H = SHEAD + depth * SROW + SFOOT
    total = root["count"]
    scale = (SW - 2 * SM) / (total or 1)
    bottom = H - SFOOT

    if j.get("unit") == "ms":
        tot = total / 1000.0 if total > 100000 else total
        sub = "阻塞 %.1fms · 栈种类 %d · 最深 %d 层 · 权重=阻塞时长" % (tot, max(len(nodes) - 1, 0), depth)
    else:
        fr = j.get("freq")
        sub = "样本 %d · 栈种类 %d · 最深 %d 层 · %s" % (
            total, max(len(nodes) - 1, 0), depth, ("%dHz" % fr) if fr else "-")
    st = j.get("_stat") or {}
    bits = []
    if st.get("collapsed"):
        bits.append("%d 条栈的连续重复帧已折叠" % st["collapsed"])
    if st.get("dropped"):
        bits.append("丢弃非法偏移 %d 个样本" % st["dropped"])
    if st.get("unsym"):
        bits.append("%d 个裸地址已归并" % st["unsym"])
    if st.get("trunc"):
        bits.append("%d 条过深栈截断至 %d 层" % (st["trunc"], MAXD))
    if bits:
        sub += " · " + "，".join(bits)
    if j.get("sym"):
        sub += " · 用户态已符号化(%d 帧命中)" % j.get("sym_hits", 0)

    out = []
    out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
               'viewBox="0 0 %d %d" font-family="DejaVu Sans Mono, Menlo, monospace">' % (SW, H, SW, H))
    out.append("""<style>
rect.f{stroke:#fff;stroke-width:.5;cursor:pointer}
rect.f:hover{stroke:#111;stroke-width:1.2}
text{font-size:11px;fill:#1a1a1a;pointer-events:none}
.t{fill:#141414;font-size:19px}
.s{font-size:12.5px;fill:#5a5a5a}
.h{font-size:12.5px;fill:#0b62c4}
#stat{font-size:12.5px;fill:#b03030}
</style>
""")
    out.append('<rect id="bg" x="0" y="0" width="%d" height="%d" fill="#fafaf8"/>' % (SW, H))
    out.append('<text class="t" x="%d" y="30">%s</text>' % (SM, xesc(title)))
    out.append('<text class="s" x="%d" y="56">%s</text>' % (SM, xesc(sub)))
    out.append('<text id="stat" x="%d" y="78">悬停看占比 · 点框缩放 · 点空白退回</text>' % SM)
    out.append('<text class="h" id="zoom" x="%d" y="78" text-anchor="end">全部</text>'
               % (SW - SM))
    out.append('<g id="static">')
    for n in nodes[1:]:
        w = n["c"] * scale
        if w < 0.7:
            continue
        x = SM + n["x"] * scale
        y = bottom - (n["d"] + 1) * SROW + 1
        out.append('<rect class="f" x="%.2f" y="%d" width="%.2f" height="%d" fill="%s">'
                   '<title>%s  %d  %.2f%%</title></rect>'
                   % (x, y, max(w - 0.6, 0.4), SROW - 1, n["col"],
                      xesc(n["n"]), n["c"], n["c"] * 100.0 / (total or 1)))
        if w > 26:
            ch = max(1, int((w - 6) / 6.3))
            label = n["n"] if len(n["n"]) <= ch else n["n"][:ch - 1] + "…"
            out.append('<text x="%.2f" y="%d">%s</text>' % (x + 3, y + 12, xesc(label)))
    out.append("</g>")
    out.append('<g id="dyn"></g>')
    out.append('<text class="s" x="%d" y="%d">lite trace_engine · 共 %d 个框 · 内核=暖色 / 用户态=冷色</text>'
               % (SM, H - 14, max(len(nodes) - 1, 0)))
    data = json.dumps([[n["n"], n["c"], n["p"], n["d"], n["col"]] for n in nodes],
                      ensure_ascii=False, separators=(",", ":"))
    js = (JS.replace("__DATA__", data).replace("__W__", str(SW)).replace("__H__", str(H))
            .replace("__HEAD__", str(SHEAD)).replace("__ROW__", str(SROW))
            .replace("__WU__", json.dumps(" ms" if j.get("unit") == "ms" else " 样本", ensure_ascii=False))
            .replace("__FOOT__", str(SFOOT)).replace("__M__", str(SM)))
    out.append("<script><![CDATA[%s]]></script>" % js)
    out.append("</svg>")
    open(out_svg, "w", encoding="utf-8").write("\n".join(out))
    return out_svg, total, max(len(nodes) - 1, 0), depth


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else "on-CPU 火焰图"
    j, folded = load(src)
    root = build(folded)
    if dst.lower().endswith(".svg"):
        print(draw_svg(j, root, dst, title))     # 可交互版，不需要 PIL
    else:
        layout(root, 0, 0, [0])
        print(draw(j, root, dst, title))
