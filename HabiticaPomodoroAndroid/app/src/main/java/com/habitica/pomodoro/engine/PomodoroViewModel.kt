package com.habitica.pomodoro.engine

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaProfile
import com.habitica.pomodoro.data.LocalStore
import com.habitica.pomodoro.data.BlockHistoryEntry
import com.habitica.pomodoro.data.BlockProgress
import com.habitica.pomodoro.data.BlockTask
import com.habitica.pomodoro.data.DailyBlockProgress
import com.habitica.pomodoro.data.PlantDay
import com.habitica.pomodoro.data.QishiLibrary
import com.habitica.pomodoro.data.QishiPreset
import com.habitica.pomodoro.data.HabiticaTaskItem
import com.habitica.pomodoro.data.calendarDayKey
import com.habitica.pomodoro.data.currentBlockIndex
import com.habitica.pomodoro.data.TopThreeStore
import com.habitica.pomodoro.data.mergeTopThreeTodos
import com.habitica.pomodoro.data.pendingCreateCandidates
import com.habitica.pomodoro.data.remoteIdOccupied
import com.habitica.pomodoro.data.quarantinesDeletedCreation
import com.habitica.pomodoro.data.parseTopThreeNotes
import com.habitica.pomodoro.data.topThreeNotes
import com.habitica.pomodoro.data.UserSettings
import com.habitica.pomodoro.data.normalized
import com.habitica.pomodoro.data.cloudAccount
import com.habitica.pomodoro.data.isValidHabiticaUid
import com.habitica.pomodoro.data.TimerBusinessSnapshot
import com.habitica.pomodoro.data.TaskFocusSession
import com.habitica.pomodoro.data.HabiticaFeedbackOrder
import com.habitica.pomodoro.data.HabiticaGate
import com.habitica.pomodoro.data.HabiticaRequestBudgets
import com.habitica.pomodoro.data.TOP_THREE_FIXED_SLOT_CATEGORIES
import com.habitica.pomodoro.data.TOP_THREE_MAX_FIXED_TASKS
import com.habitica.pomodoro.data.UnfinishedTask
import com.habitica.pomodoro.data.definitelyNotCreated
import com.habitica.pomodoro.data.hasRoom
import com.habitica.pomodoro.data.isTombstoned
import com.habitica.pomodoro.data.isUnfinished
import com.habitica.pomodoro.data.latestActiveCopy
import com.habitica.pomodoro.data.movingUnfinishedToToday
import com.habitica.pomodoro.data.unfinishedTasks
import com.habitica.pomodoro.service.PomodoroTimerService
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * 番茄钟引擎 —— 业务规则与 Swift 端 PomodoroEngine 对齐。
 *
 * 关键设计：用**绝对结束时刻**（phaseEndsAt）而不是递减计数器驱动 UI。
 * Android 后台会冻结协程/计时，回到前台时按真实时间重算剩余秒数
 * （与 iOS 端 resyncAfterForeground 同一思路），保证计时不会因后台被"暂停"而走慢。
 */
class PomodoroViewModel(app: Application) : AndroidViewModel(app) {

    enum class Phase { IDLE, POMODORO, BREAK, LONG_BREAK, BREAK_EXTENSION, MANUAL_BREAK }

    data class UiState(
        val phase: Phase = Phase.IDLE,
        val isRunning: Boolean = false,
        val remainingSeconds: Int = 0,
        val totalSeconds: Int = 0,
        val pomoSetCounter: Int = 0,
        val todayPomodoros: Int = 0,
        val settings: UserSettings = UserSettings(),
        val profile: HabiticaProfile? = null,
        val profileLoading: Boolean = false,
        val profileError: String? = null,
        val store: TopThreeStore = TopThreeStore(),
        val message: String? = null,
        val habiticaBusy: Boolean = false,
        val blockProgress: BlockProgress = BlockProgress(),
        val dailyBlocks: Map<String, DailyBlockProgress> = emptyMap(),
        val blockHistory: Map<String, List<BlockHistoryEntry>> = emptyMap(),
        val plants: Map<String, PlantDay> = emptyMap(),
        val pomoCounts: Map<String, Int> = emptyMap(),
        val histogram: Map<String, com.habitica.pomodoro.data.DayHistogram> = emptyMap(),
        val habits: List<HabiticaTaskItem> = emptyList(),
        val dailies: List<HabiticaTaskItem> = emptyList(),
        val tasksLoading: Boolean = false,
        val tasksError: String? = null,
        val topThreeSyncing: Boolean = false,
        val topThreeSyncError: String? = null,
        // FIX2(D2): non-null while a local store save is failing; the in-memory
        // state still advances, but the user must see that persistence failed.
        val persistenceError: String? = null,
        val scoringIds: Set<String> = emptySet(),
        /** 当前番茄激活的栖时场景（ambientSource=="qishi"）。专注开始时随机选出；
         *  暂停/回前台延续同一场景；每个环境音停止点清空。播放由前台服务的 refreshAudio 消费。 */
        val qishiScene: QishiPreset? = null,
        val taskFocus: TaskFocusSession? = null,
    )

    private val store = LocalStore(app)

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var tickJob: Job? = null
    /** 当前阶段的绝对结束时刻（epoch millis）；暂停时为 null */
    private var phaseEndsAt: Long = 0L
    /** 暂停时剩余秒数，用于恢复后重算 phaseEndsAt */
    private var pausedRemainingSeconds: Int = 0
    /** An old notification must never control a newer phase. */
    private var timerSessionId: String? = null
    private var serviceAttachAllowed = false
    private var customBreak = false
    private var completedSet = false
    private var phaseSnapshot: TimerBusinessSnapshot? = null
    private var processingDeadline = false
    private var accountGeneration = 0
    private var profileJob: Job? = null
    private var tasksJob: Job? = null
    private var tasksGeneration = 0
    private var topThreeSyncJob: Job? = null
    private var topThreeSyncGeneration = 0

    /** 场景库加载注入点：设备上由 PomoApplication 注入 assets 读取实现；fixtures 注入仓库文件读取。
     *  未注入或读取失败 → 空库（选择结果为 null，走"场景库不可用"提示）。 */
    var qishiLibraryLoader: (() -> List<QishiPreset>)? = null
    private var qishiLibraryCache: List<QishiPreset>? = null
    /** 跨番茄记忆：新番茄随机场景时避开上一个（激活场景清空后仍保留，与 Apple lastQishiSceneId 一致） */
    private var lastQishiSceneId: String? = null

    /** Same epoch and same connection (UID, token, connect toggle, effective API root). */
    private fun isCurrentAccount(settings: UserSettings, generation: Int): Boolean =
        generation == accountGeneration && HabiticaGate.sameConnection(_state.value.settings, settings)

    // v2.1.4 feedback ordering. Every Habitica call takes a dispatch sequence number; a channel shows an
    // error only if no later-dispatched request already reported one, and a success clears only errors
    // published before it was dispatched. Authentication is ordered across all features.
    private var requestSequence = 0L
    private var latestAuthSequence = 0L
    private var latestProfileSequence = 0L
    private val tasksFeedback = HabiticaFeedbackOrder()
    private val profileFeedback = HabiticaFeedbackOrder()
    private val topThreeFeedback = HabiticaFeedbackOrder()
    /** Deletion markers added while that UUID's POST was in flight; a definite rejection takes them back. */
    private val rejectableDeletionMarkers = mutableMapOf<String, Pair<String, String>>()

    private fun rateLimitMessage(settings: UserSettings): String? = HabiticaRequestBudgets.rateLimitMessage(settings.cloudAccount())

    /** All Habitica calls go through here so a current 401 from any feature revokes the shown role. */
    private suspend fun <T> habitica(
        settings: UserSettings,
        sequence: Long = ++requestSequence,
        call: suspend () -> HabiticaAPI.Result<T>,
    ): HabiticaAPI.Result<T> {
        val generation = accountGeneration
        val result = call()
        if (result is HabiticaAPI.Result.Error && result.statusCode == 401 && isCurrentAccount(settings, generation))
            noteAuthenticationFailure(sequence)
        return result
    }

    private fun noteAuthenticationFailure(sequence: Long) {
        if (sequence < latestAuthSequence) return
        latestAuthSequence = sequence
        _state.value = _state.value.copy(profile = null,
            profileError = if (profileFeedback.acceptError(sequence)) HabiticaGate.AUTH_FAILED else _state.value.profileError)
    }

    private fun publishTopThreeError(message: String) {
        topThreeFeedback.noteError()
        _state.value = _state.value.copy(topThreeSyncError = message)
    }

    private val habitMutex = kotlinx.coroutines.sync.Mutex()
    private val taskMutex = kotlinx.coroutines.sync.Mutex()
    private var creatingTasks = 0
    private var localRevision = 0
    private val creationIds = mutableSetOf<String>()

    init {
        loadAll()
    }

    // MARK: - 加载

    private fun loadAll() {
        val settings = store.loadSettings()
        HabiticaGate.activate(settings)
        val topThree = store.loadTopThree().forAccount(settings.cloudAccount())
        val topThreeSaved = store.saveTopThree(topThree)
        val todayKey = calendarDayKey()
        val counts = store.loadPomoCount()
        _state.value = _state.value.copy(
            settings = settings,
            store = topThree,
            todayPomodoros = counts[todayKey] ?: 0,
            pomoCounts = counts,
            histogram = store.loadHistogram(),
            blockProgress = store.loadBlockProgress(),
            dailyBlocks = store.loadDailyBlocks(),
            blockHistory = store.loadBlockHistory(),
            plants = store.loadPlants(),
            persistenceError = if (topThreeSaved) null else TOP_THREE_PERSIST_FAILED,
        )
        refreshDay()
        restoreTimer()
        refreshProfile()
        refreshTopThreeFromCloud()
        ensureDefaultHabits()
        com.habitica.pomodoro.service.BlockReminderReceiver.schedule(getApplication(), settings)
    }

    // MARK: - 计时核心

    /** Main control pauses rather than abandoning; resets are explicit actions. */
    fun activate() {
        resyncTimer()
        val s = _state.value
        when {
            s.phase == Phase.MANUAL_BREAK -> startBreak()
            s.phase == Phase.BREAK_EXTENSION && !s.isRunning && s.remainingSeconds == 0 -> startPomodoro()
            s.isRunning -> pause()
            s.phase == Phase.IDLE -> startPomodoro()
            else -> resume()
        }
    }

    fun startPomodoro() {
        startPomodoro(taskFocus = null)
    }

    fun startTaskFocus(dateKey: String, category: Int, taskId: String): Boolean {
        resyncTimer()
        val state = _state.value
        if (state.phase == Phase.POMODORO || dateKey != todayKey()) return false
        val task = state.store.history[dateKey]?.taskGroups?.getOrNull(category)
            ?.firstOrNull { it.id == taskId && it.isUnfinished } ?: return false
        startPomodoro(TaskFocusSession(UUID.randomUUID().toString().uppercase(), task.id, task.title,
            state.settings.pomoDurationMins, System.currentTimeMillis()))
        return true
    }

