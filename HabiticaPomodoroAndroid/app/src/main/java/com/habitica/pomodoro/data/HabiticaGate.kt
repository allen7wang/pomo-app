package com.habitica.pomodoro.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** A raw HTTP reply from a transport (OkHttp in the app, the scripted substitute in fixtures). */
class HabiticaReply(
    val status: Int,
    val body: String = "",
    headers: Map<String, String> = emptyMap(),
    /** Fixture transport only: an already-typed result to hand back unchanged. */
    val payload: Any? = null,
) {
    private val headers = headers.mapKeys { it.key.lowercase(Locale.ROOT) }
    fun header(name: String): String? = headers[name.lowercase(Locale.ROOT)]
}

/**
 * Dispatch policy shared by every Habitica feature, kept outside HabiticaAPI.kt so the offline fixtures
 * run the same code: connection epochs (v2.1.4), the per-account request budget (v2.1.2) and
 * coalescing of identical in-flight reads.
 */
object HabiticaGate {
    sealed class Exchange {
        /** Never dispatched (retired connection or budget/cooldown): the server saw nothing. */
        data class NotSent(val message: String, val rateLimited: Boolean = false) : Exchange()
        /** A read answered for a connection that has since been retired; its data must not be adopted. */
        data object Retired : Exchange()
        /** Dispatched but no usable reply (timeout, dropped connection): the outcome is unknown. */
        data class Lost(val message: String) : Exchange()
        data class Replied(val reply: HabiticaReply) : Exchange()
    }

    const val STALE_CONNECTION = "账号或连接已变化，旧请求未采用"
    const val NETWORK_FAILED = "网络连接失败，请检查网络或服务器"
    const val AUTH_FAILED = "Habitica 认证失败，请检查 User ID / API Token"
    const val TASK_LIST_MALFORMED = "Habitica 任务列表响应格式错误，已保留上次加载的数据。"

    private data class Connection(val connect: Boolean, val uid: String, val token: String, val root: String)
    private data class ReadKey(val path: String, val connection: Connection, val epoch: Long, val readGeneration: Long)

    private val lock = Any()
    private var current: Connection? = null
    private var epoch = 0L
    private var readGeneration = 0L
    private val reads = HashMap<ReadKey, CompletableDeferred<Exchange>>()

    private fun connectionOf(settings: UserSettings) = Connection(settings.connectHabitica, settings.uid, settings.apiToken,
        // Equivalent spellings of one API root are the same connection; an invalid root never matches a valid one.
        runCatching { HabiticaAPI.apiRoot(settings) }.getOrElse { "\u0000" + settings.developerServerUrl })

    /** UID, token, connect toggle and effective API root; ordinary preferences are not part of a connection. */
    fun sameConnection(a: UserSettings, b: UserSettings): Boolean = connectionOf(a) == connectionOf(b)

    /** Called by the engine whenever settings are applied. A different connection starts a new epoch. */
    fun activate(settings: UserSettings): Long = synchronized(lock) {
        val next = connectionOf(settings)
        if (next != current) {
            current = next
            epoch++
        }
        epoch
    }

    /** The current epoch when [settings] is the active connection, else null (a retired request). */
    fun epochOf(settings: UserSettings): Long? = synchronized(lock) {
        if (current != null && connectionOf(settings) == current) epoch else null
    }

    /**
     * Admit and send one request. Reads with the same path/credentials/epoch share a single dispatch unless a
     * write was admitted in between, so verification after a write never joins an older read. Writes return
     * their real outcome even if the connection changes while they are in flight.
     */
    suspend fun exchange(
        settings: UserSettings,
        method: String,
        path: String,
        expectedEpoch: Long? = null,
        transport: suspend () -> HabiticaReply,
    ): Exchange {
        val startEpoch = epochOf(settings)?.takeIf { expectedEpoch == null || it == expectedEpoch }
            ?: return Exchange.NotSent(STALE_CONNECTION)
        if (method != "GET") return dispatch(settings, method, startEpoch, transport)
        val key = ReadKey(path, connectionOf(settings), startEpoch, synchronized(lock) { readGeneration })
        var shared: CompletableDeferred<Exchange>? = null
        val leader = synchronized(lock) {
            shared = reads[key]
            if (shared == null) CompletableDeferred<Exchange>().also { reads[key] = it } else null
        }
        val result = if (leader == null) shared!!.await() else try {
            // The leader finishes even if its caller is cancelled, so joined callers always get the reply.
            withContext(NonCancellable) { dispatch(settings, method, startEpoch, transport).also { leader.complete(it) } }
        } finally {
            if (!leader.isCompleted) leader.complete(Exchange.Lost(NETWORK_FAILED))
            synchronized(lock) { if (reads[key] === leader) reads.remove(key) }
        }
        return if (epochOf(settings) == startEpoch) result else Exchange.Retired
    }

