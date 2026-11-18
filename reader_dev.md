# reader_dev.md — 平台无关的开发视角（一份代码）

> 对象：`~/Desktop/reader`（git: quqiufeng/reader）
> 配套：**打包/部署按平台各写一份**，见文末「平台交付矩阵」
> 本文只讲「代码怎么写、怎么在开发机上一秒改一秒验」，
> 不讲 sysroot、不讲交叉、不讲 APK 签名 —— 那些属于各自的平台文档。

---

## 0. 一句话架构

```
                     lua/  39 个 .lua，6250 行   ← 全部业务逻辑：书库/排版/渲染调度/UI/主题
                       ↑  FFI 调用（lua/ffi/*.lua 手写 cdef）
        ┌──────────────┼──────────────┬─────────────┐
  libreader_native   libreader_ocr  libreader_ctl   libSDL2
  (MuPDF+libmobi)    (ONNX PP-OCR)  (ioctl 小工具)   (窗口/输入/字体)
                       ↑
                src/main.c 68 行：造 Lua 状态机 → 塞 5 个全局 → dofile("lua/ui/app.lua")
```

**C 只有 1726 行，Lua 6250 行。** 这不是巧合，是有意的分工：

| 层 | 写什么 | 不写什么 |
|---|---|---|
| C `src/shim/reader_api.c`（1431 行） | 文档模型：open/layout/render/toc/links/text/fonts，缓存，PNG 落盘 | 任何界面、任何状态机、任何字符串拼接 |
| C `src/main.c`（68 行） | 起 Lua、传参、加 `package.path` | 所有别的 |
| Lua `lua/ui/*`（32 文件） | 书架、翻页、目录、书签、设置、主题、面板、toast、输入 | 碰指针、碰 FreeType、碰 mupdf 结构体 |
| Lua `lua/ffi/*`（4 文件） | cdef + 薄封装，唯一允许 `ffi.C` 的地方 | 业务判断 |

新平台要做的只有三件事：**给 SDL2、给这几个 `.so`、给一个能跑 lua 的 cwd**。
逻辑一行都不用改 —— 这就是「代码一份、平台各自解决打包」的物理基础。

---

## 1. 目录职责（改代码前先认门）

```
reader/
├── src/
│   ├── main.c                68 行，Lua 宿主
│   ├── shim/reader_api.c     1431 行，rd_* C ABI（唯一的文档后端）
│   ├── shim/mobi_epub.c      124 行，mobi→epub 转换入口
│   ├── shim/ocr_api.cpp      OCR 的 C ABI（可选）
│   ├── ocr/ocr.cpp           DBNet + CRNN 推理
│   └── ctl/reader_ctl.c      103 行，独立小工具，不依赖上面任何东西
├── lua/                      39 个 .lua
│   ├── ffi/{reader,sdl2,sdl2_ttf,ocr}.lua   指针边界（4）
│   ├── core/{library,clock,automation}.lua  书库索引、定时、自动化（3）
│   └── ui/                   32 个文件，见下
├── third_party/luajit/       自带 LuaJIT，静态进 native-reader
├── third_party/stb/          stb_image 等头文件
├── assets/fonts/             TsangerJinKai02 W04/W05
└── testdata/                 sample.txt（TXT）、cjk.pdf（534 页 PDF）
```

`lua/ui/` 32 个文件里，几个容易找错的：

| 文件 | 职责 |
|---|---|
| `app.lua` | 程序入口（`main.c` 直接 dofile 这个），装配所有模块 |
| `loop.lua` | 事件循环 + 帧调度（headless 的 `--frames` 就砍在这里） |
| `layout.lua` / `text.lua` / `page_md.lua` | 断行、分页、行高、中日韩标点处理 |
| `renderer.lua` / `render.lua` / `page_cache.lua` | 位图缓存、缩放、区域重绘 |
| `bookshelf.lua` / `browser.lua` / `file_dialog.lua` | 书库与文件系统 |
| `chrome.lua` / `header.lua` / `panel.lua` / `toast.lua` | 自绘的「窗口装饰」 |
| `screenshot.lua` | `--screenshot` 真正落 PNG 的地方 |

---

## 2. C ABI 是唯一的平台契约

