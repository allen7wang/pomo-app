import Foundation

// MARK: - Habitica API Constants
struct HabiticaConsts {
    static let xClientHeader = "5a8238ab-1819-4f7f-a750-f23264719a2d-HabiticaPomodoroSiteKeeper-v2"
    static let serverUrl = "https://habitica.com/api/v3/"
    static let pathUser = "user/"
    static let pathUserTasks = "tasks/user"
    static let pathUserHabits = "tasks/user?type=habits"
    static let pathPomodoroHabit = "tasks/sitepassPomodoro"
    static let pathPomodoroSetHabit = "tasks/sitepassPomodoroSet"
    static let pathReward = "tasks/sitepass"
}

// MARK: - Habitica Task Item (habits / dailies 列表项)
struct HabiticaTaskItem: Identifiable, Equatable {
    let id: String
    let text: String
    let notes: String
    let value: Double
    let completed: Bool
    let canUp: Bool
    let canDown: Bool
    let isDue: Bool // dailies: 今天是否到期
}

// MARK: - Habitica API Client
class HabiticaAPI: ObservableObject {
    static let shared = HabiticaAPI()
    #if DEBUG
    /// Scratch-only offline probes can replace transport before the singleton is initialized.
    static var isolatedURLProtocols: [AnyClass]?
    #endif

    @Published var monies: Double = 0
    @Published var exp: Double = 0
    @Published var hp: Double = 0
    @Published var lastError: String?
    @Published var isAuthenticated: Bool = false

    private var serverUrl: String { HabiticaConsts.serverUrl }

    func configure(serverUrlOverride: String?) -> String {
        let value = (serverUrlOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = value.isEmpty ? serverUrl : value
        guard var parts = URLComponents(string: configured), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return "" }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.path += "/"
        return parts.string ?? ""
    }

    func cloudAccount(settings: UserSettings) -> String? {
        let root = configure(serverUrlOverride: settings.developerServerUrl)
        guard !settings.uid.isEmpty, !root.isEmpty else { return nil }
        return "\(settings.uid)|\(root)"
    }

    func endpoint(path: String, settings: UserSettings) -> URL? {
        let base = configure(serverUrlOverride: settings.developerServerUrl)
        guard !base.isEmpty, let url = URL(string: base + path), url.scheme?.lowercased() == "https", url.host != nil else {
            reportError("服务地址无效：请使用不含账号、查询参数或片段的 HTTPS API 根地址。", settings: settings)
            return nil
        }
        return url
    }

    private func matchesCurrentAccount(_ settings: UserSettings) -> Bool {
        let current = SettingsManager.shared.settings
        return current.connectHabitica == settings.connectHabitica && current.uid == settings.uid &&
            current.apiToken == settings.apiToken &&
            configure(serverUrlOverride: current.developerServerUrl) == configure(serverUrlOverride: settings.developerServerUrl)
    }
    private func matchesCurrentRequest(_ request: URLRequest) -> Bool {
        let current = SettingsManager.shared.settings
        guard !configure(serverUrlOverride: current.developerServerUrl).isEmpty else { return false }
        return current.connectHabitica && request.value(forHTTPHeaderField: "x-api-user") == current.uid && request.value(forHTTPHeaderField: "x-api-key") == current.apiToken && request.url?.absoluteString.hasPrefix(configure(serverUrlOverride: current.developerServerUrl)) == true
    }

    // A custom header carrying the API token must not follow redirects to another origin.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        #if DEBUG
        if let protocols = isolatedURLProtocols { configuration.protocolClasses = protocols }
        #endif
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    private enum RequestFailure: Error { case status(Int), rateLimited, invalidResponse, staleAccount }
    // These dictionaries are only accessed on MainActor. Budget keys never include API tokens.
    private var requestBudgets: [String: HabiticaRequestBudget] = [:]
    private struct RequestContext {
        let request: URLRequest
        let accountGeneration: UInt64
        let sequence: UInt64
        let errorRevision: UInt64
    }
    private typealias RequestResult = (data: Data, response: URLResponse, context: RequestContext)
    private var feedbackAccountGeneration: UInt64?
    private var requestSequence: UInt64 = 0
    private var errorRevision: UInt64 = 0
    private var latestErrorSequence: UInt64 = 0
    private var latestAuthenticationSequence: UInt64 = 0
    private var latestProfileSequence: UInt64 = 0
    private struct ReadKey: Hashable {
        let url: URL?
        let user: String?
        let token: String?
        let generation: UInt64
        let accountGeneration: UInt64
    }
    private var readsInFlight: [ReadKey: Task<RequestResult, Error>] = [:]
    private var readGeneration: UInt64 = 0

