import SwiftUI

// MARK: - Shared page chrome keeps connected, empty and error states aligned with the focus skin.
private struct HabiticaPageChrome<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let subtitle: String
    let symbol: String
    let detail: String?
    let configured: Bool
    let loading: Bool
    let error: String?
    let refresh: () -> Void
    let content: Content

    init(title: String, subtitle: String, symbol: String, detail: String? = nil,
         configured: Bool, loading: Bool, error: String?, refresh: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.configured = configured
        self.loading = loading
        self.error = error
        self.refresh = refresh
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.pageSpacing) {
            HStack(alignment: .top, spacing: 12) {
                ThemedPageHeader(title: title, subtitle: subtitle, symbol: symbol, detail: detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if configured {
                    ThemeRefreshButton(loading: loading, action: refresh)
                }
            }
            if configured, let error = error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.smallShape(10).fill(theme.subtle))
                    .overlay(theme.smallShape(10).strokeBorder(theme.danger.opacity(0.35), lineWidth: 1))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, theme.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .foregroundColor(theme.ink)
        .tint(theme.accent)
    }
}

private struct HabiticaLoadingState: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(theme.accent)
            Text("正在同步 Habitica…")
                .font(.system(size: 12))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Habits Tab (Habitica 习惯列表，支持 +/- 打分)
struct HabiticaHabitsView: View {
    @Environment(\.appTheme) private var theme

    @ObservedObject var engine = PomodoroEngine.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject private var api = HabiticaAPI.shared

    @State private var habits: [HabiticaTaskItem] = HabiticaPreviewSamples.habits
    @State private var loading = false
    @State private var loadedAccount = ""
    @State private var loadGeneration = 0
    @State private var scoredIds = Set<String>()
    @State private var inFlightIds = Set<String>()
    @State private var accountGeneration = 0

    var body: some View {
        themedBody
            .task(id: accountSignature) { await load() }
    }

    private var accountSignature: String {
        let settings = settingsManager.settings
        return "\(settings.connectHabitica)|\(settings.uid)|\(settings.apiToken)|\(settings.developerServerUrl)"
    }

    private var isConfigured: Bool {
        settingsManager.settings.connectHabitica &&
        !settingsManager.settings.uid.isEmpty &&
        !settingsManager.settings.apiToken.isEmpty
    }

    /// Scoring still requires isConfigured, so offline preview samples can never reach the network.
    private var showsAccount: Bool { isConfigured || HabiticaPreviewSamples.enabled }

    @MainActor
    func load() async {
        if HabiticaPreviewSamples.enabled { return }
        let settings = settingsManager.settings
        let signature = accountSignature
        if loadedAccount != signature {
            habits = []
            scoredIds.removeAll()
            inFlightIds.removeAll()
            accountGeneration += 1
            loading = false
            loadedAccount = signature
        }
        guard !loading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard isConfigured else {
            habits = []
            scoredIds.removeAll()
            inFlightIds.removeAll()
            loading = false
            return
        }
        scoredIds.removeAll()
        loading = true
        let items = await HabiticaAPI.shared.fetchTaskList(type: "habits", settings: settings)
        guard accountSignature == signature, loadGeneration == generation else { return }
        if let items = items { habits = items.sorted { $0.value < $1.value } } // 红色（弱项）在前
        loading = false
    }

    func score(item: HabiticaTaskItem, direction: String) {
        guard isConfigured, !scoredIds.contains(item.id), !inFlightIds.contains(item.id) else { return }
        let settings = settingsManager.settings
        let signature = accountSignature
        inFlightIds.insert(item.id)
        let generation = accountGeneration
        Task {
            let result = await HabiticaAPI.shared.scoreTask(taskId: item.id, direction: direction, settings: settings)
            await MainActor.run {
                guard accountSignature == signature, loadedAccount == signature, accountGeneration == generation else { return }
                if result != nil {
                    scoredIds.insert(item.id)
                    // 刷新本地 value 与顶部状态栏
                    if let idx = habits.firstIndex(where: { $0.id == item.id }) {
                        let current = habits[idx]
                        habits[idx] = HabiticaTaskItem(
                            id: current.id, text: current.text, notes: current.notes,
                            value: current.value + (direction == "up" ? 1 : -1),
                            completed: current.completed, canUp: current.canUp, canDown: current.canDown, isDue: current.isDue)
                    }
                    Task { await engine.refreshHabitica() }
                }
                inFlightIds.remove(item.id)
            }
        }
    }
}

