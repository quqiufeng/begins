# 代码量台账（linux-7.2.12，仅 x86）
顶层（C/H/S 行数）：
drivers 26,024,616 / include 1,467,369 / tools 1,413,437 / sound 1,672,987
fs 1,645,569 / net 1,301,266 / arch 476,101 / lib 324,214 / kernel 560,442
security 128,919 / mm 224,076 / crypto 104,452 / samples 36,199 / scripts 62,658
block 73,172 / io_uring 27,429 / rust 3,049 / virt 11,044 / usr 882 / init 4,738
ipc 9,885 / certs 1,066
drivers 前几大：gpu 8,268,787 / net 5,264,916 / media 1,540,898 / scsi 1,021,462
                clk 830,219 / pinctrl 587,985 / usb 584,063 / infiniband 441,025
                iio 410,935 / accel 383,625 / staging 306,904

# 基线复现（2026-11-10）
串口/serial: 让 serial8250 内置 → 需改 CONFIG_SERIAL_8250=y
（本次未改，仅记录）
vmlinux 602MB, __kcrctab 14767 条 CRC
契约 610 = 内置 490（全中，0 不符）+ 模块 120（需 make modules 才能验）