    @MainActor
    func rateLimitMessage(settings: UserSettings) -> String? {
        guard let account = cloudAccount(settings: settings) else { return nil }
        return rateLimitMessage(account: account)
    }

    @MainActor
    private func rateLimitMessage(account: String) -> String? {
        guard var budget = requestBudgets[account] else { return nil }
        let delay = budget.delay(at: ProcessInfo.processInfo.systemUptime)
        requestBudgets[account] = budget
        guard delay > 0 else { return nil }
        let reason = budget.received429 ? "Habitica 暂时限流（HTTP 429）" : "Habitica 请求额度暂时用完"
        // A finite server delay can still exceed Int's range. Keep its cooldown intact
        // while avoiding a trapping conversion when formatting an unusual response header.
        let retry = Int(exactly: ceil(delay)).map { "\($0) 秒后重试。" }
            ?? "稍后重试（服务器要求的等待时间过长）。"
        return "\(reason)，请 \(retry)"
    }
    @MainActor
    private func prepareFeedbackGeneration() {
        let generation = SettingsManager.shared.habiticaAccountGeneration
        guard feedbackAccountGeneration != generation else { return }
        feedbackAccountGeneration = generation
        errorRevision &+= 1
        latestErrorSequence = 0
        latestAuthenticationSequence = 0
        latestProfileSequence = 0
        lastError = nil
    }

    @MainActor
    private func isCurrent(_ context: RequestContext) -> Bool {
        context.accountGeneration == SettingsManager.shared.habiticaAccountGeneration &&
            matchesCurrentRequest(context.request)
    }

    @MainActor
    private func connectionGeneration(settings: UserSettings) -> UInt64? {
        matchesCurrentAccount(settings) ? SettingsManager.shared.habiticaAccountGeneration : nil
    }

    @MainActor
    private func publishError(_ message: String?, context: RequestContext) {
        guard isCurrent(context), context.sequence >= latestErrorSequence else { return }
        latestErrorSequence = context.sequence
        errorRevision &+= 1
        lastError = message
        // @Published emits in willSet; a subscriber can retire this connection before assignment ends.
        if !isCurrent(context), lastError == message { lastError = nil }
    }

    @MainActor
    private func publishSuccess(context: RequestContext, account: String) {
        // Only a request started after the currently displayed error may clear it.
        guard isCurrent(context), errorRevision == context.errorRevision,
              requestBudgets[account]?.received429 != true else { return }
        lastError = nil
    }

    private func reportError(_ message: String, settings: UserSettings? = nil,
                             context: RequestContext? = nil) {
        let generation = context?.accountGeneration ?? SettingsManager.shared.habiticaAccountGeneration
        DispatchQueue.main.async {
            guard generation == SettingsManager.shared.habiticaAccountGeneration else { return }
            if let context = context {
                self.publishError(message, context: context)
            } else {
                if let settings = settings, !self.matchesCurrentAccount(settings) { return }
                self.prepareFeedbackGeneration()
                self.requestSequence &+= 1
                self.latestErrorSequence = self.requestSequence
                self.errorRevision &+= 1
                self.lastError = message
            }
        }
    }
    // MainActor isolation: caller validation and mutation dispatch share a non-suspending segment.
    @MainActor
    private func perform(_ request: URLRequest, accountGeneration expectedGeneration: UInt64? = nil) async throws -> RequestResult {
        let generation = expectedGeneration ?? SettingsManager.shared.habiticaAccountGeneration
        guard generation == SettingsManager.shared.habiticaAccountGeneration,
              matchesCurrentRequest(request) else { throw RequestFailure.staleAccount }
        try Task.checkCancellation()
        // Only reads can share an in-flight request. Scores/creates/deletes are never replayed.
        if (request.httpMethod ?? "GET") == "GET" {
            let key = ReadKey(url: request.url, user: request.value(forHTTPHeaderField: "x-api-user"),
                              token: request.value(forHTTPHeaderField: "x-api-key"), generation: readGeneration,
                              accountGeneration: generation)
            let pending: Task<RequestResult, Error>
            let ownsRead: Bool
            if let existing = readsInFlight[key] {
                pending = existing
                ownsRead = false
            } else {
                pending = Task { @MainActor in try await self.performRequest(request, accountGeneration: generation) }
                readsInFlight[key] = pending
                ownsRead = true
            }
            defer { if ownsRead { readsInFlight.removeValue(forKey: key) } }
            do {
                let result = try await pending.value
                guard isCurrent(result.context) else { throw RequestFailure.staleAccount }
                return result
            } catch {
                guard generation == SettingsManager.shared.habiticaAccountGeneration,
                      matchesCurrentRequest(request) else { throw RequestFailure.staleAccount }
                throw error
            }
        }
        // Sent mutations must return their real outcome, even after a connection change.
        return try await performRequest(request, accountGeneration: generation)
    }

