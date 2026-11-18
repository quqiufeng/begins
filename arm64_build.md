# arm64_build.md — arm64 盒子：交叉编译 + 打包 + 部署

> **定位：平台交付文档，只讲这一个平台怎么编、怎么装、怎么验。**
> 架构、C ABI、Lua 分层、开发循环 → 见 `reader_dev.md`（平台无关，一份代码）。
> 代码是同一份，本文只解决「arm64 无桌面盒子」这一种容器的打包部署问题；
> 换平台就照这个模板另写一份（Android 已有自己的链）。
>
> 目标机：X96Max 盒子，Debian 13 arm64，**没有 X / Wayland**，只有 KMS+DRM
> 构建机：x86_64 Ubuntu 24.04，`aarch64-linux-gnu-gcc 13.3.0`
> 工作目录：`~/kernel/reader-test`（sysroot / 工具链 / 交叉构建现场，已 gitignore）

所有命令都实际敲过，所有数字（大小、依赖、路径）都从产物里读出来，不是估的。

---

## 0. 结论先摆出来

| 产物 | 大小 | NEEDED（除 libc/libm） |
|---|---|---|
| `build/native-reader` | 662,424 B | `libgcc_s.so.1` ← 仅此一个 |
| `build/libreader_native.so` | 296,280 B | `libmupdf.so.25.1` `libxml2.so.2` `libzip.so.5` `libz.so.1` |
| `build/libreader_ctl.so` | 70,528 B | —（只链 libc） |

`native-reader` 是 ELF aarch64 PIE，`RUNPATH=$ORIGIN/lib:$ORIGIN`，
业务库全在自己目录下，**不需要 `LD_LIBRARY_PATH`**。

三条渲染链路在盒子上实机通过（截图同目录）：
`shot-nobook.png` 书库空态 / `shot-book.png` TXT 中文+拉丁混排 /
`shot-pdf.png` 534 页 PDF 向量渲染 / `shot-kms.png` kmsdrm 上屏。

---

## 1. 目标机的硬约束（先搞清楚再动手）

盒子上 **什么都有、就是没有桌面**：

```console
$ ssh root@192.168.1.121 'cat /etc/os-release | head -2; ls /dev/dri /dev/fb0'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
/dev/dri: card0 renderD128
/dev/fb0
```

- 有 `/dev/dri/card0`、`/dev/fb0`（2560x2160）、`/dev/input/event*`
- 无 Xorg、无 Wayland、无 libGL 桌面栈
- HDMI 实际输出 2560x1440@60
- 所以 **SDL 只能用 `kmsdrm` 或 `dummy` 视频驱动**，永远别指望 `x11`

这三个约束决定了后面所有设计选择：
1. 不能用「桌面 Linux 那套」依赖（GTK/Qt/GLX），只用 SDL2 + MuPDF；
2. 所有窗口/输入自己画、自己读 evdev（见 `keybord/`）；
3. 验收必须靠**截图文件 + 日志**，不能靠 GUI 点。

---

## 2. 为什么不直接在盒子上编

盒子 4 核 A53，编 MuPDF + 链接 71 MB 的 `libmupdf.so` 要按小时算；
而且盒子上没有 `-dev` 头文件、没有 cmake 工具链、没有 git 缓存。

交叉编译的真实成本只有两件事：**一套 sysroot** + **一个 toolchain 文件**。
配好之后增量编译是秒级；改一行 lua 不用重编 —— 部署时把 `lua/` 一起 scp
上去就生效（见 §8），这是「开发在桌面、交付按平台」能分开的关键。

---

## 3. 环境：工具链 + sysroot

### 3.1 宿主侧装交叉工具链

```bash
sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
                        cmake pkg-config
aarch64-linux-gnu-gcc --version   # 13.3.0
```

### 3.2 sysroot 两条取法（选一条）

**A. 从盒子上直接打包运行时库**（最快，保证与盒子 ABI 完全一致）

