// Harness stub: com.habitica.pomodoro.data.HabiticaAPI — an in-memory SUBSTITUTE
// for the real OkHttp client. HTTP 0 by construction: there is no networking
// code in this file at all. Every call is answered from scriptable state, so
// cases control the cloud world deterministically.
//
// The public surface mirrors the production object exactly (same method names,
// parameter shapes and Result types) so the production ViewModel/Models compile
// against it unmodified. apiRoot/validServerUrl mirror production semantics
// (canonical HTTPS root, no user-info/query/fragment; lower-case host, no :443)
// with java.net.URI instead of okhttp; the default official root is byte-identical.
//
// Like production, every call is routed through the REAL HabiticaGate (connection
// epochs, per-account HabiticaRequestBudgets, read coalescing). The scripted
// world is the "transport": `calls` records only requests the gate actually
// dispatched, so budget/cooldown/stale-connection rejections never appear there.
package com.habitica.pomodoro.data

import kotlinx.coroutines.CompletableDeferred
import org.json.JSONObject
import java.util.UUID

object HabiticaAPI {

    sealed class Result<out T> {
        data class Success<T>(val value: T) : Result<T>()
        data class Error(val message: String, val statusCode: Int? = null, val dispatched: Boolean = true) : Result<Nothing>()
    }

    private const val SERVER_URL = "https://habitica.com/api/v3/"
    private const val NOT_CONNECTED = "未连接 Habitica：请先在设置中填写 User ID 与 API Token"

    /** A scripted HTTP reply for one dispatched call. `body == null` on 2xx keeps the typed default answer. */
    data class StubReply(val status: Int = 200, val headers: Map<String, String> = emptyMap(),
                         val body: String? = null, val lost: Boolean = false)

    // ---- scriptable cloud world ----
    /** Todos currently visible in the cloud (fetchTopThreeTodos answers from here). */
    val cloud = mutableListOf<CloudTodo>()
    /** Tag name -> id. */
    val tags = linkedMapOf<String, String>()
    /** Dispatched-call log, e.g. "deleteTodo:RID-1". */
    val calls = mutableListOf<String>()
    /** When non-null, every fetch* answers with Error(message, fetchStatus). */
    var fetchFailure: String? = null
    var fetchStatus: Int? = null
    /** Ids whose read-back (fetchTodo) must 404 even if still present in `cloud`. */
    val fetchTodoMissing = mutableSetOf<String>()
    /** Scripted delete behaviour. Default: succeed and remove from `cloud`. */
    var deleteOutcome: (String) -> Result<Boolean> = { Result.Success(true) }
    /** When true, a successful delete also removes the todo from `cloud`. */
    var deleteRemovesFromCloud = true
    /** Scripted create behaviour: (title, notes) -> Result<remoteId?>. */
    var createOutcome: (String, String) -> Result<String?> = { _, _ -> Result.Success("RID-" + UUID.randomUUID().toString().take(8)) }
    /** When true, a successful create makes the todo visible in `cloud`. */
    var createAddsToCloud = true
    var nextTagId = 0
    /** Profile answered by fetchProfile, captured when the request is dispatched. */
    var profile = HabiticaProfile(username = "stub-user", level = 1)
    /** Raw `tasks/user?type=` bodies by type, parsed by the REAL strict parser. Default: legal empty list. */
    val taskListBodies = mutableMapOf<String, String>()
    /** HTTP-level override per dispatched call name (status, headers, raw body, transport loss). */
    var replyFor: (String) -> StubReply? = { null }
    /** Headers on unscripted replies, e.g. X-RateLimit-Remaining. */
    var defaultHeaders: Map<String, String> = emptyMap()
    /** One-shot holds: a dispatched call with this exact name waits (in flight) until completed. */
    val holds = linkedMapOf<String, CompletableDeferred<Unit>>()

    fun hold(name: String): CompletableDeferred<Unit> = CompletableDeferred<Unit>().also { holds[name] = it }

    fun reset() {
        cloud.clear(); tags.clear(); calls.clear(); fetchTodoMissing.clear()
        fetchFailure = null; fetchStatus = null
        deleteOutcome = { Result.Success(true) }; deleteRemovesFromCloud = true
        createOutcome = { _, _ -> Result.Success("RID-" + UUID.randomUUID().toString().take(8)) }
        createAddsToCloud = true
        nextTagId = 0
        profile = HabiticaProfile(username = "stub-user", level = 1)
        taskListBodies.clear(); replyFor = { null }; defaultHeaders = emptyMap(); holds.clear()
        HabiticaGate.reset()
        HabiticaRequestBudgets.reset()
    }

    private fun canCall(settings: UserSettings): Boolean =
        settings.connectHabitica && isValidHabiticaUid(settings.uid) && settings.apiToken.isNotBlank()

