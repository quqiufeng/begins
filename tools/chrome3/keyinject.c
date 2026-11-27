// keyinject —— 通过 /dev/uinput 造一个虚拟键盘并注入按键
// 用法: keyinject <key> [key...]   键名见下表，或直接 KEY_xxx
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <linux/input.h>
#include <linux/uinput.h>

static struct { const char *n; int c; } TBL[] = {
    {"up", KEY_UP}, {"down", KEY_DOWN}, {"left", KEY_LEFT}, {"right", KEY_RIGHT},
    {"ok", KEY_OK}, {"enter", KEY_ENTER}, {"esc", KEY_ESC}, {"home", KEY_HOME},
    {"back", KEY_BACK}, {"menu", KEY_MENU}, {"volup", KEY_VOLUMEUP}, {"voldn", KEY_VOLUMEDOWN},
    {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN}, {"tab", KEY_TAB},
    {"space", KEY_SPACE}, {"a", KEY_A}, {"b", KEY_B}, {"1", KEY_1}, {"2", KEY_2},
    {NULL, 0}
};

static int lookup(const char *s)
{
    for (int i = 0; TBL[i].n; i++) if (!strcmp(TBL[i].n, s)) return TBL[i].c;
    if (!strncasecmp(s, "KEY_", 4)) {
        char *e; long v = strtol(s + 4, &e, 10);
        if (*e == 0) return (int)v;
    }
    return -1;
}

static void emit(int fd, int type, int code, int val)
{
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type; ev.code = code; ev.value = val;
    write(fd, &ev, sizeof ev);
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "用法: %s <key> [key...]\n", argv[0]); return 1; }
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { perror("open /dev/uinput"); return 1; }

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_KEYBIT, KEY_UP); ioctl(fd, UI_SET_KEYBIT, KEY_DOWN);
    ioctl(fd, UI_SET_KEYBIT, KEY_LEFT); ioctl(fd, UI_SET_KEYBIT, KEY_RIGHT);
    ioctl(fd, UI_SET_KEYBIT, KEY_OK); ioctl(fd, UI_SET_KEYBIT, KEY_ENTER);
    ioctl(fd, UI_SET_KEYBIT, KEY_ESC); ioctl(fd, UI_SET_KEYBIT, KEY_HOME);
    ioctl(fd, UI_SET_KEYBIT, KEY_BACK); ioctl(fd, UI_SET_KEYBIT, KEY_MENU);
    ioctl(fd, UI_SET_KEYBIT, KEY_PAGEUP); ioctl(fd, UI_SET_KEYBIT, KEY_PAGEDOWN);
    ioctl(fd, UI_SET_KEYBIT, KEY_TAB); ioctl(fd, UI_SET_KEYBIT, KEY_SPACE);
    ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEUP); ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEDOWN);
    for (int i = KEY_A; i <= KEY_Z; i++) ioctl(fd, UI_SET_KEYBIT, i);

    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_USB;
    us.id.vendor = 0x1234; us.id.product = 0x5678;
    snprintf(us.name, sizeof us.name, "lite-browser-kbd");
    if (ioctl(fd, UI_DEV_SETUP, &us) || ioctl(fd, UI_DEV_CREATE)) { perror("uidev"); return 1; }
    usleep(300000);   /* 等 libinput 发现设备 */

    for (int i = 1; i < argc; i++) {
        int code = lookup(argv[i]);
        if (code < 0) { fprintf(stderr, "未知键: %s\n", argv[i]); continue; }
        emit(fd, EV_KEY, code, 1); emit(fd, EV_SYN, SYN_REPORT, 0);
        usleep(60000);
        emit(fd, EV_KEY, code, 0); emit(fd, EV_SYN, SYN_REPORT, 0);
        usleep(120000);
        printf("注入 %s (code %d)\n", argv[i], code);
    }
    usleep(200000);
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
