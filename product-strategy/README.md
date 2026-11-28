# 番时 Pomo · 产品与商业化分析

整理日期：2026-11-28。外部数据的访问日期均为 2026-11-28。标「估算」的是推算值，标「待核实」的是尚未找到一手来源的信息。本目录是分析和建议，不构成法律或财务意见。

## 一句话定位

番时是给 Habitica 玩家和「时间块」工作法使用者的跨端番茄钟：把一天切成时间块，排好每日三件事，从任务开始专注，完成结果自动记到 Habitica 角色上。

## 目标用户

- **Habitica 重度玩家**：已经用打怪升级管理习惯，希望专注时间也能自动计分。
- **用时间块安排一天的知识工作者**：仓库里的 `Pomo记录.xlsx` 就是这套方法的原型，04:00 起每 3 小时一块，每块若干番茄。
- **Mac 菜单栏用户**：希望倒计时常驻菜单栏，iPhone 和 Android 随身查看。

## 当前阶段

| 项目 | 状态 |
| --- | --- |
| 版本 | 3.2.0：macOS build 23、iOS build 10、Android versionCode 9，Web 3.2.0 |
| 分发 | GitHub Release 提供 macOS 包、需自行重签的 iOS 包和可侧载的 APK。Web 版在统一工作台运行，需授权 Google 账号登录。尚未上架任何应用商店 |
| 数据 | 全部存在本机。Mac 和 iPhone 通过用户授权的 iCloud Drive 目录共享 JSON；Android 只通过 Habitica todo 交换任务。没有账号、服务端和埋点 |
| 来源 | Fork 自 [ofekmiz/Habitica-Pomodoro-SiteKeeper](https://github.com/ofekmiz/Habitica-Pomodoro-SiteKeeper)（MIT 许可），原生端为重写 |

## 关键结论

1. **差异化成立，但市场小。** 时间块、种植、Top 3、任务专注复盘和 Habitica 双向同步，这几样合在一起，主流番茄钟里没有对等的组合。代价是核心卖点绑定 Habitica。Habitica 注册用户「400 万以上」的说法来自第三方汇总（待核实），活跃用户更少。
2. **上架前有几处硬伤。**
   - 请求头 `x-client` 已改为开发者自己的 Habitica User ID（`a0badcb0-…-Pomo`，各端带平台后缀），符合 Habitica 对第三方工具的要求。
   - iOS 和 Android 的「栖时随机场景」从 `allen7wang.github.io/qishi-meditation-web/audio/` 流式读取，该地址 2026-11-28 实测返回 404，移动端的环境音实际不可用。
   - 番时引用了栖时的 CC BY / CC BY-SA 声音，但应用内没有署名页。
   - Mac 主程序不在沙盒中运行，上架 Mac App Store 前需要改造。
3. **几乎没有边际成本，适合买断。** 没有服务端，Habitica 请求由用户设备直接发出。同类产品里，Forest、Focus To-Do、Flow 都提供一次性买断，没有持续成本时订阅缺少理由。
4. **商业化的目标应是覆盖成本、验证需求。** 按 2%–4% 的转化率估算，年净收入在数百到一两万美元之间（估算，见商业化文档）。适合作为个人产品经营，不适合按融资项目规划。

## 推荐商业模式

免费下载，加一次性买断的「番时 Pro」。Apple 端用通用购买，Mac 和 iPhone 买一次，参考价 $9.99 / ¥38，Android 同价。Habitica 集成和基础计时保持免费，用来在 Habitica 社区获客。不做广告。若以后推出 Android 与 Apple 之间的同步服务，再为同步单独设年订阅。

## 接下来三件事

1. **修掉上架阻断项**：换成自己的 Habitica User ID 作为 `x-client`；环境音改用可公开访问的存储地址，并加上声音来源页；补齐隐私政策。
2. **先上 Apple 一端**：注册开发者账号，把 Mac 和 iOS 合成一个通用购买的 App Store 记录，用 TestFlight 招 50 名内测用户。
3. **做两个低成本验证**：在 r/habitica 和 Habitica 维基的第三方工具页发布等候名单，在小红书发「时间块工作法」笔记，看报名数和收藏率（见商业化文档第 6 节）。

## 详细文档

- [product-analysis.md](./product-analysis.md)：问题与场景、用户画像、功能与差异、竞品对比、现状评估、3 / 6 / 12 个月路线图。
- [commercialization.md](./commercialization.md)：市场、商业模式与定价、渠道、成本与单位经济、风险合规、验证实验。
