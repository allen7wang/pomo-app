package com.habitica.pomodoro

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.service.PomodoroTimerService
import com.habitica.pomodoro.ui.PomoScreen
import com.habitica.pomodoro.ui.RoleScreen
import com.habitica.pomodoro.ui.SettingsScreen
import com.habitica.pomodoro.ui.TaskScreen
import com.habitica.pomodoro.ui.HabiticaListsScreen
import com.habitica.pomodoro.ui.HistoryScreen
import com.habitica.pomodoro.ui.FocusReviewScreen
import com.habitica.pomodoro.ui.theme.AppUiStyle
import com.habitica.pomodoro.ui.theme.HabiticaPomodoroTheme
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.SkinPaletteButton
import com.habitica.pomodoro.ui.theme.rememberAppSkinState
import com.habitica.pomodoro.ui.theme.resolveDark
import com.habitica.pomodoro.ui.theme.skinBackground
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

class MainActivity : ComponentActivity() {

    private val vm: PomodoroViewModel get() = (application as PomoApplication).engine

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* 拒绝也不阻塞：计时通知仍可显示，仅提醒横幅受限 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        requestNotificationPermissionIfNeeded()

        // Debug-only launch overrides for screenshot passes (adb am start --es previewSkin pixel --ei previewTab 1).
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val previewSkin = intent.getStringExtra("previewSkin")?.takeIf { debuggable }
            ?.let { raw -> AppUiStyle.entries.firstOrNull { it.storageValue == raw } }
        val previewTab = if (debuggable) intent.getIntExtra("previewTab", 0) else 0

        setContent {
            val skins = rememberAppSkinState(previewSkin)
            val style by skins.style
            val dark = style.resolveDark(isSystemInDarkTheme())
            // Re-run on skin change: a forced-dark skin needs light system-bar icons even in light mode.
            DisposableEffect(dark) {
                val bars = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
                onDispose { }
            }
            HabiticaPomodoroTheme(style = style) {
                Box(modifier = Modifier.fillMaxSize().skinBackground(LocalSkin.current)) {
                    RootTabs(vm, skins, previewTab)
                }
            }
        }
        dispatchNotificationAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        dispatchNotificationAction(intent)
    }

    private fun dispatchNotificationAction(actionIntent: Intent?) {
        if (actionIntent?.action !in setOf(PomodoroTimerService.ACTION_PAUSE,
                PomodoroTimerService.ACTION_RESUME, PomodoroTimerService.ACTION_STOP)) return
        vm.handleNotificationAction(actionIntent?.action,
            actionIntent?.getStringExtra(PomodoroTimerService.EXTRA_SESSION))
        // Do not replay a notification action when the activity is recreated.
        setIntent(Intent(this, MainActivity::class.java))
    }

    override fun onResume() {
        super.onResume()
        // 回前台按绝对结束时刻重算剩余时间；后台已结束的阶段补触发结束逻辑
        vm.resyncAfterForeground()
        vm.attachTimerService()
    }

    /** Android 13+ 需运行时授权通知；首次启动时请求一次 */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

/** Six compact destinations; Habits and Dailies share one live Habitica page. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RootTabs(vm: PomodoroViewModel, skins: com.habitica.pomodoro.ui.theme.AppSkinState, initialTab: Int = 0) {
    var selected by rememberSaveable { mutableIntStateOf(initialTab.coerceIn(0, 5)) }
    var reviewOpen by rememberSaveable { mutableStateOf(false) }
    val state by vm.state.collectAsStateWithLifecycle()
    val skin = LocalSkin.current
    val c = skin.colors
    val dateLine = remember { LocalDate.now().format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.CHINA)) }
    val navColors = NavigationBarItemDefaults.colors(
        selectedIconColor = c.accent,
        selectedTextColor = c.accent,
        indicatorColor = c.accentSoft,
        unselectedIconColor = c.muted,
        unselectedTextColor = c.muted,
    )

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(dateLine, style = MaterialTheme.typography.labelLarge, color = c.muted) },
                actions = { SkinPaletteButton(skins) },
                expandedHeight = 48.dp,
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = Color.Transparent,
                    actionIconContentColor = c.muted,
                ),
            )
        },
        containerColor = Color.Transparent,
        bottomBar = {
            NavigationBar(
                containerColor = c.surface,
                tonalElevation = 0.dp,
                modifier = Modifier.drawWithContent {
                    drawContent()
                    // Hairline (ink rule in pixel) instead of a tonal elevation step.
                    val stroke = if (skin.isPixel) 2.dp.toPx() else 1.dp.toPx()
                    drawLine(if (skin.isPixel) c.ink else c.line, Offset(0f, stroke / 2f), Offset(size.width, stroke / 2f), stroke)
                },
            ) {
                NavigationBarItem(
                    selected = selected == 0,
                    onClick = { selected = 0 },
                    icon = { Icon(Icons.Filled.Timer, contentDescription = null) },
                    label = { Text("Pomo") },
                    colors = navColors,
                )
                NavigationBarItem(
                    selected = selected == 1,
                    onClick = { selected = 1 },
                    icon = { Icon(Icons.Filled.Star, contentDescription = null) },
                    label = { Text("Task") },
                    colors = navColors,
                )
                NavigationBarItem(
                    selected = selected == 2,
                    onClick = { selected = 2 },
                    icon = { Icon(Icons.Filled.Favorite, contentDescription = null) },
                    label = { Text("打卡") },
                    colors = navColors,
                )
                NavigationBarItem(
                    selected = selected == 3,
                    onClick = { selected = 3 },
                    icon = { Icon(Icons.Filled.DateRange, contentDescription = null) },
                    label = { Text("历史") },
                    colors = navColors,
                )
                NavigationBarItem(
                    selected = selected == 4,
                    onClick = { selected = 4 },
                    icon = { Icon(Icons.Filled.Person, contentDescription = null) },
                    label = { Text("角色") },
                    colors = navColors,
                )
                NavigationBarItem(
                    selected = selected == 5,
                    onClick = { selected = 5 },
                    icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                    label = { Text("设置") },
                    colors = navColors,
                )
            }
        },
    ) { innerPadding ->
        val modifier = Modifier
            .fillMaxSize()
            .padding(innerPadding)

        when (selected) {
            0 -> PomoScreen(vm = vm, state = state, modifier = modifier)
            1 -> TaskScreen(vm = vm, state = state, onFocusStarted = { selected = 0 }, modifier = modifier)
            2 -> HabiticaListsScreen(vm = vm, state = state, modifier = modifier)
            3 -> if (reviewOpen) FocusReviewScreen(state = state, onBack = { reviewOpen = false }, modifier = modifier)
                else HistoryScreen(vm = vm, state = state, modifier = modifier, onOpenReview = { reviewOpen = true })
            4 -> RoleScreen(vm = vm, state = state, modifier = modifier)
            5 -> SettingsScreen(vm = vm, state = state, skins = skins, modifier = modifier)
        }
    }
}