```bash
S=~/kernel/reader-test/sysroot
mkdir -p $S/usr/lib/aarch64-linux-gnu
ssh root@192.168.1.121 \
  'cd /usr/lib/aarch64-linux-gnu && tar cfh - libmupdf.so.25.1 libSDL2-2.0.so.0 \
     libzip.so.5 libxml2.so.2 libmobi.so.0 libfreetype.so.6 libharfbuzz.so.0 \
     libpng16.so.16 libz.so.1' | tar xf - -C $S/usr/lib/aarch64-linux-gnu
```

> **`tar cfh` 的 `-h` 不是可选项。** 盒子上的 `libSDL2.so`、`libxml2.so`、
> `libmobi.so`、`libz.so` 是指向带完整版本号文件名（`.0.3200.4` / `.2.9.14` /
> `.0.0.0` / `.1.3.1`）的软链。不加 `-h`，tar 会把软链原样存下来，
> 回到 x86 上就是一堆 `BROKEN` 链接，`ld` 报 `cannot find -lSDL2` 而你以为库没拷全。

**B. 用 Debian 的 arm64 dev 包拼**（拿到头文件 + `.pc`，可重复、可版本化）

```bash
mkdir -p ~/kernel/reader-test/sysroot-debs && cd ~/kernel/reader-test/sysroot-debs
for p in libmupdf-dev libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
         libmobi-dev libzip-dev libxml2-dev libfreetype-dev libharfbuzz-dev \
         libpng-dev libjpeg-dev zlib1g-dev; do
    apt-get download $p:arm64
done
for d in *.deb; do dpkg-deb -x "$d" ../sysroot; done
```

本次实际用的是 **B**：12 个 deb（4.4 MB）解出 95 MB 的 sysroot，含
`usr/include/{mupdf,SDL2,...}` 和 `usr/lib/aarch64-linux-gnu/pkgconfig/*.pc`。
`libmupdf-dev_1.25.1+ds1-6+deb13u1_arm64.deb` 里的 `libmupdf.so.25.1`（71 MB）
就是后来链接用的那一个 —— 版本和盒子一致，省掉自己编 MuPDF。

### 3.3 校验 sysroot 没坏

```bash
find ~/kernel/reader-test/sysroot -xtype l        # 必须为空：没有 BROKEN 软链
readelf -h sysroot/usr/lib/aarch64-linux-gnu/libmupdf.so.25.1 | grep Machine
# Machine: AArch64      ← 拿错架构在这里就会露出来
```

---

## 4. 工具链文件 `toolchain-aarch64.cmake`

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(SYSROOT "$ENV{READER_SYSROOT}")
set(CMAKE_SYSROOT "${SYSROOT}")

set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_AR           aarch64-linux-gnu-ar)
set(CMAKE_RANLIB       aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP        aarch64-linux-gnu-strip)

set(CMAKE_FIND_ROOT_PATH "${SYSROOT}" "${SYSROOT}/usr")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # 构建期工具仍跑在 x86 上
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_PREFIX_PATH "${SYSROOT}/usr" "${SYSROOT}/usr/lib/aarch64-linux-gnu")
```

四个 `MODE` 那几行是防「悄悄链接到宿主 x86 库」的唯一保险：
`PROGRAM NEVER` 让 cmake/lua 生成器等构建期工具照常用宿主二进制，
剩下三个 `ONLY` 逼 `find_library/find_path/pkg-config` 只在 sysroot 里找。

---

## 5. 三方依赖怎么办

### 5.1 libmobi —— 自建静态库

`libmobi` 不在 sysroot 的运行时集合里（只有 deb 的 `libmobi.a` 可选），
本次是源码交叉编出静态库，落在 `reader-test/mobi/src/.libs/libmobi.a`：

```bash
cd ~/kernel/reader-test/mobi
./autogen.sh
./configure --host=aarch64-linux-gnu \
            CC=aarch64-linux-gnu-gcc --enable-static --disable-shared
