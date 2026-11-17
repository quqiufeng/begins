#!/usr/bin/env python3
"""gen-osd-font.py —— 把 OSD 需要的那几十个字形烘成 osd_font.inc（1bpp 位图）

为什么不用 freetype：
  盒子上没有 libfreetype，也不该为一行提示文字加一个运行期依赖。OSD 只用
  固定几十个字符（数字 + 少量汉字），在编译机上烘成位图钉进二进制最省事，
  运行时零依赖、零解析。

字符集 = ASCII 可见字符 + CJK 子集，改文案就往 EXTRA 里加字再跑一遍：
    ./gen-osd-font.py            # 生成 osd_font.inc
    ./gen-osd-font.py --dump     # 顺便在终端把位图打出来看
"""
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
PIX = 40          # 字高（像素，按 1080p 屏幕 1:1 上屏）
THRESH = 96       # 1bpp 阈值：CJK 笔画细，低于这个会断笔

# OSD 文案用到的汉字。加一条新文案就把新字加进来（不用的字不占空间）
EXTRA = "音量已是最大小静取消暂停播放快进退位置秒无音轨"
CHARS = "".join(chr(c) for c in range(0x20, 0x7F)) + EXTRA


def glyphs():
    font = ImageFont.truetype(FONT, PIX, index=0)
    ascent, descent = font.getmetrics()
    H = ascent + descent
    out = []
    for ch in sorted(set(CHARS)):
        adv = max(1, int(round(font.getlength(ch))))
        img = Image.new("L", (adv, H), 0)
        ImageDraw.Draw(img).text((0, 0), ch, font=font, fill=255, anchor="la")
        rows = []
        for y in range(H):
            row = 0
            for x in range(adv):
                row = (row << 1) | (1 if img.getpixel((x, y)) >= THRESH else 0)
            rows.append(row)
        out.append((ord(ch), adv, H, rows))
    return out, H, ascent


def main():
    gs, H, ascent = glyphs()
    bits = []          # 扁平位流（按字节，MSB 先）
    entries = []
    acc = 0
    nbits = 0
    off = 0
    for cp, adv, h, rows in gs:
        acc = 0
        nbits = 0
        off = len(bits) * 8
        for row in rows:
            acc = (acc << adv) | row
            nbits += adv
            while nbits >= 8:
                nbits -= 8
                bits.append((acc >> nbits) & 0xFF)
                acc &= (1 << nbits) - 1
        if nbits:                     # 尾巴补零，下一个字形从整字节开始
            bits.append((acc << (8 - nbits)) & 0xFF)
        entries.append((cp, adv, h, off))

    with open("osd_font.inc", "w") as f:
        f.write("/* 自动生成，别手改：见 gen-osd-font.py（PIL + %s） */\n" % FONT)
        f.write("#define OSD_FONT_H %d\n#define OSD_FONT_ASCENT %d\n\n" % (H, ascent))
        f.write("static const struct osd_glyph osd_glyphs[] = {\n")
        for cp, adv, h, off in entries:
            f.write("\t{0x%04x, %d, %d, %d},\n" % (cp, adv, h, off))
        f.write("};\n#define OSD_NGLYPH (sizeof osd_glyphs / sizeof osd_glyphs[0])\n\n")
        f.write("static const unsigned char osd_bits[] = {\n")
        for i in range(0, len(bits), 16):
            f.write("\t" + ",".join("0x%02x" % b for b in bits[i:i + 16]) + ",\n")
        f.write("};\n")
    print("osd_font.inc: %d 字形, %d 位图字节, 字高 %d, ascent %d"
          % (len(entries), len(bits), H, ascent))

    if "--dump" in sys.argv:
        for cp, adv, h, off in entries[:200]:
            print("--- %s (%d px)" % (chr(cp), adv))
            for y in range(h):
                line = ""
                for x in range(adv):
                    b = bits[(off + y * adv + x) // 8] >> (7 - (off + y * adv + x) % 8) & 1
                    line += "#" if b else "."
                print(line)


if __name__ == "__main__":
    main()