// MARK: - Habit Row
struct HabitRow: View {
    @Environment(\.appTheme) private var theme

    let item: HabiticaTaskItem
    let onScore: (String) -> Void
    let scored: Bool
    let busy: Bool

    /// Weak habits read as danger, neutral as highlight, strong as accent (Habitica's red→green scale).
    private var valueColor: Color {
        if item.value < -1 { return theme.danger }
        if item.value < 1 { return theme.highlight }
        if item.value < 5 { return theme.accent.opacity(0.6) }
        return theme.accent
    }

    var body: some View {
        themedBody
    }
}

// MARK: - Dailies Tab (今日打卡)
struct HabiticaDailiesView: View {
    @Environment(\.appTheme) private var theme

    @ObservedObject var engine = PomodoroEngine.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject private var api = HabiticaAPI.shared

    @State private var dailies: [HabiticaTaskItem] = HabiticaPreviewSamples.dailies
    @State private var loading = false
    @State private var loadedAccount = ""
    @State private var loadGeneration = 0
    @State private var inFlightIds = Set<String>()
    @State private var accountGeneration = 0

    var body: some View {
        themedBody
            .task(id: accountSignature) { await load() }
    }

    private var accountSignature: String {
        let settings = settingsManager.settings
        return "\(settings.connectHabitica)|\(settings.uid)|\(settings.apiToken)|\(settings.developerServerUrl)"
    }

    private var isConfigured: Bool {
        settingsManager.settings.connectHabitica &&
        !settingsManager.settings.uid.isEmpty &&
        !settingsManager.settings.apiToken.isEmpty
    }

    /// Scoring still requires isConfigured, so offline preview samples can never reach the network.
    private var showsAccount: Bool { isConfigured || HabiticaPreviewSamples.enabled }

    @MainActor
    func load() async {
        if HabiticaPreviewSamples.enabled { return }
        let settings = settingsManager.settings
        let signature = accountSignature
        if loadedAccount != signature {
            dailies = []
            inFlightIds.removeAll()
            accountGeneration += 1
            loading = false
            loadedAccount = signature
        }
        guard !loading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard isConfigured else {
            dailies = []
            inFlightIds.removeAll()
            loading = false
            return
        }
        loading = true
        let items = await HabiticaAPI.shared.fetchTaskList(type: "dailys", settings: settings)
        guard accountSignature == signature, loadGeneration == generation else { return }
        if let items = items { dailies = items }
        loading = false
    }

    func toggle(item: HabiticaTaskItem) {
        guard isConfigured, !inFlightIds.contains(item.id) else { return }
        let settings = settingsManager.settings
        let signature = accountSignature
        inFlightIds.insert(item.id)
        let generation = accountGeneration
        Task {
            let direction = item.completed ? "down" : "up"
            let result = await HabiticaAPI.shared.scoreTask(taskId: item.id, direction: direction, settings: settings)
            await MainActor.run {
                guard accountSignature == signature, loadedAccount == signature, accountGeneration == generation else { return }
                if result != nil, let idx = dailies.firstIndex(where: { $0.id == item.id }) {
                    let current = dailies[idx]
                    dailies[idx] = HabiticaTaskItem(
                        id: current.id, text: current.text, notes: current.notes, value: current.value,
                        completed: direction == "up", canUp: current.canUp, canDown: current.canDown, isDue: current.isDue)
                    Task { await engine.refreshHabitica() }
                }
                inFlightIds.remove(item.id)
            }
        }
    }
}

// MARK: - Daily Row
struct DailyRow: View {
    @Environment(\.appTheme) private var theme