make -j$(nproc)
```

CMake 里用 `LIBMOBI_ROOT` 指过去，`reader_native` 直接把它 `.a` 链进 `.so`
（静态进动态，最后只暴露 MuPDF 那几个 NEEDED）。

### 5.2 MuPDF —— 优先用盒子的 `.so`，必要时源码编

```cmake
set(MUPDF_ROOT "/opt/mupdf" CACHE PATH "MuPDF root")
set(MUPDF_LIB  "${MUPDF_ROOT}/build/shared-release/libmupdf.so" CACHE FILEPATH ...)
```

交叉构建时覆盖成 sysroot 里的：

```bash
-DMUPDF_ROOT=$S/usr -DMUPDF_LIB=$S/usr/lib/aarch64-linux-gnu/libmupdf.so
```

如果以后必须自己编（要打补丁、或盒子版本 API 不够），备选脚本
`~/kernel/mupdf-build/mupdf-1.24.10-source/build-cross.sh`：

```bash
make -j$(nproc) build=release \
  HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no HAVE_LIBARCHIVE=no tesseract=no pkcs7=no \
  CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ AR=aarch64-linux-gnu-ar \
  RANLIB=aarch64-linux-gnu-ranlib LD=aarch64-linux-gnu-ld HAVE_LIBCRYPTO=no \
  XCFLAGS="-O2 -fPIC -DHAVE_PTHREAD" OUT=build/aarch64 libs tools
```

关掉 X11/GLUT/CURL/LIBARCHIVE/Tesseract —— 无桌面目标不需要它们，
少一个依赖就少一次「盒子上找不到 .so.xx」。

---

## 6. configure & build（完整可复制的命令）

```bash
S=$HOME/kernel/reader-test/sysroot
R=$HOME/kernel/reader-test/mobi
B=$HOME/kernel/reader-test/build
export READER_SYSROOT=$S

PKG_CONFIG_LIBDIR=$S/usr/lib/aarch64-linux-gnu/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=$S \
cmake -S ~/Desktop/reader -B $B \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/kernel/reader-test/toolchain-aarch64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DMUPDF_ROOT=$S/usr \
  -DMUPDF_LIB=$S/usr/lib/aarch64-linux-gnu/libmupdf.so \
  -DLIBMOBI_ROOT=$R \
  -DREADER_OCR=OFF

cmake --build $B -j$(nproc)
```

两个必须注意的点：

- **`PKG_CONFIG_LIBDIR` 不是 `PKG_CONFIG_PATH`。**
  `PATH` 是「在默认目录之外追加」，默认目录（宿主 `/usr/lib/x86_64-linux-gnu/pkgconfig`）
  仍然生效，`pkg_check_modules(SDL2)` 会拿到**宿主的** `-lSDL2` 和 `-I/usr/include/SDL2`，
  然后你会在链接期看到 x86_64 的 `.so` 或一堆 undefined。`LIBDIR` 是「换掉默认目录」。
  `PKG_CONFIG_SYSROOT_DIR` 把 `.pc` 里的 `-I/usr/include` 自动前缀成 `$S/usr/include`。
- **`READER_OCR=OFF`。** OCR 那条链是 ONNX Runtime，本机只有
  `x86_64` 的 `libonnxruntime.so`，交叉时必然失败。arm64 版可另找 ORT 的 aarch64 包，
  那是另一个话题（见第 11 节）。

---

## 7. 产物审计（交叉编译必须自己做这一步）

```console
$ file build/native-reader
ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked, ...

$ objdump -p build/native-reader | grep -E 'NEEDED|RUNPATH'
  NEEDED   ld-linux-aarch64.so.1
  NEEDED   libc.so.6
  NEEDED   libgcc_s.so.1
  NEEDED   libm.so.6
  RUNPATH  $ORIGIN/lib:$ORIGIN

