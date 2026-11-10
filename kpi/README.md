# kpi/ — 驱动内核 API 面清单

## 方法
`closure.sh <driver.c>`：抽源文件标识符 ∩ `Module.symvers` 导出符号。
得到的是**下界**，不是全量。

## 已知偏差（必读）
1. **宏包装会漏**：`register_blkdev`→`__register_blkdev`、`register_virtio_driver`→`__register_virtio_driver`。
   宏名不是导出符号，导出的是带 `__` 的真函数。已手工补入。
2. 只覆盖"函数/变量符号"，**不覆盖**结构体字段、内联函数、宏常量 —— 这部分看头文件。
3. 未构建日志，闭包未做传递展开（A 调 B、B 又调 C）。做 kpi 时要逐层展开。

## 产出
- `virtio_blk.txt` — virtio-blk 驱动需要内核提供的符号（63 个，已修正）