    let item: HabiticaTaskItem
    let busy: Bool
    let onToggle: () -> Void

    var body: some View {
        themedBody
    }
}

// MARK: - Role Tab (Habitica 角色信息：血量/法力/经验/属性)
struct HabiticaProfileView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ObservedObject var engine = PomodoroEngine.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject private var api = HabiticaAPI.shared

    @State private var profile: HabiticaProfile? = HabiticaPreviewSamples.profile
    @State private var loading = false
    @State private var loadedAccount = ""
    @State private var loadGeneration = 0

    var body: some View {
        themedBody
            .task(id: accountSignature) { await load() }
    }

    private var isConfigured: Bool {
        settingsManager.settings.connectHabitica &&
        !settingsManager.settings.uid.isEmpty &&
        !settingsManager.settings.apiToken.isEmpty
    }

    /// Scoring still requires isConfigured, so offline preview samples can never reach the network.
    private var showsAccount: Bool { isConfigured || HabiticaPreviewSamples.enabled }

    private func expInLevel(_ p: HabiticaProfile) -> Double {
        // Habitica: exp needed = ((lvl^2)*0.25 + 10*lvl + 139.75)
        let lvl = Double(p.level)
        return (lvl * lvl) * 0.25 + 10 * lvl + 139.75
    }

    private func fmtDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: d)
    }

    private var accountSignature: String {
        let settings = settingsManager.settings
        return "\(settings.connectHabitica)|\(settings.uid)|\(settings.apiToken)|\(settings.developerServerUrl)"
    }

    @MainActor
    func load() async {
        if HabiticaPreviewSamples.enabled { return }
        let settings = settingsManager.settings
        let signature = accountSignature
        if loadedAccount != signature {
            profile = nil
            loading = false
            loadedAccount = signature
        }
        guard !loading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard isConfigured else { profile = nil; return }
        loading = true
        let result = await HabiticaAPI.shared.fetchProfile(settings: settings)
        guard accountSignature == signature, loadGeneration == generation else { return }
        if let result = result { profile = result }
        loading = false
    }
}

// MARK: - StatBar
struct StatBar: View {
    @Environment(\.appTheme) private var theme

    let icon: String
    let color: Color
    let label: String
    let value: Double
    let maxValue: Double
    var valueText: String? = nil

    var body: some View {
        themedBody
    }
}

// MARK: - AttrCell
struct AttrCell: View {
    @Environment(\.appTheme) private var theme

    let name: String
    let value: Int
    let color: Color

    var body: some View {
        themedBody
    }
}

// MARK: - AchieveCell
struct AchieveCell: View {
    @Environment(\.appTheme) private var theme

    let name: String
    let value: String

    var body: some View {
        themedBody
    }
}

// MARK: - Habitica pages in the active skin

extension HabiticaHabitsView {
    private var themedBody: some View {
        HabiticaPageChrome(title: "习惯", subtitle: "每天一点，慢慢养成。", symbol: "sparkles",
                           detail: showsAccount && !habits.isEmpty ? "\(habits.count) 项" : nil,
                           configured: showsAccount, loading: loading, error: api.lastError,
                           refresh: { Task { await load() } }) {
            if !showsAccount {
                ThemedEmptyState(symbol: "person.badge.key", title: "连接你的 Habitica",
                                 message: "在设置 → Habitica 中填入 User ID 与 API Token，开始记录习惯。")
            } else if loading && habits.isEmpty {
                HabiticaLoadingState()
            } else if habits.isEmpty {
                ThemedEmptyState(symbol: api.lastError == nil ? "sparkles" : "wifi.exclamationmark",
                                 title: api.lastError == nil ? "还没有习惯" : "习惯加载失败",
                                 message: api.lastError == nil ? "在 Habitica 添加习惯后，点击刷新同步到这里。" : "请检查网络连接，然后点击右上角刷新。")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: theme.rowSpacing) {
                        ForEach(habits) { habit in
                            HabitRow(item: habit, onScore: { direction in
                                score(item: habit, direction: direction)
                            }, scored: scoredIds.contains(habit.id), busy: inFlightIds.contains(habit.id))
                        }
                        Text("用 + 记录好习惯，用 − 提醒自己。弱项会排在前面。")
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .padding(.bottom, 2)
                }
            }
        }
    }
}

