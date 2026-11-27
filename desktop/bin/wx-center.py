#!/usr/bin/env python3
# wx-center.py —— 微信窗口居中：sway 的 for_window resize 在 map 时刻会被
# Electron 自己的尺寸覆盖，只能在 map 之后补一刀（resize set + move absolute）。
import glob, json, os, subprocess, sys, time

W, H = 1280, 720          # 目标窗口尺寸
OUT = "HDMI-A-1"

def sock():
    s = glob.glob('/run/user/0/sway-ipc.*.sock')
    return s[0] if s else None

def msg(*a):
    return subprocess.run(['swaymsg', *a], capture_output=True, text=True).stdout

def tree():
    try:
        return json.loads(msg('-t', 'get_tree') or '{}')
    except Exception:
        return {}

def find(node):
    """返回 (输出尺寸, 微信 con) """
    outw = outh = None
    hit = [None]
    def walk(n):
        nonlocal outw, outh
        if n.get('type') == 'output' and n.get('name') == OUT:
            r = n.get('rect') or {}
            outw, outh = r.get('width'), r.get('height')
        if n.get('app_id') == 'wechat' or n.get('name') == 'Weixin':
            if not hit[0]:
                hit[0] = n
        for c in n.get('nodes', []) + n.get('floating_nodes', []):
            walk(c)
    walk(tree())
    return (outw, outh), hit[0]

s = sock()
while not s:
    time.sleep(0.3)
    s = sock()
os.environ['SWAYSOCK'] = s

deadline = time.time() + 180
done = 0
while time.time() < deadline:
    (ow, oh), con = find(None)
    if con and ow and oh:
        r = con['rect']
        tx, ty = (ow - W) // 2, (oh - H) // 2
        if (r['width'], r['height'], r['x'], r['y']) != (W, H, tx, ty):
            msg('[app_id=wechat] resize set %d %d' % (W, H))
            time.sleep(0.2)
            msg('[app_id=wechat] move absolute position %d %d' % (tx, ty))
            done += 1
            print('center-> %dx%d @ %d,%d (was %dx%d @ %d,%d)' %
                  (W, H, tx, ty, r['width'], r['height'], r['x'], r['y']), flush=True)
        elif done:
            print('stable', flush=True)
    time.sleep(0.5)
