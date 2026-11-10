"""最小 ELF64 解析：读 section、符号表、__versions。不依赖 readelf。"""
import struct

class Elf:
    SHT_SYMTAB, SHT_UNDEF = 2, 0
    def __init__(self, path):
        self.path = path
        self.d = open(path, 'rb').read()
        d = self.d
        assert d[:4] == b'\x7fELF' and d[4] == 2, "需要 ELF64"
        self.shoff, = struct.unpack_from('<Q', d, 0x28)
        self.shentsize, self.shnum, self.shstrndx = struct.unpack_from('<HHH', d, 0x3a)
        self.sec = [self._sh(i) for i in range(self.shnum)]

    def _sh(self, i):
        o = self.shoff + i * self.shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from('<IIQQQQIIQQ', self.d, o)
        return dict(name_off=name, type=typ, off=off, size=size,
                    link=link, info=info, entsize=entsize)

    def shstr(self, s):
        base = self.sec[self.shstrndx]['off']
        end = self.d.index(b'\0', base + s['name_off'])
        return self.d[base + s['name_off']:end].decode()

    def find(self, name):
        for s in self.sec:
            if self.shstr(s) == name:
                return s
        return None

    def syms(self):
        """返回 [(name, value, shndx)]，只含 FUNC/OBJECT/NOTYPE。"""
        st = self.find('.symtab')
        if not st: return []
        str_off = self.sec[st['link']]['off']
        out = []
        for i in range(st['size'] // 24):
            o = st['off'] + i * 24
            nm, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', self.d, o)
            typ = info & 0xf
            if typ not in (0, 1, 2):   # NOTYPE/FUNC/OBJECT
                continue
            end = self.d.index(b'\0', str_off + nm)
            out.append((self.d[str_off + nm:end].decode(errors='replace'), value, shndx))
        return out

    def undefined(self):
        return sorted({n for n, v, sh in self.syms() if sh == 0 and n})

    ENTSZ = 64   # crc(8) + name[56]；MODULE_NAME_LEN = 64 - sizeof(unsigned long)

    def versions(self):
        """__versions: [(crc, name)] —— 这就是 ABI 契约。"""
        s = self.find('__versions')
        if not s: return []
        assert s['size'] % self.ENTSZ == 0, \
            f"__versions 大小 {s['size']} 不是 {self.ENTSZ} 的整数倍"
        out, j, end = [], s['off'], s['off'] + s['size']
        while j + self.ENTSZ <= end:
            crc, = struct.unpack_from('<Q', self.d, j)
            name = self.d[j+8:j+self.ENTSZ].split(b'\0')[0].decode(errors='replace')
            if name: out.append((crc, name))
            j += self.ENTSZ
        return out