    private fun startPomodoro(taskFocus: TaskFocusSession?) {
        val s = _state.value
        if (s.phase == Phase.POMODORO) return
        customBreak = false
        if (completedSet) _state.value = s.copy(pomoSetCounter = 0)
        completedSet = false
        phaseSnapshot = TimerBusinessSnapshot.capture(s.settings)
        beginPhase(Phase.POMODORO, s.settings.pomoDurationMins * 60, taskFocus = taskFocus)
        // 栖时模式：每个番茄开始时随机选一个新场景（避开上个番茄）。放在 beginPhase 之后，
        // 因为 beginPhase 会清空 message，"场景库不可用"提示必须随后写入状态。
        selectQishiScene(s.settings)
    }

    private fun startBreak(startingAt: Long = System.currentTimeMillis()) {
        val settings = phaseSnapshot?.settings ?: _state.value.settings
        beginPhase(if (completedSet) Phase.LONG_BREAK else Phase.BREAK,
            (if (completedSet) settings.longBreakDuration else settings.breakDuration) * 60, startingAt)
    }

    fun takeBreak(minutes: Int) {
        resyncTimer()
        if (minutes !in listOf(1, 5, 15, 30)) return
        if (_state.value.phase != Phase.IDLE || _state.value.isRunning) return
        customBreak = true
        phaseSnapshot = TimerBusinessSnapshot.capture(_state.value.settings)
        beginPhase(Phase.LONG_BREAK, minutes * 60) // Independent custom break; never fabricate a completed set.
    }

    fun skipToBreak() {
        resyncTimer()
        if (_state.value.phase != Phase.POMODORO) return
        val settings = phaseSnapshot?.settings ?: _state.value.settings
        if (settings.enableBlockMode) recordPlant("wilted", false, settings)
        _state.value = _state.value.copy(pomoSetCounter = 0)
        completedSet = false
        startBreak() // No completion and no Habitica penalty for skip.
    }

    private fun beginPhase(
        phase: Phase, seconds: Int, startingAt: Long = System.currentTimeMillis(),
        taskFocus: TaskFocusSession? = null,
    ) {
        tickJob?.cancel()
        timerSessionId = UUID.randomUUID().toString()
        phaseEndsAt = startingAt + seconds * 1000L
        pausedRemainingSeconds = 0
        _state.value = _state.value.copy(phase = phase, isRunning = true, totalSeconds = seconds,
            remainingSeconds = seconds, message = null, taskFocus = taskFocus,
            // 进入非专注阶段（休息/延长）即清空激活场景；POMODORO 由紧随其后的选择逻辑写入
            qishiScene = if (phase == Phase.POMODORO) _state.value.qishiScene else null)
        persistTimer()
        if (!processingDeadline) { syncTimerService(); startTicking() }
    }

    fun pause() {
        if (!_state.value.isRunning) return
        if (remainingNow() <= 0) { onPhaseEnd(); return }
        pausedRemainingSeconds = remainingNow()
        phaseEndsAt = 0L
        tickJob?.cancel()
        timerSessionId = UUID.randomUUID().toString() // Invalidate the old notification controls.
        _state.value = _state.value.copy(isRunning = false, remainingSeconds = pausedRemainingSeconds)
        persistTimer()
        PomodoroTimerService.updatePaused(getApplication(), pausedRemainingSeconds, timerSessionId!!)
    }

    fun resume() {
        val s = _state.value
        if (s.isRunning || s.phase == Phase.IDLE || s.phase == Phase.MANUAL_BREAK) return
        if (pausedRemainingSeconds <= 0) { startPomodoro(); return }
        timerSessionId = UUID.randomUUID().toString()
        phaseEndsAt = System.currentTimeMillis() + pausedRemainingSeconds * 1000L
        _state.value = s.copy(isRunning = true, remainingSeconds = pausedRemainingSeconds)
        persistTimer()
        syncTimerService()
        startTicking()
    }

    fun handleNotificationAction(action: String?, sessionId: String?) {
        resyncTimer()
        if (sessionId == null || sessionId != timerSessionId) return
        when (action) {
            PomodoroTimerService.ACTION_PAUSE -> pause()
            PomodoroTimerService.ACTION_RESUME -> resume()
            PomodoroTimerService.ACTION_STOP -> stop()
        }
    }

    fun isCurrentTimer(id: String): Boolean = id.isNotBlank() && id == timerSessionId

    fun onServiceDeadline(sessionId: String) {
        if (sessionId == timerSessionId && _state.value.isRunning && remainingNow() <= 0) onPhaseEnd()
    }

    /** Explicit abandon resets the combo; pause and skip never score a failure. */
    fun stop() {
        if (_state.value.isRunning && phaseEndsAt > 0 && remainingNow() <= 0) { onPhaseEnd(); return }
        val s = _state.value
        val interrupted = s.phase == Phase.POMODORO
        val snapshot = phaseSnapshot
        val settings = snapshot?.settings ?: s.settings
        if (interrupted && settings.enableBlockMode) recordPlant("wilted", false, settings)
        resetTimer(resetCombo = true)
        if (interrupted && settings.pomoHabitMinus) snapshot?.withCurrentCredentials(_state.value.settings)?.let { scoreFailure(it, captured = true) }
    }

    private fun resetTimer(resetCombo: Boolean) {
        tickJob?.cancel(); phaseEndsAt = 0; pausedRemainingSeconds = 0; timerSessionId = null
        customBreak = false
        phaseSnapshot = null
        if (resetCombo) completedSet = false
        _state.value = _state.value.copy(phase = Phase.IDLE, isRunning = false, remainingSeconds = 0,
            totalSeconds = 0, pomoSetCounter = if (resetCombo) 0 else _state.value.pomoSetCounter,
            qishiScene = null, taskFocus = null)
        persistTimer()
        PomodoroTimerService.stop(getApplication())
    }

    fun skipBreak() {
        resyncTimer()
        val s = _state.value
        if (s.phase !in listOf(Phase.BREAK, Phase.LONG_BREAK, Phase.BREAK_EXTENSION, Phase.MANUAL_BREAK)) return
        resetTimer(!customBreak && completedSet)
        startPomodoro()
    }

    private fun remainingNow(): Int = if (phaseEndsAt <= 0) pausedRemainingSeconds else
        ((phaseEndsAt - System.currentTimeMillis() + 999) / 1000L).toInt().coerceAtLeast(0)

    private fun startTicking() {
        tickJob?.cancel()
        tickJob = viewModelScope.launch {
            while (true) {
                val remaining = remainingNow()
                _state.value = _state.value.copy(remainingSeconds = remaining)
                if (remaining <= 0) { onPhaseEnd(); break }
                delay(500)
            }
        }
    }

    fun resyncAfterForeground() {
        refreshDay(); refreshTopThreeFromCloud(); resyncTimer(); refreshDay()
        // 进程恢复后正在运行的专注可能丢失了内存中的场景：补选一次；已有场景绝不重随机。
        ensureQishiSceneForRunningFocus()
        com.habitica.pomodoro.service.BlockReminderReceiver.schedule(getApplication(), _state.value.settings)
    }
    private fun resyncTimer() {
        if (phaseEndsAt <= 0 || processingDeadline) return
        processingDeadline = true
        try {
            // At most focus -> break -> grace. Never create an unattended focus during restoration.
            repeat(6) {
                if (!_state.value.isRunning || phaseEndsAt <= 0 || remainingNow() > 0) return@repeat
                val deadline = phaseEndsAt
                tickJob?.cancel(); phaseEndsAt = 0; pausedRemainingSeconds = 0; timerSessionId = null
                when (_state.value.phase) {
                    Phase.POMODORO -> onPomodoroEnds(deadline)
                    Phase.BREAK, Phase.LONG_BREAK -> onBreakEnds(deadline)
                    Phase.BREAK_EXTENSION -> onExtensionEnds()
                    else -> resetTimer(false)
                }
            }
        } finally { processingDeadline = false }
        _state.value = _state.value.copy(remainingSeconds = remainingNow())
        if (_state.value.isRunning && phaseEndsAt > 0) {
            syncTimerService()
            if (tickJob?.isActive != true) startTicking()
        }
    }

    private fun persistTimer() {
        val s = _state.value
        store.saveTimer(org.json.JSONObject().apply {
            put("phase", s.phase.name); put("phaseID", timerSessionId ?: org.json.JSONObject.NULL)
            put("endsAt", phaseEndsAt); put("pausedRemaining", pausedRemainingSeconds)
            put("totalSeconds", s.totalSeconds); put("combo", s.pomoSetCounter); put("running", s.isRunning)
            put("customBreak", customBreak); put("completedSet", completedSet)
            put("phaseSnapshot", phaseSnapshot?.toJson() ?: org.json.JSONObject.NULL)
            s.taskFocus?.let { put("taskFocus", it.toJson()) }
        })
    }
    private fun restoreTimer() {
        val json = store.loadTimer() ?: return
        val phase = runCatching { Phase.valueOf(json.optString("phase")) }.getOrDefault(Phase.IDLE)
        timerSessionId = json.optString("phaseID").takeIf { it.isNotBlank() && it != "null" }
        customBreak = json.optBoolean("customBreak", false)
        completedSet = json.optBoolean("completedSet", json.optInt("combo") >= _state.value.settings.pomoSetNum)
        // Old snapshots had no captured settings. Preserve their known duration; never invent an owner for scoring.
        phaseSnapshot = json.optJSONObject("phaseSnapshot")?.let(TimerBusinessSnapshot::fromJson)
            ?: if (phase != Phase.IDLE) TimerBusinessSnapshot.capture(_state.value.settings).copy(cloudAccount = null) else null
        phaseEndsAt = json.optLong("endsAt"); pausedRemainingSeconds = json.optInt("pausedRemaining").coerceAtLeast(0)
        _state.value = _state.value.copy(phase = phase, isRunning = json.optBoolean("running") && phaseEndsAt > 0,
            totalSeconds = json.optInt("totalSeconds").coerceAtLeast(0), remainingSeconds = remainingNow(),
            pomoSetCounter = json.optInt("combo").coerceAtLeast(0),
            taskFocus = if (phase == Phase.POMODORO) json.optJSONObject("taskFocus")?.let(TaskFocusSession::fromJson) else null)
        // No background FGS launch in Application/boot receivers. Activity resume attaches it.
        resyncTimer()
    }
    fun attachTimerService() {
        serviceAttachAllowed = true // Only the resumed Activity may initiate a first FGS.
        resyncTimer()
        syncTimerService()
    }
    private fun syncTimerService() {
        if (!serviceAttachAllowed || !_state.value.isRunning || phaseEndsAt <= 0 || timerSessionId == null) return
        if (!PomodoroTimerService.start(getApplication(), _state.value.phase, phaseEndsAt, timerSessionId!!))
            _state.value = _state.value.copy(message = "系统未允许启动前台计时服务；当前只能保证前台计时，请重新打开应用")
    }