`lua/ffi/reader.lua` 里那段 cdef（39 行）就是全部契约，改它等于改 ABI：

```c
void *rd_open(const char *path, int *err);
int   rd_layout(void *h, float w, float h, float em, float lf, float margin);
int   rd_render_page(void *h, int page, float zoom,
                     int br, int bg, int bb, uint8_t **out, int *w, int *h, int *stride);
char *rd_toc(void *h);          // JSON 字符串，caller 负责 rd_free
int   rd_link_at(void *h, int page, float nx, float ny, int *p, float *x, float *y);
int   rd_save_png(const char *path, int w, int h, const uint8_t *rgba);
```

三条约束，跨平台时最容易踩：

1. **只用 C 类型**：`float` / `int` / `char*`，不出现 `size_t*`、不出现结构体返回、
   不出现 `bool`（LuaJIT 侧 `bool` 是 1 字节，C 侧 `_Bool` 也是，但历史代码里
   统一用 `int`，别混）。
2. **字符串一律 JSON + caller free**：`rd_toc`/`rd_page_text`/`rd_list_dir` 返回
   `malloc` 出来的 JSON，Lua 侧 `rd_free` 回收。32/64 位、大端小端都不影响。
3. **不跨线程**：`rd_*` 都在 Lua 主线程调。要并发就在 Lua 侧开 `lite` 子进程
   或自己 fork，不要给 ABI 加锁。

> 想加新能力（比如 `rd_annotate`），顺序永远是：
> `reader_api.c` 实现 → `lua/ffi/reader.lua` 加 cdef + 包装 → `lua/ui/*` 用起来。
> 不要反过来先写 UI 再补底层，FFI 类型一错就是 segfault，没有栈。

---

## 3. 开发机上的构建（x86_64 桌面，最快那条路）

```bash
cd ~/Desktop/reader
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DMUPDF_ROOT=/opt/mupdf \
  -DLIBMOBI_ROOT=/opt/libmobi \
  -DREADER_OCR=ON \
  -DREADER_OCR_MODEL_DIR=/data/models/ocr
cmake --build build -j$(nproc)
```

四个 target：

| target | 产物 | 依赖 |
|---|---|---|
| `reader_native` | `libreader_native.so` 743 KB（x86_64） | mupdf / libmobi.a / xml2 / zip / z |
| `reader_ctl` | `libreader_ctl.so` 16 KB | 只有 libc |
| `reader_ocr` | `libreader_ocr.so` | ONNX Runtime（找不到就 **自动跳过**，不报错） |
| `native-reader` | `native-reader` 645 KB | 自带静态 LuaJIT + SDL2 |

几个 CMake 细节值得知道：

- `MUPDF_LIB` 默认 `/opt/mupdf/build/shared-release/libmupdf.so`，
  `file(REAL_PATH)` 解出真路径，POST_BUILD 再按它建一个 `libmupdf.so.28.0`
  软链到 build 目录 —— 因为 `.so` 的 SONAME 和文件名常常不一致，运行期认 SONAME。
- `target_link_options(reader_native PRIVATE -Wl,--exclude-libs,ALL)`：
  libmobi.a 静态链进来但**不导出**它的符号，避免和 mupdf 里同名符号打架。
- LuaJIT 是 vendored 的，`add_custom_command` 用 `BUILDMODE=static` 现编
  `libluajit.a`，`native-reader` 链接它并 `-rdynamic`（这样 Lua 侧能拿到 C 符号，
  `ffi.C` 找得到 `rd_*`，不依赖 `ldconfig`）。
- `READER_OCR` 的 `if(ORT_INCLUDE AND ORT_LIB)` —— 缺 ORT 是**正常状态**，
  不是错误。交叉编译、CI、干净容器里都靠这个自动降级。

---

## 4. 改一行、看一帧（开发循环）

Lua 不需要重新编译，`native-reader` 直接 `dofile("lua/ui/app.lua")`：

```bash
cd ~/Desktop/reader
./build/native-reader testdata/sample.txt          # 手点
./build/native-reader testdata/cjk.pdf --page 12 --zoom 2.0
```

`main.c` 只认这几个参数（68 行，没有 getopt、没有配置文件）：