    @MainActor
    private func performRequest(_ request: URLRequest, accountGeneration generation: UInt64) async throws -> RequestResult {
        guard generation == SettingsManager.shared.habiticaAccountGeneration,
              matchesCurrentRequest(request) else { throw RequestFailure.staleAccount }
        try Task.checkCancellation()
        prepareFeedbackGeneration()
        // Publishing the reset can synchronously reenter settings via Combine subscribers.
        guard generation == SettingsManager.shared.habiticaAccountGeneration,
              matchesCurrentRequest(request),
              let account = cloudAccount(settings: SettingsManager.shared.settings) else { throw RequestFailure.staleAccount }
        requestSequence &+= 1
        let context = RequestContext(request: request, accountGeneration: generation,
                                     sequence: requestSequence, errorRevision: errorRevision)
        var budget = requestBudgets[account] ?? HabiticaRequestBudget()
        let delay = budget.reserve(at: ProcessInfo.processInfo.systemUptime)
        requestBudgets[account] = budget
        guard delay <= 0 else {
            publishError(rateLimitMessage(account: account), context: context)
            throw RequestFailure.rateLimited
        }
        let isMutation = (request.httpMethod ?? "GET") != "GET"
        if isMutation { readGeneration &+= 1 }
        // Verification after a write must not join a read started before its acknowledgement.
        defer { if isMutation { readGeneration &+= 1 } }
        do {
            let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: RequestFailure.invalidResponse)
                    }
                }
                task.resume()
            }
            guard let http = response as? HTTPURLResponse else { throw RequestFailure.invalidResponse }
            // Server limits belong to the original UID/root, including retired connections.
            var updated = requestBudgets[account] ?? budget
            updated.observe(http, at: ProcessInfo.processInfo.systemUptime, date: Date())
            requestBudgets[account] = updated
            guard (200..<300).contains(http.statusCode) || (request.httpMethod == "DELETE" && http.statusCode == 404) else {
                publishError(http.statusCode == 429 ? rateLimitMessage(account: account)
                    : (http.statusCode == 401 ? "Habitica 认证失败，请检查 User ID / API Token" : "Habitica 请求失败（HTTP \(http.statusCode)）"), context: context)
                if http.statusCode == 401, isCurrent(context), context.sequence >= latestAuthenticationSequence {
                    latestAuthenticationSequence = context.sequence
                    isAuthenticated = false
                }
                throw RequestFailure.status(http.statusCode)
            }
            publishSuccess(context: context, account: account)
            return (data, response, context)
        } catch {
            if case RequestFailure.invalidResponse = error {
                publishError("Habitica 返回了无法识别的响应。", context: context)
            } else if !(error is RequestFailure) && !(error is CancellationError) {
                publishError("网络错误：\(error.localizedDescription)", context: context)
            }
            throw error
        }
    }

    // GET user data
    @MainActor
    func fetchUserData(settings: UserSettings, silent: Bool = false) async {
        let generation = SettingsManager.shared.habiticaAccountGeneration
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else {
            guard matchesCurrentAccount(settings) else { return }
            prepareFeedbackGeneration()
            isAuthenticated = false
            monies = 0; exp = 0; hp = 0
            if !silent {
                guard generation == SettingsManager.shared.habiticaAccountGeneration,
                      matchesCurrentAccount(settings) else { return }
                requestSequence &+= 1
                latestErrorSequence = requestSequence
                errorRevision &+= 1
                lastError = settings.connectHabitica ? "Credentials not configured" : nil
                if generation != SettingsManager.shared.habiticaAccountGeneration { lastError = nil }
            }
            return
        }
        guard let url = endpoint(path: HabiticaConsts.pathUser, settings: settings) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, context) = try await perform(req)
            guard isCurrent(context), let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded: Any
            do { decoded = try JSONSerialization.jsonObject(with: data) }
            catch {
                publishError("Habitica 角色响应格式错误。", context: context)
                return
            }
            guard let json = decoded as? [String: Any], let userData = json["data"] as? [String: Any],
                  let stats = userData["stats"] as? [String: Any] else {
                publishError("Habitica 角色响应格式错误。", context: context)
                return
            }
            guard context.sequence >= latestAuthenticationSequence,
                  context.sequence >= latestProfileSequence else { return }
            defer {
                // Undo an outer @Published setter that finished after a subscriber changed accounts.
                if !isCurrent(context) {
                    monies = 0; exp = 0; hp = 0
                    isAuthenticated = false
                }
            }
            latestProfileSequence = context.sequence
            latestAuthenticationSequence = context.sequence
            monies = (stats["gp"] as? Double) ?? 0
            guard isCurrent(context) else { return }
            exp = (stats["exp"] as? Double) ?? 0
            guard isCurrent(context) else { return }
            hp = (stats["hp"] as? Double) ?? 0
            guard isCurrent(context) else { return }
            isAuthenticated = true
            // Transport already handled feedback ordering. Parsing must not clear it again.
        } catch { /* Preserve transport errors; only an actual current 401 invalidates credentials. */ }
    }

    // Score a habit up/down
    // MainActor: mutation dispatch chain — caller validation and task.resume() must share one
    // uninterrupted MainActor segment (see perform).
    @MainActor
    func scoreHabit(taskId: String, direction: String, settings: UserSettings) async -> [String: Double]? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: "tasks/\(taskId)/score/\(direction)", settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                return [
                    "lvl": (d["lvl"] as? Double) ?? 0,
                    "hp": (d["hp"] as? Double) ?? 0,
                    "exp": (d["exp"] as? Double) ?? 0,
                    "mp": (d["mp"] as? Double) ?? 0,
                    "gp": (d["gp"] as? Double) ?? 0
                ]
            }
        } catch { return nil }
        return nil
    }

    // Fetch or create the Pomodoro habit task
    func ensurePomodoroHabit(settings: UserSettings) async -> String? {
        if settings.customPomodoroTask {
            guard let id = settings.pomodoroTaskId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reportError("请填写自定义 Pomodoro Habit ID", settings: settings); return nil }
            return id
        }
        // Try GET existing
        do {
            if let id = try await getTaskId(path: HabiticaConsts.pathPomodoroHabit, settings: settings) { return id }
            return nil
        } catch RequestFailure.status(404) { /* missing alias: create below */ }
        catch { return nil }
        // Create new
        return await createHabit(text: "Pomodoro", alias: "sitepassPomodoro", notes: "Habit utilized by Habitica SiteKeeper. Change the difficulty manually according to your needs.", priority: 1, settings: settings)
    }

    func ensurePomodoroSetHabit(settings: UserSettings) async -> String? {
        if settings.customSetTask {
            guard let id = settings.pomodoroSetTaskId, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reportError("请填写自定义 Combo Habit ID", settings: settings); return nil }
            return id
        }
        do {
            if let id = try await getTaskId(path: HabiticaConsts.pathPomodoroSetHabit, settings: settings) { return id }
            return nil
        } catch RequestFailure.status(404) { /* missing alias: create below */ }
        catch { return nil }
        return await createHabit(text: "Pomodoro Combo!", alias: "sitepassPomodoroSet", notes: "Habit utilized by Habitica SiteKeeper. Change the difficulty manually according to your needs.", priority: 1.5, settings: settings)
    }

    private func getTaskId(path: String, settings: UserSettings) async throws -> String? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: path, settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, context) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                let id = d["id"] as? String
                return await MainActor.run { self.isCurrent(context) ? id : nil }
            }
        } catch { throw error }
        return nil
    }

    private func createHabit(text: String, alias: String, notes: String, priority: Double, settings: UserSettings) async -> String? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: HabiticaConsts.pathUserTasks, settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "type": "habit", "alias": alias, "notes": notes, "priority": priority]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 || http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                return d["id"] as? String
            }
        } catch { return nil }
        return nil
    }

    // Send private message (used for mobile notifications)
    func sendPrivateMessage(_ message: String, settings: UserSettings) async {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return }
        guard let url = endpoint(path: "members/send-private-message", settings: settings) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["message": message, "toUserId": settings.uid]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await perform(req)
    }

    // MARK: - Tags (用于任务分类 Work/MyOwn/Chores)

    // 获取所有 tag: [tagId: tagName]
    func fetchTags(settings: UserSettings) async -> [String: String]? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: "tags", settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, context) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tags = json["data"] as? [[String: Any]] {
                var result: [String: String] = [:]
                for tag in tags {
                    if let id = tag["id"] as? String, let name = tag["name"] as? String {
                        result[id] = name
                    }
                }
                let tags = result
                return await MainActor.run { self.isCurrent(context) ? tags : nil }
            }
        } catch { return nil }
        return nil
    }

    // 创建 tag，返回 tag id
    func createTag(name: String, settings: UserSettings) async -> String? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: "tags", settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": name]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 || http.statusCode == 200 else { return nil }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                return d["id"] as? String
            }
        } catch { return nil }
        return nil
    }

    // 确保 tag 存在（按名称查找，不存在则创建），返回 tag id
    func ensureTag(name: String, settings: UserSettings) async -> String? {
        guard let tags = await fetchTags(settings: settings) else { return nil }
        if let existing = tags.first(where: { $0.value == name }) {
            return existing.key
        }
        return await createTag(name: name, settings: settings)
    }

    // 重命名 tag
    @discardableResult
    func renameTag(tagId: String, name: String, settings: UserSettings) async -> Bool {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return false }
        guard let url = endpoint(path: "tags/\(tagId)", settings: settings) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": name]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch { return false }
    }

    // MARK: - Todos (Top3 任务同步为 Habitica todo)

    enum TodoCreationResult {
        case created(String)
        /// The request never dispatched or was explicitly rejected before creation.
        case notCreated
        /// The server may have created the task; reconcile before any new POST.
        case uncertain
    }

    // 创建 todo，保留“确定未创建”与“结果不明”的区别。
    // MainActor: POST dispatch is part of the atomic validation→dispatch segment.
    @MainActor
    func createTodo(text: String, notes: String, tagIds: [String], settings: UserSettings) async -> TodoCreationResult {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return .notCreated }
        guard let url = endpoint(path: HabiticaConsts.pathUserTasks, settings: settings) else { return .notCreated }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "type": "todo", "notes": notes, "tags": tagIds]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 || http.statusCode == 200 else { return .uncertain }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any],
               let id = d["id"] as? String, !id.isEmpty {
                return .created(id)
            }
        } catch RequestFailure.rateLimited {
            return .notCreated
        } catch RequestFailure.staleAccount {
            return .notCreated
        } catch is CancellationError {
            // performRequest checks cancellation before task.resume(); it never cancels a sent POST.
            return .notCreated
        } catch RequestFailure.status(let code) where code == 401 || code == 429 {
            return .notCreated
        } catch {
            return .uncertain
        }
        return .uncertain
    }

    // 更新 todo（标题 / tags）
    // MainActor: PUT dispatch is part of the atomic validation→dispatch segment.
    @MainActor
    func updateTodo(taskId: String, text: String?, tagIds: [String]?, notes: String? = nil, settings: UserSettings) async -> Bool {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return false }
        guard let url = endpoint(path: "tasks/\(taskId)", settings: settings) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let text = text { body["text"] = text }
        if let tagIds = tagIds { body["tags"] = tagIds }
        if let notes = notes { body["notes"] = notes }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch { return false }
    }

    // 完成 / 取消完成 todo
    // MainActor: score dispatch is part of the atomic validation→dispatch segment.
    @MainActor
    func scoreTodo(taskId: String, completed: Bool, settings: UserSettings) async -> Bool {
        let direction = completed ? "up" : "down"
        let result = await scoreHabit(taskId: taskId, direction: direction, settings: settings)
        return result != nil
    }

    // 删除 todo
    // MainActor: DELETE dispatch is part of the atomic validation→dispatch segment.
    @MainActor
    func deleteTodo(taskId: String, settings: UserSettings) async -> Bool {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return false }
        guard let url = endpoint(path: "tasks/\(taskId)", settings: settings) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (_, response, _) = try await perform(req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200 || http.statusCode == 404
        } catch { return false }
    }

    struct CloudTodo {
        var id: String
        var title: String
        var notes: String
        var completed: Bool
        var tags: [String]
    }

    func fetchTopThreeTodos(settings: UserSettings) async -> [CloudTodo]? {
        guard settings.connectHabitica, !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let generation = await connectionGeneration(settings: settings) else { return nil }
        var result: [CloudTodo] = []
        for kind in ["todos", "completedTodos"] {
            guard let url = endpoint(path: "tasks/user?type=\(kind)", settings: settings) else { return nil }
            var request = URLRequest(url: url)
            request.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
            request.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
            request.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
            do {
                let (data, _, context) = try await perform(request, accountGeneration: generation)
                let decoded: Any
                do { decoded = try JSONSerialization.jsonObject(with: data) }
                catch {
                    reportError("Habitica todo 响应格式错误", settings: settings, context: context)
                    return nil
                }
                guard let json = decoded as? [String: Any],
                      let entries = json["data"] as? [[String: Any]] else { reportError("Habitica todo 响应格式错误", settings: settings, context: context); return nil }
                result += entries.compactMap { item in
                    guard let id = item["id"] as? String, let title = item["text"] as? String else { return nil }
                    return CloudTodo(id: id, title: title, notes: item["notes"] as? String ?? "",
                                     completed: item["completed"] as? Bool ?? false, tags: item["tags"] as? [String] ?? [])
                }
            } catch { return nil }
        }
        let todos = result
        return await MainActor.run {
            generation == SettingsManager.shared.habiticaAccountGeneration && self.matchesCurrentAccount(settings) ? todos : nil
        }
    }

    // MARK: - Task Lists (habits / dailies)

    // 获取指定类型的任务列表
    func fetchTasks(type: String, settings: UserSettings) async -> [HabiticaTaskItem] {
        await fetchTaskList(type: type, settings: settings) ?? []
    }

    /// A failed request is distinct from a valid empty list, so views can retain their last data.
    func fetchTaskList(type: String, settings: UserSettings) async -> [HabiticaTaskItem]? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: "tasks/user?type=\(type)", settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, context) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded: Any
            do { decoded = try JSONSerialization.jsonObject(with: data) }
            catch {
                reportError("Habitica 任务列表响应格式错误，已保留上次加载的数据。", settings: settings, context: context)
                return nil
            }
            guard let json = decoded as? [String: Any], let arr = json["data"] as? [[String: Any]] else {
                reportError("Habitica 任务列表响应格式错误，已保留上次加载的数据。", settings: settings, context: context)
                return nil
            }
            var items: [HabiticaTaskItem] = []
            var ids = Set<String>()
            for t in arr {
                guard let id = t["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                      let text = t["text"] as? String else {
                    reportError("Habitica 任务列表响应格式错误，已保留上次加载的数据。", settings: settings, context: context)
                    return nil
                }
                let notes = t["notes"] as? String ?? ""
                let value = t["value"] as? Double ?? 0
                var completed = false
                var isDue = true
                if type == "dailys" {
                    completed = t["completed"] as? Bool ?? false
                    isDue = t["isDue"] as? Bool ?? true
                }
                var canUp = true, canDown = true
                if let up = t["up"] as? Bool { canUp = up }
                if let down = t["down"] as? Bool { canDown = down }
                items.append(HabiticaTaskItem(id: id, text: text, notes: notes, value: value,
                                             completed: completed, canUp: canUp, canDown: canDown, isDue: isDue))
            }
            let parsed = items
            return await MainActor.run { self.isCurrent(context) ? parsed : nil }
        } catch {
            return nil
        }
    }

    // 打分（up/down），返回最新 stats
    func scoreTask(taskId: String, direction: String, settings: UserSettings) async -> [String: Double]? {
        return await scoreHabit(taskId: taskId, direction: direction, settings: settings)
    }

    // MARK: - User Profile (账号信息)

    // 获取完整账号信息
    func fetchProfile(settings: UserSettings) async -> HabiticaProfile? {
        guard settings.connectHabitica,
              !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return nil }
        guard let url = endpoint(path: HabiticaConsts.pathUser + "?userFields=auth,stats,achievements", settings: settings) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HabiticaConsts.xClientHeader, forHTTPHeaderField: "x-client")
        req.setValue(settings.uid, forHTTPHeaderField: "x-api-user")
        req.setValue(settings.apiToken, forHTTPHeaderField: "x-api-key")
        do {
            let (data, response, context) = try await perform(req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = json["data"] as? [String: Any] else { return nil }
            let parsed = parseProfile(d)
            return await MainActor.run { self.isCurrent(context) ? parsed : nil }
        } catch { return nil }
    }

    private func parseProfile(_ d: [String: Any]) -> HabiticaProfile {
        var p = HabiticaProfile()
        if let auth = d["auth"] as? [String: Any] {
            if let local = auth["local"] as? [String: Any] {
                p.username = (local["username"] as? String) ?? ""
            }
            // timestamps 在 auth 层级，ISO8601 字符串格式
            if let timestamps = auth["timestamps"] as? [String: Any] {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let f2 = ISO8601DateFormatter()
                if let created = timestamps["created"] as? String {
                    p.joinedAt = f.date(from: created) ?? f2.date(from: created)
                }
                if let login = timestamps["loggedin"] as? String {
                    p.lastLoginAt = f.date(from: login) ?? f2.date(from: login)
                }
            }
        }
        if let stats = d["stats"] as? [String: Any] {
            p.className = (stats["class"] as? String) ?? ""
            p.level = Int(stats["lvl"] as? Double ?? 0)
            p.exp = stats["exp"] as? Double ?? 0
            p.hp = stats["hp"] as? Double ?? 0
            p.mp = stats["mp"] as? Double ?? 0
            p.gp = stats["gp"] as? Double ?? 0
            p.str = Int(stats["str"] as? Double ?? 0)
            p.con = Int(stats["con"] as? Double ?? 0)
            p.int = Int(stats["int"] as? Double ?? 0)
            p.per = Int(stats["per"] as? Double ?? 0)
            p.toNextLevel = stats["toNextLevel"] as? Double ?? 0
            p.maxHealth = 50 // Habitica HP 上限固定 50
            // MP 上限公式: 30 + 3*(lvl-1) + int/2
            let lvl = Double(p.level)
            p.maxMP = 30 + 3 * max(0, lvl - 1) + Double(p.int) / 2
        }
        if let achievements = d["achievements"] as? [String: Any] {
            p.streak = Int(achievements["streak"] as? Double ?? 0)
            p.perfectDays = Int(achievements["perfectCount"] as? Double ?? 0)
            p.questsTotal = 0
            if let quests = achievements["quests"] as? [String: Any] {
                p.questsTotal = quests.values.reduce(0) { $0 + Int($1 as? Double ?? 0) }
            }
        }
        return p
    }
}

// MARK: - Habitica Profile (账号信息)
struct HabiticaProfile {
    var username: String = ""
    var authId: String = ""
    var className: String = ""
    var level: Int = 0
    var exp: Double = 0
    var toNextLevel: Double = 0
    var hp: Double = 0
    var maxHealth: Double = 50
    var mp: Double = 0
    var maxMP: Double = 0
    var gp: Double = 0
    var str: Int = 0
    var con: Int = 0
    var int: Int = 0
    var per: Int = 0
    var streak: Int = 0
    var perfectDays: Int = 0
    var questsTotal: Int = 0
    var joinedAt: Date? = nil
    var lastLoginAt: Date? = nil
}