$ objdump -p build/libreader_native.so | grep -E 'NEEDED|RUNPATH'
  NEEDED   libmupdf.so.25.1
  NEEDED   libxml2.so.2
  NEEDED   libzip.so.5
  NEEDED   libz.so.1
  RUNPATH  $ORIGIN
```

`$ORIGIN` 的 RUNPATH 由 CMakeLists 里这几行保证，是「拖到盒子任意目录都能跑」的关键：

```cmake
set_target_properties(reader_native PROPERTIES
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH TRUE)
```

`BUILD_WITH_INSTALL_RPATH` 让**构建产物本身**就带 RPATH（不用先 install），
否则你从 build 目录直接 scp 过去，RPATH 还是空的，运行期只能靠
`LD_LIBRARY_PATH` —— 那种「在 ssh 里手动 export 才跑得起来」的部署，
换个 `systemd`/`setsid` 启动就崩，等于没交付。

> 提醒：`ldd` 在 x86 上对 aarch64 产物会输出 `not a dynamic executable`，
> 别被吓到。审计用 `objdump -p` / `readelf -d`，别用 `ldd`。

---

## 8. 部署（只带运行时真正要的东西）

盒子没有 `rsync`，用 tar over ssh：

```bash
R=/opt/reader
ssh root@192.168.1.121 "mkdir -p $R/{build,lua,assets/fonts,assets/icons,testdata}"

tar cf - build/native-reader build/libreader_native.so build/libreader_ctl.so \
  | ssh root@192.168.1.121 "tar xf - -C $R/build"

tar cf - lua | ssh root@192.168.1.121 "tar xf - -C $R"
```

**资源要挑，不要整目录拖。** 本地 `assets/` 有 37 MB（各种字重、图标、样例），
运行时真正需要的只有：

```
assets/fonts/TsangerJinKai02-W04.ttf   18,948,244 B   ← 中文正文
assets/fonts/TsangerJinKai02-W05.ttf   18,953,516 B   ← 中文粗体/标题
assets/icons/native-reader.bmp                      ← 窗口/任务栏图标
```

其余字重盒子用不到，白占 20 MB。`testdata/` 只放一本 `sample.txt` 和一本
`cjk.pdf` 用来验收。

---

## 9. 在无桌面上跑起来

### 9.1 真上屏（kmsdrm）

```bash
ssh root@192.168.1.121 'cd /opt/reader && READER_ROOT=/opt/reader \
  SDL_VIDEODRIVER=kmsdrm ./build/native-reader testdata/sample.txt'
```

盒子 `card0` 独占，**同时只能有一个 kmsdrm 进程**；起之前先
`pkill -f native-reader`，否则第二个进程拿到 `SDL_Init` 失败，
日志里只有一句「could not initialize KMSDRM video driver」，
很容易误判成「库没装」。

### 9.2 无人值守 / CI（dummy 驱动 + 截帧）

```bash
SDL_VIDEODRIVER=dummy ./build/native-reader testdata/cjk.pdf \
  --page 1 --zoom 1.0 --frames 8 --screenshot /tmp/p1.png
