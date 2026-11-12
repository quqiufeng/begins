## proto/render-py —— 已退役的 Python 渲染实现

这三个脚本是 `tools/render.lua` 的移植来源，**不参与任何流程**，只在需要逐字节对照时拿出来跑：

```bash
cd proto/render-py && python3 flame.py in.json out.svg "标题"
```

注意：并列权重的先后由字典/集合序决定，Python 版每次运行的 tie 顺序本身就不稳定，
比对时只看权重集合，不要 `cmp`。