    private fun <T> failOr(value: () -> T): Result<T> {
        val failure = fetchFailure
        return if (failure != null) Result.Error(failure, fetchStatus) else Result.Success(value())
    }

    /** A typed answer travels as the reply payload; an Error without status models a lost transport. */
    private fun typedReply(result: Result<*>): HabiticaReply = when (result) {
        is Result.Success -> HabiticaReply(200, "", defaultHeaders, result)
        is Result.Error -> HabiticaReply(result.statusCode ?: 0, "", if (result.statusCode == null) emptyMap() else defaultHeaders, result)
    }

    /**
     * One dispatched request. [answer] runs at dispatch time (before any hold), only when no scripted reply
     * replaces it, so a scripted 401/429 never performs the cloud side effects of a success.
     */
    private suspend fun <T> send(
        settings: UserSettings, name: String, method: String, epoch: Long? = null,
        parse: (HabiticaReply) -> Result<T> = { Result.Error("stub: scripted 2xx body without a parser") },
        answer: () -> HabiticaReply,
    ): Result<T> {
        if (!canCall(settings)) return Result.Error(NOT_CONNECTED, dispatched = false)
        val exchange = HabiticaGate.exchange(settings, method, name, epoch) {
            calls += name
            val scripted = replyFor(name)
            val reply = when {
                scripted == null -> answer()
                scripted.lost -> null
                scripted.status in 200..299 && scripted.body == null ->
                    answer().let { HabiticaReply(scripted.status, it.body, scripted.headers, it.payload) }
                else -> HabiticaReply(scripted.status, scripted.body ?: "", scripted.headers)
            }
            holds.remove(name)?.await()
            reply ?: throw java.io.IOException("scripted transport loss")
        }
        val payload = (exchange as? HabiticaGate.Exchange.Replied)?.reply?.payload
        @Suppress("UNCHECKED_CAST")
        return if (payload is Result<*>) payload as Result<T> else exchange.toResult(settings.cloudAccount(), parse)
    }

    // ---- surface used by production code ----

    suspend fun fetchProfile(settings: UserSettings): Result<HabiticaProfile> =
        send(settings, "fetchProfile", "GET") { typedReply(failOr { profile }) }

    suspend fun fetchTaskItems(settings: UserSettings, type: String): Result<List<HabiticaTaskItem>> =
        send(settings, "fetchTaskItems:$type", "GET",
            parse = { reply -> parseHabiticaTaskList(type, reply.body)?.let { Result.Success(it) } ?: Result.Error(HabiticaGate.TASK_LIST_MALFORMED) }) {
            fetchFailure?.let { typedReply(Result.Error(it, fetchStatus)) }
                ?: HabiticaReply(200, taskListBodies[type] ?: "{\"data\":[]}", defaultHeaders)
        }

    suspend fun scoreTask(settings: UserSettings, taskId: String, direction: String): Result<JSONObject?> =
        send(settings, "scoreTask:$taskId:$direction", "POST") { typedReply(failOr { JSONObject() }) }

    /** Two gated reads like production (todos + completedTodos, one connection epoch). The second leg answers empty. */
    suspend fun fetchTopThreeTodos(settings: UserSettings): Result<List<CloudTodo>> {
        if (!canCall(settings)) return Result.Error(NOT_CONNECTED, dispatched = false)
        val epoch = HabiticaGate.epochOf(settings) ?: return Result.Error(HabiticaGate.STALE_CONNECTION, dispatched = false)
        val active = send<List<CloudTodo>>(settings, "fetchTopThreeTodos", "GET", epoch) { typedReply(failOr { cloud.toList() }) }
        if (active is Result.Error) return active
        val completed = send<List<CloudTodo>>(settings, "fetchCompletedTodos", "GET", epoch) { typedReply(failOr { emptyList<CloudTodo>() }) }
        if (completed is Result.Error) return completed
        return Result.Success((active as Result.Success).value + (completed as Result.Success).value)
    }

    suspend fun fetchTodo(settings: UserSettings, id: String): Result<CloudTodo> =
        send(settings, "fetchTodo:$id", "GET") {
            typedReply(fetchFailure?.let { Result.Error(it, fetchStatus) }
                ?: if (id in fetchTodoMissing) Result.Error("Habitica 请求失败 (HTTP 404)", 404)
                else cloud.firstOrNull { it.id == id }?.let { Result.Success(it) } ?: Result.Error("Habitica 请求失败 (HTTP 404)", 404))
        }