```

自己实现的三个参数（`main.c` 里解析）：
位置参数 = 书路径；`--screenshot` 出 PNG；`--page` / `--zoom` 定视图；
`--frames N` 跑 N 帧后退出 —— headless 下没有事件循环可等，用帧数给确定性退出点。

`~/kernel/reader-test/box-launch.sh` 把「后台起、等 socket、打印日志」封好了：

```bash
./box-launch.sh /opt/reader/testdata/sample.txt
# pid=12345
# sock=up
# --- log ---
```

### 9.3 工作目录的坑

`main.c` 里 lua 路径是**硬编码相对当前目录**的（`lua/ui/app.lua` + `./lua/?.lua` 搜索路径），
所以必须 `cd /opt/reader` 再起，或者用 `READER_ROOT` 指定根。
从 `/` 或 `/tmp` 启动的表现是：窗口起来了，但书库空白 + 日志 `cannot open lua/ui/app.lua`。

---

## 10. 验收：三条链路都要有截图

| 场景 | 命令 | 证据 |
|---|---|---|
| 书库空态 | `dummy` + `--screenshot` | `shot-nobook.png` |
| TXT（中文+拉丁混排、断行分页） | `testdata/sample.txt` | `shot-book.png` |
| PDF 534 页（852x1103 向量） | `testdata/cjk.pdf` | `shot-pdf.png` |
| 真 KMS 上屏 | `SDL_VIDEODRIVER=kmsdrm` | `shot-kms.png` |

判断标准不是「窗口开了」，而是：
1. 中文不是方块/豆腐（说明 `TsangerJinKai02` 被 freetype 从字体文件加载了，
   而不是 fallback 到系统字体 —— 盒子上没有中文字体）；
2. 长行在版面宽度处正确断行、分页符位置合理（排版逻辑在 lua 里跑通了）；
3. PDF 放大后边缘仍是矢量锐利（MuPDF 走的是 render，不是位图缩放）。

---

## 11. 坑位速查表

| 现象 | 根因 | 解法 |
|---|---|---|
| `cannot find -lSDL2` / 链接到 x86 `.so` | pkg-config 用了宿主默认目录 | 设 `PKG_CONFIG_LIBDIR`（不是 `PATH`） |
| 头文件搜到 `/usr/include/SDL2` | 同上 + sysroot 未前缀 | 加 `PKG_CONFIG_SYSROOT_DIR=$S` |
| sysroot 里一堆 `BROKEN` 软链 | 打包软链库时没 `-h` | `tar cfh`，或事后 `ln -sf` 重指 |
| 运行报 `libSDL2-2.0.so.0: cannot open` | 只拷了 `.so` 软链没拷实体 | 传实体文件 + 在盒子建软链 |
| 换启动方式就找不到库 | 靠 `LD_LIBRARY_PATH` 临时糊的 | `INSTALL_RPATH=$ORIGIN` + `BUILD_WITH_INSTALL_RPATH` |
| `SDL_Init` 失败 | 已有进程占着 card0，或忘了 `SDL_VIDEODRIVER` | `pkill -f native-reader`；显式给 `kmsdrm`/`dummy` |
| 窗口起来但白屏 | 工作目录不对，lua 没加载 | `cd /opt/reader`，或设 `READER_ROOT` |
| 中文全豆腐 | 字体没带到盒子 / 路径不对 | 只带 `assets/fonts` 的两个 ttf |
| 交叉时报 `onnxruntime` 架构不符 | OCR 只有 x86_64 ORT | `-DREADER_OCR=OFF` |
| 盒子上编到天荒地老 | 4 核 A53 + 71 MB 库链接 | 交叉编译，增量秒级 |

---

## 12. 从零复现（一次粘贴）

```bash
set -e
S=$HOME/kernel/reader-test/sysroot
mkdir -p $S ~/kernel/reader-test/sysroot-debs
cd ~/kernel/reader-test/sysroot-debs
for p in libmupdf-dev libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev libmobi-dev \
         libzip-dev libxml2-dev libfreetype-dev libharfbuzz-dev libpng-dev \
         libjpeg-dev zlib1g-dev; do apt-get download $p:arm64; done
for d in *.deb; do dpkg-deb -x "$d" $S; done
find $S -xtype l && { echo "有 BROKEN 软链，先修" ; exit 1; }

export READER_SYSROOT=$S
PKG_CONFIG_LIBDIR=$S/usr/lib/aarch64-linux-gnu/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=$S \
cmake -S ~/Desktop/reader -B ~/kernel/reader-test/build \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/kernel/reader-test/toolchain-aarch64.cmake \
  -DCMAKE_BUILD_TYPE=Release -DMUPDF_ROOT=$S/usr \
  -DMUPDF_LIB=$S/usr/lib/aarch64-linux-gnu/libmupdf.so \
  -DLIBMOBI_ROOT=$HOME/kernel/reader-test/mobi -DREADER_OCR=OFF