    private fun onPhaseEnd() { resyncTimer() }

    private fun onPomodoroEnds(deadline: Long) {
        val before = _state.value
        val snapshot = phaseSnapshot ?: TimerBusinessSnapshot.capture(before.settings).copy(cloudAccount = null)
        val settings = snapshot.settings
        val date = java.util.Date(deadline)
        val day = calendarDayKey(date)
        val old = before.histogram[day] ?: com.habitica.pomodoro.data.DayHistogram()
        // Duration is the completed phase snapshot, NOT the setting at completion.
        val minutes = before.totalSeconds / 60
        val session = before.taskFocus?.takeIf { minutes > 0 }?.copy(minutes = minutes)
        val alreadyRecorded = session != null && before.histogram.values.any { entry ->
            entry.taskSessions.any { it.id == session.id }
        }
        val histogram = if (alreadyRecorded) before.histogram else before.histogram + (day to old.copy(
            pomodoros = old.pomodoros + 1,
            minutes = old.minutes + minutes,
            weekday = java.text.SimpleDateFormat("EEEE", java.util.Locale.getDefault()).format(date),
            taskSessions = if (session == null) old.taskSessions else old.taskSessions + session,
        ))
        if (!alreadyRecorded) store.saveHistogram(histogram)
        val combo = before.pomoSetCounter + 1
        val setComplete = combo >= settings.pomoSetNum
        completedSet = setComplete
        if (settings.enableBlockMode) recordPlant("shrub", setComplete, settings, date)
        val s = _state.value
        val index = s.blockProgress.currentBlockIndex
        val blockComplete = settings.enableBlockMode &&
            s.blockHistory[day].orEmpty().any { it.blockIndex == index && it.isComplete } &&
            before.blockHistory[day].orEmpty().none { it.blockIndex == index && it.isComplete }
        val message = if (blockComplete) "时间块 B${index + 1} 完成！🎉\n${settings.blockGoals.getOrNull(index).orEmpty()}\n${breakSuggestion(index, settings, date)}"
            else if (setComplete) "一组番茄完成！🎉" else "番茄完成！"
        _state.value = s.copy(histogram = histogram, pomoCounts = histogram.mapValues { it.value.pomodoros },
            todayPomodoros = histogram[calendarDayKey()]?.pomodoros ?: 0, pomoSetCounter = combo,
            phase = if (settings.manualBreak) Phase.MANUAL_BREAK else Phase.IDLE, isRunning = false,
            remainingSeconds = 0, totalSeconds = 0, message = message, qishiScene = null, taskFocus = null)
        persistTimer()
        PomodoroTimerService.endSignal(getApplication(), if (setComplete) "一组番茄完成" else "番茄结束", message,
            settings.pomoEndSound, settings.pomoEndSoundVolume)
        PomodoroTimerService.stop(getApplication())
        snapshot.withCurrentCredentials(_state.value.settings)?.let { scoringSettings ->
            val generation = accountGeneration
            viewModelScope.launch { scorePomodoroHabit(scoringSettings, setComplete, blockComplete, generation) }
        }
        if (!settings.manualBreak) startBreak(deadline)
    }

    private suspend fun scorePomodoroHabit(settings: UserSettings, setComplete: Boolean, blockComplete: Boolean, generation: Int) {
        val needsPomo = settings.pomoHabitPlus || (blockComplete && settings.blockRewardEnabled)
        if (!needsPomo && !(setComplete && settings.pomoSetHabitPlus)) return
        val pomo = if (needsPomo) resolveHabit(settings, false, generation, captured = true) else null
        val combo = if (setComplete && settings.pomoSetHabitPlus) resolveHabit(settings, true, generation, captured = true) else null
        val ids = buildList {
            if (settings.pomoHabitPlus) pomo?.let(::add)
            if (setComplete && settings.pomoSetHabitPlus) combo?.let(::add)
            // The block reward is separate from the regular completion reward, like macOS.
            if (blockComplete && settings.blockRewardEnabled) pomo?.let(::add)
        }
        for (id in ids) {
            if (!isCurrentAccount(settings, generation)) return
            val result = habitica(settings) { HabiticaAPI.scoreTask(settings, id, "up") }
            if (!isCurrentAccount(settings, generation)) return
            if (result is HabiticaAPI.Result.Error) _state.value = _state.value.copy(message = result.message + "；本机完成记录已保留，未自动重试以免重复奖励")
        }
        if (isCurrentAccount(settings, generation)) refreshProfile()
    }

    private fun scoreFailure(settings: UserSettings, captured: Boolean = false) {
        val generation = accountGeneration
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        viewModelScope.launch {
            val id = resolveHabit(settings, false, generation, captured) ?: return@launch
            if (!isCurrentAccount(settings, generation)) return@launch
            val result = habitica(settings) { HabiticaAPI.scoreTask(settings, id, "down") }
            if (!isCurrentAccount(settings, generation)) return@launch
            if (result is HabiticaAPI.Result.Error) _state.value = _state.value.copy(message = result.message)
            else refreshProfile()
        }
    }

    private fun onBreakEnds(deadline: Long) {
        val s = _state.value
        val snapshot = phaseSnapshot
        val settings = snapshot?.settings ?: s.settings
        val long = s.phase == Phase.LONG_BREAK
        val message = if (long) "长休息结束" else "短休息结束，回到专注"
        resetTimer(long && !customBreak)
        _state.value = _state.value.copy(message = message)
        PomodoroTimerService.endSignal(getApplication(), message, "开始下一个番茄吧", settings.breakEndSound, settings.breakEndSoundVolume)
        snapshot?.withCurrentCredentials(_state.value.settings)?.let {
            sendBreakMessage(it, if (long) settings.longBreakNotify else settings.breakExtentionNotify && settings.breakExtention > 0,
                if (long) "Long Break is over" else "Back to work! ${settings.breakExtention} minutes left for Break Extension.")
        }
        if (!long && settings.breakExtention > 0) {
            phaseSnapshot = snapshot
            beginPhase(Phase.BREAK_EXTENSION, settings.breakExtention * 60, deadline)
        }
        // Zero extension ends the break directly: no timeout, penalty, or combo reset.
    }

    private fun onExtensionEnds() {
        val snapshot = phaseSnapshot
        val settings = snapshot?.settings ?: _state.value.settings
        resetTimer(settings.resetPomoAfterBreak)
        _state.value = _state.value.copy(message = if (settings.resetPomoAfterBreak) "休息延长结束，本组已重置" else "休息延长结束，连击保留，开始专注吧")
        // Zero extension is a grace-free transition, not a spurious interruption penalty.
        if (settings.breakExtention > 0 && settings.breakExtentionFails) snapshot?.withCurrentCredentials(_state.value.settings)?.let { scoreFailure(it, captured = true) }
        persistTimer()
    }

    private fun sendBreakMessage(settings: UserSettings, enabled: Boolean, message: String) {
        if (!enabled || !settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        val generation = accountGeneration
        viewModelScope.launch {
            val r = habitica(settings) { HabiticaAPI.sendPrivateMessage(settings, message) }
            if (isCurrentAccount(settings, generation) && r is HabiticaAPI.Result.Error) _state.value = _state.value.copy(message = r.message)
        }
    }

    private fun breakSuggestion(index: Int, settings: UserSettings, date: java.util.Date): String {
        val c = java.util.Calendar.getInstance().apply { time = date }
        val now = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        val next = settings.blockTimeRanges.getOrNull((index + 1) % settings.blockCount)
        val until = next?.let { (it.startMinutes - now).mod(1440) }
        return when {
            until != null && until in 1..10 -> "建议短休息 2 分钟：下一块即将开始"
            (index + 1) % 2 == 0 -> "建议长休息 15–20 分钟"
            else -> "建议普通休息 5–10 分钟"
        }
    }

    private suspend fun resolveHabit(settings: UserSettings, combo: Boolean, generation: Int, captured: Boolean = false): String? {
        habitMutex.lock()
        try {
            if (!isCurrentAccount(settings, generation)) return null
            val r = habitica(settings) { HabiticaAPI.ensureHabit(settings, combo) }
            if (!isCurrentAccount(settings, generation)) return null
            if (r is HabiticaAPI.Result.Error) { _state.value = _state.value.copy(message = r.message); return null }
            val current = _state.value.settings
            val configurationMatches = (if (combo) current.customSetTask == settings.customSetTask else current.customPomodoroTask == settings.customPomodoroTask) &&
                (if (combo && settings.customSetTask) current.pomodoroSetTaskId == settings.pomodoroSetTaskId else if (!combo && settings.customPomodoroTask) current.pomodoroTaskId == settings.pomodoroTaskId else true)
            if (!captured && !configurationMatches) return null
            val id = (r as HabiticaAPI.Result.Success).value
            if (configurationMatches) updateSettings { if (combo) it.copy(pomodoroSetTaskId = id) else it.copy(pomodoroTaskId = id) }
            return id
        } finally { habitMutex.unlock() }
    }
    fun ensureDefaultHabits() {
        val settings = _state.value.settings
        val generation = accountGeneration
        if (!isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank() || !settings.connectHabitica) return
        viewModelScope.launch {
            _state.value = _state.value.copy(habiticaBusy = true)
            resolveHabit(settings, false, generation); resolveHabit(settings, true, generation)
            if (isCurrentAccount(settings, generation)) _state.value = _state.value.copy(habiticaBusy = false)
        }
    }

    // MARK: - Habitica：Role 页

    fun refreshProfile() {
        val settings = _state.value.settings
        profileJob?.cancel()
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) {
            _state.value = _state.value.copy(
                profile = null,
                profileLoading = false,
                profileError = "未连接 Habitica：请在设置中填写 User ID 与 API Token",
            )
            return
        }
        val generation = accountGeneration
        profileJob = viewModelScope.launch {
            _state.value = _state.value.copy(profileLoading = true)
            val sequence = ++requestSequence
            val revision = profileFeedback.revision
            val result = HabiticaAPI.fetchProfile(settings)
            if (!isCurrentAccount(settings, generation)) return@launch
            when (result) {
                is HabiticaAPI.Result.Success -> {
                    // An older role response may not undo a newer 401 or replace a newer profile.
                    if (sequence < latestAuthSequence || sequence < latestProfileSequence) {
                        _state.value = _state.value.copy(profileLoading = false)
                        return@launch
                    }
                    latestAuthSequence = sequence
                    latestProfileSequence = sequence
                    _state.value = _state.value.copy(
                        profile = result.value,
                        profileLoading = false,
                        profileError = if (profileFeedback.mayClear(revision) && !HabiticaRequestBudgets.coolingDown429(settings.cloudAccount())) null
                            else _state.value.profileError,
                    )
                }
                is HabiticaAPI.Result.Error -> {
                    if (result.statusCode == 401) noteAuthenticationFailure(sequence)
                    else if (profileFeedback.acceptError(sequence)) _state.value = _state.value.copy(profileError = result.message)
                    // Keep the last role shown for this account; only an authentication failure revokes it.
                    _state.value = _state.value.copy(profileLoading = false)
                }
            }
        }
    }