    private suspend fun dispatch(settings: UserSettings, method: String, startEpoch: Long, transport: suspend () -> HabiticaReply): Exchange {
        val account = settings.cloudAccount() ?: return Exchange.NotSent(STALE_CONNECTION)
        synchronized(lock) {
            if (current != connectionOf(settings) || epoch != startEpoch) return Exchange.NotSent(STALE_CONNECTION)
            if (HabiticaRequestBudgets.reserve(account) > 0) {
                return Exchange.NotSent(HabiticaRequestBudgets.rateLimitMessage(account) ?: "Habitica 请求额度暂时用完，请稍后重试。", rateLimited = true)
            }
            if (method != "GET") readGeneration++
        }
        return try {
            val reply = transport()
            // Server limits belong to the original UID/root, including a connection retired meanwhile.
            if (reply.status > 0) HabiticaRequestBudgets.observe(account, reply.status, reply::header)
            Exchange.Replied(reply)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Exchange.Lost(NETWORK_FAILED)
        } finally {
            if (method != "GET") synchronized(lock) { readGeneration++ }
        }
    }

    /** Fixtures only: drop the active connection and in-flight reads. Epochs stay monotonic. */
    fun reset() = synchronized(lock) {
        current = null
        reads.clear()
    }
}

/** User-facing message for a non-2xx reply; 429 carries the wait from the account's budget. */
fun habiticaHttpError(status: Int, account: String?): String = when (status) {
    429 -> HabiticaRequestBudgets.rateLimitMessage(account) ?: "Habitica 暂时限流（HTTP 429），请稍后重试。"
    401 -> HabiticaGate.AUTH_FAILED
    else -> "Habitica 请求失败 (HTTP $status)"
}

/** Map an exchange to the API result type; [parse] only sees 2xx replies. */
fun <T> HabiticaGate.Exchange.toResult(account: String?, parse: (HabiticaReply) -> HabiticaAPI.Result<T>): HabiticaAPI.Result<T> = when (this) {
    is HabiticaGate.Exchange.NotSent -> HabiticaAPI.Result.Error(message, dispatched = false)
    HabiticaGate.Exchange.Retired -> HabiticaAPI.Result.Error(HabiticaGate.STALE_CONNECTION)
    is HabiticaGate.Exchange.Lost -> HabiticaAPI.Result.Error(message)
    is HabiticaGate.Exchange.Replied ->
        if (reply.status in 200..299) parse(reply) else HabiticaAPI.Result.Error(habiticaHttpError(reply.status, account), reply.status)
}

/** A create that certainly produced nothing remotely: never sent, or explicitly refused (401/429). */
fun HabiticaAPI.Result.Error.definitelyNotCreated(): Boolean = !dispatched || statusCode == 401 || statusCode == 429

/**
 * Strict Habits/Dailies parsing (v2.1.3): a malformed envelope, an entry without id/text or a duplicate id
 * fails the whole list, so the caller keeps the list it already shows. A valid empty array is a success.
 */
fun parseHabiticaTaskList(type: String, body: String): List<HabiticaTaskItem>? {
    val array = runCatching { JSONObject(body).get("data") as? JSONArray }.getOrNull() ?: return null
    val ids = HashSet<String>()
    val dailies = type == "dailys"
    return (0 until array.length()).map { index ->
        val obj = array.opt(index) as? JSONObject ?: return null
        val id = (obj.opt("id") as? String)?.takeIf { it.isNotEmpty() }
            ?: (obj.opt("_id") as? String)?.takeIf { it.isNotEmpty() } ?: return null
        val text = obj.opt("text") as? String ?: return null
        if (!ids.add(id)) return null
        HabiticaTaskItem(
            id = id,
            text = text,
            notes = obj.opt("notes") as? String ?: "",
            value = (obj.opt("value") as? Number)?.toDouble() ?: 0.0,
            completed = dailies && obj.opt("completed") == true,
            canUp = obj.opt("up") as? Boolean ?: true,
            canDown = obj.opt("down") as? Boolean ?: true,
            isDue = !dailies || obj.opt("isDue") as? Boolean ?: true,
        )
    }
}

/**
 * Ordering for one feedback channel (Apple's lastError rules, v2.1.4): an error is shown only if no request
 * dispatched later has already reported one, and a success may clear only an error published before that
 * request was dispatched. Sequence numbers come from the caller's dispatch counter.
 */
class HabiticaFeedbackOrder {
    private var latestError = 0L
    var revision = 0L
        private set

    fun acceptError(sequence: Long): Boolean {
        if (sequence < latestError) return false
        latestError = sequence
        revision++
        return true
    }

    /** Unordered publication (state-derived errors) still prevents older successes from clearing it. */
    fun noteError() { revision++ }

    fun mayClear(revisionAtDispatch: Long): Boolean = revisionAtDispatch == revision

    fun reset() {
        latestError = 0
        revision++
    }
}