extension HabitRow {
    private var themedBody: some View {
        HStack(spacing: 12) {
            scoreButton("minus", direction: "down", enabled: item.canDown)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    theme.dotShape.fill(valueColor).frame(width: 6, height: 6)
                    Text(String(format: "习惯值 %.1f", item.value))
                        .font(theme.numberFont(size: 10, weight: .regular))
                        .foregroundColor(theme.muted)
                    if scored {
                        Text("· 已记录").font(.system(size: 10, weight: .medium)).foregroundColor(theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small).tint(theme.accent)
            }
            scoreButton(scored ? "checkmark" : "plus", direction: "up", enabled: item.canUp)
        }
        .themeCard(theme, padding: theme.cardPadding)
        .opacity(scored ? 0.82 : 1)
    }

    private func scoreButton(_ symbol: String, direction: String, enabled: Bool) -> some View {
        let available = enabled && !scored && !busy
        let up = direction == "up"
        let shape = theme.smallShape(9)
        return Button { onScore(direction) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(available ? (up ? theme.onAccent : theme.danger) : theme.muted.opacity(0.5))
                .frame(width: 34, height: 34)
                .background(shape.fill(available && up ? theme.accent : theme.subtle))
                .overlay(theme.squareCorners ? shape.strokeBorder(theme.ink, lineWidth: theme.borderWidth) : nil)
                .contentShape(shape)
        }
        .buttonStyle(SkinPlainButtonStyle(theme: theme, radius: min(theme.controlRadius, 9)))
        .disabled(!available)
        .accessibilityLabel(up ? "为\(item.text)加分" : "为\(item.text)减分")
    }
}

extension HabiticaDailiesView {
    private var themedBody: some View {
        HabiticaPageChrome(title: "每日", subtitle: "把日常的小事，一件件做好。", symbol: "calendar",
                           detail: showsAccount && !dailies.isEmpty ? "\(dailies.filter(\.completed).count) / \(dailies.count)" : nil,
                           configured: showsAccount, loading: loading, error: api.lastError,
                           refresh: { Task { await load() } }) {
            if !showsAccount {
                ThemedEmptyState(symbol: "person.badge.key", title: "连接你的 Habitica",
                                 message: "在设置 → Habitica 中填入 User ID 与 API Token，查看每日打卡。")
            } else if loading && dailies.isEmpty {
                HabiticaLoadingState()
            } else if dailies.isEmpty {
                ThemedEmptyState(symbol: api.lastError == nil ? "calendar" : "wifi.exclamationmark",
                                 title: api.lastError == nil ? "还没有每日任务" : "每日任务加载失败",
                                 message: api.lastError == nil ? "在 Habitica 添加每日任务后，点击刷新同步到这里。" : "请检查网络连接，然后点击右上角刷新。")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: theme.rowSpacing) {
                        ForEach(dailies) { daily in
                            DailyRow(item: daily, busy: inFlightIds.contains(daily.id), onToggle: { toggle(item: daily) })
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
    }
}

extension DailyRow {
    private var themedBody: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: theme.checkSymbol(item.completed))
                    .font(.system(size: 21, weight: .light))
                    .foregroundColor(item.completed ? theme.accent : theme.muted)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SkinPlainButtonStyle(theme: theme))
            .disabled(busy)
            .accessibilityLabel(item.completed ? "取消完成\(item.text)" : "完成\(item.text)")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.completed ? theme.muted : theme.ink)
                    .strikethrough(item.completed, color: theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small).tint(theme.accent)
            } else if item.completed {
                SkinChip(text: "已完成")
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }
}

