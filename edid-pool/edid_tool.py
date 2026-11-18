import sys, struct, os, hashlib

def checksum(d, o, n):
    return sum(d[o:o+n]) % 256 == 0

def parse(d):
    out = {}
    if len(d) < 128 or d[:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00':
        return None, "header BAD"
    if not checksum(d, 0, 128):
        return None, "base checksum BAD"
    n_ext = d[126]
    if len(d) < 128 + n_ext*128:
        return None, "truncated (%d ext declared)" % n_ext
    for i in range(n_ext):
        o = 128 + i*128
        if not checksum(d, o, 128):
            return None, "ext%d checksum BAD" % i
    mfg = struct.unpack(">H", d[8:10])[0]
    name = "".join(chr(ord('A') + ((mfg >> s) & 0x1f) - 1) for s in (10, 5, 0))
    dtds = []
    for i in range(4):
        o = 54 + i*18
        if d[o:o+2] == b'\x00\x00':
            continue
        clk = (d[o] | d[o+1] << 8) * 10000
        ha = d[o+2] | ((d[o+4] & 0xf0) << 4)
        hb = d[o+3] | ((d[o+4] & 0x0f) << 8)
        va = d[o+5] | ((d[o+7] & 0xf0) << 4)
        vb = d[o+6] | ((d[o+7] & 0x0f) << 8)
        if ha == 0 or va == 0:
            continue
        hz = clk / ((ha+hb)*(va+vb))
        dtds.append((ha, va, hz, clk))
    out = dict(mfg=name, n_ext=n_ext, dtds=dtds,
               base_ok=checksum(d,0,128), sha=hashlib.sha256(d).hexdigest()[:12])
    return out, None

def show(path, d=None):
    d = d or open(path,'rb').read()
    p, err = parse(d)
    if err:
        print("  %-40s %4dB  INVALID: %s" % (os.path.basename(path), len(d), err))
        return None
    print("  %-40s %4dB  mfg=%-4s ext=%d  sha=%s" % (os.path.basename(path), len(d), p['mfg'], p['n_ext'], p['sha']))
    for i,(ha,va,hz,clk) in enumerate(p['dtds']):
        print("      DTD%d %dx%d @%.2fHz clk=%.2fMHz%s" % (i, ha, va, hz, clk/1e6, "  <-- PREFERRED" if i==0 else ""))
    return p

def mkdtd(ha, va, hf, hs, hb_back, vf, vs, vb_back, clk_hz, flags=0x1a, wmm=0, hmm=0):
    """CEA DTD 18 bytes. blank = front+sync+back"""
    hblank = hf + hs + hb_back
    vblank = vf + vs + vb_back
    pc = clk_hz // 10000
    b = bytearray(18)
    b[0] = pc & 0xff; b[1] = (pc >> 8) & 0xff
    b[2] = ha & 0xff; b[3] = hblank & 0xff
    b[4] = ((ha >> 8) << 4) | ((hblank >> 8) & 0x0f)
    b[5] = va & 0xff; b[6] = vblank & 0xff
    b[7] = ((va >> 8) << 4) | ((vblank >> 8) & 0x0f)
    b[8] = hf & 0xff; b[9] = hs & 0xff
    b[10] = ((vf & 0x0f) << 4) | (vs & 0x0f)
    b[11] = (((hf >> 8) & 0x03) << 6) | (((hs >> 8) & 0x03) << 4) | (((vf >> 4) & 0x03) << 2) | ((vs >> 4) & 0x03)
    b[12] = wmm & 0xff; b[13] = hmm & 0xff
    b[14] = ((wmm >> 8) << 4) | ((hmm >> 8) & 0x0f)
    b[15] = 0; b[16] = 0; b[17] = flags
    return bytes(b)

def fix_cs(d):
    d = bytearray(d)
    d[127] = (-sum(d[0:127])) % 256
    for i in range(d[126]):
        o = 128 + i*128
        d[o+127] = (-sum(d[o:o+127])) % 256
    return bytes(d)
