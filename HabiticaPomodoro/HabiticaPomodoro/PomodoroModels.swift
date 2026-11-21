import Foundation

// MARK: - User Settings (mirrors the extension's UserSettings)
struct UserSettings: Codable {
    var uid: String = ""
    var apiToken: String = ""
    var connectHabitica: Bool = true
    var pomoDurationMins: Int = 25
    var breakDuration: Int = 5
    var breakExtention: Int = 2
    var longBreakDuration: Int = 30
    var pomoSetNum: Int = 4
    var manualBreak: Bool = true
    var breakFreePass: Bool = false
    var breakExtentionFails: Bool = false
    var breakExtentionNotify: Bool = false
    var resetPomoAfterBreak: Bool = false
    var longBreakNotify: Bool = false
    var vacationMode: Bool = false
    var pomoHabitPlus: Bool = false
    var pomoHabitMinus: Bool = false
    var pomoSetHabitPlus: Bool = false
    var customPomodoroTask: Bool = false
    var customSetTask: Bool = false
    var pomodoroTaskId: String? = nil
    var pomodoroSetTaskId: String? = nil
    var pomoEndSound: String = "None"
    var breakEndSound: String = "None"
    var ambientSound: String = "None"
    var pomoEndSoundVolume: Double = 0.5
    var breakEndSoundVolume: Double = 0.5
    var ambientSoundVolume: Double = 0.5
    /// 环境音来源："custom" = 内置环境音（老方案）；"qishi" = 每个番茄随机播放一个栖时场景混音
    var ambientSource: String = "custom"
    var developerServerUrl: String = ""

    // MARK: - Block Settings (时间块功能)
    var enableBlockMode: Bool = false // 启用时间块模式
    var blockCount: Int = 8 // 每天分几块（默认 8 块）
    var blockPomoCount: Int = 6 // 每块几个 pomo（默认 6 个）
    var blockGoals: [String] = [] // 每块的目标（可选）
    var blockTimeRanges: [BlockTimeRange] = [] // 每块的时间范围（如 4:00-7:00）
    var blockTasks: [[BlockTask]] = [] // 每块的任务列表
    var blockRewardEnabled: Bool = true // 块完成后 Habitica 奖励
    var blockSprintReminder: Bool = true // 块进度 4/6 时提醒冲刺
    var blockStartReminder: Bool = true // 块开始前 5 分钟提醒
    var blockReminderMinutes: Int = 5 // 块开始前提醒分钟数

    init() {
        // 初始化默认块时间范围（4:00 开始，每块 3 小时）
        blockTimeRanges = [
            BlockTimeRange(startHour: 4, startMinute: 0, endHour: 7, endMinute: 0),   // 4:00-7:00
            BlockTimeRange(startHour: 7, startMinute: 0, endHour: 10, endMinute: 0),  // 7:00-10:00
            BlockTimeRange(startHour: 10, startMinute: 0, endHour: 13, endMinute: 0),  // 10:00-13:00
            BlockTimeRange(startHour: 13, startMinute: 0, endHour: 16, endMinute: 0),  // 13:00-16:00
            BlockTimeRange(startHour: 16, startMinute: 0, endHour: 19, endMinute: 0),  // 16:00-19:00
            BlockTimeRange(startHour: 19, startMinute: 0, endHour: 22, endMinute: 0),  // 19:00-22:00
            BlockTimeRange(startHour: 22, startMinute: 0, endHour: 1, endMinute: 0),   // 22:00-01:00
            BlockTimeRange(startHour: 1, startMinute: 0, endHour: 4, endMinute: 0),    // 01:00-04:00
        ]

        // 初始化默认块任务列表
        blockTasks = Array(repeating: [], count: 8)
        normalize()
    }

