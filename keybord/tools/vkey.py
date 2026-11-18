"""vkey.py — 造虚拟键盘往盒子里打按键（不用遥控器也能测 keybd）
盒子上的 /dev/uinput 只吃 UI_DEV_SETUP 那套，老式 write(uinput_user_dev) 会 EINVAL。
    python3 vkey.py right
    python3 vkey.py ctrl+1 ok
"""
import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405c5503
UI_DEV_CREATE = 0x5501

NAMES = {
    "right": 106, "left": 105, "up": 103, "down": 108, "ok": 352,
    "enter": 28, "home": 172, "volup": 115, "voldn": 114, "back": 158,
    "blue": 371, "green": 399, "yellow": 400, "red": 398,
    "ctrl": 29, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6,
    "menu": 139, "playpause": 164, "mute": 113, "info": 358,
    "next": 163, "prev": 165, "power": 116,
}

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, 1)                    # EV_KEY
for c in set(NAMES.values()):
    fcntl.ioctl(fd, UI_SET_KEYBIT, c)
# struct uinput_setup { input_id id; char name[80]; u32 ff_effects_max; }
fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 3, 1, 1, 1, b"vkeybd-test", 0))
# 等 keybd 扫描到并 grab（默认 2s 一次）；设备建好就发键，抓不到就白发了
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(float(os.getenv("VKEY_WAIT", "3")))


def emit(t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))


def key(code):
    emit(1, code, 1)
    emit(0, 0, 0)
    time.sleep(0.05)
    emit(1, code, 0)
    emit(0, 0, 0)
    time.sleep(0.35)


for spec in sys.argv[1:]:
    if spec.startswith("hold:"):        # hold:right — 模拟长按连发
        c = NAMES[spec[5:]]
        emit(1, c, 1)
        emit(0, 0, 0)
        for _ in range(10):
            time.sleep(0.04)
            emit(1, c, 2)
            emit(0, 0, 0)
        emit(1, c, 0)
        emit(0, 0, 0)
        time.sleep(0.35)
    elif "+" in spec:
        mod, k = spec.split("+", 1)
        emit(1, NAMES[mod], 1)
        emit(0, 0, 0)
        key(NAMES[k])
        emit(1, NAMES[mod], 0)
        emit(0, 0, 0)
    else:
        key(NAMES[spec])
print("sent:", " ".join(sys.argv[1:]))

time.sleep(4)   # 设备留着，等 keybd 下一次扫描（默认 2s）接手