extension HabiticaProfileView {
    private var themedBody: some View {
        HabiticaPageChrome(title: "角色", subtitle: "每一份努力，都在让你成长。", symbol: "person.crop.circle",
                           detail: profile.map { "Lv.\($0.level)" },
                           configured: showsAccount, loading: loading, error: api.lastError,
                           refresh: { Task { await load() } }) {
            if !showsAccount {
                ThemedEmptyState(symbol: "person.badge.key", title: "连接你的 Habitica",
                                 message: "在设置 → Habitica 中填入 User ID 与 API Token，查看你的角色与成长记录。")
            } else if loading && profile == nil {
                HabiticaLoadingState()
            } else if let p = profile {
                ScrollView(showsIndicators: false) {
                    if theme.showsColumns(compactWidth: horizontalSizeClass == .compact) {
                        HStack(alignment: .top, spacing: theme.pageSpacing) {
                            VStack(spacing: theme.pageSpacing) {
                                identityCard(p)
                                resourcesCard(p)
                            }.frame(maxWidth: .infinity)
                            VStack(spacing: theme.pageSpacing) {
                                attributesCard(p)
                                achievementsCard(p)
                            }.frame(maxWidth: .infinity)
                        }
                        .padding(.bottom, 2)
                    } else {
                        VStack(spacing: theme.pageSpacing) {
                            identityCard(p)
                            resourcesCard(p)
                            attributesCard(p)
                            achievementsCard(p)
                        }
                        .padding(.bottom, 2)
                    }
                }
            } else {
                ThemedEmptyState(symbol: "wifi.exclamationmark", title: "角色数据加载失败",
                                 message: "请检查网络或 Habitica 服务状态，然后点击右上角刷新。")
            }
        }
    }

