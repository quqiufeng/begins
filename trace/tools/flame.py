#!/usr/bin/env python3
"""折叠栈 -> 火焰图 PNG（纯 PIL，无外部依赖）
输入：lite trace_engine --mode oncpu --json 的 top[]（stack 叶子在前）
用法：flame.py in.json out.png "标题"
"""
import json, sys, hashlib, re
from PIL import Image, ImageDraw, ImageFont

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

if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else "on-CPU 火焰图"
    j, folded = load(src)
    root = build(folded)
    maxd = [0]
    layout(root, 0, 0, maxd)
    print(draw(j, root, dst, title))
