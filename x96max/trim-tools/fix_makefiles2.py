#!/usr/bin/env python3
import os, re, sys
tree = os.environ.get('KTREE', '/x96-build/src-linux')
ASSIGN = re.compile(r'^\s*(obj|lib|extra|subdir)-')
def alive(root, d):
    if os.path.isdir(os.path.join(root, d)): return True
    if '/' in d and os.path.isdir(os.path.join(tree, d)): return True
    return False
def filt(root, code):
    keep, dropped = [], False
    for t in code.split():
        tt = t.split('+=')[-1] if '+=' in t and t != '+=' else t
        if tt.endswith('/') and '$' not in tt and len(tt) > 1 and not alive(root, tt.rstrip('/')):
            dropped = True; continue
        keep.append(t)
    return ' '.join(keep), dropped
def main():
    apply = '--apply' in sys.argv
    tf = ts = 0
    for root, dirs, fs in os.walk(tree):
        if '.git' in dirs: dirs.remove('.git')
        if 'Makefile' not in fs: continue
        p = os.path.join(root, 'Makefile')
        lines = open(p, errors='surrogateescape').read().split('\n')
        out, i, n = [], 0, 0
        while i < len(lines):
            ln = lines[i]
            if ln.rstrip().endswith('\\'):
                start = i
                while i < len(lines) and lines[i].rstrip().endswith('\\'): i += 1
                i += 1
                block = []
                for j in range(start, i):
                    t = lines[j].rstrip()
                    if t.endswith('\\'): t = t[:-1]
                    block.append(t)
                logical = ' '.join(x.strip() for x in block)
                code = logical.split('#')[0]
                if '+=' in code and ASSIGN.match(code):
                    new, dropped = filt(root, code)
                    if dropped:
                        n += 1
                        if len(new.split()) > 1: out.append(new)
                        continue
                out.append(logical); continue
            code = ln.split('#')[0]
            if '+=' in code and ASSIGN.match(code):
                new, dropped = filt(root, code)
                if dropped:
                    n += 1
                    if len(new.split()) <= 1: i += 1; continue
                    ln = new
            out.append(ln); i += 1
        if n:
            tf += 1; ts += n
            print('  %-52s %d' % (os.path.relpath(p, tree), n))
            if apply: open(p, 'w', errors='surrogateescape').write('\n'.join(out))
    print('%s写 %d 个 Makefile，%d 条语句' % ('改' if apply else '待改', tf, ts))
main()
