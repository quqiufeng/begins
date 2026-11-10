#!/usr/bin/env python3
"""把裁剪树适配到当前这台机器。

思路：不猜符号，直接问机器。
  1. probe  —— 读 /sys，把本机真正在用/存在的驱动名捞出来（pci、usb、net、block、lsmod）
  2. plan   —— 驱动名 → 模块名 → CONFIG 符号（解析 Makefile 的 obj-$(CONFIG_X) += y.o）
                → 所在目录；再对比树里还有没有这个目录
  3. fetch  —— 缺的目录从上游 tar.xz 只解出这几个，cp 回树里
  4. config —— 生成 config 片段，merge 进 .config，olddefconfig 后回报没生效的符号

用法（在目标机器上跑）：
    python3 tools/trim/adapt.py probe
    python3 tools/trim/adapt.py plan
    sudo python3 tools/trim/adapt.py fetch --apply
    python3 tools/trim/adapt.py config --apply
"""
import argparse, json, os, re, subprocess, sys, tarfile, glob

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREE = os.path.join(ROOT, "src", "linux-7.2.12")
NOTES = os.path.join(ROOT, "notes")
DEFAULT_TAR = "/opt/linux/src/linux-7.2.12.tar.xz"

# 这些不是“某块硬件的驱动”，是总线/框架/核心，缺了才需处理，别当缺失驱动
CORE = {
    "pcieport", "pci", "usb", "hub", "usbfs", "button", "processor", "acpi",
    "container", "pnp", "rtc_cmos", "serial8250", "8250", "i8042",
}


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=30).stdout.strip()
    except Exception:
        return ""


def norm(name):
    """驱动名/模块名归一：snd-usb-audio / snd_usb_audio → sndusbaudio"""
    return re.sub(r"[-_]", "", name).lower()


# ---------------------------------------------------------------- probe
def probe():
    hw = {"pci": [], "usb": [], "net": [], "block": [], "modules": [],
          "kernel": os.uname().release, "host": os.uname().nodename}

    for dev in sorted(glob.glob("/sys/bus/pci/devices/*")):
        driver = os.path.basename(os.readlink(os.path.join(dev, "driver"))) \
            if os.path.exists(os.path.join(dev, "driver")) else ""
        hw["pci"].append({
            "slot": os.path.basename(dev),
            "id": "%s:%s" % (open(os.path.join(dev, "vendor")).read().strip()[2:],
                             open(os.path.join(dev, "device")).read().strip()[2:]),
            "driver": driver,
            "class": open(os.path.join(dev, "class")).read().strip() if
                     os.path.exists(os.path.join(dev, "class")) else "",
        })

    for iface in sorted(glob.glob("/sys/bus/usb/drivers/*")):
        name = os.path.basename(iface)
        if os.listdir(iface):
            hw["usb"].append({"driver": name,
                              "count": len([x for x in os.listdir(iface)
                                            if not x.startswith(("bind", "unbind", "uevent", "module", "new_id", "remove_id"))])})

    for nic in sorted(glob.glob("/sys/class/net/*")):
        d = os.path.join(nic, "device", "driver")
        hw["net"].append({"iface": os.path.basename(nic),
                          "driver": os.path.basename(os.readlink(d)) if os.path.exists(d) else "virtual"})

    hw["modules"] = sorted({l.split()[0] for l in sh("lsmod").splitlines()[1:] if l.split()})
    hw["pci_brief"] = sh("lspci -nn 2>/dev/null")
    return hw


# ---------------------------------------------------------------- 索引
def parse_makefiles(basedir, prefix):
    """Makefile → {归一模块名: (CONFIG, 相对目录)}；dir 类型 += 也记一份"""
    idx = {}
    pat = re.compile(r"^obj-\$\(CONFIG_([A-Z0-9_]+)\)\s*[:+]?=\s*(.+)$")
    for dirpath, _, files in os.walk(basedir):
        if "Makefile" not in files:
            continue
        rel = os.path.relpath(dirpath, basedir)
        try:
            text = open(os.path.join(dirpath, "Makefile"), errors="ignore").read()
        except OSError:
            continue
        for line in text.splitlines():
            m = pat.match(line.strip())
            if not m:
                continue
            sym, targets = m.group(1), m.group(2)
            for t in targets.split():
                t = t.strip().rstrip("\\")
                if t.endswith(".o"):
                    idx.setdefault(norm(t[:-2]), (sym, rel, "obj"))
                elif t.endswith("/"):
                    idx.setdefault(norm(t[:-1]), (sym, rel, "dir"))
    return idx