    suspend fun createTodo(settings: UserSettings, text: String, notes: String, tagIds: List<String>): Result<String?> =
        send(settings, "createTodo:$text", "POST",
            parse = { reply -> Result.Success(runCatching { JSONObject(reply.body).optJSONObject("data")?.optString("id") }.getOrNull()?.takeIf { it.isNotBlank() }) }) {
            val outcome = createOutcome(text, notes)
            if (outcome is Result.Success && createAddsToCloud) {
                outcome.value?.takeIf { it.isNotBlank() }?.let { id ->
                    if (cloud.none { it.id == id }) cloud += CloudTodo(id, text, notes, false, tagIds)
                }
            }
            typedReply(outcome)
        }

    suspend fun updateTodo(settings: UserSettings, taskId: String, text: String, notes: String = "", tagIds: List<String>? = null): Result<Boolean> =
        send(settings, "updateTodo:$taskId", "PUT") {
            fetchFailure?.let { return@send typedReply(Result.Error(it, fetchStatus)) }
            val index = cloud.indexOfFirst { it.id == taskId }
            if (index >= 0) {
                val old = cloud[index]
                cloud[index] = old.copy(title = text, notes = if (notes.isNotEmpty()) notes else old.notes,
                    tags = tagIds ?: old.tags)
            }
            typedReply(Result.Success(true))
        }

    suspend fun deleteTodo(settings: UserSettings, taskId: String): Result<Boolean> =
        send(settings, "deleteTodo:$taskId", "DELETE") {
            fetchFailure?.let { return@send typedReply(Result.Error(it, fetchStatus)) }
            val outcome = deleteOutcome(taskId)
            if (outcome is Result.Success && deleteRemovesFromCloud) {
                cloud.removeAll { it.id == taskId }
                fetchTodoMissing += taskId
            }
            typedReply(outcome)
        }

    suspend fun fetchTags(settings: UserSettings, epoch: Long? = null): Result<Map<String, String>> =
        send(settings, "fetchTags", "GET", epoch) { typedReply(failOr { tags.toMap() }) }

    suspend fun createTag(settings: UserSettings, name: String, epoch: Long? = null): Result<String?> =
        send(settings, "createTag:$name", "POST", epoch) {
            fetchFailure?.let { return@send typedReply(Result.Error(it, fetchStatus)) }
            val id = "TAG-${++nextTagId}"
            tags[name] = id
            typedReply(Result.Success(id))
        }

    suspend fun updateTag(settings: UserSettings, tagId: String, name: String): Result<Boolean> =
        send(settings, "updateTag:$tagId:$name", "PUT") {
            fetchFailure?.let { return@send typedReply(Result.Error(it, fetchStatus)) }
            val entry = tags.entries.firstOrNull { it.value == tagId }
            if (entry != null) { tags.remove(entry.key); tags[name] = tagId }
            typedReply(Result.Success(true))
        }

    suspend fun ensureTag(settings: UserSettings, name: String): Result<String?> {
        if (!canCall(settings)) return Result.Error("未连接 Habitica", dispatched = false)
        val epoch = HabiticaGate.epochOf(settings) ?: return Result.Error(HabiticaGate.STALE_CONNECTION, dispatched = false)
        val found = send<String?>(settings, "ensureTag:$name", "GET", epoch) {
            typedReply(fetchFailure?.let { Result.Error(it, fetchStatus) } ?: Result.Success(tags[name]))
        }
        if (found !is Result.Success || found.value != null) return found
        return createTag(settings, name, epoch)
    }

    suspend fun ensureHabit(settings: UserSettings, combo: Boolean): Result<String> =
        send(settings, "ensureHabit:${if (combo) "combo" else "pomo"}", "GET") {
            typedReply(failOr { if (combo) "HABIT-COMBO-STUB" else "HABIT-POMO-STUB" })
        }

    suspend fun sendPrivateMessage(settings: UserSettings, message: String): Result<JSONObject?> =
        send(settings, "sendPrivateMessage", "POST") { typedReply(failOr { JSONObject() }) }

    suspend fun verifyCredentials(settings: UserSettings): Result<String> =
        send(settings, "verifyCredentials", "GET") { typedReply(failOr { "stub-user" }) }

    // ---- non-suspend helpers (pure, mirror production semantics) ----

    fun validServerUrl(value: String): Boolean = value.isBlank() || runCatching { checkedUrl(value); true }.getOrDefault(false)

    fun apiRoot(settings: UserSettings): String =
        if (settings.developerServerUrl.isBlank()) SERVER_URL else checkedUrl(settings.developerServerUrl)

    private fun checkedUrl(value: String): String {
        val url = java.net.URI(value.trim())
        require(url.scheme.equals("https", ignoreCase = true) && url.userInfo == null && url.query == null && url.fragment == null && url.host != null)
        // OkHttp's HttpUrl lower-cases the host and drops the default port; mirror that canonical form.
        val port = if (url.port > 0 && url.port != 443) ":${url.port}" else ""
        val path = (url.path ?: "").trimEnd('/')
        return "https://${url.host.lowercase()}$port$path/"
    }
}