    enum CodingKeys: String, CodingKey { case uid, apiToken, connectHabitica, pomoDurationMins, breakDuration, breakExtention, longBreakDuration, pomoSetNum, manualBreak, breakFreePass, breakExtentionFails, breakExtentionNotify, resetPomoAfterBreak, longBreakNotify, vacationMode, pomoHabitPlus, pomoHabitMinus, pomoSetHabitPlus, customPomodoroTask, customSetTask, pomodoroTaskId, pomodoroSetTaskId, pomoEndSound, breakEndSound, ambientSound, pomoEndSoundVolume, breakEndSoundVolume, ambientSoundVolume, ambientSource, developerServerUrl, enableBlockMode, blockCount, blockPomoCount, blockGoals, blockTimeRanges, blockTasks, blockRewardEnabled, blockSprintReminder, blockStartReminder, blockReminderMinutes }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? uid
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken) ?? apiToken
        connectHabitica = try c.decodeIfPresent(Bool.self, forKey: .connectHabitica) ?? connectHabitica
        pomoDurationMins = try c.decodeIfPresent(Int.self, forKey: .pomoDurationMins) ?? pomoDurationMins
        breakDuration = try c.decodeIfPresent(Int.self, forKey: .breakDuration) ?? breakDuration
        breakExtention = try c.decodeIfPresent(Int.self, forKey: .breakExtention) ?? breakExtention
        longBreakDuration = try c.decodeIfPresent(Int.self, forKey: .longBreakDuration) ?? longBreakDuration
        pomoSetNum = try c.decodeIfPresent(Int.self, forKey: .pomoSetNum) ?? pomoSetNum
        manualBreak = try c.decodeIfPresent(Bool.self, forKey: .manualBreak) ?? manualBreak
        breakFreePass = try c.decodeIfPresent(Bool.self, forKey: .breakFreePass) ?? breakFreePass
        breakExtentionFails = try c.decodeIfPresent(Bool.self, forKey: .breakExtentionFails) ?? breakExtentionFails
        breakExtentionNotify = try c.decodeIfPresent(Bool.self, forKey: .breakExtentionNotify) ?? breakExtentionNotify
        resetPomoAfterBreak = try c.decodeIfPresent(Bool.self, forKey: .resetPomoAfterBreak) ?? resetPomoAfterBreak
        longBreakNotify = try c.decodeIfPresent(Bool.self, forKey: .longBreakNotify) ?? longBreakNotify
        vacationMode = try c.decodeIfPresent(Bool.self, forKey: .vacationMode) ?? vacationMode
        pomoHabitPlus = try c.decodeIfPresent(Bool.self, forKey: .pomoHabitPlus) ?? pomoHabitPlus
        pomoHabitMinus = try c.decodeIfPresent(Bool.self, forKey: .pomoHabitMinus) ?? pomoHabitMinus
        pomoSetHabitPlus = try c.decodeIfPresent(Bool.self, forKey: .pomoSetHabitPlus) ?? pomoSetHabitPlus
        customPomodoroTask = try c.decodeIfPresent(Bool.self, forKey: .customPomodoroTask) ?? customPomodoroTask
        customSetTask = try c.decodeIfPresent(Bool.self, forKey: .customSetTask) ?? customSetTask
        pomodoroTaskId = try c.decodeIfPresent(String.self, forKey: .pomodoroTaskId)
        pomodoroSetTaskId = try c.decodeIfPresent(String.self, forKey: .pomodoroSetTaskId)
        pomoEndSound = try c.decodeIfPresent(String.self, forKey: .pomoEndSound) ?? pomoEndSound
        breakEndSound = try c.decodeIfPresent(String.self, forKey: .breakEndSound) ?? breakEndSound
        ambientSound = try c.decodeIfPresent(String.self, forKey: .ambientSound) ?? ambientSound
        pomoEndSoundVolume = try c.decodeIfPresent(Double.self, forKey: .pomoEndSoundVolume) ?? pomoEndSoundVolume
        breakEndSoundVolume = try c.decodeIfPresent(Double.self, forKey: .breakEndSoundVolume) ?? breakEndSoundVolume
        ambientSoundVolume = try c.decodeIfPresent(Double.self, forKey: .ambientSoundVolume) ?? ambientSoundVolume
        ambientSource = try c.decodeIfPresent(String.self, forKey: .ambientSource) ?? ambientSource
        developerServerUrl = try c.decodeIfPresent(String.self, forKey: .developerServerUrl) ?? developerServerUrl
        enableBlockMode = try c.decodeIfPresent(Bool.self, forKey: .enableBlockMode) ?? enableBlockMode
        blockCount = try c.decodeIfPresent(Int.self, forKey: .blockCount) ?? blockCount
        blockPomoCount = try c.decodeIfPresent(Int.self, forKey: .blockPomoCount) ?? blockPomoCount
        blockGoals = try c.decodeIfPresent([String].self, forKey: .blockGoals) ?? blockGoals
        blockTimeRanges = try c.decodeIfPresent([BlockTimeRange].self, forKey: .blockTimeRanges) ?? blockTimeRanges
        blockTasks = try c.decodeIfPresent([[BlockTask]].self, forKey: .blockTasks) ?? blockTasks
        blockRewardEnabled = try c.decodeIfPresent(Bool.self, forKey: .blockRewardEnabled) ?? blockRewardEnabled
        blockSprintReminder = try c.decodeIfPresent(Bool.self, forKey: .blockSprintReminder) ?? blockSprintReminder
        blockStartReminder = try c.decodeIfPresent(Bool.self, forKey: .blockStartReminder) ?? blockStartReminder
        blockReminderMinutes = try c.decodeIfPresent(Int.self, forKey: .blockReminderMinutes) ?? blockReminderMinutes
        normalize()
    }

    /// Preserve surplus arrays when the count is lowered; expand safely when it grows.
    mutating func normalize() {
        blockCount = min(24, max(1, blockCount))
        blockPomoCount = min(12, max(1, blockPomoCount))
        pomoDurationMins = min(120, max(1, pomoDurationMins))
        breakDuration = min(60, max(1, breakDuration))
        longBreakDuration = min(120, max(1, longBreakDuration))
        breakExtention = min(30, max(0, breakExtention))
        pomoSetNum = min(12, max(1, pomoSetNum))
        blockReminderMinutes = min(60, max(1, blockReminderMinutes))
        while blockGoals.count < blockCount { blockGoals.append("") }
        while blockTasks.count < blockCount { blockTasks.append([]) }
        while blockTimeRanges.count < blockCount {
            let start = (4 * 60 + blockTimeRanges.count * 180) % 1440
            let end = (start + 180) % 1440
            blockTimeRanges.append(BlockTimeRange(startHour: start / 60, startMinute: start % 60, endHour: end / 60, endMinute: end % 60))
        }
    }
}