def upstream_makefile_index(tar, cache):
    """上游 Makefile 索引（只解 Makefile，缓存到 notes/.cache）"""
    js = os.path.join(cache, "index.json")
    if os.path.exists(js):
        raw = json.load(open(js))
        return {k: tuple(v) for k, v in raw.items()}
    os.makedirs(cache, exist_ok=True)
    tmp = os.path.join(cache, "mk")
    if not os.path.isdir(tmp):
        os.makedirs(tmp)
        print("  · 从上游解 Makefile（首次，稍慢）…", file=sys.stderr)
        with tarfile.open(tar, "r:*") as tf:
            members = [m for m in tf.getmembers()
                       if m.name.endswith("/Makefile") and m.isfile()]
            tf.extractall(tmp, members=members)
    idx = {}
    top = os.path.join(tmp, os.listdir(tmp)[0])
    for dirpath, _, files in os.walk(top):
        if "Makefile" not in files:
            continue
        rel = os.path.relpath(dirpath, top)
        text = open(os.path.join(dirpath, "Makefile"), errors="ignore").read()
        for line in text.splitlines():
            m = re.match(r"^obj-\$\(CONFIG_([A-Z0-9_]+)\)\s*[:+]?=\s*(.+)$", line.strip())
            if not m:
                continue
            sym, targets = m.group(1), m.group(2)
            for t in targets.split():
                t = t.rstrip("\\")
                if t.endswith(".o"):
                    idx.setdefault(norm(t[:-2]), [sym, rel, "obj"])
                elif t.endswith("/"):
                    idx.setdefault(norm(t[:-1]), [sym, rel, "dir"])
    json.dump(idx, open(js, "w"))
    return {k: tuple(v) for k, v in idx.items()}


