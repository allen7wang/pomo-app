# Habitica Pomodoro iOS

macOS 版 Habitica Pomodoro 的 iOS 客户端，与 Mac 版共享同一套核心代码（引擎 / 数据 / Habitica API / 视图），通过 `#if os(iOS)` 与跨平台兼容层适配移动端。

> **当前源码为 3.1.1（build 9）**。本版修复了应用在保存专注历史时退出可能漏记的问题。Mac 与 iPhone 共用 iCloud 目录时应使用相同版本。[更新说明](../releases/v3.1.1.md)
>
> GitHub 已发布的 IPA 为 3.0.0（build 7），须用自己的 Apple ID 重签后安装。[下载 IPA](https://github.com/allen7wang/pomo-app/releases/tag/v3.0.0-ios) · [三端功能清单](../FEATURE_PARITY.md)

## 数据同步（iCloud Drive 文件）

仅授权共享目录后，iOS 才与 Mac 读写 iCloud Drive `Documents/.habitica-pomodoro/` 下的同一批 JSON。五个既有文件保存设置、块进度/历史和 Task；独立 `habitica_pomodoro_plants.json` 保存种植，新增独立 `habitica_pomodoro_histogram.json` 保存番茄数量和实际完成分钟。七类文件全部接入目录发现、保存、reload 与前台变更检测；未授权时数据在应用沙盒。

### 首次连接（一次性操作）

1. 打开 Settings → **iCloud Drive 同步** → 点「选择 iCloud Drive 文件夹…」
2. 在 Files 选择器中选 **iCloud Drive → Documents**（注意：`.` 开头的隐藏文件夹在 Files 里不可见，选它的父目录即可，App 会自动定位/创建里面的 `.habitica-pomodoro`）
3. 授权后数据立即从云端加载；此后每次启动自动恢复，无需再选

### 技术实现

- iOS 沙箱不允许直接读写 iCloud Drive 根目录，走 **UIDocumentPicker（fileImporter）+ 普通 bookmark 持久化**：用户选一次目录 → security-scoped URL → 存 bookmark → 冷启动 resolve 恢复。无需 entitlement、无需付费开发者账号。
- 授权范围递归覆盖子目录（含隐藏目录），bookmark 失效（文件夹被移动/权限被撤销）时 UI 会提示重新选择。
- 未授权时回退 App 沙箱，仍可用；配置 Habitica 后任务有独立云端通道，但不代表专注/块/植物历史已同步。文件级最后写入生效，同时编辑可能覆盖。「立即保存全部数据」只写文件，传送由 iCloud 系统负责。
- 本轮已用 scratch 探针验证选择 iCloud 根或其 Documents 父目录时，Histogram 单独存在也能发现同一数据目录；真实 fileImporter 授权、冷启动 bookmark、跨设备系统传送仍须真机人工验收。

## 功能

- **Pomo**：启动、暂停/继续、放弃/跳到休息、手动/自动短长休息与延长、空闲时 1/5/15/30 分钟自选休息；1–24 块的 timeline/Current、目标/跨午夜时段/任务编辑与预计番茄数；🌿 完成、🥀 放弃、🌳 combo、○ 空位；达标同一天同一块只记一次历史/奖励
- **Task**：Work/MyOwn 各最多新增 3 条，Chores 不限；统一新增、修改标题、完成/取消、确认删除、分类改名；昨日只读及未完成任务顺延；todo/tag 出站、应用专用 dated Top3 todo 入站；普通 todo 不导入，失败保留本机，待上传修改/删除标记阻止旧响应覆盖。按 UID＋规范 HTTPS API 根保存每个账号的 UUID/远端映射/tag/待同步修改与删除队列，其他账号不执行这些操作；回切保留映射，同账号 Token 轮换不改变归属
- **Habits / Dailies**：读取并打分/勾选，刷新及错误提示；同一任务请求期间阻止重复操作，切换账号时清旧列表并拒绝旧响应
- **Role**：角色属性、成就、请求状态、刷新和失败提示；账号切换拒绝旧响应
- **专注复盘**（与 macOS 2.0 对齐）：Pomo 页底部「专注复盘」进入。7 / 30 / 90 天范围与向前翻页（翻到旧区间后跨午夜仍保留该区间），默认选中区间内最近有记录的一天；Swift Charts 柱形趋势（点按切换日期）、每日记录列表与当日明细（番茄、专注分钟、时间块进度/目标/曾达标、灌木/树/枯萎）；「导出 CSV」经系统分享表导出当前日期范围，CSV 内容与文件名由共享 `FocusReview.swift` 生成，与 Mac 完全一致。原「统计与历史」页（累计/日均、块与植物历史、清空按钮）保留在复盘页底部「累计统计与历史记录」
- **锁屏实时活动 / 灵动岛**（iOS 16.2+）：计时开始即显示阶段（专注/短休息/长休息/休息延长/自选休息，手动休息模式下显示「专注完成」）、`Text(timerInterval:)` 系统倒计时与进度、当前时间块与组合进度；暂停时冻结剩余时间；完成、放弃、重置后结束，阶段切换时更新；启动时清理上次进程残留的活动。设置 → 「锁屏与小组件」→「锁屏实时活动」可关闭（默认开启，仅本机）
- **主屏「今日任务」小组件**（小/中两种尺寸）：今天 Top3 各分类完成度与下一件未完成任务。数据经 App Group 共享，详见下方「签名、扩展与免费账号」；读不到共享容器或数据不是今天时显示「打开应用同步」
- **Settings**：Habitica、计时/组合/计分、默认或自定义 Habit ID、短长休息消息提醒、块奖励/开始/冲刺提醒、真实打包音效/环境音/独立音量/预听、重置与分别清理、iCloud Drive 父目录授权；未实现的旧开关不显示但保留解码字段。自定义服务会收到凭据，只接受 HTTPS API 根地址，并禁止自动跟随重定向
- **栖时声音**：自定义单轨或 73 场景随机混音；仅清单打包，音频从公开站流式，需要联网。本轮源码修复暂停/继续保持原播放资源，试听独立且离开设置时清理；真实流式与锁屏后台仍待设备验证

## 与 Mac 版的数据关系

- **授权共享目录后**：Mac/iPhone 读写同一目录下七类文件（包括独立 Histogram/Plant），前台重载变更。目录授权成功不证明系统传送已完成。Android 本机历史不会通过此授权共享。
- **未授权时**：iOS 回退应用沙盒 `Documents/.habitica-pomodoro/`，任务仍可经 Habitica 云端上传 todo/tag
- 不依赖 iCloud 容器/entitlement/开发者账号，只靠文档选择器的一次性授权 + bookmark 持久化

Task 使用第一个块起点的逻辑日（默认 04:00）；统计、时间块及植物保留自然日 `yyyy-MM-dd`，不重归档旧记录。

iPhone 原生 TabView 超过五个目的地时，Role/Settings 在 **More**，不是缺少页面。

## 签名、扩展与免费账号

App 内嵌一个 WidgetKit 扩展 `PlugIns/HabiticaPomodoroWidgets.appex`（bundle ID `com.hermes.habitica-pomodoro.ios.widgets`），同时承载实时活动界面和主屏小组件。重签工具必须连同扩展一起签名。

| 安装方式 | 实时活动 / 灵动岛 | 主屏今日任务小组件 |
|---|---|---|
| Xcode / `resign_ios.sh`（免费个人团队） | ✅ 不需要推送或任何付费能力 | ✅ Apple 的能力表列出免费账号可用 App Group；`resign_ios.sh` 若遇 Xcode 拒绝 App Group，会自动不带 App Group 重签，小组件改为显示占位 |
| AltStore / SideStore（免费 Apple ID） | ✅ | ✅ 工具会注册 `group.com.hermes.habitica-pomodoro.<TEAMID>` 并写入 `ALTAppGroups`，App 与扩展运行时自动识别。前提是 IPA 带 entitlements：CI 产出的 IPA 已用 ad-hoc 签名写入 App Group |
| Sideloadly（免费 Apple ID） | 预期可用 | ⚠️ 公开报告显示免费账号重签不下发 App Group，小组件只显示「打开应用同步」 |

依据（2026-11 查证，未在真机上逐一验证）：Apple [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) 表中 App groups 一行对免费「Apple Developer」列为可用（Push notifications 不可用，所以实时活动只做本地更新）；AltStore 源码 [FetchProvisioningProfilesOperation.swift](https://github.com/altstoreio/AltStore/blob/master/AltStore/Operations/FetchProvisioningProfilesOperation.swift)（`groupIdentifier + "." + team.identifier`，且 IPA 无 entitlements 时跳过 App Group）与 [ResignAppOperation.swift](https://github.com/altstoreio/AltStore/blob/master/AltStore/Operations/ResignAppOperation.swift)（写入 `ALTAppGroups`）；Sideloadly 见 [ryanbr/noop#2798](https://github.com/ryanbr/noop/pull/2798) 的设备日志结论。App 运行时依次尝试 `ALTAppGroups`、`embedded.mobileprovision` 授予的 group、默认 group，取第一个可用的共享容器。

免费账号限制（与重签工具无关，由 Apple 服务器执行）：

- 签名 7 天过期，到期 App 与扩展都无法启动，需重签（`resign_ios.sh` / AltStore 刷新）。
- 每个 Apple ID 每 7 天最多注册 **10 个 App ID**；本 App 占 **2 个**（主 App + 小组件扩展）。用 AltStore/SideStore 时，同时激活的侧载 App 最多 3 个。
- 共享容器只存一份今日任务摘要（分类完成数与前几条未完成标题），不含 Habitica 凭据；扩展无法访问 App 沙盒或 iCloud Drive 授权目录。
- 改 bundle ID 时同时改 `iOS/HabiticaPomodoro.entitlements` 与 `iOSWidgets/HabiticaPomodoroWidgets.entitlements` 中的 App Group（App Group ID 与 bundle ID 一样全局唯一），以及 `iOS/Shared/TodayTasksSnapshot.swift` 的 `SharedAppGroup.baseIdentifier`。

## 构建与运行

```bash
# 依赖: Xcode 16+、xcodegen (brew install xcodegen)
bash build_ios.sh              # 生成工程 → 编译 → 安装并启动到 iPhone 17 模拟器
bash build_ios.sh --no-install # 仅编译
SIM_NAME="iPhone Air" bash build_ios.sh   # 指定其他模拟器
```

DEBUG 构建的模拟器验证参数（Release 不生效）：`-previewReview`（打开复盘）、`-previewReviewRange 30|90`、`-previewReviewPage -1`（更早区间）、`-previewReviewDetail`（打开默认日期明细）、`-previewWidgets`（App 内预览锁屏/灵动岛视图，加 `-previewWidgetsHome` 预览主屏小组件）、`-previewStartFocus`（启动后自动开始一次专注以触发实时活动）。

DEBUG 版传入 `-isolatedDataDirectory <目录>` 后，可加 `-captureDevicePreview` 将应用窗口预览写到该目录的 `device-preview.png`。该模式使用隔离样本，并暂停向真实小组件共享容器发布摘要。

工程文件 `HabiticaPomodoroMobile.xcodeproj` 由 `project.yml`（xcodegen）生成，**不入库**；改文件列表请改 `project.yml`。

### 真机部署

已配置 Xcode 免费签名环境后，在 `HabiticaPomodoro` 目录运行：

```sh
bash resign_ios.sh
```

脚本发现所有已连接、解锁的实体 iPhone，逐台构建签名 Release、校验 profile 后覆盖安装并尝试启动；不卸载或清数据。免费签名 7 天后需重跑。换签名团队可设置 `HABITICA_IOS_TEAM`。首次开发者模式与证书信任仍须在手机上确认；只想编译时不要运行此脚本。手动 Xcode 路径如下：

1. `open HabiticaPomodoroMobile.xcodeproj`
2. Target → Signing & Capabilities → Team 选你的 Apple ID（免费账号即可，7 天有效需重签）
3. 连接 iPhone，选为运行目标，⌘R

## iOS 专属适配

| 问题 | 方案 |
|------|------|
| 后台 Timer 被系统挂起 | `phaseEndsAt` 绝对时刻；回前台补处理过期专注→休息→延长，不产生无人操作的下一轮专注；观察到时钟后退时不补回已消耗秒数。后台不能承诺实时 Habitica 计分 |
| 锁屏/后台无提醒 | 启动番茄时预排 `UNTimeIntervalNotificationTrigger`；Block Mode 开始前提醒使用每日重复的 `UNCalendarNotificationTrigger`，设置变更时重排，不依赖后台运行的计时器 |
| 通知权限弹窗打扰启动 | 懒加载：首次点击开始番茄时才请求权限 |
| 静音开关吞掉提示音 | `AVAudioSession` 设为 `.playback + .mixWithOthers` |
| macOS-only API | `PlatformCompat.swift` 提供 `Color.cardBackground` / `cancelOnExitCommand` 等跨平台垫片 |

## 代码结构

```
project.yml                    # xcodegen 工程定义（唯一事实源）
build_ios.sh                   # 构建脚本
iOS/                           # iOS 专属代码
├── HabiticaPomodoroMobileApp.swift  # 入口、AppDelegate、底部 TabView
├── MobilePomoView.swift             # 番茄主页 + 时间块种植
├── MobileBlockTimelineView.swift    # 水平 timeline / Current / 编辑导航
├── MobileBlockEditorView.swift      # 时间块目标/时段/任务编辑
├── MobileFocusReviewView.swift      # 专注复盘（范围/趋势/每日记录/当日明细/CSV）
├── MobileHistoryView.swift          # 累计统计与块/植物历史（复盘页底部进入）
├── PomodoroLiveActivity.swift       # 观察引擎驱动实时活动 + 设置区块 + 皮肤强调色桥
├── TodayTasksWidgetSync.swift       # 观察 Task 数据，写 App Group 今日任务快照
├── WidgetPreviewGallery.swift       # DEBUG：-previewWidgets 在 App 内预览实时活动/小组件
├── Shared/                          # App 与小组件扩展共编译
│   ├── PomodoroActivityAttributes.swift  # ActivityAttributes / ContentState
│   ├── PomodoroActivityViews.swift       # 锁屏、灵动岛视图
│   ├── TodayTasksSnapshot.swift          # 快照模型 + App Group 定位
│   └── TodayTasksWidgetViews.swift       # 主屏小组件视图与占位
├── MobileSettingsView.swift         # 原生 Form 风格设置页（含 iCloud Drive 同步区块）
├── ICloudFolderGrant.swift          # iCloud Drive 文件夹授权（fileImporter + bookmark 持久化）
└── Assets.xcassets/                 # 图标
iOSWidgets/                    # WidgetKit 扩展 target（WidgetBundle、Info.plist、entitlements）
HabiticaPomodoro/              # 与 Mac 版共享
├── PomodoroEngine.swift       # 计时引擎（含 iOS 后台重同步）
├── PomodoroFileStore.swift    # iCloud Drive/沙盒文件存储与监控
├── PlantJournal.swift         # Mac/iOS 共用植物记录（独立 JSON）
├── HabiticaAPI.swift          # Habitica REST API
├── TopThreeView.swift         # Task 页（跨平台共用）
├── HabiticaTabsView.swift     # Role/Habits/Dailies 视图（跨平台共用）
└── PlatformCompat.swift       # 跨平台兼容垫片
```

## 验证边界与手测清单

当前源码对应已发布 v1.2.5。Debug/Release 构建、离线逻辑回归、手机安装、UI、后台及 iCloud 传送分别记账，不能互相替代。

实际完成 iOS Simulator Debug 构建、macOS arm64/x86_64 编译和 scratch 离线状态/持久化探针。早期专用模拟器已安装启动，Pomo 截图包含计时圈、控制、自选休息、历史入口和原生 More。后续详细页面验证遇到模拟器启动超时 / LaunchdSimError 111，**白屏不能证明 Settings 布局已验收**。

Apple 离线夹具已固化在 [../fixtures/](../fixtures/README.md)：真实生产逻辑配隔离目录及音频 transport 替身，无真实账号或网络请求，不新增测试框架。共享改动要同时检查 Mac/iOS 构建；尚未执行的人工项保留下列清单：

- [ ] 圆圈启动/暂停/继续；暂停休息后恢复仍是休息；放弃/跳过不计完成。
- [ ] 手动/自动短休息、combo 长休息、自选休息；0 延长、延长后保留/清 combo。
- [ ] 块数 1→24→1→24 保留目标/任务；Current、跨午夜时段、块任务编辑/预计数/完成/删除。
- [ ] 达标去重、重置当前块不重复奖励；清块/植物与清统计不误删 Task。
- [ ] Task 增改完成删除、分类改名、跨 04:00 日界及昨日顺延。
- [ ] 测试账号验证 Habits/Dailies/Role、Top3 双向合并、请求中修改/删除/账号切换。
- [ ] 真机声音/环境音/音量、暂停结束停止环境音、锁屏提醒与后台恢复。
- [ ] 真机 iCloud 根/其 Documents 两种父目录授权、冷启动 bookmark、Mac/iPhone Histogram/Plant 新文件前台重载与系统传送。
- [ ] 真机实时活动：开始/暂停/继续/跳到休息/放弃/长休息/自选休息时锁屏与灵动岛（有灵动岛的机型）随之变化；后台到点后显示「时间到」，回前台后更新；关闭设置开关后立即消失。
- [ ] 真机主屏小组件：Xcode、AltStore 两种安装下添加小/中尺寸，Task 页勾选后刷新；跨第一个时间块起点后显示「打开应用同步」；Sideloadly 免费签名下显示占位。
- [ ] 复盘 CSV 经分享表存到「文件」，与 Mac 同范围导出逐字节一致。