// MARK: - Block Time Range (块时间范围)
struct BlockTimeRange: Codable, Equatable {
    var startHour: Int // 开始小时（0-23）
    var startMinute: Int // 开始分钟（0-59）
    var endHour: Int // 结束小时
    var endMinute: Int // 结束分钟

    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }

    // 判断给定时间是否在此块内
    func contains(hour: Int, minute: Int) -> Bool {
        let minutes = hour * 60 + minute
        if startMinutes > endMinutes {
            return minutes >= startMinutes || minutes < endMinutes // spans midnight
        }
        if startMinutes == endMinutes { return true } // equal endpoints represent a full day
        return minutes >= startMinutes && minutes < endMinutes
    }

    // 获取时间范围字符串
    var displayString: String {
        return String(format: "%02d:%02d-%02d:%02d", startHour, startMinute, endHour, endMinute)
    }
}

// MARK: - Block Progress (当前块进度)
struct BlockProgress: Codable {
    var currentBlockIndex: Int = 0 // 当前块索引 (0-based)
    var blockPomoCounter: Int = 0 // 当前块内完成 pomo 数
    var blockStartTime: Date? = nil // 块开始时间
    var progressDate: String = "" // calendar date owning the cached count

    // 获取当前时间点对应的块索引
    static func getCurrentBlockIndex(timeRanges: [BlockTimeRange], date: Date = Date()) -> Int? {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        for (index, range) in timeRanges.enumerated() {
            if range.contains(hour: hour, minute: minute) {
                return index
            }
        }
        return nil
    }

