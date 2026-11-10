import subprocess, sys, struct, re
VML=sys.argv[1] if len(sys.argv)>1 else 'vmlinux'
kv=ko=None
for ln in subprocess.run(['objdump','-h',VML],capture_output=True,text=True).stdout.splitlines():
    f=ln.split()
    if len(f)>=6 and f[1]=='__kcrctab':
        kv,ko,ks=int(f[3],16),int(f[5],16),int(f[2],16)
if kv is None: sys.exit("找不到 __kcrctab")
data=open(VML,'rb').read(); crc={}
for ln in subprocess.run(['nm',VML],capture_output=True,text=True).stdout.splitlines():
    f=ln.split()
    if len(f)==3 and f[2].startswith('__crc_'):
        a=int(f[0],16)
        if kv<=a<kv+ks:
            o=ko+(a-kv); crc[f[2][6:]]=struct.unpack('<I',data[o:o+4])[0]
print(f"__kcrctab @ {kv:#x} off {ko:#x} size {ks} → 提取 {len(crc)} 个 CRC",file=sys.stderr)
for n,v in sorted(crc.items()): print(f"{n}=0x{v:08x}")
