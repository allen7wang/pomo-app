package com.habitica.pomodoro.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Habitica REST API 客户端 —— 端点、x-client header、解析规则与 Swift 端逐条对齐。
 *
 * 关键约定（踩坑记录，来自 Swift 端）：
 * - Dailies 的类型参数必须是 `type=dailys`（不是 dailies），
 *   否则报 `Task type must be one of "habits", "dailys", "todos", "rewards", "completedTodos".`
 * - 注册时间在 `auth.timestamps`，不是 `auth.local.timestamps`
 * - API 不返回 maxMP / maxHealth / toNextLevel，需用公式计算（见 HabiticaProfile）
 */
object HabiticaAPI {

    private const val SERVER_URL = "https://habitica.com/api/v3/"
    // 与 Swift HabiticaConsts.xClientHeader 使用同一开发者 User ID，后缀区分平台，便于 Habitica 侧识别本应用
    private const val X_CLIENT = "a0badcb0-f6b8-40d7-bb79-26b797a01d8e-Pomo-Android"

    private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /** API 调用结果：成功返回 data 里的 JSON，失败返回错误描述 */
    sealed class Result<out T> {
        data class Success<T>(val value: T) : Result<T>()
        /** [dispatched] = false: the request never left the device (not connected, retired connection, budget). */
        data class Error(val message: String, val statusCode: Int? = null, val dispatched: Boolean = true) : Result<Nothing>()
    }

    private const val NOT_CONNECTED = "未连接 Habitica：请先在设置中填写 User ID 与 API Token"
    private const val INVALID_ADDRESS = "API 地址或任务 ID 无效；仅支持不含账号、查询参数的 HTTPS 地址"

    private fun Request.Builder.withAuth(settings: UserSettings): Request.Builder = apply {
        header("x-client", X_CLIENT)
        header("x-api-user", settings.uid)
        header("x-api-key", settings.apiToken)
    }

    private fun canCall(settings: UserSettings): Boolean =
        settings.connectHabitica && isValidHabiticaUid(settings.uid) && settings.apiToken.isNotBlank()

    // MARK: - 通用请求

    private fun buildRequest(settings: UserSettings, path: String, method: String, body: JSONObject?): Request {
        val builder = Request.Builder().url(baseUrl(settings) + path).withAuth(settings)
        when (method) {
            "GET" -> builder.get()
            "DELETE" -> builder.delete()
            else -> builder.method(method, (body?.toString() ?: "{}").toRequestBody(JSON_MEDIA))
        }
        return builder.build()
    }