    func getBlockGoal(goals: [String]) -> String {
        if currentBlockIndex < goals.count && !goals[currentBlockIndex].isEmpty {
            return goals[currentBlockIndex]
        }
        return "Block \(currentBlockIndex + 1)"
    }

    func getBlockProgress(pomoCount: Int) -> (completed: Int, total: Int) {
        return (blockPomoCounter, pomoCount)
    }

    mutating func incrementBlockPomo() {
        blockPomoCounter += 1
    }

    mutating func moveToNextBlock() {
        currentBlockIndex += 1
        blockPomoCounter = 0
        blockStartTime = Date()
    }

    mutating func resetBlock() {
        currentBlockIndex = 0
        blockPomoCounter = 0
        blockStartTime = nil
    }

    func isBlockComplete(pomoCount: Int) -> Bool {
        return blockPomoCounter >= pomoCount
    }
}

// MARK: - Block Task (块内的任务)
struct BlockTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false
    var estimatedPomo: Int = 1 // 预计需要几个 pomo
}

// MARK: - Daily Block History (每日块历史)
struct DailyBlockHistory: Codable {
    var date: String // yyyy-MM-dd
    var blocks: [BlockHistoryEntry]
}

// MARK: - Block History (历史块记录)
struct BlockHistoryEntry: Codable {
    var date: String // yyyy-MM-dd
    var blockIndex: Int
    var pomodoros: Int
    var isComplete: Bool
    var completedAt: Date?
}

// MARK: - Daily Block Progress (每天的块进度)
struct DailyBlockProgress: Codable {
    var date: String // yyyy-MM-dd
    var blockProgress: [Int] // 每个块完成的 pomo 数（索引 0 = block 1）
    var blockGoals: [String] // 每个块的目标
}

typealias BlockHistory = [String: [BlockHistoryEntry]] // date -> entries
typealias DailyBlocksHistory = [String: DailyBlockProgress] // date -> daily progress

