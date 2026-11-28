# 番时 Pomo · 产品分析

整理日期：2026-11-28。外部链接的访问日期均为 2026-11-28。功能描述以仓库当前源码和文档为准，竞品信息来自公开页面。

## 1. 问题与使用场景

番茄钟本身已经很普及，番时要解决的是三个更具体的问题：

- **专注没有和长期目标挂钩。** 普通计时器结束就结束了。Habitica 玩家希望专注、放弃和完成一组都能自动给习惯加减分，不必手动去点。
- **一天的节奏难以安排。** 只有 25 分钟的颗粒度太细。番时把一天分成 1–24 个时间块，每块设目标、任务和预计番茄数，按块推进。
- **回顾时看不出时间花在哪。** 3.0.0 起可以从任务开始番茄，3.2.0 能按天回看每个任务番茄的开始时间和分钟数，并导出 CSV。

典型场景：

1. 早上在 Mac 上写下今天 Work、MyOwn 各三件事，任务自动同步为带分类标签的 Habitica todo。
2. 从第一件事开始番茄，菜单栏倒计时，结束后 Habitica 的 Pomodoro 习惯自动加分，当前时间块种下一株灌木。
3. 外出时用 iPhone 继续，锁屏实时活动显示进度，主屏小组件显示今日任务。
4. 周末打开「专注复盘」，查看 7 / 30 / 90 天趋势，导出任务用时 CSV。

## 2. 用户画像

| 画像 | 特征 | 核心需求 | 在番时里的关键功能 |
| --- | --- | --- | --- |
| A. Habitica 老玩家（主） | 英文用户居多，用 Habitica 两年以上，习惯装第三方工具 | 专注自动计分，不在多个应用之间来回记 | 番茄完成、组合、放弃、延长超时按开关计分，Habits / Dailies / 角色页 |
| B. 时间块工作者 | 产品经理、研发、自由职业者，按 3 小时为一块安排日程 | 一天有节奏，晚上能回看 | 时间块、块提醒与冲刺提醒、种植、专注复盘 |
| C. 学生自习 | 国内用户，在 Mac 或 iPad 上自习，常用番茄ToDo、Forest | 看得见的积累，有白噪音 | 种植记录、七套皮肤、栖时环境音 |

A 是当前功能最匹配的人群，也是最容易触达的社区。C 的规模最大，但已经被番茄ToDo、Forest 等成熟产品占据，番时在 C 群体中缺少明显优势。

## 3. 核心功能与差异

| 功能 | 现状 | 代码位置 |
| --- | --- | --- |
| 计时引擎 | 暂停不算失败，放弃和跳过单独记录；阶段沿用开始时的设置；冷启动按原截止时间补记 | `HabiticaPomodoro/HabiticaPomodoro/PomodoroEngine.swift`，`HabiticaPomodoroAndroid/.../engine/PomodoroViewModel.kt`，`web/model.mjs` |
| 时间块与种植 | 1–24 块，可跨午夜；完成种灌木，放弃记枯萎，完成一组另种一棵树 | `BlockProgressManager.swift`，`PlantJournal.swift`，`BlockModels.kt` |
| 每日三件事 | Work / MyOwn 各 3 件，Chores 不限；逻辑日以第一个时间块为界；Mac 与 iPhone 并发修改按任务合并 | `TopThreeManager.swift`，`TopThreeMerge.swift`，`TopThreeCloudSync.kt` |
| Habitica 集成 | todo 双向同步；按账号隔离队列；创建结果不明时先核对云端；本机限额每 60 秒 24 次 | `HabiticaAPI.swift`，`HabiticaRequestBudget.swift`，`HabiticaGate.kt`，`web/sync.mjs` |
| 专注复盘 | 7 / 30 / 90 天，单日专注明细，两种 CSV，各端导出逐字节一致 | `FocusReview.swift`，`FocusReview.kt`，`web/review.mjs` |
| 环境音 | 结束音、休息音、环境音分开设置；栖时场景随机且不与上次重复 | `AudioManager.swift`，`PomoAudio.kt`，`web/qishi.mjs` |
| 皮肤 | 七套，由 `design/skins.json` 生成两端令牌 | `design/gen_skins.py`，`SkinTokens.swift`，`ui/theme/SkinTokens.kt` |

