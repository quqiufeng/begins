# tools/cdp/bench —— 压测页变体（2026-11-26 chrome/cog 直出调优时迭代出来的）

`../bench.html` + `../bench2.html` 是入库基线版（§13.4 引用的就是它们）。
本目录是同一批实验里的**迭代变体**，按用途粗分：

| 文件 | 侧重 |
|---|---|
| `bench.html` / `bench2.html` | 重写版：自测上报（`fetch 127.0.0.1:8099/r`）+ 分阶段计时 |
| `bench3.html`~`bench6.html` | canvas / blur / 合成层 逐步加码的 A/B 变体 |
| `fps.html` | 只数 rAF/真实帧，最小页面 |
| `fps2k.html` | 内部光栅固定 2560x1440，测上采样代价 |
| `phase.html` | 分阶段（布局/光栅/合成）耗时拆解 |
| `gpuinfo.html` | webgl: 读 renderer/vendor/扩展，判断是否走软件栈 |

用法同 `../sc2.sh`：`scp` 到盒上 `/tmp/` 再 `file:///tmp/<name>.html`（脚本路径硬编码 `/tmp`）。