```
<book>            位置参数，一次一个
--page N          初始页
--zoom F          初始缩放（默认 1.2）
--frames N        跑 N 帧后退出（0 = 一直跑）
--screenshot PATH 退出前落一张 PNG
```

参数不是「命令行选项」，是**塞进 Lua 全局变量的初始状态**：
`READER_BOOK` / `READER_PAGE` / `READER_ZOOM` / `READER_FRAMES` / `READER_SCREENSHOT`。
所以自动化脚本可以在 Lua 侧直接改这些全局，不必经过 argv。

无头验证（不打窗口，纯渲染断言）：

```bash
SDL_VIDEODRIVER=dummy ./build/native-reader testdata/cjk.pdf \
  --page 3 --zoom 1.0 --frames 8 --screenshot /tmp/p3.png
```

这条命令是**跨平台通用的**：桌面、盒子、CI 容器里跑的都是它。
差别只在 `SDL_VIDEODRIVER` 取 `x11` / `kmsdrm` / `dummy` —— 
这正是「平台差异收敛在一个环境变量」的设计。

---

## 5. `package.path` 与 cwd（唯一的工作目录假设）

`main.c` 里写死：

```c
snprintf(newpath, sizeof(newpath), "./lua/?.lua;./lua/?/init.lua;%s", oldpath);
luaL_dofile(L, "lua/ui/app.lua");
```

**两个都是相对 cwd 的。** 所以：

- 从仓库根起：`./build/native-reader ...` ✅
- 从 `build/` 起：❌ `cannot open lua/ui/app.lua`
- 从 systemd / `setsid` / 桌面图标起：❌ 同上（cwd 是 `/`）

平台文档里的「安装到 `/opt/reader` 后必须 `cd /opt/reader`」不是偷懒，
是这个设计的直接后果。要改成绝对路径就得引入 `READER_ROOT` 环境变量，
那是接口变更，不是打包问题 —— **不要为了打包去改 C**。

---

## 6. 平台交付矩阵（一份代码，四份打包）

逻辑共享，**打包/部署各自独立**，每个平台一个文档、一套脚本：

| 平台 | 构建方式 | 打包产物 | 显示后端 | 状态 |
|---|---|---|---|---|
| x86_64 桌面（开发机） | 本机 cmake | `build/` 直接跑 | `x11` / `dummy` | 日常开发 |
| **arm64 盒子（无桌面）** | **交叉 cmake**（`arm64_build.md`） | `/opt/reader` 目录 tar | `kmsdrm` / `dummy` | 已上屏 |
| Android arm64 | gradle `abiFilters 'arm64-v8a'`，minSdk 23 / targetSdk 35 | `out/zspace-reader.apk`（`tools/build-apk.sh`） | Android Surface | 另一条链 |
| 其他 | 新写一份 | — | — | 按需 |

两条已经落地的差异化打包，正好说明「分开」的必要：

- **Android 走的是完全不同的路**：不编 cmake、不装 SDL 桌面版，
  用 `reference/base/base.apk` 打底 + 塞 `classes*.dex` + `zipalign` + `apksigner`，
  产物是签好名的 APK（`tools/build-apk.sh`，44 个 dex）。
  同一个 `lua/` 目录、同一个 `rd_*` ABI，装进的是完全不同的容器。
- **arm64 盒子走 sysroot 交叉**：sysroot 从盒子的 deb 里解，RPATH 用 `$ORIGIN` 自包含，
  部署是 tar over ssh 到 `/opt/reader`。细节全在 `arm64_build.md`。

**新增平台时不要动的文件**：`lua/**`（除非真有平台特性）、
`src/shim/reader_api.c`。要动的是：CMake target 的 RPATH、依赖怎么来、
产物怎么装、`SDL_VIDEODRIVER` 叫什么。

---

## 7. 相关文档

| 文档 | 位置 | 内容 |
|---|---|---|
| 本文件 | `~/kernel/reader_dev.md` | 平台无关：架构、ABI、开发循环 |
| arm64 盒子 | `~/kernel/arm64_build.md` | 交叉编译 + sysroot + 部署 + 验收 |
| 仓库内设计 | `~/Desktop/reader/{design,native_reader,renderer}.md` | 上游原始设计记录 |
