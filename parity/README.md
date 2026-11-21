# 跨平台业务回归

Swift 与 Kotlin 的离线夹具读取本目录中的同一份输入和预期结果。

- `logical_day.json` 记录 UTC 时刻、IANA 时区、首个时间块起点（分钟）及两个预期日期。包含首块边界、自然日、跨年和夏令时切换。
- `focus_review.json` 使用客户端已有的统计、块历史和种植 JSON 字段。7、30、90 日窗口核对范围、总数及默认日期。7、30 日窗口还核对完整 CSV，`csvRows` 以 CRLF 拼接并以 CRLF 结尾。

在对应文件中添加场景后，从仓库根运行 Apple 夹具 `--only shared_logical_day --only focus_review` 和 Android 夹具 `--only shared_logical_day,fr_01_apple_reference_dataset`。夹具入口见各端的 `fixtures/README.md`。
