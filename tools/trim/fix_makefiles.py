#!/usr/bin/env python3
"""删除 Makefile 中指向「已被裁剪掉的目录」的引用。
判据：token 以 '/' 结尾、不含 '$'、且 <dir>/Makefile 不存在 → 删掉该 token。
处理续行（反斜杠连接），改写时保留原有缩进与结尾续行符。
"""
import os, re, sys

tree = os.path.expanduser('~/kernel/src/linux-7.2.12')
APPLY = '--apply' in sys.argv
drop_log, nfiles = [], 0

def alive(root, tok):
    t = tok.rstrip('/')
    for base in (root, tree):          # 有的 Makefile 用树根相对路径
        if os.path.isfile(os.path.join(base, t, 'Makefile')):
            return True
    return False

for root, dirs, fs in os.walk(tree):
    if root.startswith(os.path.join(tree, 'tools')): continue
    if '.git' in dirs: dirs.remove('.git')
    for f in fs:
        if f != 'Makefile': continue
        p = os.path.join(root, f)
        try: lines = open(p, encoding='utf-8', errors='surrogateescape').read().split('\n')
        except OSError: continue
        # 合并续行
        logical, i, changed = [], 0, False
        while i < len(lines):
            cur, cont = lines[i], lines[i].rstrip().endswith('\\')
            if cont: cur = cur.rstrip()[:-1]
            while cont and i + 1 < len(lines):
                i += 1
                nxt = lines[i]
                cont = nxt.rstrip().endswith('\\')
                if cont: nxt = nxt.rstrip()[:-1]
                cur += ' ' + nxt.strip()
            logical.append(cur); i += 1
        out = []
        for ln in logical:
            if ln.strip().startswith('#') or ln.startswith('\t'):
                out.append(ln); continue
            # 只处理 make 变量赋值行（obj-y / core-y / sound-y / obj-$(CONFIG_X) 等）
            if not re.match(r'^[A-Za-z_][A-Za-z0-9_$(){}-]*\s*[:+]?=', ln):
                out.append(ln); continue
            toks = ln.split()
            def isdir_tok(t):
                t = t[2:] if t.startswith('+=') else t
                if not t.endswith('/') or '$' in t: return False
                if '%' in t or "'" in t or '"' in t or '|' in t: return False
                return bool(re.fullmatch(r'[A-Za-z0-9._/-]+/', t))
            dead = []
            for t in toks:
                cand = t[2:] if t.startswith('+=') else t
                if isdir_tok(cand) and not alive(root, cand):
                    dead.append(t)
            if not dead:
                out.append(ln); continue
            changed = True
            drop_log += [(os.path.relpath(p, tree), t) for t in dead]
            kept = [t for t in toks if t not in dead]
            out.append(' '.join(kept) if kept else '')
        if changed:
            nfiles += 1
            if APPLY:
                open(p, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
for f, t in drop_log: print(f"  - {t:34s} {f}")
print(f"{'已改写' if APPLY else '待改写'} {nfiles} 个 Makefile，共 {len(drop_log)} 条失效引用")