    /** The only network call site; the gate decides whether it may run (connection epoch, shared budget). */
    private suspend fun execute(request: Request): HabiticaReply = withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { resp ->
            HabiticaReply(resp.code, resp.body?.string().orEmpty(), resp.headers.names().associateWith { resp.headers[it].orEmpty() })
        }
    }

    /** Raw exchange through [HabiticaGate]; `epoch` pins multi-request operations to one connection. */
    private suspend fun send(
        settings: UserSettings,
        path: String,
        method: String = "GET",
        body: JSONObject? = null,
        epoch: Long? = null,
    ): Pair<HabiticaGate.Exchange, String?>? {
        if (!canCall(settings)) return null
        val request = try { buildRequest(settings, path, method, body) } catch (e: IllegalArgumentException) {
            return HabiticaGate.Exchange.NotSent(INVALID_ADDRESS) to null
        }
        return HabiticaGate.exchange(settings, method, path, epoch) { execute(request) } to settings.cloudAccount()
    }

    private suspend fun request(
        settings: UserSettings,
        path: String,
        method: String = "GET",
        body: JSONObject? = null,
        epoch: Long? = null,
    ): Result<JSONObject?> {
        val (exchange, account) = send(settings, path, method, body, epoch) ?: return Result.Error(NOT_CONNECTED, dispatched = false)
        return exchange.toResult(account) { reply ->
            if (method == "DELETE" && reply.body.isBlank()) return@toResult Result.Success(null)
            val json = runCatching { JSONObject(reply.body) }.getOrNull() ?: return@toResult Result.Error("API 返回格式无效")
            if (json.optBoolean("success", true) == false) Result.Error("API 未确认请求成功") else Result.Success(json.optJSONObject("data"))
        }
    }

    // MARK: - 角色信息（Role 页）

    /** 获取账号角色信息：等级、HP/MP/EXP/GP、四维属性、成就 */
    suspend fun fetchProfile(settings: UserSettings): Result<HabiticaProfile> {
        val result = request(settings, "user")
        return when (result) {
            is Result.Error -> result
            is Result.Success -> {
                val d = result.value
                    ?: return Result.Error("返回数据为空")
                Result.Success(parseProfile(d))
            }
        }
    }

    private fun parseProfile(d: JSONObject): HabiticaProfile {
        var username = ""
        var registeredAt = ""
        var lastLoginAt = ""
        d.optJSONObject("auth")?.let { auth ->
            auth.optJSONObject("local")?.let { local ->
                username = local.optString("username", "")
            }
            // 注册时间在 auth.timestamps（不是 auth.local.timestamps）
            auth.optJSONObject("timestamps")?.let { ts ->
                fun date(key: String): String = runCatching {
                    java.time.Instant.parse(ts.optString(key)).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString()
                }.getOrDefault("")
                registeredAt = date("created")
                lastLoginAt = date("loggedin")
            }
        }

        val stats = d.optJSONObject("stats") ?: JSONObject()
        val achievements = d.optJSONObject("achievements") ?: JSONObject()

        var questsTotal = 0
        achievements.optJSONObject("quests")?.let { q ->
            q.keys().forEach { k -> questsTotal += q.optInt(k, 0) }
        }

        return HabiticaProfile(
            username = username,
            className = stats.optString("class", ""),
            level = stats.optInt("lvl", 0),
            exp = stats.optDouble("exp", 0.0),
            hp = stats.optDouble("hp", 0.0),
            mp = stats.optDouble("mp", 0.0),
            gp = stats.optDouble("gp", 0.0),
            str = stats.optInt("str", 0),
            con = stats.optInt("con", 0),
            int = stats.optInt("int", 0),
            per = stats.optInt("per", 0),
            streak = achievements.optInt("streak", 0),
            perfectDays = achievements.optInt("perfectCount", 0),
            questsTotal = questsTotal,
            registeredAt = registeredAt,
            lastLoginAt = lastLoginAt,
        )
    }

    // MARK: - 任务列表（Habits / Dailies）

    /** data 为数组的接口专用（tasks/user?type=todos、tags）；单个条目格式不对时跳过 */
    private suspend fun requestArray(
        settings: UserSettings,
        path: String,
        epoch: Long? = null,
    ): Result<List<JSONObject>> {
        val (exchange, account) = send(settings, path, epoch = epoch) ?: return Result.Error(NOT_CONNECTED, dispatched = false)
        return exchange.toResult(account) { reply ->
            val arr = runCatching { JSONObject(reply.body).optJSONArray("data") }.getOrNull()
                ?: return@toResult Result.Error("Habitica 返回的任务列表格式无效")
            Result.Success((0 until arr.length()).mapNotNull { arr.optJSONObject(it) })
        }
    }

    /** Habits/Dailies: malformed lists are failures, never an empty or partial success (see parseHabiticaTaskList). */
    suspend fun fetchTaskItems(settings: UserSettings, type: String): Result<List<HabiticaTaskItem>> {
        val (exchange, account) = send(settings, "tasks/user?type=$type") ?: return Result.Error(NOT_CONNECTED, dispatched = false)
        return exchange.toResult(account) { reply ->
            parseHabiticaTaskList(type, reply.body)?.let { Result.Success(it) } ?: Result.Error(HabiticaGate.TASK_LIST_MALFORMED)
        }
    }

    /** 打分（up / down），返回最新 stats（金币/经验/血量），用于刷新 Role 数据 */
    suspend fun scoreTask(
        settings: UserSettings,
        taskId: String,
        direction: String,
    ): Result<JSONObject?> {
        if (!validTaskId(taskId)) return Result.Error("任务 ID 无效")
        return request(settings, "tasks/${safeTaskId(taskId)}/score/$direction", method = "POST")
    }

    // MARK: - Todos（Task 页任务同步为 Habitica todo）

    /** Fetch both active todos and the completedTodos endpoint before merging. */
    suspend fun fetchTopThreeTodos(settings: UserSettings): Result<List<CloudTodo>> {
        if (!canCall(settings)) return Result.Error(NOT_CONNECTED, dispatched = false)
        // Both reads belong to one connection; the second is never sent after a switch.
        val epoch = HabiticaGate.epochOf(settings) ?: return Result.Error(HabiticaGate.STALE_CONNECTION, dispatched = false)
        val active = requestArray(settings, "tasks/user?type=todos", epoch)
        if (active is Result.Error) return active
        val completed = requestArray(settings, "tasks/user?type=completedTodos", epoch)
        if (completed is Result.Error) return completed
        val objects = (active as Result.Success).value + (completed as Result.Success).value
        return Result.Success(objects.mapNotNull { obj ->
            val id = obj.optString("_id", obj.optString("id", ""))
            if (id.isBlank() || obj.optString("type", "todo") != "todo") null else CloudTodo(
                id = id,
                title = obj.optString("text", ""),
                notes = obj.optString("notes", ""),
                completed = obj.optBoolean("completed", false),
                tags = obj.optJSONArray("tags")?.let { arr ->
                    (0 until arr.length()).mapNotNull { i -> arr.optString(i).takeIf(String::isNotBlank) }
                } ?: emptyList(),
            )
        })
    }

    /** 创建 todo，返回 task id */
    suspend fun createTodo(
        settings: UserSettings,
        text: String,
        notes: String,
        tagIds: List<String>,
    ): Result<String?> {
        val body = JSONObject().apply {
            put("type", "todo")
            put("text", text)
            put("notes", notes)
            if (tagIds.isNotEmpty()) put("tags", org.json.JSONArray(tagIds))
        }
        return when (val result = request(settings, "tasks/user", method = "POST", body = body)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(result.value?.optString("_id", null))
        }
    }

    /** 更新 todo 文本/备注/标签 */
    suspend fun updateTodo(
        settings: UserSettings,
        taskId: String,
        text: String,
        notes: String = "",
        tagIds: List<String>? = null,
    ): Result<Boolean> {
        if (!validTaskId(taskId)) return Result.Error("任务 ID 无效")
        val body = JSONObject().apply {
            put("text", text)
            if (notes.isNotEmpty()) put("notes", notes)
            tagIds?.let { put("tags", org.json.JSONArray(it)) }
        }
        return when (val result = request(settings, "tasks/${safeTaskId(taskId)}", method = "PUT", body = body)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(true)
        }
    }

    /** 删除 todo */
    suspend fun deleteTodo(settings: UserSettings, taskId: String): Result<Boolean> {
        if (!validTaskId(taskId)) return Result.Error("任务 ID 无效")
        return when (val result = request(settings, "tasks/${safeTaskId(taskId)}", method = "DELETE")) {
            is Result.Error -> result
            is Result.Success -> Result.Success(true)
        }
    }

    // MARK: - Tags（分类名同步为 Habitica tag）

    /** 获取全部 tag：name -> id */
    suspend fun fetchTags(settings: UserSettings, epoch: Long? = null): Result<Map<String, String>> {
        return when (val result = requestArray(settings, "tags", epoch)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(result.value.associate { obj ->
                obj.optString("name", "") to obj.optString("id", "")
            }.filterKeys { it.isNotEmpty() })
        }
    }

    /** 创建 tag，返回 tag id */
    suspend fun createTag(settings: UserSettings, name: String, epoch: Long? = null): Result<String?> {
        val body = JSONObject().apply { put("name", name) }
        return when (val result = request(settings, "tags", method = "POST", body = body, epoch = epoch)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(result.value?.optString("id", null))
        }
    }

    /** 重命名 tag（分类名修改时同步） */
    suspend fun updateTag(settings: UserSettings, tagId: String, name: String): Result<Boolean> {
        if (!validTaskId(tagId)) return Result.Error("分类 tag ID 无效")
        val body = JSONObject().apply { put("name", name) }
        return when (val result = request(settings, "tags/${safeTaskId(tagId)}", method = "PUT", body = body)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(true)
        }
    }

    /**
     * 确保分类对应的 tag 存在，返回 tag id。
     * 先查已有 tag（按名字精确匹配），没有则创建 —— 与 Swift 端 ensureTag 行为一致，
     * 避免重复创建同名 tag。
     */
    suspend fun ensureTag(settings: UserSettings, name: String): Result<String?> {
        if (!canCall(settings)) return Result.Error("未连接 Habitica", dispatched = false)
        val epoch = HabiticaGate.epochOf(settings) ?: return Result.Error(HabiticaGate.STALE_CONNECTION, dispatched = false)
        return when (val tags = fetchTags(settings, epoch)) {
            is Result.Error -> tags
            is Result.Success -> {
                val existing = tags.value[name]
                if (existing != null) Result.Success(existing)
                else createTag(settings, name, epoch)
            }
        }
    }


    fun validServerUrl(value: String): Boolean = value.isBlank() || runCatching { checkedUrl(value); true }.getOrDefault(false)
    private fun checkedUrl(value: String): String {
        val url = value.trim().toHttpUrlOrNull() ?: throw IllegalArgumentException()
        require(url.scheme == "https" && url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null)
        return url.toString().trimEnd('/') + "/"
    }
    fun apiRoot(settings: UserSettings): String = if (settings.developerServerUrl.isBlank()) SERVER_URL else checkedUrl(settings.developerServerUrl)
    private fun baseUrl(settings: UserSettings): String = apiRoot(settings)
    private fun validTaskId(value: String) = Regex("[A-Za-z0-9_-]+").matches(value)
    private fun safeTaskId(value: String): String { require(validTaskId(value)); return value }

    suspend fun ensureHabit(settings: UserSettings, combo: Boolean): Result<String> {
        val custom = if (combo) settings.customSetTask else settings.customPomodoroTask
        val configured = if (combo) settings.pomodoroSetTaskId else settings.pomodoroTaskId
        if (custom) {
            if (configured.isNullOrBlank() || !Regex("[A-Za-z0-9_-]+").matches(configured)) return Result.Error("请填写有效的自定义 Habit ID")
            return when (val fetched = request(settings, "tasks/$configured")) {
                is Result.Error -> fetched
                is Result.Success -> if (fetched.value?.optString("type") == "habit") Result.Success(configured) else Result.Error("自定义任务必须是 Habit")
            }
        }
        val alias = if (combo) "sitepassPomodoroSet" else "sitepassPomodoro"
        // The lookup and a possible create must use the same connection.
        val epoch = HabiticaGate.epochOf(settings) ?: return Result.Error(HabiticaGate.STALE_CONNECTION, dispatched = false)
        when (val found = request(settings, "tasks/$alias", epoch = epoch)) {
            is Result.Success -> return found.value?.optString("_id", found.value.optString("id"))?.takeIf { it.isNotBlank() }?.let { Result.Success(it) } ?: Result.Error("默认 Habit 返回格式无效")
            is Result.Error -> if (found.statusCode != 404) return found // Never create on timeout/auth/server failure.
        }
        val body = JSONObject().apply {
            put("type", "habit"); put("text", if (combo) "Pomodoro Combo!" else "Pomodoro"); put("alias", alias)
            put("notes", "Habit utilized by Habitica SiteKeeper. Change the difficulty manually according to your needs.")
            put("priority", if (combo) 1.5 else 1.0); put("up", true); put("down", true)
        }
        return when (val created = request(settings, "tasks/user", "POST", body, epoch)) {
            is Result.Error -> created
            is Result.Success -> created.value?.optString("_id", created.value.optString("id"))?.takeIf { it.isNotBlank() }?.let { Result.Success(it) } ?: Result.Error("默认 Habit 创建结果无效")
        }
    }

    suspend fun sendPrivateMessage(settings: UserSettings, message: String): Result<JSONObject?> =
        if (!validTaskId(settings.uid)) Result.Error("User ID 无效") else request(settings, "members/send-private-message", "POST", JSONObject().apply { put("message", message); put("toUserId", settings.uid) })

    suspend fun fetchTodo(settings: UserSettings, id: String): Result<CloudTodo> = if (!validTaskId(id)) Result.Error("任务 ID 无效") else when (val r = request(settings, "tasks/${safeTaskId(id)}")) {
        is Result.Error -> r
        is Result.Success -> r.value?.let { obj -> Result.Success(CloudTodo(id, obj.optString("text"), obj.optString("notes"), obj.optBoolean("completed"),
            obj.optJSONArray("tags")?.let { arr -> (0 until arr.length()).map { arr.optString(it) } } ?: emptyList())) } ?: Result.Error("任务返回格式无效")
    }

    // MARK: - 连通性自检

    /** 验证 uid/token 是否有效（Role 页与设置页用） */
    suspend fun verifyCredentials(settings: UserSettings): Result<String> {
        return when (val result = fetchProfile(settings)) {
            is Result.Error -> result
            is Result.Success -> Result.Success(result.value.username.ifEmpty { "已连接" })
        }
    }
}