    // MARK: - 设置

    fun updateSettings(transform: (UserSettings) -> UserSettings) {
        val old = _state.value.settings
        var settings = transform(old).normalized()
        if (settings.uid != old.uid && !isValidHabiticaUid(settings.uid)) {
            _state.value = _state.value.copy(message = "User ID 必须是完整 UUID，不能包含空白；原账号和设置未改变")
            return
        }
        if (old.cloudAccount() != settings.cloudAccount()) {
            val previous = _state.value.store.copy(pomodoroHabitId = old.pomodoroTaskId, comboHabitId = old.pomodoroSetTaskId)
            val next = previous.forAccount(settings.cloudAccount())
            persistStore(next)
            settings = settings.copy(pomodoroTaskId = next.pomodoroHabitId, pomodoroSetTaskId = next.comboHabitId)
        }
        val settingsSaved = store.saveSettings(settings)
        _state.value = _state.value.copy(settings = settings,
            // FIX2(D2): surface a failed settings save; keep an active Top3 error otherwise.
            persistenceError = if (settingsSaved) _state.value.persistenceError else SETTINGS_PERSIST_FAILED)
        // Before anything else can dispatch: a new connection retires every in-flight read and queued
        // request of the old one. Ordinary preferences and equivalent API roots keep the connection.
        HabiticaGate.activate(settings)
        refreshDay()
        if (!HabiticaGate.sameConnection(old, settings)) {
            accountGeneration++
            tasksGeneration++
            topThreeSyncGeneration++
            tasksFeedback.reset()
            profileFeedback.reset()
            topThreeFeedback.reset()
            profileJob?.cancel()
            tasksJob?.cancel()
            topThreeSyncJob?.cancel()
            _state.value = _state.value.copy(profile = null, habits = emptyList(), dailies = emptyList(),
                profileLoading = false, tasksLoading = false, tasksError = null, scoringIds = emptySet(), habiticaBusy = false,
                topThreeSyncing = false, topThreeSyncError = null,
                profileError = if (!isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank() || !settings.connectHabitica) "未连接 Habitica" else null)
            refreshTopThreeFromCloud()
        }
        if (old.blockStartReminder != settings.blockStartReminder || old.enableBlockMode != settings.enableBlockMode ||
            old.blockCount != settings.blockCount || old.blockReminderMinutes != settings.blockReminderMinutes || old.blockTimeRanges != settings.blockTimeRanges || old.blockGoals != settings.blockGoals)
            com.habitica.pomodoro.service.BlockReminderReceiver.schedule(getApplication(), settings)
        // 运行中的专注切到 qishi（或恢复后场景缺失）：立即补选场景，随后的 refreshAudio 就能播放
        ensureQishiSceneForRunningFocus()
        PomodoroTimerService.refreshAudio(getApplication())
    }

    /** Histogram/blocks/plants use calendar days; Task alone uses the logical boundary. */
    fun refreshDay() {
        val s = _state.value
        val key = calendarDayKey()
        val index = currentBlockIndex(s.settings) ?: s.blockProgress.currentBlockIndex.coerceIn(0, s.settings.blockCount - 1)
        val count = s.dailyBlocks[key]?.blockProgress?.getOrNull(index) ?: 0
        val progress = BlockProgress(index, count)
        if (progress != s.blockProgress) store.saveBlockProgress(progress)
        val counts = store.loadPomoCount()
        _state.value = s.copy(blockProgress = progress, todayPomodoros = counts[calendarDayKey()] ?: 0, pomoCounts = counts, histogram = store.loadHistogram())
    }

    private fun recordPlant(outcome: String, combo: Boolean, settings: UserSettings, date: java.util.Date = java.util.Date()) {
        val s = _state.value
        val key = calendarDayKey(date)
        val index = currentBlockIndex(settings, date) ?: s.blockProgress.currentBlockIndex.coerceIn(0, settings.blockCount - 1)
        val existing = s.dailyBlocks[key] ?: DailyBlockProgress(key, List(settings.blockCount) { 0 }, settings.blockGoals)
        val completed = existing.blockProgress.getOrElse(index) { 0 }
        val oldPlant = s.plants[key] ?: PlantDay()
        val attempts = oldPlant.attempts.getOrElse(index) { emptyList() }
        val missing = (completed - attempts.count { it == "shrub" }).coerceAtLeast(0)
        val aligned = List(missing) { "shrub" } + attempts
        val newAttempts = List(maxOf(oldPlant.attempts.size, settings.blockCount)) { i ->
            if (i == index) aligned + outcome else oldPlant.attempts.getOrElse(i) { emptyList() }
        }
        val newTrees = List(maxOf(oldPlant.trees.size, settings.blockCount)) { i ->
            oldPlant.trees.getOrElse(i) { 0 } + if (i == index && combo) 1 else 0
        }
        val plants = s.plants + (key to PlantDay(newAttempts, newTrees))
        store.savePlants(plants)
        if (outcome == "wilted") {
            _state.value = s.copy(plants = plants)
            return
        }
        val next = completed + 1
        val progressList = List(maxOf(existing.blockProgress.size, settings.blockCount)) { i ->
            if (i == index) next else existing.blockProgress.getOrElse(i) { 0 }
        }
        val days = s.dailyBlocks + (key to existing.copy(blockProgress = progressList, blockGoals = settings.blockGoals))
        store.saveDailyBlocks(days)
        var history = s.blockHistory
        if (next >= settings.blockPomoCount && history[key].orEmpty().none { it.blockIndex == index && it.isComplete }) {
            val entry = BlockHistoryEntry(key, index, next, true, (date.time - 978307200000L) / 1000.0)
            history = history + (key to (history[key].orEmpty() + entry))
            store.saveBlockHistory(history)
        }
        val progress = BlockProgress(index, next)
        store.saveBlockProgress(progress)
        _state.value = s.copy(plants = plants, dailyBlocks = days, blockHistory = history, blockProgress = progress)
        val reminderKey = "$key-$index"
        val preferences = getApplication<Application>().getSharedPreferences("block_reminders", 0)
        if (settings.blockSprintReminder && settings.blockPomoCount == 6 && next == 4 && preferences.getString("sprint", "") != reminderKey) {
            preferences.edit().putString("sprint", reminderKey).apply()
            PomodoroTimerService.alert(getApplication(), "冲刺时间 🚀", "B${index + 1}: 4/6 番茄完成 · ${settings.blockGoals.getOrNull(index).orEmpty()}", 2200 + index)
        }
    }

    fun updateBlockGoal(index: Int, goal: String) {
        if (index !in 0 until _state.value.settings.blockCount) return
        updateSettings { s -> s.copy(blockGoals = List(maxOf(s.blockCount, s.blockGoals.size)) { i -> if (i == index) goal else s.blockGoals.getOrElse(i) { "" } }) }
    }

    fun updateBlockRange(index: Int, range: com.habitica.pomodoro.data.BlockTimeRange) {
        if (index !in 0 until _state.value.settings.blockCount) return
        updateSettings { s -> s.copy(blockTimeRanges = s.normalized().blockTimeRanges.mapIndexed { i, r -> if (i == index) range else r }) }
    }

    fun addBlockTask(index: Int, title: String) {
        if (title.isBlank() || index !in 0 until _state.value.settings.blockCount) return
        updateSettings { s -> s.copy(blockTasks = List(maxOf(s.blockCount, s.blockTasks.size)) { i ->
            val tasks = s.blockTasks.getOrElse(i) { emptyList() }
            if (i == index) tasks + BlockTask(title = title.trim()) else tasks
        }) }
    }

    fun toggleBlockTask(index: Int, taskId: String) = updateSettings { s ->
        s.copy(blockTasks = s.blockTasks.mapIndexed { i, tasks -> if (i == index) tasks.map { if (it.id == taskId) it.copy(isCompleted = !it.isCompleted) else it } else tasks })
    }

    fun deleteBlockTask(index: Int, taskId: String) = updateSettings { s ->
        s.copy(blockTasks = s.blockTasks.mapIndexed { i, tasks -> if (i == index) tasks.filterNot { it.id == taskId } else tasks })
    }

    fun editBlockTask(index: Int, id: String, title: String, estimate: Int) {
        if (title.isBlank() || estimate !in 1..12) return
        updateSettings { s -> s.copy(blockTasks = s.blockTasks.mapIndexed { i, list ->
            if (i == index) list.map { if (it.id == id) it.copy(title = title.trim(), estimatedPomo = estimate) else it } else list
        }) }
    }
    fun resetCurrentBlock() {
        refreshDay()
        val s = _state.value; val key = calendarDayKey(); val index = s.blockProgress.currentBlockIndex
        val day = s.dailyBlocks[key] ?: DailyBlockProgress(key, List(s.settings.blockCount) { 0 }, s.settings.blockGoals)
        val days = s.dailyBlocks + (key to day.copy(blockProgress = List(maxOf(s.settings.blockCount, day.blockProgress.size)) { if (it == index) 0 else day.blockProgress.getOrElse(it) { 0 } }))
        val progress = BlockProgress(index, 0)
        store.saveDailyBlocks(days); store.saveBlockProgress(progress)
        _state.value = s.copy(dailyBlocks = days, blockProgress = progress, message = "当前块计数已重置；已有植物与达标奖励记录保留，不重复奖励")
    }
    fun clearHistogram() {
        store.saveHistogram(emptyMap()); _state.value = _state.value.copy(histogram = emptyMap(), pomoCounts = emptyMap(), todayPomodoros = 0)
    }

    fun clearBlockHistory() {
        store.saveDailyBlocks(emptyMap()); store.saveBlockHistory(emptyMap()); store.savePlants(emptyMap())
        store.saveBlockProgress(BlockProgress())
        _state.value = _state.value.copy(dailyBlocks = emptyMap(), blockHistory = emptyMap(), plants = emptyMap(), blockProgress = BlockProgress())
        refreshDay()
    }