    private func identityCard(_ p: HabiticaProfile) -> some View {
        HStack(spacing: 14) {
            Text(p.username.prefix(1).uppercased())
                .font(theme.titleFont(size: 25, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 58, height: 58)
                .background(theme.dotShape.fill(theme.accentSoft))
                .overlay(theme.squareCorners ? Rectangle().strokeBorder(theme.ink, lineWidth: theme.borderWidth) : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("@\(p.username)")
                    .font(theme.sectionFont(size: 15))
                    .foregroundColor(theme.ink)
                    .lineLimit(1)
                    .modifier(MacHelp(text: p.username))
                Text(p.className.isEmpty ? "Lv.\(p.level)" : "\(p.className) · Lv.\(p.level)")
                    .font(theme.numberFont(size: 11, weight: .regular))
                    .foregroundColor(theme.muted)
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle.fill").foregroundColor(theme.highlight)
                    Text(String(format: "%.2f GP", p.gp)).foregroundColor(theme.ink)
                }
                .font(theme.numberFont(size: 11))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func resourcesCard(_ p: HabiticaProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("角色状态", symbol: "waveform.path.ecg")
            StatBar(icon: "heart.fill", color: theme.danger, label: "HP 生命", value: p.hp, maxValue: max(p.maxHealth, 50),
                    valueText: String(format: "%.0f / %.0f", p.hp, max(p.maxHealth, 50)))
            StatBar(icon: "sparkles", color: theme.rest, label: "MP 法力", value: p.mp, maxValue: max(p.maxMP, p.mp, 1),
                    valueText: String(format: "%.0f", p.mp))
            StatBar(icon: "star.fill", color: theme.highlight, label: "EXP 经验", value: p.exp, maxValue: max(expInLevel(p), 1),
                    valueText: String(format: "%.0f / %.0f", p.exp, expInLevel(p)))
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func attributesCard(_ p: HabiticaProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("能力属性", symbol: "square.grid.2x2")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: theme.rowSpacing) {
                AttrCell(name: "STR 力量", value: p.str, color: theme.danger)
                AttrCell(name: "CON 体质", value: p.con, color: theme.highlight)
                AttrCell(name: "INT 智力", value: p.int, color: theme.rest)
                AttrCell(name: "PER 感知", value: p.per, color: theme.accent)
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func achievementsCard(_ p: HabiticaProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("成长记录", symbol: "rosette")
            VStack(spacing: theme.rowSpacing) {
                AchieveCell(name: "连续完美天数", value: "\(p.streak)")
                AchieveCell(name: "完美日总数", value: "\(p.perfectDays)")
                AchieveCell(name: "任务卷轴", value: "\(p.questsTotal)")
                AchieveCell(name: "注册时间", value: p.joinedAt.map { fmtDate($0) } ?? "—")
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accent)
            Text(title)
                .font(theme.sectionFont(size: 13))
                .foregroundColor(theme.ink)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension StatBar {
    private var themedBody: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(color).frame(width: 14)
                Text(label).foregroundColor(theme.muted)
                Spacer(minLength: 4)
                Text(valueText ?? String(format: "%.0f", value))
                    .font(theme.numberFont(size: 11))
                    .foregroundColor(theme.ink)
            }
            .font(.system(size: 11))
            SkinProgressBar(value: value, total: maxValue, tint: color, height: theme.squareCorners ? 8 : 6)
        }
        .accessibilityElement(children: .combine)
    }
}

extension AttrCell {
    private var themedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                theme.dotShape.fill(color).frame(width: 6, height: 6)
                Text(name).font(.system(size: 10)).foregroundColor(theme.muted)
            }
            Text("\(value)")
                .font(theme.numberFont(size: 19))
                .foregroundColor(theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeWell(theme)
        .accessibilityElement(children: .combine)
    }
}

extension AchieveCell {
    private var themedBody: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11)).foregroundColor(theme.muted)
            Spacer(minLength: 0)
            Text(value).font(theme.numberFont(size: 12)).foregroundColor(theme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.smallShape().fill(theme.subtle))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Offline preview samples (DEBUG `-previewHabiticaSamples`, skin screenshots only)

/// Rows shown instead of live data when the launch argument is present. Never used for scoring or sync.
enum HabiticaPreviewSamples {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-previewHabiticaSamples")
    #else
    static let enabled = false
    #endif

    static var habits: [HabiticaTaskItem] {
        #if DEBUG
        guard enabled else { return [] }
        return [
            HabiticaTaskItem(id: "s-h1", text: "睡前刷手机超过 30 分钟", notes: "", value: -3.2,
                             completed: false, canUp: false, canDown: true, isDue: true),
            HabiticaTaskItem(id: "s-h2", text: "喝一杯水", notes: "", value: 0.4,
                             completed: false, canUp: true, canDown: false, isDue: true),
            HabiticaTaskItem(id: "s-h3", text: "Pomodoro", notes: "", value: 3.6,
                             completed: false, canUp: true, canDown: true, isDue: true),
            HabiticaTaskItem(id: "s-h4", text: "读 20 页书", notes: "", value: 9.1,
                             completed: false, canUp: true, canDown: false, isDue: true),
        ]
        #else
        return []
        #endif
    }

    static var dailies: [HabiticaTaskItem] {
        #if DEBUG
        guard enabled else { return [] }
        return [
            HabiticaTaskItem(id: "s-d1", text: "晨间拉伸 10 分钟", notes: "起床后先活动肩颈", value: 2,
                             completed: true, canUp: true, canDown: true, isDue: true),
            HabiticaTaskItem(id: "s-d2", text: "整理今日三件事", notes: "", value: 1,
                             completed: false, canUp: true, canDown: true, isDue: true),
            HabiticaTaskItem(id: "s-d3", text: "复盘与写日记", notes: "睡前 15 分钟", value: 0,
                             completed: false, canUp: true, canDown: true, isDue: true),
        ]
        #else
        return []
        #endif
    }

    static var profile: HabiticaProfile? {
        #if DEBUG
        guard enabled else { return nil }
        var p = HabiticaProfile()
        p.username = "pomo_ranger"
        p.className = "战士"
        p.level = 23
        p.exp = 412
        p.hp = 38
        p.maxHealth = 50
        p.mp = 41
        p.maxMP = 60
        p.gp = 128.5
        p.str = 12
        p.con = 9
        p.int = 7
        p.per = 10
        p.streak = 14
        p.perfectDays = 63
        p.questsTotal = 5
        p.joinedAt = Date(timeIntervalSince1970: 1_640_995_200)
        return p
        #else
        return nil
        #endif
    }
}