// MARK: - Top Three (当天最重要的三件事，按分类 Work / MyOwn / 琐事)
struct TopThreeTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false
    var habiticaTaskId: String? = nil // 对应的 Habitica todo id
    var movedToToday: Bool = false    // 原日期保留的已转移副本
    var syncPending: Bool = false
    var cloudAccount: String? = nil // UID + canonical HTTPS API root; never credentials
    var cloudCreateAttempt: CloudCreateAttempt? = nil
    var updatedAt: Date? = nil // last local edit of title/completion/category/move; nil = before merge support

    var isUnfinished: Bool {
        !isCompleted && !movedToToday && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey { case id, title, isCompleted, habiticaTaskId, movedToToday, syncPending, cloudAccount, cloudCreateAttempt, updatedAt }

    init(id: UUID = UUID(), title: String, isCompleted: Bool = false, habiticaTaskId: String? = nil, movedToToday: Bool = false, syncPending: Bool = false, cloudAccount: String? = nil) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.habiticaTaskId = habiticaTaskId
        self.movedToToday = movedToToday
        self.syncPending = syncPending
        self.cloudAccount = cloudAccount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        habiticaTaskId = try c.decodeIfPresent(String.self, forKey: .habiticaTaskId)
        movedToToday = try c.decodeIfPresent(Bool.self, forKey: .movedToToday) ?? false
        syncPending = try c.decodeIfPresent(Bool.self, forKey: .syncPending) ?? false
        cloudAccount = try c.decodeIfPresent(String.self, forKey: .cloudAccount)
        cloudCreateAttempt = try c.decodeIfPresent(CloudCreateAttempt.self, forKey: .cloudCreateAttempt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// Persist the exact attempted POST version so a lost response is reconciled before retrying.
struct CloudCreateAttempt: Codable, Equatable {
    var title: String
    var notes: String
    var tags: [String]
}

/// A removed local UUID may already exist remotely even when its POST response was lost.
struct DeletedCloudCreateAttempt: Codable, Equatable {
    var id: UUID
    var attempt: CloudCreateAttempt
}

struct TopThreeCloudState: Codable {
    var categoryTagIds: [String: String] = [:]
    var deletedCloudIds: [String] = []
    var confirmedDeletedCloudIds: [String] = []
    var pendingTagRenames: [String: String] = [:] // tag ID -> desired name
    var deletedCreateAttempts: [DeletedCloudCreateAttempt] = []

    init(categoryTagIds: [String: String] = [:], deletedCloudIds: [String] = [], confirmedDeletedCloudIds: [String] = [], pendingTagRenames: [String: String] = [:], deletedCreateAttempts: [DeletedCloudCreateAttempt] = []) {
        self.categoryTagIds = categoryTagIds
        self.deletedCloudIds = deletedCloudIds
        self.confirmedDeletedCloudIds = confirmedDeletedCloudIds
        self.pendingTagRenames = pendingTagRenames
        self.deletedCreateAttempts = deletedCreateAttempts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryTagIds = try c.decodeIfPresent([String: String].self, forKey: .categoryTagIds) ?? [:]
        deletedCloudIds = try c.decodeIfPresent([String].self, forKey: .deletedCloudIds) ?? []
        confirmedDeletedCloudIds = try c.decodeIfPresent([String].self, forKey: .confirmedDeletedCloudIds) ?? []
        pendingTagRenames = try c.decodeIfPresent([String: String].self, forKey: .pendingTagRenames) ?? [:]
        deletedCreateAttempts = try c.decodeIfPresent([DeletedCloudCreateAttempt].self, forKey: .deletedCreateAttempts) ?? []
    }
    enum CodingKeys: String, CodingKey { case categoryTagIds, deletedCloudIds, confirmedDeletedCloudIds, pendingTagRenames, deletedCreateAttempts }
}

struct TopThreeDay: Codable {
    var date: String // yyyy-MM-dd（逻辑日，以第一个 time block 启动时间为界）
    var taskGroups: [[TopThreeTask]] = [] // 每个分类一组；Work/MyOwn 固定 3 槽位，琐事为自由列表

    enum CodingKeys: String, CodingKey { case date, taskGroups }

    init(date: String, taskGroups: [[TopThreeTask]] = []) {
        self.date = date
        self.taskGroups = taskGroups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        taskGroups = try c.decodeIfPresent([[TopThreeTask]].self, forKey: .taskGroups) ?? []
    }
}

// 持久化单元：分类名可自定义 + Habitica tag 映射 + 历史记录
struct TopThreeStore: Codable {
    var categoryNames: [String] = ["Work", "MyOwn", "Chores"]
    var categoryTagIds: [String: String] = [:] // 分类名 -> Habitica tag id
    var history: [String: TopThreeDay] = [:] // logical date -> day record
    var deletedCloudIds: [String] = [] // durable tombstones: stale reads cannot resurrect deletions
    var confirmedDeletedCloudIds: [String] = [] // acknowledged deletes need no repeated HTTP request
    var cloudAccount: String = "" // UID + API root only; never store a token here
    var pendingTagRenames: [String: String] = [:]
    var cloudStates: [String: TopThreeCloudState] = [:]
    var deletedCreateAttempts: [DeletedCloudCreateAttempt] = [] // active owner's unresolved removals
    // Concurrent-edit merge metadata (TopThreeMerge); absent in files written by older versions.
    var taskTombstones: [String: Date] = [:] // deleted task UUID -> deletion time
    var categoryNamesUpdatedAt: [Date] = [] // per category index; missing = never renamed since upgrade
    var writeClock: [String: Int]? = nil // device ID -> number of saves; nil = written by an older version

    enum CodingKeys: String, CodingKey { case categoryNames, categoryTagIds, history, deletedCloudIds, confirmedDeletedCloudIds, cloudAccount, pendingTagRenames, cloudStates, deletedCreateAttempts, taskTombstones, categoryNamesUpdatedAt, writeClock }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryNames = try c.decodeIfPresent([String].self, forKey: .categoryNames) ?? ["Work", "MyOwn", "Chores"]
        categoryTagIds = try c.decodeIfPresent([String: String].self, forKey: .categoryTagIds) ?? [:]
        history = try c.decodeIfPresent([String: TopThreeDay].self, forKey: .history) ?? [:]
        deletedCloudIds = try c.decodeIfPresent([String].self, forKey: .deletedCloudIds) ?? []
        confirmedDeletedCloudIds = try c.decodeIfPresent([String].self, forKey: .confirmedDeletedCloudIds) ?? []
        cloudAccount = try c.decodeIfPresent(String.self, forKey: .cloudAccount) ?? ""
        pendingTagRenames = try c.decodeIfPresent([String: String].self, forKey: .pendingTagRenames) ?? [:]
        cloudStates = try c.decodeIfPresent([String: TopThreeCloudState].self, forKey: .cloudStates) ?? [:]
        deletedCreateAttempts = try c.decodeIfPresent([DeletedCloudCreateAttempt].self, forKey: .deletedCreateAttempts) ?? []
        taskTombstones = try c.decodeIfPresent([String: Date].self, forKey: .taskTombstones) ?? [:]
        categoryNamesUpdatedAt = try c.decodeIfPresent([Date].self, forKey: .categoryNamesUpdatedAt) ?? []
        writeClock = try c.decodeIfPresent([String: Int].self, forKey: .writeClock)
    }
}

typealias TopThreeHistory = [String: TopThreeDay] // logical date -> day record

// MARK: - Histogram (daily pomodoro counts)
struct DayHistogram: Codable, Equatable {
    var pomodoros: Int
    var minutes: Int
    var weekday: String
}

typealias Histogram = [String: DayHistogram]

// Additive schema defaults keep old Mac/iPhone JSON readable.
extension BlockTimeRange {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour) ?? 4
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 0
        endHour = try c.decodeIfPresent(Int.self, forKey: .endHour) ?? 7
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? 0
    }
}
extension BlockProgress {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentBlockIndex = try c.decodeIfPresent(Int.self, forKey: .currentBlockIndex) ?? 0
        blockPomoCounter = try c.decodeIfPresent(Int.self, forKey: .blockPomoCounter) ?? 0
        blockStartTime = try c.decodeIfPresent(Date.self, forKey: .blockStartTime)
        progressDate = try c.decodeIfPresent(String.self, forKey: .progressDate) ?? ""
    }
}
extension BlockTask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        estimatedPomo = try c.decodeIfPresent(Int.self, forKey: .estimatedPomo) ?? 1
    }
}
extension BlockHistoryEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        blockIndex = try c.decodeIfPresent(Int.self, forKey: .blockIndex) ?? 0
        pomodoros = try c.decodeIfPresent(Int.self, forKey: .pomodoros) ?? 0
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}
extension DailyBlockProgress {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        blockProgress = try c.decodeIfPresent([Int].self, forKey: .blockProgress) ?? []
        blockGoals = try c.decodeIfPresent([String].self, forKey: .blockGoals) ?? []
    }
}
extension DayHistogram {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pomodoros = try c.decodeIfPresent(Int.self, forKey: .pomodoros) ?? 0
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 0
        weekday = try c.decodeIfPresent(String.self, forKey: .weekday) ?? ""
    }
}