    /** A failed or malformed load keeps the list already shown for this account; a legal empty list clears it. */
    fun refreshHabiticaTasks(type: String) {
        if (type != "habits" && type != "dailys") return
        val settings = _state.value.settings
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        tasksJob?.cancel()
        val generation = accountGeneration
        val request = ++tasksGeneration
        tasksJob = viewModelScope.launch {
            _state.value = _state.value.copy(tasksLoading = true)
            val revision = tasksFeedback.revision
            val sequence = ++requestSequence
            val result = habitica(settings, sequence) { HabiticaAPI.fetchTaskItems(settings, type) }
            if (!isCurrentAccount(settings, generation) || request != tasksGeneration) return@launch
            when (result) {
                is HabiticaAPI.Result.Success -> {
                    _state.value = if (type == "habits") _state.value.copy(habits = result.value.sortedBy { it.value }, tasksLoading = false)
                    else _state.value.copy(dailies = result.value, tasksLoading = false)
                    clearTasksError(settings, revision)
                }
                is HabiticaAPI.Result.Error -> {
                    _state.value = _state.value.copy(tasksLoading = false)
                    publishTasksError(sequence, result.message)
                }
            }
        }
    }

    private fun publishTasksError(sequence: Long, message: String) {
        if (tasksFeedback.acceptError(sequence)) _state.value = _state.value.copy(tasksError = message)
    }

    private fun clearTasksError(settings: UserSettings, revisionAtDispatch: Long) {
        if (tasksFeedback.mayClear(revisionAtDispatch) && !HabiticaRequestBudgets.coolingDown429(settings.cloudAccount()))
            _state.value = _state.value.copy(tasksError = null)
    }

    fun scoreHabiticaTask(type: String, item: HabiticaTaskItem, direction: String) {
        if (type !in listOf("habits", "dailys") || direction !in listOf("up", "down") || item.id in _state.value.scoringIds) return
        val settings = _state.value.settings
        val generation = accountGeneration
        viewModelScope.launch {
            _state.value = _state.value.copy(scoringIds = _state.value.scoringIds + item.id)
            val revision = tasksFeedback.revision
            val sequence = ++requestSequence
            // Sent once; a rejected or failed score is reported, never queued or replayed.
            val result = habitica(settings, sequence) { HabiticaAPI.scoreTask(settings, item.id, direction) }
            if (!isCurrentAccount(settings, generation)) return@launch
            when (result) {
                is HabiticaAPI.Result.Error -> publishTasksError(sequence, result.message)
                is HabiticaAPI.Result.Success -> {
                    if (type == "habits") _state.value = _state.value.copy(habits = _state.value.habits.map { if (it.id == item.id) it.copy(value = it.value + if (direction == "up") 1 else -1) else it })
                    else _state.value = _state.value.copy(dailies = _state.value.dailies.map { if (it.id == item.id) it.copy(completed = !it.completed) else it })
                    clearTasksError(settings, revision)
                    refreshProfile()
                }
            }
            _state.value = _state.value.copy(scoringIds = _state.value.scoringIds - item.id)
        }
    }

    fun refreshRuntimeAudio() { PomodoroTimerService.refreshAudio(getApplication()) }

    // MARK: - 栖时随机场景（ambientSource == "qishi"）
    // 选择与延续逻辑全部在 VM 层（可离线测试）；MediaPlayer 多轨流式播放只在 PomoAudio。

    private fun qishiLibrary(): List<QishiPreset> = qishiLibraryCache
        ?: (runCatching { qishiLibraryLoader?.invoke() }.getOrNull() ?: emptyList<QishiPreset>()).also { qishiLibraryCache = it }

    /** 新番茄开始：随机选一个场景并避开上个番茄；custom 模式清空场景状态。 */
    private fun selectQishiScene(settings: UserSettings) {
        if (settings.ambientSource != AMBIENT_SOURCE_QISHI) {
            if (_state.value.qishiScene != null) _state.value = _state.value.copy(qishiScene = null)
            return
        }
        val chosen = QishiLibrary.randomPreset(qishiLibrary(), excluding = lastQishiSceneId)
        if (chosen == null) {
            _state.value = _state.value.copy(qishiScene = null, message = QISHI_LIBRARY_UNAVAILABLE)
            return
        }
        lastQishiSceneId = chosen.id
        _state.value = _state.value.copy(qishiScene = chosen)
    }

    /** 正在运行的专注缺失场景（中途切到 qishi / 进程恢复后）时补选一次；已有场景绝不重随机。 */
    private fun ensureQishiSceneForRunningFocus() {
        val s = _state.value
        if (s.settings.ambientSource == AMBIENT_SOURCE_QISHI && s.qishiScene == null && s.isRunning && s.phase == Phase.POMODORO)
            selectQishiScene(s.settings)
    }

    /** 设置页试听：随机场景，不写 lastQishiSceneId、不影响当前番茄（试听播放器独立于前台服务）。 */
    fun randomQishiPreviewScene(): QishiPreset? = QishiLibrary.randomPreset(qishiLibrary(), excluding = null)

    /** 场景总数（设置页文案用）。 */
    fun qishiSceneCount(): Int = qishiLibrary().size

    /** 设备端播放错误（如栖时流式全轨失败）经既有 message 通道提示。 */
    fun reportAudioError(text: String) {
        _state.value = _state.value.copy(message = text)
    }

    fun clearMessage() {
        _state.value = _state.value.copy(message = null)
    }

    // MARK: - Task（Top Three）

    /** A failed/partial fetch never changes disk; merge against current local edits on success. */
    fun refreshTopThreeFromCloud() {
        val settings = _state.value.settings.copy()
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        if (creatingTasks > 0) return
        // During a cooldown nothing is sent; a manual refresh afterwards continues normally.
        rateLimitMessage(settings)?.let { publishTopThreeError(it); return }
        topThreeSyncJob?.cancel()
        val generation = accountGeneration
        val request = ++topThreeSyncGeneration
        val revision = localRevision
        val feedbackRevision = topThreeFeedback.revision
        topThreeSyncJob = viewModelScope.launch {
            // FIX3(D4): no optimistic clear at cycle start — an error whose condition
            // is still active (markers, delete protection, persistence failure) must
            // stay displayed. Clearing happens at successful completion, guarded.
            _state.value = _state.value.copy(topThreeSyncing = true)
            val result = habitica(settings) { HabiticaAPI.fetchTopThreeTodos(settings) }
            if (!isCurrentAccount(settings, generation) || request != topThreeSyncGeneration) return@launch
            when (result) {
                is HabiticaAPI.Result.Success -> {
                    val current = _state.value.store
                    val merged = if (revision == localRevision && creatingTasks == 0) mergeTopThreeTodos(current, result.value) else current
                    if (merged != current) persistStore(merged)
                    val deletionConflict = result.value.any { !current.isTombstoned(it.id) && current.quarantinesDeletedCreation(it) }
                    // FIX3(D4): a stale error must not survive a clean successful cycle, but
                    // never clear while an error condition is still active: quarantine
                    // conflict (this cycle), unresolved create markers, delete protection for
                    // a queued id, or a persistence failure (FIX2) of this cycle's save.
                    val latest = _state.value.store
                    val markersPending = latest.deletedCreateMarkers.isNotEmpty()
                    val deleteProtectionActive = latest.deletedCloudIds.any { id ->
                        latest.history.values.any { day -> day.taskGroups.flatten().any {
                            it.cloudAccount == latest.cloudAccount && it.habiticaTaskId == id &&
                                !(latest.deletedCloudTaskOrigins[id] == it.id && it.movedToToday)
                        } }
                    }
                    // v2.1.4: an error published after this refresh was dispatched (or a running 429
                    // cooldown) is newer than this success and stays visible.
                    val newerError = !topThreeFeedback.mayClear(feedbackRevision) || HabiticaRequestBudgets.coolingDown429(settings.cloudAccount())
                    if (deletionConflict) topThreeFeedback.noteError()
                    _state.value = _state.value.copy(topThreeSyncing = false,
                        topThreeSyncError = when {
                            deletionConflict -> "未确认创建请求的删除仍待核对；同日期 notes 的未知任务已隔离（包括改名任务），请人工核对，未按 notes 删除"
                            markersPending || deleteProtectionActive || _state.value.persistenceError != null || newerError -> _state.value.topThreeSyncError
                            else -> null
                        })
                }
                is HabiticaAPI.Result.Error -> {
                    _state.value = _state.value.copy(topThreeSyncing = false)
                    publishTopThreeError(result.message)
                }
            }
        }
    }

    fun addTask(categoryIndex: Int, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        val settings = _state.value.settings
        val s = _state.value.store
        // Work/MyOwn（前 2 个分类）上限 3 条；其余（Chores）自由列表
        val limit = if (categoryIndex < FIXED_SLOT_CATEGORIES) MAX_FIXED_TASKS else Int.MAX_VALUE

        val todayKey = store.logicalDateKey(settings)
        val day = s.history[todayKey] ?: newDay(todayKey, s.categoryNames.size)
        val groups = day.taskGroups.toMutableList()
        while (groups.size <= categoryIndex) groups.add(emptyList())
        val group = groups[categoryIndex].toMutableList()
        if (group.count { !it.movedToToday } >= limit) {
            _state.value = _state.value.copy(message = "该分类最多 $limit 条任务")
            return
        }
        val newTask = com.habitica.pomodoro.data.TopThreeTask(title = trimmed, syncPending = true, cloudAccount = settings.cloudAccount())
        group.add(newTask)
        groups[categoryIndex] = group
        val newStore = s.copy(history = s.history + (todayKey to day.copy(taskGroups = groups)))
        persistStore(newStore)
        syncTaskToHabitica(categoryIndex, newTask, todayKey)
    }

    private fun newDay(date: String, categoryCount: Int) =
        com.habitica.pomodoro.data.TopThreeDay(
            date = date,
            taskGroups = List(categoryCount) { emptyList() },
        )

    fun editTask(categoryIndex: Int, taskIndex: Int, title: String) {
        val key = todayKey(); val day = _state.value.store.history[key] ?: return
        val task = day.taskGroups.getOrNull(categoryIndex)?.getOrNull(taskIndex) ?: return
        if (task.movedToToday || title.isBlank() || title.trim() == task.title) return
        replaceTask(task.id) { if (it.movedToToday) it else it.copy(title = title.trim(), syncPending = true, syncError = null, syncVersion = it.syncVersion + 1) }
        if (task.habiticaTaskId != null) syncExistingTask(task.id)
    }

    fun toggleTask(categoryIndex: Int, taskIndex: Int) {
        val day = _state.value.store.history[todayKey()] ?: return
        val task = day.taskGroups.getOrNull(categoryIndex)?.getOrNull(taskIndex) ?: return
        if (task.movedToToday) return
        replaceTask(task.id) { if (it.movedToToday) it else it.copy(isCompleted = !task.isCompleted, syncPending = true, syncError = null, syncVersion = it.syncVersion + 1) }
        if (task.habiticaTaskId != null) syncExistingTask(task.id)
    }