def read_config():
    p = os.path.join(TREE, ".config")
    cfg = {}
    if os.path.exists(p):
        for line in open(p):
            m = re.match(r"^(CONFIG_[A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                cfg[m.group(1)] = m.group(2)
    return cfg


# ---------------------------------------------------------------- plan
def plan(args):
    hw = json.load(open(os.path.join(NOTES, "hw.json")))
    cache = os.path.join(NOTES, ".cache")
    idx = upstream_makefile_index(args.tar, cache)
    tree_idx = parse_makefiles(TREE, TREE)
    idx.update({k: v for k, v in tree_idx.items() if k not in idx})
    cfg = read_config()

    wanted = {}   # driver -> {config, dir, why}
    drv_names = set()
    for p in hw["pci"]:
        if p["driver"]:
            drv_names.add(p["driver"])
    for u in hw["usb"]:
        drv_names.add(u["driver"])
    for n in hw["net"]:
        if n["driver"] != "virtual":
            drv_names.add(n["driver"])
    for m in hw["modules"]:
        drv_names.add(m)

    unresolved = []
    for d in sorted(drv_names):
        if d in CORE:
            continue
        hit = idx.get(norm(d))
        if not hit:
            unresolved.append(d)
            continue
        sym, rel, kind = hit
        wanted.setdefault(sym, {"config": sym, "dir": rel if kind == "dir" else os.path.dirname(rel),
                                "drivers": set()})
        wanted[sym]["drivers"].add(d)

    missing_dirs, satisfied, absent = [], [], []
    for sym, w in sorted(wanted.items()):
        d = w["dir"]
        have_dir = os.path.isdir(os.path.join(TREE, d))
        state = cfg.get("CONFIG_" + sym)
        w["drivers"] = sorted(w["drivers"])
        w["state"] = state
        w["have_dir"] = have_dir
        if not have_dir:
            missing_dirs.append(w)
        elif state in ("y", "m"):
            satisfied.append(w)
        else:
            absent.append(w)

    out = {"host": hw["host"], "kernel": hw["kernel"],
           "missing_dirs": missing_dirs, "absent_config": absent,
           "satisfied": satisfied, "unresolved": unresolved}
    os.makedirs(NOTES, exist_ok=True)
    json.dump(out, open(os.path.join(NOTES, "adapt-plan.json"), "w"), indent=1, ensure_ascii=False)

    print("本机 %s（%s）" % (hw["host"], hw["kernel"]))
    print("  在用的驱动/模块 %d 个\n" % len(drv_names))
    print("✅ 已就绪 %d 个：%s" % (len(satisfied), ", ".join(w["config"] for w in satisfied) or "无"))
    if absent:
        print("\n⚠️  目录在、CONFIG 没开 %d 个（改 config 即可）" % len(absent))
        for w in absent:
            print("   %-24s %s  ← %s" % (w["config"], w["state"] or "未设置", ", ".join(w["drivers"])))
    if missing_dirs:
        print("\n❌ 目录被删了 %d 个（要先从上游拷回来）" % len(missing_dirs))
        for w in missing_dirs:
            exists = os.path.isdir(os.path.join(args.upstream or "/nonexistent", w["dir"]))
            print("   %-24s %-42s ← %s%s" % (w["config"], w["dir"], ", ".join(w["drivers"]),
                                             "" if exists else "  (上游这一层是父目录，需按文件定位)"))
    if unresolved:
        print("\n· 对不上 CONFIG 的 %d 个（多为 core/总线，通常可忽略）：%s"
              % (len(unresolved), ", ".join(unresolved)))
    print("\n计划写入 notes/adapt-plan.json")
    return out


# ---------------------------------------------------------------- fetch
def fetch(args):
    p = os.path.join(NOTES, "adapt-plan.json")
    if not os.path.exists(p):
        sys.exit("先跑 probe + plan")
    planj = json.load(open(p))
    dirs = sorted({w["dir"] for w in planj["missing_dirs"]})
    if not dirs:
        print("没有缺失目录，跳过")
        return
    print("要从上游取回 %d 个目录：" % len(dirs))
    for d in dirs:
        print("   ", d)
    if not args.apply:
        print("\n（未加 --apply，仅预演）")
        return
    prefix = os.path.basename(DEFAULT_TAR).replace(".tar.xz", "")
    with tarfile.open(args.tar, "r:*") as tf:
        names = set(tf.getnames())
        for d in dirs:
            want = "%s/%s" % (prefix, d)
            members = [m for m in tf.getmembers()
                       if m.name == want or m.name.startswith(want + "/")]
            if not members:
                print("   ! 上游没有 %s，跳过" % d)
                continue
            dest = os.path.join(TREE, d)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.isdir(dest):
                print("   = 已存在，跳过 %s" % d)
                continue
            tf.extractall(TREE, members=members, filter="data")
            # tar 解出来是 <prefix>/d/...，挪到位
            shutil_move = os.path.join(TREE, prefix, d)
            if os.path.isdir(shutil_move) and os.path.abspath(shutil_move) != os.path.abspath(dest):
                subprocess.run(["cp", "-a", shutil_move + "/.", dest], check=True)
                subprocess.run(["rm", "-rf", os.path.join(TREE, prefix)])
            n = sum(len(f) for _, _, f in os.walk(dest))
            print("   + %s (%d 文件)" % (d, n))
    print("\n完成。接着改 config： python3 tools/trim/adapt.py config --apply")


# ---------------------------------------------------------------- config
def config(args):
    p = os.path.join(NOTES, "adapt-plan.json")
    planj = json.load(open(p))
    need = [w for w in planj["missing_dirs"] + planj["absent_config"]]
    if not need:
        print("本机驱动都已就绪，无需生成 config")
        return
    frag = os.path.join(NOTES, "adapt-%s.config" % planj["host"])
    with open(frag, "w") as f:
        f.write("# 由 tools/trim/adapt.py 按 %s 的硬件生成\n" % planj["host"])
        for w in need:
            f.write("CONFIG_%s=m\n" % w["config"])
    print("生成片段 %s（%d 个符号）" % (os.path.relpath(frag, ROOT), len(need)))
    if not args.apply:
        print("（未加 --apply，只写片段）")
        return
    merge = os.path.join(TREE, "scripts", "kconfig", "merge_config.sh")
    if os.path.exists(merge):
        subprocess.run(["bash", merge, "-m", "-O", TREE, os.path.join(TREE, ".config"), frag],
                       cwd=TREE, check=False)
    subprocess.run(["make", "olddefconfig"], cwd=TREE, check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cfg = read_config()
    bad = [w for w in need if cfg.get("CONFIG_" + w["config"]) not in ("y", "m")]
    if bad:
        print("\n⚠️  合并后仍未生效 %d 个（依赖没满足，需补父符号）：" % len(bad))
        for w in bad:
            print("   CONFIG_%s" % w["config"])
    else:
        print("\n✅ 全部生效，可以 make -j6")


def main():
    ap = argparse.ArgumentParser(description="把裁剪内核适配到本机硬件")
    ap.add_argument("cmd", choices=["probe", "plan", "fetch", "config"])
    ap.add_argument("--tar", default=DEFAULT_TAR, help="上游 tarball")
    ap.add_argument("--upstream", default="", help="已解包的上游目录（仅用于检查）")
    ap.add_argument("--apply", action="store_true", help="真的执行（fetch/config）")
    a = ap.parse_args()
    os.makedirs(NOTES, exist_ok=True)

    if a.cmd == "probe":
        hw = probe()
        json.dump(hw, open(os.path.join(NOTES, "hw.json"), "w"), indent=1, ensure_ascii=False)
        print("上机探测 → notes/hw.json")
        print("  PCI %d 台 / USB 驱动 %d / 网卡 %d / 已加载模块 %d"
              % (len(hw["pci"]), len(hw["usb"]), len(hw["net"]), len(hw["modules"])))
        for n in hw["net"]:
            print("   %-10s %s" % (n["iface"], n["driver"]))
    elif a.cmd == "plan":
        plan(a)
    elif a.cmd == "fetch":
        fetch(a)
    elif a.cmd == "config":
        config(a)


if __name__ == "__main__":
    main()
