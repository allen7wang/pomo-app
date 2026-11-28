# 番时 Pomo · 商业化分析

整理日期：2026-11-28。外部链接的访问日期均为 2026-11-28。「估算」是基于公开数据的推算，「待核实」是尚未找到一手来源的信息。本文不构成法律或财务意见。

## 1. 市场规模与趋势

| 口径 | 数据 | 来源与可信度 |
| --- | --- | --- |
| 全球时间管理应用 | 2025 年约 33 亿至 123 亿美元，各机构口径差异很大，年增速约 8%–12% | [Sector Data Insights](https://www.sectordatainsights.com/reports/time-management-application-and-tools-7062)、[Verified Market Reports](https://www.verifiedmarketreports.com/product/time-management-application-and-tools-market/)，均为付费报告摘要，只能看方向 |
| 番茄钟和专注计时细分 | 2025 年约 4.13 亿美元；该报告称免费转付费约 9.2% | [Dataintelo](https://dataintelo.com/report/pomodoro-apps-market)，单一来源，待核实 |
| Habitica 用户 | 注册用户「400 万以上」，年收入约 520 万美元 | [HelloLeads](https://www.helloleads.io/blog/stats-facts/20-amazing-habitica-stats-and-facts/)、[checkthat.ai](https://checkthat.ai/brands/habitica)，第三方汇总，非官方数据，待核实 |
| 国内番茄钟 | 番茄ToDo 在 App Store 有约 94 万条评分 | [飞出国论坛转述](https://bbs.fcgvisa.com/t/todo-93-9-4-91-app-9/57619)，待核实 |

**趋势判断：**

- **买断和订阅并存。** Session、Flow 走订阅，Forest、Focus To-Do、Flow 也提供买断或终身选项。纯计时器类产品很难长期收订阅费，有评测直接称 Session 的定价「对番茄钟来说太贵」（[publicspace.net](https://www.publicspace.net/focus/best-pomodoro-apps-mac/)）。
- **专注工具和屏蔽功能在融合。** Session 和 Flow 的 Pro 版都包含应用和网站屏蔽。
- **Habitica 社区在收缩。** 2023 年 8 月 8 日 Habitica 移除了公会和酒馆（[Habitica 维基](https://habitica.fandom.com/wiki/Extensions,_Add-Ons,_and_Customizations)），有评论认为这影响了社区信任（待核实）。

结论：番时能触达的人群是 Habitica 活跃用户里会安装第三方工具的那部分，加上偏好时间块方法的效率工具用户。用户规模大概在数万人量级（估算），只够支撑个人产品。

## 2. 商业模式评估

| 模式 | 适配度 | 理由 |
| --- | --- | --- |
| 免费加一次性买断 | **高（推荐）** | 没有服务端，边际成本接近零；同类产品普遍提供买断 |
| 订阅 | 现阶段低 | 没有持续服务支撑订阅；用户可能已经在付 Habitica 的 $47.99/年 |
| 打赏和赞助 | 中 | Habitica 第三方工具多为免费开源，适合用应用内小费或 GitHub Sponsors 补充 |
| 团队版或授权 | 低 | 个人效率工具；团队版需要账号体系和管理后台 |
| 广告 | 不建议 | 在专注工具里放广告与产品目标冲突 |

**定价建议**（对标第 4 节竞品表，见 [product-analysis.md](./product-analysis.md#4-竞品对比)）：

| 档位 | 内容 | 价格 | 依据 |
| --- | --- | --- | --- |
| 免费 | 计时、时间块、种植、Top 3、Habitica 全部集成、7 天复盘、2 套皮肤 | 0 | 保留获客入口 |
| Pro 买断 | 7 套皮肤、90 天及更早的复盘、两种 CSV、单日专注明细、小组件和实时活动、栖时环境音 | $9.99 / 国区 ¥38，Mac 和 iOS 通用购买 | 高于 Forest iOS 的 $3.99（番时额外包含 Mac 端），低于 Focus To-Do 终身的 $11.99 和 Flow 终身的 $39.99；国区 ¥38 约等于滴答清单 ¥139/年的三个月 |
| 早鸟价 | 同 Pro | $6.99，限 TestFlight 用户 | 换取早期反馈和评分 |
| 同步订阅（12 个月后视情况） | Android 与 Apple 之间同步历史和设置 | $7.99/年 | 只在需求验证通过后推出 |

## 3. 渠道与上市策略

| 渠道 | 做法 | 备注 |
| --- | --- | --- |
| r/habitica 等 Habitica 社区 | 发布内测招募，并说明 `x-client` 和限流处理 | 先遵守 [Guidance for Comrades](https://habitica.fandom.com/wiki/Guidance_for_Comrades) |
| Habitica 维基第三方工具页 | 申请收录到 [Extensions, Add-Ons, and Customizations](https://habitica.fandom.com/wiki/Extensions,_Add-Ons,_and_Customizations) | 成本低，流量长期稳定 |
| App Store 和 Mac App Store | 关键词：pomodoro、habitica、time blocking、番茄钟、时间块 | Mac 版需要沙盒改造，见第 5 节 |
| 小红书、少数派、即刻 | 讲时间块工作法和种植复盘，用截图和 Excel 原型说清楚方法 | 国内以时间块为卖点，不强调 Habitica |
| Product Hunt、Show HN | 以 Mac 菜单栏应用为主打 | 一次性曝光，用来积累评分 |
| Setapp | Session 已经在 Setapp 上架，番时可以评估 | 分成条款待核实 |

上市顺序：先海外 Apple 端，因为个人开发者门槛低，Habitica 用户也集中在英文区。验证通过后再上 Google Play。国内安卓商店上架需要软著、APP 备案，接入支付通常还要企业主体，暂缓。

## 4. 成本结构与单位经济（估算）

| 成本项 | 金额 | 说明 |
| --- | --- | --- |
| Apple Developer Program | $99/年（国区 ¥688，待核实） | [费用说明汇总](https://rottenwifi.com/every-apple-app-store-fee-explained-what-developers-pay-how-much-and-when-2026/) |
| Google Play 开发者账号 | $25，一次性 | 同上 |
| 服务端 | $0 | 没有服务端；Habitica 请求由用户设备直接发出 |
| 栖时音频存储 | 约 $0 | 约 202 MiB，在 [Cloudflare R2](https://developers.cloudflare.com/r2/pricing) 每月 10 GB 免费额度内，出站流量免费 |
| 域名和隐私政策页 | 约 $15/年 | 估算 |
| 第一年合计 | 约 $140 | 估算，不含开发时间 |

**单次购买净收入：**

- 海外：$9.99，扣除小型企业计划 15% 佣金后约 $8.49。
- 国区：¥38，按 2026 年 3 月 15 日起的 12% 费率扣除后约 ¥33.4（[TechCrunch](https://techcrunch.com/2026/03/13/apple-drops-commission-rates-in-china-25-percent/)）。
- 两者都还要扣除各地的增值税等税费，实际到账更少（待核实）。

**盈亏平衡**：每年约 17 笔海外购买即可覆盖固定成本。

**收入情景（估算）**：

| 情景 | 年下载量 | 付费转化率 | 年净收入 |
| --- | --- | --- | --- |
| 保守 | 2,000 | 2% | 约 $340 |
| 中性 | 10,000 | 3% | 约 $2,500 |
| 乐观 | 50,000 | 4% | 约 $17,000 |

转化率没有采用 Dataintelo 的 9.2%，而是按更保守的 2%–4% 计算。

## 5. 风险与合规

- **Habitica 平台依赖**
  - [API 使用规范](https://github.com/HabitRPG/habitica/wiki/API-Usage-Guidelines)要求：`x-client` 填写「开发者 User ID-应用名」；每个用户的所有第三方工具合计每 60 秒最多 30 次请求；后台自动调用之间间隔 30 秒；只使用 v3 API。
  - 当前代码沿用上游作者的标识，必须修改。
  - 本机已设每 60 秒 24 次的限额（`HabiticaRequestBudget.swift`），但与其他工具共享的额度无法控制。
  - 有第三方文章称，2025 年 7 月开始强制检查 `x-client` 后，部分旧工具失效（待核实）。
  - 缓解办法：独立模式也要完整可用；Habitica 相关功能出错时，不影响计时和记录。
- **商标**：「Habitica」是他方品牌。商店名称不应包含它，描述中可以写「支持 Habitica」。Habitica 的商标政策待核实。
- **上游许可**：上游扩展是 MIT 许可，分发时要在「关于」页保留 `Copyright (c) 2024 OfeX` 许可声明。随包的提示音（`Sound1–8.mp3` 等）来自上游扩展，来源待核实。
- **栖时音频授权**
  - 番时的随机场景引用了栖时的 CC BY 和 CC BY-SA 素材，例如 `light-rain`、`pine-wind`、`cricket`，但番时目前没有声音来源页。公开分发前要加上署名和许可链接。CC BY-SA 素材不能加 DRM。
  - 场景里还有 4 段诵经（`heart-sutra-mandarin` 等），国区版本建议排除。详见栖时仓库的 `商业化/02-授权与合规.md`。
- **Mac App Store 沙盒**
  - Mac 主程序目前不在沙盒中运行（见 `TodayTasksWidget.swift` 第 4 行注释），直接读写 `~/Documents/.habitica-pomodoro/`，还会读取本机栖时仓库的路径。
  - 上架 Mac App Store 需要改为用户授权目录或 iCloud 容器。
  - 另一条路是用 Developer ID 签名加公证，在 App Store 之外分发，收款用 Paddle 或 Lemon Squeezy 等服务。
- **隐私（PIPL / GDPR）**
  - 目前开发者不收集任何个人信息，隐私政策可以写得很简单，但要说明任务标题会写入用户自己的 Habitica 账号，以及 iCloud Drive 同步。
  - 如果加入埋点，要先征得同意，并同步更新 App 隐私标签和 Google Play 数据安全表单。
- **效果宣传**：只描述功能，不宣称「治疗拖延」或改善注意力障碍之类的效果。

## 6. 低成本验证实验

| # | 实验 | 做法 | 成功标准 |
| --- | --- | --- | --- |
| 1 | Habitica 社区等候名单 | 在 r/habitica 发帖，在维基第三方工具页收录，落地页收集邮箱，为期 2 周 | ≥ 150 人报名，落地页转化 ≥ 20% |
| 2 | TestFlight 内测 | 50 名用户使用 4 周，内置一次问卷 | D7 留存 ≥ 30%，每周使用 ≥ 3 天的用户 ≥ 40% |
| 3 | 价格假门 | 内测版分两组，Pro 按钮分别标 $9.99 和 $4.99，点击后进入预约页 | 点击率 ≥ 8%；$9.99 组的点击率不低于 $4.99 组的一半 |
| 4 | 小红书「时间块工作法」 | 发 5 篇笔记，附 Excel 原型和种植截图 | 收藏数 / 曝光数 ≥ 3%，引流到等候名单 ≥ 50 人 |
| 5 | 独立模式需求 | 首次启动时选择「Habitica 模式」或「独立模式」，统计比例 | 独立模式超过 60% 时，把定位重心移到时间块，Habitica 降为可选集成 |

实验 1 和 4 不需要改代码，可以马上开始。实验 2、3、5 需要先完成 README 中「接下来三件事」的第 1 项。