    fun deleteTask(categoryIndex: Int, taskIndex: Int) {
        val day = _state.value.store.history[todayKey()] ?: return
        val task = day.taskGroups.getOrNull(categoryIndex)?.getOrNull(taskIndex) ?: return
        if (task.movedToToday) return
        removeTask(todayKey(), categoryIndex, task.id, fromUnfinished = false)
    }

    /**
     * Today's tasks, or (fromUnfinished) an unfinished task from an earlier day. The UUID is resolved again
     * at action time, so a stale row cannot remove a moved copy or its archive.
     */
    private fun removeTask(key: String, categoryIndex: Int, id: String, fromUnfinished: Boolean): Boolean {
        val today = todayKey()
        if (if (fromUnfinished) key >= today else key != today) return false
        val s = _state.value.store
        val (date, index, task) = s.latestActiveCopy(id) ?: return false
        if (date != key || index != categoryIndex || (fromUnfinished && !task.isUnfinished)) return false
        val day = s.history.getValue(key)
        val groups = day.taskGroups.mapIndexed { gi, g -> if (gi == categoryIndex) g.filterNot { it.id == task.id && !it.movedToToday } else g }
        val owner = _state.value.settings.cloudAccount()
        val owned = owner != null && s.cloudAccount == owner && task.cloudAccount == owner
        val remoteId = task.habiticaTaskId.takeIf { owned }
        // Persist tombstone BEFORE attempting delete; inbound refresh cannot resurrect a failed delete.
        val marker = if (owned) task.pendingCreateTitle?.let { title -> task.pendingCreateNotes?.let { "$it\n$title" } } else null
        // A POST still in flight may yet be refused outright (401/429); then this marker must not outlive it.
        if (marker != null && owner != null && task.id in creationIds && marker !in s.deletedCreateMarkers)
            rejectableDeletionMarkers[task.id] = owner to marker
        persistStore(s.copy(history = s.history + (key to day.copy(taskGroups = groups)), deletedCloudIds = s.deletedCloudIds + listOfNotNull(remoteId),
            deletedCloudTaskOrigins = if (remoteId == null) s.deletedCloudTaskOrigins else s.deletedCloudTaskOrigins + (remoteId to task.id),
            // D1: link the queued remote id to its lost-creation marker so any later
            // marker-less consumption of the queue entry retires the marker atomically.
            deletedCloudIdMarkers = if (remoteId == null || marker == null) s.deletedCloudIdMarkers else s.deletedCloudIdMarkers + (remoteId to marker),
            deletedCreateMarkers = s.deletedCreateMarkers + listOfNotNull(marker)))
        remoteId?.let { deleteCloudTask(it) }
        if (marker != null) retryDeletedCreations()
        return true
    }