cmake --build ~/kernel/reader-test/build -j$(nproc)

objdump -p ~/kernel/reader-test/build/native-reader | grep -E 'NEEDED|RUNPATH'
```

部署 + 验收：

```bash
B=~/kernel/reader-test/build
ssh root@192.168.1.121 "mkdir -p /opt/reader/{build,lua,assets/fonts,assets/icons,testdata}"
tar cf - -C $B native-reader libreader_native.so libreader_ctl.so \
  | ssh root@192.168.1.121 'tar xf - -C /opt/reader/build'
tar cf - -C ~/Desktop/reader lua assets/fonts/TsangerJinKai02-W04.ttf \
        assets/fonts/TsangerJinKai02-W05.ttf assets/icons/native-reader.bmp \
  | ssh root@192.168.1.121 'tar xf - -C /opt/reader'
tar cf - -C ~/Desktop/reader testdata/sample.txt \
  | ssh root@192.168.1.121 'tar xf - -C /opt/reader'
scp ~/kernel/reader-test/cjk.pdf root@192.168.1.121:/opt/reader/testdata/  # PDF 验收用

ssh root@192.168.1.121 'cd /opt/reader && SDL_VIDEODRIVER=kmsdrm \
  READER_ROOT=/opt/reader ./build/native-reader testdata/sample.txt'
```

---

## 13. 平台交付清单（换平台照这张表填）

新增一个平台的产物容器时，逐项确认；代码侧一行不改。

| # | 项目 | 本平台（arm64 盒子）的答案 |
|---|---|---|
| 1 | 依赖怎么来 | sysroot 从固定版本 deb 解（`deb13u1`），`apt-get download $p:arm64` 可重建 |
| 2 | 依赖放哪 | `$ORIGIN` / `$ORIGIN/lib` 自包含，`LD_LIBRARY_PATH` 全程不出现 |
| 3 | `NEEDED` 是否可审计 | 5 个库（mupdf/xml2/zip/z + libgcc_s），其余静态进 `.so` |
| 4 | lua 与 C 的边界 | 同一个 `rd_*` ABI、同一份 `lua/`，运行期加载 |
| 5 | 显示后端 | `SDL_VIDEODRIVER=kmsdrm`；CI 用 `dummy` |
| 6 | cwd 假设 | 必须 `cd /opt/reader`（`package.path` 相对 cwd，见 reader_dev.md §5） |
| 7 | 启动方式 | `box-launch.sh` 封装 + `setsid`，不留 tty |
| 8 | 验收证据 | 三张截图 + 日志，不接受「我看着没问题」 |

同构参照：`hevcdec/` 的 `make CROSS=1` 也是这套（cross gcc + `$ORIGIN` 库 +
产物 scp），视频解码和阅读器共用一套 arm64 交付方式。

---

## 附：相关文件位置

| 内容 | 路径 |
|---|---|
| 平台无关的开发文档 | `~/kernel/reader_dev.md`（架构 / ABI / 开发循环） |
| 应用源码 | `~/Desktop/reader`（github.com:quqiufeng/reader） |
| 交叉现场（gitignore） | `~/kernel/reader-test/`（219 MB，含 sysroot 95 MB） |
| 工具链文件 | `~/kernel/reader-test/toolchain-aarch64.cmake` |
| sysroot debs | `~/kernel/reader-test/sysroot-debs/`（12 个，4.4 MB） |
| MuPDF 源码交叉（备选） | `~/kernel/mupdf-build/mupdf-1.24.10-source/build-cross.sh` |
| 运行时启动封装 | `~/kernel/reader-test/box-launch.sh` |
| SDL2 KMS 冒烟测试 | `~/kernel/reader-test/sdltest.lua`（纯 FFI，不用编译） |
| 端到端最小验证 | `~/kernel/reader-test/e2e.c`（MuPDF 渲染 + SDL 窗口） |