**差异化判断：**

- 与 Forest 相比，同样有种植隐喻，番时多了时间块结构和 Habitica 计分，但没有防手机分心的锁屏机制。
- 与番茄ToDo、Focus To-Do 相比，番时在任务管理上更克制，只有三件事加琐事，优势在节奏和复盘。
- Habitica 自身没有内置番茄钟。维基上列出的第三方工具以脚本和浏览器扩展为主（[Extensions, Add-Ons, and Customizations](https://habitica.fandom.com/wiki/Extensions,_Add-Ons,_and_Customizations)），提供原生 Mac、iOS、Android 三端并带双向任务同步的工具不多。逐一比对尚待完成，此判断待核实。

## 4. 竞品对比

价格为美区或国区标价，各区不同，以商店实时页面为准。

| 产品 | 定位 | 平台 | 价格 | 与番时的关系 |
| --- | --- | --- | --- | --- |
| [Forest](https://calmevo.com/forest-app-review/) | 种树防分心 | iOS、Android、Chrome | iOS $3.99 买断；Android 免费加 Pro，Pro 价格各来源为 $1.99 或 $3.99（待核实） | 种植隐喻相同，Forest 品牌强、社交多 |
| [番茄ToDo](https://www.zhihu.com/question/448397936/answer/2871237453) | 国内自习、学霸模式 | iOS、Android | 只卖季度卡，不自动续费；台区 3 个月 NT$60、3 年 NT$290。国区现价待核实 | 国内学生市场的主流 |
| [滴答清单](https://help.dida365.com/forum/topic/4795/) | 待办、日历加番茄 | 全平台 | 官网 ¥139/年，iOS ¥168/年；美区 iOS $27.99/年（[App Store](https://apps.apple.com/cn/app/id626144601)） | 任务管理强，番茄是附带功能 |
| [Focus To-Do](https://goalsandprogress.com/is-focus-to-do-worth-it-in-2025-full-review-features-focus-to-do/) | 番茄加任务 | iOS、Android、Mac、Windows | Premium 终身 $11.99，或 3 个月 $3.99 | 功能形态最接近，跨端同步更成熟 |
| [Session](https://apps.apple.com/md/app/session-pomodoro-focus-timer/id1521432881) | Mac 专注 | Mac、iOS | $4.99/月，$39.99/年 | Mac 高价订阅的标杆 |
| [Flow](https://apps.apple.com/us/app/flow-focus-pomodoro-timer/id1423210932) | Mac 菜单栏番茄 | Mac、iOS | $2.99/月，$17.99/年，终身 $39.99 | 菜单栏体验的标杆 |

Habitica 不是竞品，而是上游平台。它免费，订阅 $4.99/月或 $47.99/年（[mainquest.net](https://www.mainquest.net/habitica-pricing)，第三方整理），番时不应与它的订阅权益重叠。

## 5. 现状评估

**成熟度**：功能完整度高于多数个人项目。四个客户端共用一套业务规则，共享场景放在 `parity/`（`focus_review.json`、`logical_day.json`），对齐情况记录在 [FEATURE_PARITY.md](../HabiticaPomodoro/FEATURE_PARITY.md)。

**质量与测试**：

- Apple 离线回归 23 组用例，Android 离线回归 60 组，Web `node --test` 43 个测试。CI（`.github/workflows/build.yml`）先跑离线回归再构建。
- 待设备验收的项目仍不少：Habitica 在线流程和账号切换、真实音频与锁屏后台、iCloud 跨设备传送、iOS 重签和主屏小组件、Android 真机。见 FEATURE_PARITY 的「当前状态」。

**技术债与风险**：

| 项目 | 影响 | 建议 |
| --- | --- | --- |
| `x-client` 沿用上游标识 `5a8238ab-…-HabiticaPomodoroSiteKeeper-v2` | 违反 Habitica 第三方工具规范，出问题时会被误认为上游工具，也可能被限流或封禁 | 改为自己的 User ID 加应用名 |
| 移动端栖时音频地址 404 | iOS 和 Android 的栖时环境音不可用；Mac 只有本机存在栖时仓库时可用 | 迁到 R2 等公开存储，或随包附带精选场景 |
| 应用内没有栖时声音的署名页 | 随机场景引用了 CC BY 和 CC BY-SA 素材，分发时不满足署名要求 | 从栖时的 `AUDIO_CREDITS.md` 生成「声音来源」页 |
| Mac 主程序不在沙盒中运行，直接读写 `~/Documents/.habitica-pomodoro/` | 无法直接上架 Mac App Store | 改用用户授权目录或 iCloud 容器，或用 Developer ID 在商店外分发 |
| 同一套规则写了四遍（Swift、Kotlin、JS，另有旧扩展） | 每个功能要改四处，验收成本高 | 商业化后以 Apple 端为主，Web 和 Android 只做修复 |
| iCloud 七类文件中只有 Top 3 能合并 | 两台设备同时修改其余文件时，后写入的会覆盖先写入的 | 公开前在说明中写明，或改用 CloudKit |
| Android 签名密钥只存在于这台 Mac 的 `~/.android/debug.keystore`，没有备份 | 密钥丢失后，用户无法覆盖升级 | 上架前生成正式密钥，并做异地备份 |
| 产品名和 Bundle ID 含 "Habitica" | 可能涉及商标问题 | 商店名用「番时 Pomo」，Habitica 只作为功能描述（待核实） |

**数据与隐私**：

- 开发者不收集任何数据，没有埋点。
- Habitica Token 保存在本机。Android 含 Token 的设置文件不参与系统备份；Web 只在页面内存中保存凭据。
- 任务标题会以 todo 的形式写入用户自己的 Habitica 账号，隐私政策中需要说明这一点。

## 6. 路线图建议

| 时间 | 优先级 | 事项 | 验证方式 |
| --- | --- | --- | --- |
| 3 个月 | P0 | 修正 `x-client`；栖时音频迁到公开存储；隐私政策；去掉产品名里的 Habitica | 抓包确认请求头；断开本机栖时仓库后，三端都能播放环境音 |
| 3 个月 | P0 | Mac 与 iOS 合并为一个 App Store 记录，提交 TestFlight | 50 名内测用户，D7 留存 ≥ 30% |
| 3 个月 | P1 | 首次使用引导：选择「Habitica 模式」或「独立模式」，预置时间块模板 | 首日完成第一个番茄的比例 ≥ 60%（App Store Connect 加问卷） |
| 6 个月 | P0 | 上线 Pro 买断（皮肤、长周期复盘与 CSV、单日明细、小组件、环境音） | 下载到付费的转化率 ≥ 2% |
| 6 个月 | P1 | 英文本地化；Google Play 上架 | 英文区下载占比；Habitica 来源用户的留存 |
| 6 个月 | P2 | Mac 专注时屏蔽网站（继承上游扩展的 Pay to Pass 思路） | 内测中的使用率 ≥ 20% |
| 12 个月 | P1 | 降低对 Habitica 的依赖：接入 Apple 提醒事项或日历，导入 Todoist | 非 Habitica 用户的占比和留存 |
| 12 个月 | P2 | 可选的 Android 与 Apple 同步服务，按年订阅 | 先发问卷，愿付费比例 ≥ 15% 再开发 |
| 12 个月 | P2 | 抽出共享核心规则（例如 Kotlin Multiplatform 或 JS 规则引擎） | 新功能改动的文件数和验收时长下降 |