    private fun deleteCloudTask(id: String, marker: String? = null) {
        val settings = _state.value.settings; val generation = accountGeneration
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) {
            publishTopThreeError("删除已保留在本机；连接 Habitica 后可重试待同步操作")
            return
        }
        viewModelScope.launch {
            if (!isCurrentAccount(settings, generation)) return@launch
            val current = _state.value.store
            val originalId = current.deletedCloudTaskOrigins[id]
            fun mayDelete(): Boolean {
                if (!isCurrentAccount(settings, generation)) return false
                val latest = _state.value.store
                if (latest.cloudAccount != settings.cloudAccount() || id !in latest.deletedCloudIds ||
                    latest.deletedCloudTaskOrigins[id] != originalId) return false
                if (latest.history.values.any { day -> day.taskGroups.flatten().any {
                    it.cloudAccount == latest.cloudAccount && it.habiticaTaskId == id &&
                        !(originalId != null && it.id == originalId && it.movedToToday)
                } }) {
                    publishTopThreeError("待删除 ID 已绑定本地任务；删除保护保留，请人工核对")
                    return false
                }
                return true
            }
            if (!mayDelete()) return@launch
            if (_state.value.persistenceError == TOP_THREE_PERSIST_FAILED && !persistStore(_state.value.store)) return@launch
            val result = habitica(settings) { HabiticaAPI.deleteTodo(settings, id) }
            if (!mayDelete()) return@launch
            if (result is HabiticaAPI.Result.Error && !result.dispatched) {
                // Never sent (cooldown/budget/retired connection): the queue entry stays for a later manual retry.
                publishTopThreeError(result.message)
                return@launch
            }
            val readBack = habitica(settings) { HabiticaAPI.fetchTodo(settings, id) }
            if (!mayDelete()) return@launch
            if (readBack is HabiticaAPI.Result.Error && readBack.statusCode == 404) {
                val s = _state.value.store
                // D1: a restart retry consumes the queue with marker == null; retire the marker
                // linked to this remote id in the SAME atomic save, or it orphans forever —
                // re-erroring every sync and quarantining future legitimate cloud todos.
                val resolvedMarker = marker ?: s.deletedCloudIdMarkers[id]
                // Confirmed: never send this DELETE again, but keep the tombstone against stale reads.
                persistStore(s.copy(deletedCloudIds = s.deletedCloudIds - id, confirmedDeletedCloudIds = s.confirmedDeletedCloudIds + id,
                    deletedCloudTaskOrigins = s.deletedCloudTaskOrigins - id,
                    deletedCloudIdMarkers = s.deletedCloudIdMarkers - id,
                    deletedCreateMarkers = if (resolvedMarker == null) s.deletedCreateMarkers else s.deletedCreateMarkers - resolvedMarker))
            } else publishTopThreeError(rateLimitMessage(settings) ?: "远端删除尚未确认；本机删除保留，可重试")
        }
    }

    private fun findTask(id: String): Triple<String, Int, com.habitica.pomodoro.data.TopThreeTask>? =
        _state.value.store.history.entries.sortedByDescending { it.key }.firstNotNullOfOrNull { (date, day) ->
            day.taskGroups.withIndex().firstNotNullOfOrNull { (index, group) -> group.firstOrNull { it.id == id && !it.movedToToday }?.let { Triple(date, index, it) } }
        }
    private fun replaceTask(id: String, transform: (com.habitica.pomodoro.data.TopThreeTask) -> com.habitica.pomodoro.data.TopThreeTask): Boolean {
        val s = _state.value.store
        return persistStore(s.copy(history = s.history.mapValues { (_, day) -> day.copy(taskGroups = day.taskGroups.map { list -> list.map { if (it.id == id) transform(it) else it } }) }))
    }

    private data class TaskSyncSnapshot(
        val date: String, val categoryIndex: Int, val category: String, val owner: String?,
        val localId: String, val remoteId: String, val title: String, val completed: Boolean, val version: Long,
    )
    private fun syncSnapshot(localId: String): TaskSyncSnapshot? {
        val (date, index, task) = findTask(localId) ?: return null
        val category = _state.value.store.categoryNames.getOrNull(index) ?: return null
        return TaskSyncSnapshot(date, index, category, task.cloudAccount, task.id,
            task.habiticaTaskId ?: return null, task.title, task.isCompleted, task.syncVersion)
    }

    /** Reconcile completion before score; only a full, unchanged write snapshot may acknowledge dirty. */
    private fun maySyncTask(snapshot: TaskSyncSnapshot, settings: UserSettings, generation: Int): Boolean {
        if (!isCurrentAccount(settings, generation)) return false
        val current = _state.value.store
        val reason = when {
            current.cloudAccount != settings.cloudAccount() || snapshot.owner != settings.cloudAccount() -> "任务所属账号已变化"
            current.remoteIdOccupied(snapshot.remoteId, snapshot.localId) -> "远端 ID 已绑定其他本地任务，请人工核对"
            syncSnapshot(snapshot.localId) != snapshot -> "原任务已移除或修改，同步快照已变化"
            else -> return true
        }
        val message = "$reason；本机修改保留，未继续写入或确认"
        replaceTask(snapshot.localId) { if (it.cloudAccount == snapshot.owner) it.copy(syncError = message) else it }
        publishTopThreeError(message)
        return false
    }

    private fun syncExistingTask(localId: String) {
        val settings = _state.value.settings; val generation = accountGeneration
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        viewModelScope.launch {
            taskMutex.lock()
            try {
                repeat(4) {
                    if (!isCurrentAccount(settings, generation)) return@launch
                    val found = findTask(localId) ?: return@launch
                    val (date, categoryIndex, task) = found
                    if (task.cloudAccount != settings.cloudAccount()) return@launch
                    val remoteId = task.habiticaTaskId ?: return@launch
                    if (!task.syncPending) return@launch
                    val snapshot = syncSnapshot(localId) ?: return@launch
                    if (!maySyncTask(snapshot, settings, generation)) {
                        return@launch
                    }
                    val category = snapshot.category
                    val tag = resolveCategoryTag(settings, category, generation) { maySyncTask(snapshot, settings, generation) }
                    if (!maySyncTask(snapshot, settings, generation)) return@launch
                    if (tag !is HabiticaAPI.Result.Success || tag.value.isNullOrBlank()) {
                        val notSent = (tag as? HabiticaAPI.Result.Error)?.takeIf { !it.dispatched }?.message
                        replaceTask(localId) { it.copy(syncError = notSent?.let { reason -> "$reason 本机修改已保留。" } ?: "分类 tag 同步失败，本机修改保留") }
                        return@launch
                    }
                    val notes = topThreeNotes(category, date)
                    val updated = habitica(settings) { HabiticaAPI.updateTodo(settings, remoteId, task.title, notes, listOf(tag.value!!)) }
                    if (!maySyncTask(snapshot, settings, generation)) return@launch
                    if (updated is HabiticaAPI.Result.Error) {
                        replaceTask(localId) { it.copy(syncError = updated.message) }; return@launch
                    }
                    var remote = habitica(settings) { HabiticaAPI.fetchTodo(settings, remoteId) }
                    if (!maySyncTask(snapshot, settings, generation)) return@launch
                    if (remote is HabiticaAPI.Result.Success && remote.value.completed != task.isCompleted) {
                        val score = habitica(settings) { HabiticaAPI.scoreTask(settings, remoteId, if (task.isCompleted) "up" else "down") }
                        if (!maySyncTask(snapshot, settings, generation)) return@launch
                        if (score is HabiticaAPI.Result.Error) {
                            replaceTask(localId) { it.copy(syncError = score.message) }; return@launch
                        }
                        remote = habitica(settings) { HabiticaAPI.fetchTodo(settings, remoteId) }
                        if (!maySyncTask(snapshot, settings, generation)) return@launch
                    }
                    if (!maySyncTask(snapshot, settings, generation)) return@launch
                    if (remote is HabiticaAPI.Result.Success && remote.value.id == snapshot.remoteId && remote.value.title == task.title &&
                        remote.value.completed == task.isCompleted && remote.value.notes == notes && tag.value in remote.value.tags) {
                        replaceTask(localId) { it.copy(syncPending = false, syncError = null) }
                        val current = _state.value.store
                        persistStore(current.copy(categoryTagIds = current.categoryTagIds + (category to tag.value!!)))
                        refreshProfile()
                    } else replaceTask(localId) { it.copy(syncError = "远端结果未确认；本机修改保留，可重试") }
                    return@launch
                }
            } finally { taskMutex.unlock() }
        }
    }

    private fun retryDeletedCreations() {
        val settings = _state.value.settings; val generation = accountGeneration
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        viewModelScope.launch {
            val r = habitica(settings) { HabiticaAPI.fetchTopThreeTodos(settings) }
            if (!isCurrentAccount(settings, generation)) return@launch
            if (r is HabiticaAPI.Result.Error) { publishTopThreeError(r.message); return@launch }
            for (marker in _state.value.store.deletedCreateMarkers) {
                val current = _state.value.store
                val linked = current.history.values.flatMap { it.taskGroups.flatten() }.filter { it.cloudAccount == current.cloudAccount }.mapNotNull { it.habiticaTaskId }.toSet()
                val matches = (r as HabiticaAPI.Result.Success).value.distinctBy { it.id }.filter {
                    it.id.isNotBlank() && it.id !in linked && parseTopThreeNotes(it.notes) != null && "${it.notes}\n${it.title}" == marker
                }
                if (matches.size == 1) {
                    val id = matches.single().id
                    // D1: persist the id->marker link with the enqueue so a restart retry that
                    // consumes the id with marker == null can still retire this marker.
                    persistStore(current.copy(deletedCloudIds = current.deletedCloudIds + id,
                        deletedCloudIdMarkers = current.deletedCloudIdMarkers + (id to marker)))
                    deleteCloudTask(id, marker)
                }
                else publishTopThreeError("未确认创建请求的删除已保护在本机；云端匹配不唯一或尚不可见，请稍后重试/人工核对")
            }
        }
    }

    /** Manual retry. During a cooldown nothing is sent; afterwards it continues from the persisted queues. */
    fun retryPendingTasks() {
        val settings = _state.value.settings
        fun limited(): Boolean = rateLimitMessage(settings)?.also { publishTopThreeError(it) } != null
        if (limited()) return
        retryCategoryTags()
        for (id in _state.value.store.deletedCloudIds) {
            if (limited()) return
            deleteCloudTask(id)
        }
        if (limited()) return
        retryDeletedCreations()
        for ((date, day) in _state.value.store.history) day.taskGroups.forEachIndexed { i, group ->
            for (task in group.filter { it.syncPending && !it.movedToToday }) {
                if (limited()) return
                if (task.habiticaTaskId == null) syncTaskToHabitica(i, task, date) else syncExistingTask(task.id)
            }
        }
    }

    /**
     * FIX1(P0): user-confirmed manual cleanup for orphaned creation markers.
     * Markers queued before the D1 fix have no remote-id association and can
     * never resolve automatically: every retry re-errors and the quarantine
     * keeps blocking same-signature inbound todos. Clears deletedCreateMarkers
     * and deletedCloudIdMarkers for the CURRENT owner partition only, persisted
     * via the normal store save (which also refreshes the counts the settings
     * entry displays). NEVER touches deletedCloudIds / deletedCloudTaskOrigins
     * (explicit delete intents are sacred) nor other owners' accountStores
     * partitions. The UI must gate this behind an explicit confirmation;
     * there is no automatic or time-based cleanup.
     */
    fun clearQuarantinedCreateMarkers() {
        val s = _state.value.store
        persistStore(s.copy(deletedCreateMarkers = emptySet(), deletedCloudIdMarkers = emptyMap()))
    }

    /** 昨天未完成的任务移动到今天（对应 Swift moveTaskToToday）；与「未完成任务」走同一路径 */
    fun moveTaskToToday(categoryIndex: Int, taskIndex: Int) {
        val task = _state.value.store.history[yesterdayKey()]?.taskGroups?.getOrNull(categoryIndex)?.getOrNull(taskIndex) ?: return
        if (task.isCompleted || task.movedToToday) return
        moveUnfinishedToToday(yesterdayKey(), categoryIndex, task.id)?.let { _state.value = _state.value.copy(message = it) }
    }

    // MARK: - 未完成任务（昨天及更早，逻辑日）

    fun unfinishedTasks(): List<UnfinishedTask> = _state.value.store.unfinishedTasks(todayKey())

    /** Whether today's copy of this category still has room (Work/MyOwn 3, Chores unlimited). */
    fun canMoveToToday(categoryIndex: Int): Boolean = _state.value.store.hasRoom(todayKey(), categoryIndex)

    /**
     * Move to today's original category; returns null on success, otherwise a hint and the task stays in the
     * unfinished list. The source day keeps a movedToToday archive copy with the same UUID and remote ID.
     */
    fun moveUnfinishedToToday(dateKey: String, categoryIndex: Int, id: String): String? {
        val s = _state.value.store
        val today = todayKey()
        if (!s.hasRoom(today, categoryIndex)) {
            val name = s.categoryNames.getOrNull(categoryIndex) ?: "该分类"
            return "今天的「$name」已满 ${TOP_THREE_MAX_FIXED_TASKS} 条，任务保留在未完成列表"
        }
        val next = s.movingUnfinishedToToday(dateKey, categoryIndex, id, today) ?: return "任务已完成、已转移或已变化，未转到今天"
        persistStore(next)
        val moved = next.history.getValue(today).taskGroups[categoryIndex].first { it.id == id && !it.movedToToday }
        if (moved.habiticaTaskId != null) syncExistingTask(id) else syncTaskToHabitica(categoryIndex, moved, today)
        return null
    }

    /** Delete an unfinished task (UI confirms first); queues the remote delete with the usual tombstone. */
    fun deleteUnfinishedTask(dateKey: String, categoryIndex: Int, id: String): Boolean =
        removeTask(dateKey, categoryIndex, id, fromUnfinished = true)

    fun renameCategory(index: Int, newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return
        val s = _state.value.store
        val oldName = s.categoryNames.getOrNull(index) ?: return
        if (oldName == trimmed || s.categoryNames.any { it == trimmed }) return
        val newNames = s.categoryNames.mapIndexed { i, n -> if (i == index) trimmed else n }
        val newTagIds = s.categoryTagIds.toMutableMap()
        val tagId = newTagIds.remove(oldName)
        if (tagId != null) newTagIds[trimmed] = tagId
        persistStore(s.copy(categoryNames = newNames, categoryTagIds = newTagIds,
            pendingTagNames = if (tagId == null) s.pendingTagNames else s.pendingTagNames + (tagId to trimmed)))
        val tasks = _state.value.store.history.values.flatMap { it.taskGroups.getOrNull(index).orEmpty() }.distinctBy { it.id }
        tasks.forEach { task -> replaceTask(task.id) { it.copy(syncPending = true, syncError = null, syncVersion = it.syncVersion + 1) } }
        retryCategoryTags()
        tasks.filter { it.habiticaTaskId != null }.forEach { syncExistingTask(it.id) }
    }

    /** Honor cached IDs and pending offline names; never replace a rename with a new tag POST. */
    private suspend fun resolveCategoryTag(settings: UserSettings, category: String, generation: Int,
        stillValid: () -> Boolean = { true }): HabiticaAPI.Result<String?> {
        if (!stillValid()) return HabiticaAPI.Result.Error("任务同步快照已变化")
        if (!isCurrentAccount(settings, generation)) return HabiticaAPI.Result.Error("账号已变化")
        val current = _state.value.store
        val known = current.categoryTagIds[category]
        if (known != null) {
            val desired = current.pendingTagNames[known]
            if (desired != null) {
                if (desired != category) return HabiticaAPI.Result.Error("分类名称已变化；修改保留")
                val result = habitica(settings) { HabiticaAPI.updateTag(settings, known, desired) }
                if (!stillValid()) return HabiticaAPI.Result.Error("任务同步快照已变化")
                if (!isCurrentAccount(settings, generation)) return HabiticaAPI.Result.Error("账号已变化")
                if (result is HabiticaAPI.Result.Error) return result
            }
            val tags = habitica(settings) { HabiticaAPI.fetchTags(settings) }
            if (!isCurrentAccount(settings, generation)) return HabiticaAPI.Result.Error("账号已变化")
            if (tags is HabiticaAPI.Result.Error) return tags
            if (!stillValid()) {
                return HabiticaAPI.Result.Error("任务同步快照已变化")
            }
            if ((tags as HabiticaAPI.Result.Success).value[category] != known) {
                return HabiticaAPI.Result.Error("分类 tag 改名未确认；本机保留，可重试旧 ID")
            }
            val latest = _state.value.store
            if (latest.categoryTagIds[category] != known || latest.pendingTagNames[known] != desired) return HabiticaAPI.Result.Error("分类名称已变化；修改保留")
            if (desired != null) persistStore(latest.copy(pendingTagNames = latest.pendingTagNames - known))
            return HabiticaAPI.Result.Success(known)
        }
        val result = habitica(settings) { HabiticaAPI.ensureTag(settings, category) }
        if (!stillValid()) return HabiticaAPI.Result.Error("任务同步快照已变化")
        if (!isCurrentAccount(settings, generation)) return HabiticaAPI.Result.Error("账号已变化")
        if (result is HabiticaAPI.Result.Success && !result.value.isNullOrBlank()) {
            val tags = habitica(settings) { HabiticaAPI.fetchTags(settings) }
            if (!isCurrentAccount(settings, generation)) return HabiticaAPI.Result.Error("账号已变化")
            if (tags !is HabiticaAPI.Result.Success || tags.value[category] != result.value) return HabiticaAPI.Result.Error("分类 tag 创建未确认；本机保留")
            if (!stillValid()) return HabiticaAPI.Result.Error("任务同步快照已变化")
            val latest = _state.value.store
            if (category !in latest.categoryNames) return HabiticaAPI.Result.Error("分类名称已变化；修改保留")
            persistStore(latest.copy(categoryTagIds = latest.categoryTagIds + (category to result.value!!)))
        }
        return result
    }

    private fun retryCategoryTags() {
        val settings = _state.value.settings; val generation = accountGeneration
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank()) return
        viewModelScope.launch {
            taskMutex.lock()
            try {
                for (name in _state.value.store.pendingTagNames.values.toSet()) {
                    val result = resolveCategoryTag(settings, name, generation)
                    if (!isCurrentAccount(settings, generation)) return@launch
                    if (result is HabiticaAPI.Result.Error) publishTopThreeError(result.message)
                }
            } finally { taskMutex.unlock() }
        }
    }

    private fun persistStore(s: TopThreeStore): Boolean {
        localRevision++
        // FIX2(D2): a failed save must surface; memory keeps advancing as before.
        val saved = store.saveTopThree(s)
        _state.value = _state.value.copy(store = s,
            persistenceError = if (saved) null else TOP_THREE_PERSIST_FAILED)
        return saved
    }

    /** Creation has no idempotency token: never automatically retry an ambiguous response. */
    private fun syncTaskToHabitica(categoryIndex: Int, task: com.habitica.pomodoro.data.TopThreeTask, dateKey: String) {
        val settings = _state.value.settings
        if (!settings.connectHabitica || !isValidHabiticaUid(settings.uid) || settings.apiToken.isBlank() || task.id in creationIds) return
        if (task.cloudAccount != settings.cloudAccount()) return
        val category = _state.value.store.categoryNames.getOrNull(categoryIndex) ?: return
        val generation = accountGeneration
        creationIds += task.id; creatingTasks++
        viewModelScope.launch {
            try {
                val initial = findTask(task.id) ?: return@launch
                fun unchanged(expected: Triple<String, Int, com.habitica.pomodoro.data.TopThreeTask>): Boolean {
                    if (!isCurrentAccount(settings, generation)) return false
                    val latest = findTask(task.id)
                    if (_state.value.store.cloudAccount == settings.cloudAccount() && expected.third.cloudAccount == settings.cloudAccount() &&
                        latest != null && latest == expected && _state.value.store.categoryNames.getOrNull(latest.second) == category) return true
                    val message = "原创建任务已移除、所属账号或完整快照已变化；本机待同步保留，请人工核对"
                    replaceTask(task.id) { if (it.cloudAccount == settings.cloudAccount()) it.copy(syncError = message) else it }
                    publishTopThreeError(message)
                    return false
                }
                if (!unchanged(initial)) return@launch
                val tag = resolveCategoryTag(settings, category, generation) { unchanged(initial) }
                if (!isCurrentAccount(settings, generation)) return@launch
                if (!unchanged(initial)) return@launch
                if (tag !is HabiticaAPI.Result.Success || tag.value.isNullOrBlank()) {
                    // Blocked before any create was sent: there is no marker to strand, the task just stays pending.
                    val notSent = (tag as? HabiticaAPI.Result.Error)?.takeIf { !it.dispatched }?.message
                    replaceTask(task.id) { it.copy(syncError = notSent?.let { reason -> "$reason 尚未创建 todo，本机任务已保留。" } ?: "分类 tag 同步失败；尚未创建 todo") }
                    return@launch
                }
                // Before creating, reconcile a unique exact owned record (e.g. POST succeeded but response was lost).
                val cloud = habitica(settings) { HabiticaAPI.fetchTopThreeTodos(settings) }
                if (!isCurrentAccount(settings, generation)) return@launch
                if (!unchanged(initial)) return@launch
                if (cloud is HabiticaAPI.Result.Error) { replaceTask(task.id) { it.copy(syncError = cloud.message) }; return@launch }
                val notes = topThreeNotes(category, dateKey)
                val currentTask = findTask(task.id)?.third ?: return@launch
                if (currentTask.habiticaTaskId != null) { syncExistingTask(task.id); return@launch }
                val hasAttempt = currentTask.pendingCreateTitle != null && currentTask.pendingCreateNotes != null
                val matches = if (hasAttempt) (cloud as HabiticaAPI.Result.Success).value.distinctBy { it.id }.filter {
                    it.title == currentTask.pendingCreateTitle && it.notes == currentTask.pendingCreateNotes && !_state.value.store.isTombstoned(it.id)
                } else emptyList()
                val candidates = if (hasAttempt) _state.value.store.pendingCreateCandidates(
                    currentTask.pendingCreateTitle!!, currentTask.pendingCreateNotes!!) else emptyList()
                val occupied = matches.any { _state.value.store.remoteIdOccupied(it.id, task.id) }
                if (hasAttempt && (candidates.singleOrNull()?.id != task.id || matches.size != 1 || occupied)) {
                    replaceTask(task.id) { it.copy(syncError = "先前创建结果不明：云端尚不可见、匹配不唯一或 ID 已绑定其他任务；请稍后核对，未重复 POST") }
                    return@launch
                }
                var bindingSnapshot = findTask(task.id) ?: return@launch
                val created = if (hasAttempt) HabiticaAPI.Result.Success(matches.single().id)
                    else {
                        val latest = findTask(task.id) ?: return@launch
                        val latestCategory = _state.value.store.categoryNames.getOrNull(latest.second) ?: return@launch
                        // The captured category/tag must still describe this UUID at the POST boundary.
                        if (latest.first != dateKey || latest.second != categoryIndex || latestCategory != category || latest.third.syncVersion != currentTask.syncVersion) return@launch
                        val saved = replaceTask(task.id) {
                            it.copy(pendingCreateTitle = latest.third.title, pendingCreateNotes = notes)
                        }
                        if (!saved) {
                            replaceTask(task.id) {
                                it.copy(pendingCreateTitle = null, pendingCreateNotes = null,
                                    syncError = "本机未能保存创建标记；修复存储后可重试")
                            }
                            return@launch
                        }
                        bindingSnapshot = findTask(task.id) ?: return@launch
                        habitica(settings) { HabiticaAPI.createTodo(settings, latest.third.title, notes, listOf(tag.value!!)) }
                    }
                if (!hasAttempt && created is HabiticaAPI.Result.Error && created.definitelyNotCreated()) {
                    // Never sent, or refused outright (401/429): nothing exists remotely. Release this attempt for its
                    // original owner, even after an account switch, so a later manual sync can create it once.
                    releaseRejectedCreate(settings.cloudAccount(), task.id, bindingSnapshot.third.pendingCreateTitle,
                        bindingSnapshot.third.pendingCreateNotes, created.message)
                    return@launch
                }
                if (!isCurrentAccount(settings, generation)) return@launch
                if (created is HabiticaAPI.Result.Success && !created.value.isNullOrBlank()) {
                    val id = created.value!!
                    // Recheck the latest partition at binding, including changes while the POST was in flight.
                    val latestStore = _state.value.store
                    val attemptTitle = bindingSnapshot.third.pendingCreateTitle ?: return@launch
                    val attemptNotes = bindingSnapshot.third.pendingCreateNotes ?: return@launch
                    val deletionMarker = "$attemptNotes\n$attemptTitle"
                    if (findTask(task.id) == null && deletionMarker in latestStore.deletedCreateMarkers && !latestStore.remoteIdOccupied(id, task.id)) {
                        // D1: same enqueue-time id->marker link as retryDeletedCreations.
                        persistStore(latestStore.copy(deletedCloudIds = latestStore.deletedCloudIds + id,
                            deletedCloudIdMarkers = latestStore.deletedCloudIdMarkers + (id to deletionMarker)))
                        deleteCloudTask(id, deletionMarker)
                        return@launch
                    }
                    if (!unchanged(bindingSnapshot)) return@launch
                    if (latestStore.remoteIdOccupied(id, task.id) ||
                        latestStore.pendingCreateCandidates(attemptTitle, attemptNotes).singleOrNull()?.id != task.id) {
                        replaceTask(task.id) { it.copy(syncError = "创建匹配不唯一或远端 ID 已绑定其他本地任务；请人工核对，未重复创建") }
                        return@launch
                    }
                    replaceTask(task.id) { if (it.cloudAccount == settings.cloudAccount()) it.copy(habiticaTaskId = id, syncPending = true, pendingCreateTitle = null, pendingCreateNotes = null, syncVersion = it.syncVersion + 1) else it }
                    syncExistingTask(task.id)
                } else replaceTask(task.id) { it.copy(syncError = "todo 创建结果未确认；本机保留，重试前会先核对云端以避免重复") }
            } finally { creationIds -= task.id; creatingTasks--; rejectableDeletionMarkers.remove(task.id) }
        }
    }

    /**
     * Clear only the exact attempt of this UUID in its owner's partition (active or parked), keep the row
     * pending, and take back a removal marker that was added while this refused POST was in flight.
     */
    private fun releaseRejectedCreate(owner: String?, localId: String, title: String?, notes: String?, reason: String) {
        val pendingRemoval = rejectableDeletionMarkers.remove(localId)
        if (owner == null || title == null || notes == null) return
        val attemptMarker = "$notes\n$title"
        val message = "$reason 本机任务已保留，稍后可手动同步重试。"
        fun release(partition: TopThreeStore): TopThreeStore {
            val history = partition.history.mapValues { (_, day) -> day.copy(taskGroups = day.taskGroups.map { group -> group.map {
                if (it.id == localId && it.cloudAccount == owner && it.habiticaTaskId == null &&
                    it.pendingCreateTitle == title && it.pendingCreateNotes == notes)
                    it.copy(pendingCreateTitle = null, pendingCreateNotes = null, syncPending = true, syncError = message) else it
            } }) }
            val ownRemoval = pendingRemoval == owner to attemptMarker && attemptMarker !in partition.deletedCloudIdMarkers.values
            return partition.copy(history = history,
                deletedCreateMarkers = if (ownRemoval) partition.deletedCreateMarkers - attemptMarker else partition.deletedCreateMarkers)
        }
        val s = _state.value.store
        val next = if (s.cloudAccount == owner) release(s)
            else s.accountStores[owner]?.let { s.copy(accountStores = s.accountStores + (owner to release(it))) } ?: return
        if (next != s) persistStore(next)
        if (s.cloudAccount == owner) publishTopThreeError(message)
    }

    fun todayKey(): String = store.logicalDateKey(_state.value.settings)
    fun yesterdayKey(): String = store.yesterdayKey(_state.value.settings)
    fun isEditable(key: String): Boolean = store.isEditable(key, _state.value.settings)
    fun dataDirectoryPath(): String = store.dataDirectoryPath()

    companion object {
        /** 前 2 个分类（Work/MyOwn）固定槽位，与 Swift TopThreeManager.fixedSlotCategories 一致 */
        private const val FIXED_SLOT_CATEGORIES = TOP_THREE_FIXED_SLOT_CATEGORIES
        private const val MAX_FIXED_TASKS = TOP_THREE_MAX_FIXED_TASKS
        // FIX2(D2): user-visible persistence failure messages.
        private const val TOP_THREE_PERSIST_FAILED = "本地写入失败：Top3 任务数据未保存，重启后本次改动将丢失"
        private const val SETTINGS_PERSIST_FAILED = "本地写入失败：设置未保存，重启后将恢复旧设置"
        /** ambientSource 的栖时取值（与 Apple 端设置 JSON 一致）；其他值一律按 custom 处理 */
        const val AMBIENT_SOURCE_QISHI = "qishi"
        private const val QISHI_LIBRARY_UNAVAILABLE = "栖时场景库不可用（qishi_presets.json 缺失或为空）"
    }
}
